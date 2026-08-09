import Foundation
import simd

import MolEnvParse
import MolEnvSpglib

enum ParseError: Error, CustomStringConvertible {
    case parse(path: String, line: Int, reason: String)
    case io(path: String, reason: String)
    var description: String {
        switch self {
        case .parse(let p, let line, let r): return "\(p):\(line): \(r)"
        case .io(let p, let r): return "\(p): \(r)"
        }
    }
}

/// Decompress a gzip file without loading a C parser with compressed bytes.
/// Read stdout before waiting so large files cannot deadlock on a full pipe.
internal func gunzipData(_ url: URL) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    process.arguments = ["-c", url.path]
    let output = Pipe()
    process.standardOutput = output
    do {
        try process.run()
    } catch {
        throw ParseError.io(path: url.path, reason: "could not launch gunzip: \(error)")
    }
    var total = 0
    let limit = 200 * 1024 * 1024
    var data = Data()
    func finish() {
        process.terminate()
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
    var capped = false
    while true {
        let bytes = output.fileHandleForReading.availableData
        if bytes.isEmpty { break }
        total += bytes.count
        if total > limit {
            capped = true
            finish()
            throw ParseError.io(path: url.path, reason: "decompressed data exceeds 200 MB limit")
        }
        data.append(bytes)
    }
    finish()
    guard !capped, process.terminationStatus == 0 else {
        throw ParseError.io(path: url.path, reason: "gunzip failed (exit \(process.terminationStatus))")
    }
    return data
}

/// Read a text file with a size cap, mirroring gunzipData's 200 MB bound.
/// Pre-checks the on-disk size, then reads through FileHandle so a malformed
/// file cannot allocate unbounded memory before the cap is detected.
fileprivate func readCappedText(_ url: URL, cap: Int = 200 * 1024 * 1024) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let fileSize = attributes[.size] as? Int, fileSize > cap {
        throw ParseError.io(path: url.path, reason: "file size \(fileSize) exceeds \(cap) byte limit")
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        throw ParseError.io(path: url.path, reason: "could not open file for reading")
    }
    defer { try? handle.close() }
    var data = Data()
    while true {
        guard let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty else { break }
        data.append(chunk)
        if data.count > cap {
            throw ParseError.io(path: url.path, reason: "file exceeds \(cap) byte limit")
        }
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw ParseError.io(path: url.path, reason: "file is not valid UTF-8")
    }
    return text
}

/// Whether the loaded atom list is sufficient for a truthful space-group
/// analysis. The C parser records per-file completeness (complete, asymmetric
/// unit, or unknown) in `MolEnvScene.symmetry_completeness`; CIF files may
/// report any of the three. CRYSCAL files commonly contain only an asymmetric
/// unit; numeric and unambiguous symbolic cubic CRYSTAL groups are expanded
/// during loading, while the remaining CRYSCAL scopes stay incomplete.
enum SymmetryInputCompleteness: Equatable {
    case complete
    case asymmetricUnit
    case unknown

    var symmetryUnavailableReason: String {
        switch self {
        case .complete:
            return ""
        case .asymmetricUnit:
            return "symmetry unavailable: the file contains an asymmetric unit; operation expansion is deferred"
        case .unknown:
            return "symmetry unavailable: the file's symmetry-input completeness is unknown"
        }
    }

    /// Map the C `symmetry_completeness` field (0 = complete, 1 = asymmetric
    /// unit, 2 = unknown) to the Swift enum, defaulting unexpected values to
    /// `.unknown` so completeness is never falsely claimed.
    static func fromC(_ raw: Int32) -> SymmetryInputCompleteness {
        switch raw {
        case 0: return .complete
        case 1: return .asymmetricUnit
        case 2: return .unknown
        default: return .unknown
        }
    }
}

struct LoadedScene {
    var atoms: [Atom] = []
    var bonds: [Bond] = []
    var cell: Cell?
    var isCrystal: Bool = false
    var periodicDim: Int = 3
    var title: String = ""
    var scalarField: ScalarField?
    var fermiSurface: FermiSurface?
    var bandStructure: BandStructure?
    var densityOfStates: DensityOfStates?
    var forceSet: ForceSet?
    var grid2D: Grid2D?
    var multiOrbitalFields: [ScalarField] = []
    var symmetryInputCompleteness: SymmetryInputCompleteness = .complete
}

private struct CRYSCALFractionalSite {
    let fractional: SIMD3<Double>
    let atomicNumber: Int
    let label: String
}

private struct CRYSCALDedupKey: Hashable {
    let atomicNumber: Int
    let x: Int64
    let y: Int64
    let z: Int64
}

/// A parser format that can be forced via a CLI flag (`--xsf`, `--pdb`, ...).
/// When omitted, `Parser.load` falls back to the file extension.
enum ParseFormat: Equatable {
    case xsf, axsf, xyz, pdb, pwi, pwo, cif, poscar, cube, bxsf, struct_, crystal, orca, fhi, bands, dos, gzmat, crystalBand, crystalDOS
    /// Map a lowercased path extension to a format. Returns nil if unknown.
    init?(ext: String) {
        switch ext.lowercased() {
        case "xsf": self = .xsf
        case "axsf": self = .axsf
        case "xyz": self = .xyz
        case "pdb": self = .pdb
        case "pwi", "in", "inp": self = .pwi
        // NOTE (.out collision): `.out` maps to QE's .pwo — XCrySDen's own convention,
        // and QE output commonly uses .out. Orca/FHI output (which also use .out) are
        // reachable via their dedicated .orca/.fhi extensions and the --orca/--fhi
        // flags. Removing `.out`->.pwo would break legitimate QE .out files, so the
        // collision is accepted; a user with an Orca/FHI .out must rename or use the flag.
        case "pwo", "out": self = .pwo
        case "cif": self = .cif
        case "poscar", "contcar", "vasp": self = .poscar
        case "cube", "g98": self = .cube
        case "bxsf": self = .bxsf
        case "struct": self = .struct_
        case "r1": self = .crystal
        case "orca": self = .orca
        case "fhi", "coord": self = .fhi
        case "bands": self = .bands
        case "dos", "pdos", "pdos_tot": self = .dos
        case "gzmat", "zmat": self = .gzmat
        case "band", "fort9": self = .crystalBand
        case "doss", "fort8": self = .crystalDOS
        default: return nil
        }
    }

    /// Resolve a format from a URL, peeling a trailing `.gz` layer so gzip-wrapped
    /// formats (`.bxsf.gz`) dispatch to their own parser. `pathExtension` alone would
    /// yield only `gz`; when it is, we look one layer deeper at the stem's extension.
    static func from(url: URL) -> ParseFormat? {
        if url.lastPathComponent.lowercased() == "geometry.in" { return .fhi }
        // projwfc.x uses names such as `prefix.pdos_tot` and
        // `prefix.pdos_atm#1(Fe)_wfc#2(p)`, whose full suffix is not a fixed
        // extension. Route the whole standard filename family to DOSParser.
        if url.lastPathComponent.lowercased().contains(".pdos_") { return .dos }
        let ext = url.pathExtension.lowercased()
        if let f = ParseFormat(ext: ext) {
            // `.out` is ambiguous: QE PWscf, ORCA and FHI-aims all use it. When the
            // extension alone can't decide, sniff the header and let content win.
            if ext == "out", let detected = sniffOutFormat(url) { return detected }
            return f
        }
        if ext == "gz", let f = ParseFormat(ext: url.deletingPathExtension().pathExtension.lowercased()) {
            return f
        }
        // CRYSTAL band/DOS properties files historically carry no recognized
        // extension (Fortran units 9 and 8, e.g. "fort.9"/"fortran.9", and
        // "band"/"doss" stems). Route by full filename only as a fallback AFTER
        // the extension table, so a file like `band.xyz` or `doss.pdb` keeps its
        // well-known format instead of being hijacked.
        let name = url.lastPathComponent.lowercased()
        let fortranUnit = name.hasPrefix("fort") || name.contains("fort.")
                          || name.hasPrefix("fortran")
        if fortranUnit, let digits = name.split(whereSeparator: { !$0.isNumber }).last,
           digits == "9" || digits == "8" || digits == "09" || digits == "08" {
            if digits == "8" || digits == "08" { return .crystalDOS }
            return .crystalBand
        }
        if name.hasPrefix("band") || name == "band" { return .crystalBand }
        if name.hasPrefix("doss") || name == "doss" { return .crystalDOS }
        return nil
    }

    /// Peek the first lines of an `.out` file to tell QE / Orca / FHI-aims apart. CHECK
    /// QE FIRST: a QE output can mention "orca" (e.g. in a methods comparison) within its
    /// first 4 KB, so the broad substring must not pre-empt the authoritative PWSCF marker.
    ///   - QE PWscf: opens with "Program PWSCF".
    ///   - Orca: the spaced "O   R   C   A" banner (matched literally — not the bare word
    ///     "orca", which false-positives on incidental mentions in other codes' output).
    ///   - FHI-aims COORD.OUT: starts directly with three lattice-vector float-triples.
    /// Anything else falls back to QE (the most common .out producer).
    private static func sniffOutFormat(_ url: URL) -> ParseFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), let head = String(data: data, encoding: .utf8) else { return nil }
        // 1) QE first — it is the common case and can mention other code names.
        if head.contains("Program PWSCF") || head.contains("PWSCF") { return .pwo }
        // 2) Orca by its specific spaced banner only.
        if head.contains("O   R   C   A") { return .orca }
        // 3) FHI-aims: first three non-blank lines must each be exactly three floats.
        let lines = head.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count >= 3 && lines[0...2].allSatisfy({ isNumericTriple($0) }) { return .fhi }
        return nil   // leave as the extension default (.pwo) chosen by the caller
    }

    /// True if `s` is exactly three whitespace-separated floats (a lattice-vector row).
    private static func isNumericTriple(_ s: String) -> Bool {
        let toks = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard toks.count == 3 else { return false }
        return toks.allSatisfy { Float($0) != nil }
    }
}

enum Parser {
    /// Load a structure file. When `format` is nil, the parser is chosen from
    /// the URL's path extension; otherwise the forced format wins.
    /// Load a structure file, optionally forcing the parser format AND/OR a
    /// specific animation frame. A negative `frameIndex` means "no frame was
    /// explicitly requested" (the default-open path): for the animated formats
    /// the single-frame path is used (ORCA shows its final geometry, AXSF/pwo show
    /// cycle 0). A non-negative index ( INCLUDING zero) means a specific cycle was
    /// requested via --frame N and is always routed through the indexed loader, so
    /// --frame 0 returns the first cycle rather than ORCA's final geometry. This is
    /// what lets the open view, the scrubber and --frame N agree on frame N.
    static func load(_ url: URL, as format: ParseFormat? = nil, frameIndex: Int = -1) throws -> LoadedScene {
        if frameIndex >= 0 {
            // An explicit frame was requested -- honor the forced format too (e.g. a
            // renamed .pwo passed as --pwo --frame 1) and route to the per-format
            // frame loader (only orca/pwo/axsf are multi-frame; for anything else the
            // index is simply ignored by the single-frame path below).
            let effective = format ?? ParseFormat.from(url: url)
            switch effective {
            case .orca, .pwo, .axsf:
                return try load(url, frameIndex: frameIndex, as: format)
            default:
                break   // non-animated format: fall through to the single-frame path
            }
        }
        return try load(url, as: format)
    }

    static func load(_ url: URL, as format: ParseFormat? = nil) throws -> LoadedScene {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParseError.io(path: url.path, reason: "file not found")
        }
        let effective = format ?? ParseFormat.from(url: url)
        guard let effective else {
            throw ParseError.io(path: url.path, reason: "unknown extension \(url.pathExtension)")
        }
        // The C XSF parser uses fopen and cannot consume gzip bytes directly.
        // Decompress to a short-lived file, then use the normal bridge so all
        // structure and DATAGRID copying still follows one path.
        if effective == .xsf, url.pathExtension.lowercased() == "gz" {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcrysden-\(UUID().uuidString).xsf")
            try gunzipData(url).write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            return try load(temporary, as: .xsf)
        }
        // Gaussian cube is a pure-text volumetric format parsed entirely in Swift
        // (it produces atoms + a scalarField but no C MolEnvScene).
        if effective == .cube {
            return try loadCube(url)
        }
        // Fermi-surface BXSF: parsed in Swift into bands (a FermiSurface) that
        // Renderer surfaces is the Fermi level — no C MolEnvScene needed.
        if effective == .bxsf {
            return try loadBXSF(url)
        }
        // WIEN2k .struct: a crystal structure in WIEN2k's own text layout — parsed
        // in Swift (XCrySDen shells to an external struct2xsf for this format).
        if effective == .struct_ {
            return try loadWIEN2kStruct(url)
        }
        // CRYSCAL .r1: XCrySDe's own crystal/molecule/slab input — parsed in Swift.
        if effective == .crystal {
            return try loadCRYSCALr1(url)
        }
        // Orca .out geometry-optimization log: parsed in Swift. Each optimization
        // cycle is a CARTESIAN COORDINATES (ANGSTROEM) block => multi-frame. The
        // indexed loader (reached via load(_:frameIndex:)) honors an explicit cycle;
        // the default-open path shows the first cycle, matching AXSF/pwo so the
        // scrubber (which starts at frame 0) and the open view agree on frame N.
        if effective == .orca {
            return try loadOrca(url, frameIndex: 0)
        }
        // FHI-aims coord.out: a structure file (lattice vectors + species blocks)
        // parsed in Swift (XCrySDen shells to an external fhi_coord2xcr for this).
        if effective == .fhi {
            return try loadFHIaims(url)
        }
        // QE PWscf band structure: parsed in Swift into a BandStructure for the
        // 2D Grapher (no atoms/cell -> no C MolEnvScene).
        if effective == .bands {
            return try loadBands(url)
        }
        // Total/projected DOS text is parsed in Swift and displayed by the DOS
        // grapher; it intentionally carries no atom or cell geometry.
        if effective == .dos {
            let text = try readCappedText(url)
            guard let densityOfStates = DOSParser.parse(text, sourceName: url.lastPathComponent) else {
                throw ParseError.parse(path: url.path, line: 0, reason: "invalid DOS data")
            }
            var out = LoadedScene()
            out.title = url.lastPathComponent
            out.densityOfStates = densityOfStates
            return out
        }
        // Gaussian Z-matrix (.gzmat): internal coordinates (bonds/angles/
        // dihedrals) converted to Cartesian by GZMatrixParser. Molecule only —
        // no cell, no periodicity.
        if effective == .gzmat {
            let text = try readCappedText(url)
            guard let atoms = GZMatrixParser.parse(text), !atoms.isEmpty else {
                let detail = GZMatrixError.get() ?? "invalid Gaussian Z-matrix"
                throw ParseError.parse(path: url.path, line: 0, reason: detail)
            }
            var out = LoadedScene()
            out.title = url.lastPathComponent
            out.atoms = atoms
            out.isCrystal = false
            out.periodicDim = 0
            return out
        }
        // CRYSTAL band-structure properties file (BAND, historically fort.9):
        // parsed in Swift into a BandStructure for the 2D grapher.
        if effective == .crystalBand {
            let text = try readCappedText(url)
            guard let bands = CrystalBandParser.parse(text) else {
                throw ParseError.parse(path: url.path, line: 0, reason: "invalid CRYSTAL band file")
            }
            var out = LoadedScene()
            out.title = url.lastPathComponent
            out.bandStructure = bands
            return out
        }
        // CRYSTAL DOS properties file (DOSS, historically fort.8): energy grid +
        // total/projected DOS tables, rendered by the DOS grapher.
        if effective == .crystalDOS {
            let text = try readCappedText(url)
            guard let dos = CrystalDOSParser.parse(text) else {
                throw ParseError.parse(path: url.path, line: 0, reason: "invalid CRYSTAL DOS file")
            }
            var out = LoadedScene()
            out.title = url.lastPathComponent
            out.densityOfStates = dos
            return out
        }
        // QE PWscf output (.pwo): structure (atoms/cell) via the C parser, plus
        // forces/energy/stress parsed in Swift from the raw text and attached to
        // the scene. Forces correspond to the final SCF iteration (the one the
        // user sees). Without this the .pwo path would return forces nowhere.
        if effective == .pwo {
            return try loadPWO(url, frameIndex: 0)
        }
        let cPath = url.path.cString(using: .utf8)!
        let scene: UnsafeMutablePointer<MolEnvScene>?
        switch effective {
        case .xsf: scene = parse_xsf(cPath)
        case .xyz: scene = parse_xyz(cPath)
        case .pdb: scene = parse_pdb(cPath)
        case .axsf: scene = parse_axsf(cPath, 0)
        case .pwi: scene = parse_pwi(cPath)
        case .pwo: scene = parse_pwo(cPath, 0)
        case .cif: scene = parse_cif(cPath)
        case .poscar: scene = parse_poscar(cPath)
        case .cube: scene = nil   // Gaussian cube is parsed in Swift (see loadCube)
        case .bxsf: scene = nil   // Fermi-surface BXSF is parsed in Swift (see loadBXSF)
        case .struct_: scene = nil   // WIEN2k .struct is parsed in Swift (see loadWIEN2kStruct)
        case .crystal: scene = nil   // CRYSCAL .r1 is parsed in Swift (see loadCRYSCALr1)
        case .orca: scene = nil   // Orca .out is parsed in Swift (see loadOrca)
        case .fhi: scene = nil   // FHI-aims coord.out is parsed in Swift (see loadFHIaims)
        case .bands: scene = nil   // QE bands are parsed in Swift (see loadBands)
        case .dos: scene = nil     // DOS is parsed in Swift above
        case .gzmat: scene = nil   // Z-matrix is parsed in Swift (see GZMatrixParser)
        case .crystalBand: scene = nil   // CRYSTAL band is parsed in Swift
        case .crystalDOS: scene = nil    // CRYSTAL DOS is parsed in Swift
        }
        guard let scene else {
            let msg = String(cString: molenv_last_error())
            // "path:line: reason" (line may be 0, written as "path: reason").
            // Locate the last "<digits>:" group before the reason.
            var path = url.path, line = 0, reason = msg
            if let match = msg.range(of: #"^(.+):(\d+):\s?(.*)$"#, options: .regularExpression) {
                let body = String(msg[match])
                let parts = body.components(separatedBy: ":")
                if parts.count >= 3, let n = Int(parts[parts.count-2]) {
                    path = parts[0..<parts.count-2].joined(separator: ":")
                    line = n
                    reason = parts[parts.count-1].trimmingCharacters(in: .whitespaces)
                }
            }
            throw ParseError.parse(path: path, line: line, reason: reason)
        }
        defer { molenv_scene_free(scene) }
        return copyOut(scene.pointee)
    }

    /// Number of animation frames in an animated file: ANIMSTEPS for AXSF, or
    /// ATOMIC_POSITIONS-block count for QE .pwo output. 0 for any single-frame
    /// / non-animated / unreadable file. Lets the GUI decide whether to show
    /// the playback controls at all. `format` forces the parser when the
    /// extension is ambiguous or was renamed.
    static func frameCount(_ url: URL, as format: ParseFormat? = nil) -> Int {
        let cPath = url.path.cString(using: .utf8)!
        let effective = format ?? ParseFormat.from(url: url)
        switch effective {
        case .pwo: return Int(molenv_pwo_frame_count(cPath))
        case .orca: return orcaCycleCount(url)
        default: return Int(molenv_axsf_frame_count(cPath))
        }
    }

    static func load(_ url: URL, frameIndex: Int, as format: ParseFormat? = nil) throws -> LoadedScene {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParseError.io(path: url.path, reason: "file not found")
        }
        let cPath = url.path.cString(using: .utf8)!
        // Choose the per-format frame loader honoring a forced format. AXSF is
        // the original animated format; QE .pwo output adds ionic steps as
        // frames via parse_pwo.
        let effective = format ?? ParseFormat.from(url: url)
        // Orca is parsed in Swift (its own multi-frame path) — route it before
        // the C parsers so frameIndex reaches loadOrca.
        if effective == .orca {
            return try loadOrca(url, frameIndex: frameIndex)
        }
        // QE .pwo: structure via C, forces/energy/stress in Swift. Routed here
        // (before the C switch) so frameIndex reaches loadPWO for animated output.
        if effective == .pwo {
            return try loadPWO(url, frameIndex: frameIndex)
        }
        let scene: UnsafeMutablePointer<MolEnvScene>?
        switch effective {
        case .pwo: scene = parse_pwo(cPath, Int32(frameIndex))
        case .axsf: scene = parse_axsf(cPath, Int32(frameIndex))
        default: scene = parse_axsf(cPath, Int32(frameIndex))
        }
        guard let scene else {
            let msg = String(cString: molenv_last_error())
            var path = url.path, line = 0, reason = msg
            if let match = msg.range(of: #"^(.+):(\d+):\s?(.*)$"#, options: .regularExpression) {
                let body = String(msg[match]); let parts = body.components(separatedBy: ":")
                if parts.count >= 3, let n = Int(parts[parts.count-2]) {
                    path = parts[0..<parts.count-2].joined(separator: ":"); line = n
                    reason = parts[parts.count-1].trimmingCharacters(in: .whitespaces)
                }
            }
            throw ParseError.parse(path: path, line: line, reason: reason)
        }
        defer { molenv_scene_free(scene) }
        return copyOut(scene.pointee)
    }

    private static func copyOut(_ s: MolEnvScene) -> LoadedScene {
        var s = s
        var out = LoadedScene()
        out.symmetryInputCompleteness = SymmetryInputCompleteness.fromC(s.symmetry_completeness)
        out.isCrystal = s.is_crystal != 0
        out.periodicDim = Int(s.periodic_dim)
        out.title = withUnsafePointer(to: &s.title) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        out.atoms = readAtoms(s)
        out.bonds = readBonds(s)
        // A DATAGRID block is either 3D (a volumetric ScalarField) or 2D (a flat
        // color-plane grid). The C parser records which in g.dim; bridge each to
        // its own field so the right renderer/overlay wins.
        if let gPtr = s.grid {
            let dim = gPtr.pointee.dim
            if dim == 2 { out.grid2D = readGrid2D(gPtr.pointee) }
            else { out.scalarField = readGrid(gPtr.pointee) }
        }
        if s.is_crystal != 0 {
            let cell = withUnsafePointer(to: &s.cell) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: 9) {
                    Array(UnsafeBufferPointer(start: $0, count: 9))
                }
            }
            out.cell = Cell(a: SIMD3(cell[0], cell[1], cell[2]),
                           b: SIMD3(cell[3], cell[4], cell[5]),
                           c: SIMD3(cell[6], cell[7], cell[8]))
        }
        return out
    }

    private static func readAtoms(_ s: MolEnvScene) -> [Atom] {
        let natoms = Int(s.natoms)
        guard natoms > 0, let atomsPtr = s.atoms else { return [] }
        // Read each MolEnvAtom BY FIELD, not by a hand-computed byte offset. The
        // Swift/C bridge imports the C layout verbatim, so every access below is
        // compiled against the real field offsets of `struct MolEnvAtom`. If that
        // struct is ever relaid out or a field renamed, this fails to compile
        // instead of silently mapping coordinates, Z and label onto the wrong
        // bytes (which was the risk of the raw-offset version above).
        let buffer = UnsafeBufferPointer(start: atomsPtr, count: natoms)
        return buffer.map { a -> Atom in
            let coord = a.coord
            let atomicNumber = Int(a.atomic_number)
            return Atom(coord: SIMD3<Float>(coord.0, coord.1, coord.2),
                        atomicNumber: atomicNumber,
                        label: labelString(a.label))
        }
    }

    /// Convert a C `char label[8]` (imported as an 8-CChar tuple) into a String,
    /// stopping at the first NUL. The C parsers always NUL-terminate via
    /// `snprintf(..., sizeof-1)`, so at least the final byte is `\0`.
    private static func labelString(_ label: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
        let all = [label.0, label.1, label.2, label.3, label.4, label.5, label.6, label.7]
        let end = all.firstIndex(of: 0) ?? all.count
        var chars = Array(all[0..<end])
        chars.append(0)
        return chars.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func readBonds(_ s: MolEnvScene) -> [Bond] {
        let nbonds = Int(s.nbonds)
        guard nbonds > 0, let bondsPtr = s.bonds else { return [] }
        let buf = UnsafeBufferPointer(start: bondsPtr, count: nbonds)
        return buf.map { Bond(i: Int($0.i), j: Int($0.j)) }
    }

    /// Bridge a C `MolEnvGrid` (a 3D `DATAGRID_3D` block) into a Swift
    /// `ScalarField`. The grid index layout in C is x-fastest (i + nx*(j + ny*k)),
    /// matching `ScalarField.index`.
    private static func readGrid(_ g: MolEnvGrid) -> ScalarField? {
        guard let valuesPtr = g.values else { return nil }
        // C fixed-size arrays surface in Swift as tuples, so fields like `g.n`
        // and `g.orig` are addressed by `.0/.1/.2` rather than subscripts.
        let nx = Int(g.n.0), ny = Int(g.n.1), nz = Int(g.n.2)
        guard nx > 0, ny > 0, nz > 0 else { return nil }
        let count = nx * ny * nz
        let values = UnsafeBufferPointer(start: valuesPtr, count: count).map { $0 }
        let orig = SIMD3<Float>(g.orig.0, g.orig.1, g.orig.2)
        let vec = [
            SIMD3<Float>(g.vec.0.0, g.vec.0.1, g.vec.0.2),
            SIMD3<Float>(g.vec.1.0, g.vec.1.1, g.vec.1.2),
            SIMD3<Float>(g.vec.2.0, g.vec.2.1, g.vec.2.2),
        ]
        return ScalarField(nx: nx, ny: ny, nz: nz, origin: orig, vec: vec,
                           values: values, minValue: g.minval, maxValue: g.maxval)
    }

    /// Bridge a C `MolEnvGrid` whose `dim == 2` (a `DATAGRID_2D` block) into a
    /// Swift `Grid2D` for the color-plane overlay. The 2D grid is stored in C as
    /// nx*ny (nz==1), x-fastest; we reshape it to row-major `values[row][col]`.
    private static func readGrid2D(_ g: MolEnvGrid) -> Grid2D? {
        guard let valuesPtr = g.values else { return nil }
        let cols = Int(g.n.0), rows = Int(g.n.1)
        guard cols > 0, rows > 0 else { return nil }
        let flat = UnsafeBufferPointer(start: valuesPtr, count: cols * rows).map { $0 }
        var values: [[Float]] = []
        values.reserveCapacity(rows)
        for r in 0..<rows {
            let start = r * cols
            values.append(Array(flat[start..<start + cols]))
        }
        let orig = SIMD3<Float>(g.orig.0, g.orig.1, g.orig.2)
        let vec = [
            SIMD3<Float>(g.vec.0.0, g.vec.0.1, g.vec.0.2),
            SIMD3<Float>(g.vec.1.0, g.vec.1.1, g.vec.1.2),
        ]
        // C fixed-size char arrays surface as tuples; rebind to read a C string.
        var g = g
        let ident = withUnsafePointer(to: &g.ident) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        return Grid2D(cols: cols, rows: rows, origin: orig, vec: vec,
                      values: values, minValue: g.minval, maxValue: g.maxval,
                      ident: ident)
    }

    // Gaussian "cube" format (Gaussian, Q-Chem, ...): a text header in Bohr
    // describing a rectilinear grid + atom list, then x-fastest volumetric values.
    // We read atoms + the scalar grid into a LoadedScene. Same ordering
    // convention as DATAGRID_3D (x fastest, v(i) = (n(i)-1)*dx(i)), confirmed by
    // XCrySDen's cube2xsf.f. Units are Bohr -> convert to Angstrom (B2A).
    /// Bridge a Fermi-surface BXSF into a LoadedScene: the bands become scene.fermiSurface
    /// and the first band is also exposed as scalarField so the existing iso pipeline
    /// has a default surface; the FermiSurface drives multi-band rendering.
    private static func loadBXSF(_ url: URL) throws -> LoadedScene {
        let fs = try BXSFLoader.load(from: url)
        var out = LoadedScene()
        out.title = url.lastPathComponent
        // Do NOT also set scalarField to the first band: drawFermiSurface already
        // surfaces every band at the Fermi level, and the iso pipeline would draw
        // that one band again at the sidebar midpoint — a duplicate, wrong shell.
        out.fermiSurface = fs
        return out
    }

    /// WIEN2k .struct crystal structure. Layout (verified against XCrySDen's
    /// struct2xsf and the 24-fixture WIEN2k example set):
    ///   <title>
    ///   <F|P|C>   LATTICE,NONEQUIV. ATOMS  <natoms>
    ///   MODE OF CALC=RELA|NONREL|...
    ///   <a> <b> <c> <alpha> <beta> <gamma>      (a,b,c in Bohr, angles degrees)
    ///   [per atom:]
    ///   ATOM= <i>: X=<x> Y=<y> Z=<z>          (fractional)
    ///          MULT= <m>  ISPLIT= <s>
    ///   <Element>   NPT= <> R0= <> RMT= <> Z: <Z>
    ///   [optional 3x3 local-rotation matrix, 3 lines]
    ///   [ <nsym> SYMMETRY OPERATIONS: ... ]
    /// a,b,c are converted Bohr->Angstrom. Fractional atoms are cartesianized via
    /// the cell; MULT replicates a site m times to consecutive atoms (all same Z).
    private static func loadWIEN2kStruct(_ url: URL) throws -> LoadedScene {
        let raw = try readCappedText(url)
        let lines = raw.components(separatedBy: "\n")
        enum E: Error { case malformed(String) }
        func tok(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        var idx = 0
        func nextLine() -> String? { guard idx < lines.count else { return nil }; defer { idx += 1 }; return lines[idx] }

        // title (first line, may be blank)
        _ = nextLine()

        // lattice line: "<F|P|C>   LATTICE,NONEQUIV. ATOMS  <nat>"
        guard let latLine = nextLine() else { throw E.malformed("empty") }
        let latToks = tok(latLine)
        // Cap declared atoms: the reading loop honors this count, so an
        // absurd value must be rejected before it can drive unbounded work.
        guard let natoms = latToks.last.flatMap(Int.init), natoms > 0, natoms <= 500_000 else {
            throw E.malformed("bad atom count: \(latLine)")
        }
        _ = nextLine()   // MODE OF CALC=...

        // lattice params
        guard let pLine = nextLine() else { throw E.malformed("no cell") }
        // WIEN2k's Fortran cell-param line can glue adjacent floats when a field
        // overflows (e.g. "90.000000120.000000") and may run to several lines, so
        // scan for the first 6 floats rather than whitespace-splitting.
        func scanFloats(_ s: String) -> [Float] {
            var out: [Float] = []
            let pattern = #"[+-]?\d+\.?\d*(?:[eE][+-]?\d+)?"#
            if let rx = try? NSRegularExpression(pattern: pattern) {
                let ns = s as NSString
                for m in rx.matches(in: s, range: NSRange(location:0, length:ns.length)) {
                    if let v = Float(ns.substring(with: m.range)) { out.append(v) }
                }
            }
            return out
        }
        var params = scanFloats(pLine)
        while params.count < 6, let more = nextLine() { params += scanFloats(more) }
        // Reject non-finite params before Cell.fromLattice can turn them into
        // its zero-cell sentinel (Float("nan") parses as non-nil but isNaN).
        guard params.count >= 6, params.allSatisfy(\.isFinite) else {
            throw E.malformed("bad cell params")
        }
        let (a, b, c) = (params[0], params[1], params[2])
        let (alpha, beta, gamma) = (params[3], params[4], params[5])
        let cell = Cell.fromLattice(a: a * b2a, b: b * b2a, c: c * b2a,
                                    alpha: alpha, beta: beta, gamma: gamma)

        // Read atom SITES. Each site:
        //   "ATOM= <i>: X=.. Y=.. Z=.."   (or "Atom <i>: ...")  <- 1st position
        //   MULT= <m>  ISPLIT= <s>
        //   [m-1 further "<i>: X=.. Y=.. Z=.." position lines]  <- same site
        //   <Element>  NPT=<> R0=<> RMT=<> Z: <Z>                 <- element
        //   [optional LOCAL ROT MATRIX: 3 lines of 3 numbers]
        // WIEN2k emits m distinct positions per site (the ATOM line + m-1 follow-ups);
        // we emit each once. (MULT=1 => just the ATOM line.)
        var atoms: [Atom] = []
        func parseVal(_ key: String, _ t: [String]) -> Float? {
            for (i, tok) in t.enumerated() where tok.hasPrefix(key) {
                let rest = tok.dropFirst(key.count)
                if let v = Float(rest) { return v }            // "X=0.333" (attached)
                if rest.isEmpty, i + 1 < t.count {              // "X= .333" (space after =)
                    return Float(t[i + 1])
                }
            }
            return nil
        }
        func parseInt(_ key: String, _ t: [String]) -> Int? {
            for i in 0..<t.count where t[i] == key && i+1 < t.count { return Int(t[i+1]) }
            return nil
        }
        while let line = nextLine() {
            let t = tok(line)
            // site start: "ATOM= <i>:" / "Atom <i>:" (first position line)
            let firstIsAtom = (!t.isEmpty && (t[0] == "ATOM=" || t[0] == "Atom" || t[0] == "ATOM"))
            // Reject non-finite coordinates: Float("nan")/Float("inf") parse as
            // non-nil, so isFinite is required on every component.
            guard firstIsAtom, let x = parseVal("X=", t), x.isFinite,
                  let y = parseVal("Y=", t), y.isFinite,
                  let z = parseVal("Z=", t), z.isFinite else {
                // not a site-start line (symmetry ops, stray text) -> skip
                continue
            }
            var positions = [SIMD3<Float>(x, y, z)]
            // MULT line directly follows the first position line
            let mult = parseInt("MULT=", tok(nextLine() ?? "")) ?? 1
            // read the remaining (m-1) position lines, each "<i>: X=.. Y=.. Z=.."
            while positions.count < mult, let pline = nextLine() {
                let pt = tok(pline)
                // MULT position lines must also be finite (same NaN/inf risk).
                if let px = parseVal("X=", pt), px.isFinite,
                   let py = parseVal("Y=", pt), py.isFinite,
                   let pz = parseVal("Z=", pt), pz.isFinite {
                    positions.append(SIMD3<Float>(px, py, pz))
                }
            }
            // element + Z line
            let elemLine = nextLine() ?? ""
            let eTok = tok(elemLine)
            var Z = 0
            for (i, tk) in eTok.enumerated() where tk == "Z:" && i+1 < eTok.count {
                // Bound the Float before converting: a non-finite or out-of-range Z must
                // not trap and must fall back to the symbol-based resolution below.
                if let f = Float(eTok[i+1]), f.isFinite, let exact = Int(exactly: f.rounded(.towardZero)) {
                    Z = exact
                }
            }
            let symbol = eTok.first ?? ""
            // skip optional 3x3 rotation matrix (3 lines, each 3 pure numbers)
            let saved = idx
            var steps = 0
            for _ in 0..<3 {
                guard idx < lines.count, tok(lines[idx]).count == 3,
                      tok(lines[idx]).compactMap({ Float($0) }).count == 3 else { break }
                idx += 1; steps += 1
            }
            if steps != 3 { idx = saved }

            if Z == 0 { Z = Table.z(symbol) }
            let sym = symbol.isEmpty ? Table.id(Z) : symbol
            for frac in positions {
                // Cap total atoms across all sites: an absurd MULT or a runaway
                // loop must not allocate unboundedly.
                if atoms.count >= 500_000 { throw E.malformed("too many atoms") }
                let cart = cell.cartesian(frac)
                // The Cartesian result must be finite: a non-finite fractional
                // coordinate or a degenerate cell can produce inf/NaN here.
                guard cart.x.isFinite, cart.y.isFinite, cart.z.isFinite else {
                    throw E.malformed("non-finite atom position")
                }
                atoms.append(Atom(coord: cart, atomicNumber: Z, label: sym))
            }
        }

        var out = LoadedScene()
        out.atoms = atoms
        out.cell = cell
        out.isCrystal = true
        out.title = url.lastPathComponent
        return out
    }

    // CRYSCAL .r1 (XCRYSDEN's native input). CRYSTAL and SLAB use:
    //   <title>, kind, <i> <j> <k>, <space group>, lattice constants, <natoms>
    // POLYMER has no space-group record: kind, dimensionality, one period/lattice
    // value, <natoms>. Atom coordinates are fractional for CRYSTAL/SLAB and
    // Cartesian for POLYMER; trailing EXPT/SUPERCELL/COORPRT/STOP/END records
    // are outside the atom block.
    // The space group -> crystal system -> lattice-param count + cell angles are the
    // standard crystallographic mapping. Lattice constants are already in Angstrom.
    private static func loadCRYSCALr1(_ url: URL) throws -> LoadedScene {
        let raw = try readCappedText(url)
        let lines = raw.components(separatedBy: "\n")
        func tok(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
        }
        // `idx` and the line indices passed below are zero-based; ParseError's
        // public line convention is one-based.
        func failure(_ zeroBasedLine: Int, _ reason: String) -> ParseError {
            ParseError.parse(path: url.path, line: max(1, zeroBasedLine + 1), reason: reason)
        }
        var idx = 0
        func next() -> String? {
            guard idx < lines.count else { return nil }
            defer { idx += 1 }
            return lines[idx]
        }

        guard next() != nil else { throw failure(0, "empty CRYSCAL file") } // title
        guard let kindLine = next() else { throw failure(idx, "missing CRYSCAL record kind") }
        let kindLineIndex = idx - 1
        let kind = kindLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard kind == "CRYSTAL" || kind == "POLYMER" || kind == "SLAB" else {
            throw failure(kindLineIndex, "unsupported CRYSCAL record kind '\(kindLine.trimmingCharacters(in: .whitespacesAndNewlines))'")
        }
        guard next() != nil else { throw failure(idx, "missing CRYSCAL dimensionality record") }
        let isPolymer = kind == "POLYMER"
        let spaceGroupLine = idx
        let spgTok: [String]
        if isPolymer {
            // POLYMER has no space-group record: its next line is the
            // one-dimensional lattice/period value. CRYSTAL and SLAB retain
            // the space-group record layout used below.
            spgTok = []
        } else {
            guard let spaceGroupText = next() else { throw failure(idx, "missing CRYSCAL space group") }
            spgTok = tok(spaceGroupText)
            guard !spgTok.isEmpty else { throw failure(spaceGroupLine, "empty CRYSCAL space group") }
        }

        // Keep the numeric declaration separate from the original symbol used
        // for lattice-system inference. The C façade compares symbolic aliases
        // against spglib's full database and returns a number only for a unique
        // match among all 230 groups; zero means unknown or ambiguous.
        let numericSpaceGroup = spgTok.count == 1 ? Int(spgTok[0]) : nil
        let symbolicSpaceGroup: Int? = {
            guard numericSpaceGroup == nil, !spgTok.isEmpty else { return nil }
            let symbol = spgTok.joined(separator: " ")
            var resolved: Int32 = 0
            let status = symbol.withCString { pointer in
                molenv_spglib_spacegroup_number(pointer, &resolved)
            }
            guard status == MOLENV_SPGLIB_OK else { return nil }
            let number = Int(resolved)
            return (1...230).contains(number) ? number : nil
        }()
        if let numericSpaceGroup, !(1...230).contains(numericSpaceGroup) {
            throw failure(spaceGroupLine,
                          "CRYSCAL space-group number \(numericSpaceGroup) is outside 1...230")
        }
        let spgNumber: Int = numericSpaceGroup ?? symbolicSpaceGroup ?? 0
        guard isPolymer || (1...230).contains(spgNumber) else {
            throw failure(spaceGroupLine,
                          "unrecognized CRYSCAL space group '\(spgTok.joined(separator: " "))'")
        }

        // crystal system -> lattice-param count + cell angles, per the standard
        // crystallographic convention (International Tables) that CRYSCAL's r1 line
        // encodes: one free length for cubic, two (a,c) for hexagonal/tetragonal,
        // three (a,b,c) for orthorhombic, four (a,b,c,beta) for monoclinic, six
        // (a,b,c,alpha,beta,gamma) for triclinic. The trigonal fixtures here use the
        // hexagonal setting (a,c, gamma=120).
        enum System { case cubic, tetragonal, orthorhombic, trigonal, hexagonal, mono, tri }
        let system: System = {
            switch spgNumber {
            case 195...230: return .cubic
            case 168...194: return .hexagonal
            case 143...167: return .trigonal
            case 75...142:  return .tetragonal
            case 16...74:   return .orthorhombic
            case 3...15:    return .mono
            case 1...2:     return .tri
            default: return .cubic
            }
        }()
        let nLat: Int = {
            switch system {
            case .cubic: return 1
            case .tetragonal, .trigonal, .hexagonal: return 2
            case .orthorhombic: return 3
            case .mono: return 4                 // a, b, c, beta
            case .tri: return 6                  // a, b, c, alpha, beta, gamma
            }
        }()

        // Lattice constants may span several lines. Reject non-finite values
        // before Cell.fromLattice can turn them into its zero-cell sentinel.
        var lats: [Float] = []
        while lats.count < nLat, let line = next() {
            for t in tok(line) {
                if let value = Float(t) {
                    guard value.isFinite else { throw failure(idx - 1, "non-finite CRYSCAL lattice constant") }
                    lats.append(value)
                    if lats.count == nLat { break }
                }
            }
        }
        guard lats.count == nLat else { throw failure(idx, "bad CRYSCAL lattice constants") }

        var cell: Cell = {
            switch system {
            case .cubic:
                return Cell.fromLattice(a: lats[0], b: lats[0], c: lats[0], alpha: 90, beta: 90, gamma: 90)
            case .tetragonal, .hexagonal:
                let gamma: Float = (system == .hexagonal) ? 120 : 90
                return Cell.fromLattice(a: lats[0], b: lats[0], c: lats[1], alpha: 90, beta: 90, gamma: gamma)
            case .trigonal:
                return Cell.fromLattice(a: lats[0], b: lats[0], c: lats[1], alpha: 90, beta: 90, gamma: 120)
            case .orthorhombic:
                return Cell.fromLattice(a: lats[0], b: lats[1], c: lats[2], alpha: 90, beta: 90, gamma: 90)
            case .mono:
                return Cell.fromLattice(a: lats[0], b: lats[1], c: lats[2], alpha: 90, beta: lats[3], gamma: 90)
            case .tri:
                return Cell.fromLattice(a: lats[0], b: lats[1], c: lats[2], alpha: lats[3], beta: lats[4], gamma: lats[5])
            }
        }()
        let cellValues = [cell.a.x, cell.a.y, cell.a.z,
                          cell.b.x, cell.b.y, cell.b.z,
                          cell.c.x, cell.c.y, cell.c.z].map(Double.init)
        guard cellValues.allSatisfy(\.isFinite) else {
            throw failure(idx, "CRYSCAL cell is non-finite or singular")
        }
        let cellScale = cellValues.map(abs).max() ?? 0
        guard cellScale.isFinite, cellScale > 0 else {
            throw failure(idx, "CRYSCAL cell is non-finite or singular")
        }
        let cellA = SIMD3<Double>(Double(cell.a.x), Double(cell.a.y), Double(cell.a.z))
        let cellB = SIMD3<Double>(Double(cell.b.x), Double(cell.b.y), Double(cell.b.z))
        let cellC = SIMD3<Double>(Double(cell.c.x), Double(cell.c.y), Double(cell.c.z))
        let normalizedA = cellA / cellScale
        let normalizedB = cellB / cellScale
        let normalizedC = cellC / cellScale
        let normalizedVolume = simd_dot(normalizedA, simd_cross(normalizedB, normalizedC))
        guard normalizedVolume.isFinite, abs(normalizedVolume) > 1e-12 else {
            throw failure(idx, "CRYSCAL cell is non-finite or singular")
        }

        // natoms, then atom lines. CRYSTAL/SLAB coordinates are fractional;
        // POLYMER coordinates are Cartesian and are never symmetry-expanded.
        let atomCountLine = idx
        guard let atomCountText = next(), let atomCountToken = tok(atomCountText).first else {
            throw failure(atomCountLine, "missing CRYSCAL atom count")
        }
        guard let natoms = Int(atomCountToken) else {
            throw failure(atomCountLine, "CRYSCAL atom count is out of range")
        }
        guard natoms > 0 else { throw failure(atomCountLine, "no atoms in CRYSCAL file") }
        let inputAtomCap = 4096
        let expansionAtomCap = 500_000
        guard natoms <= inputAtomCap else {
            throw failure(atomCountLine, "CRYSCAL atom count \(natoms) exceeds input cap \(inputAtomCap)")
        }

        var atoms: [Atom] = []
        atoms.reserveCapacity(natoms)
        var fractionalSites: [CRYSCALFractionalSite] = []
        fractionalSites.reserveCapacity(natoms)
        for atomIndex in 0..<natoms {
            let atomLine = idx
            guard let line = next() else {
                throw failure(atomLine, "truncated CRYSCAL atom block at atom \(atomIndex + 1)/\(natoms)")
            }
            let t = tok(line)
            guard t.count >= 4 else {
                throw failure(atomLine, "malformed CRYSCAL atom \(atomIndex + 1): expected Z x y z")
            }
            guard let atomicNumber = Int(t[0]), atomicNumber > 0 else {
                throw failure(atomLine, "invalid CRYSCAL atomic number '\(t[0])'")
            }
            guard let x = Float(t[1]), let y = Float(t[2]), let z = Float(t[3]),
                  x.isFinite, y.isFinite, z.isFinite else {
                throw failure(atomLine, "non-finite or invalid CRYSCAL atom coordinates")
            }
            let label = Table.id(atomicNumber)
            let position = SIMD3<Float>(x, y, z)
            let cartesian = isPolymer ? position : cell.cartesian(position)
            guard cartesian.x.isFinite, cartesian.y.isFinite, cartesian.z.isFinite else {
                throw failure(atomLine, "CRYSCAL atom \(atomIndex + 1) produces non-finite Cartesian coordinates")
            }
            atoms.append(Atom(coord: cartesian, atomicNumber: atomicNumber, label: label))
            if !isPolymer {
                fractionalSites.append(CRYSCALFractionalSite(
                    fractional: SIMD3<Double>(Double(x), Double(y), Double(z)),
                    atomicNumber: atomicNumber,
                    label: label
                ))
            }
        }

        var completeness: SymmetryInputCompleteness = .asymmetricUnit
        let candidateExpansionSpaceGroup = numericSpaceGroup ?? symbolicSpaceGroup
        let supportsExpansion = kind == "CRYSTAL" &&
            candidateExpansionSpaceGroup.map { (1...230).contains($0) } == true
        if supportsExpansion, let expansionSpaceGroup = candidateExpansionSpaceGroup {
            // Resolve the symbol for Hall setting selection. For symbolic
            // groups, the symbol constrains which Hall setting is used; for
            // numeric groups, NULL selects the convention-based choice
            // (hexagonal H for rhombohedral R groups, unique-b for monoclinic,
            // canonical lowest for others).
            let symbolForHall: String? = {
                if numericSpaceGroup != nil { return nil }
                guard !spgTok.isEmpty else { return nil }
                return spgTok.joined(separator: " ")
            }()
            let maxOperations = 192
            var rotations = [Int32](repeating: 0, count: maxOperations * 9)
            var translations = [Double](repeating: 0, count: maxOperations * 3)
            var operationCount: Int32 = 0
            let status = rotations.withUnsafeMutableBufferPointer { rotationBuffer in
                translations.withUnsafeMutableBufferPointer { translationBuffer in
                    // Use the symbol-aware Hall selection: numeric groups pass
                    // NULL for convention-based choice; symbolic groups pass the
                    // alias so the Hall setting must match it.
                    if let symbol = symbolForHall {
                        return symbol.withCString { pointer in
                            molenv_spglib_operations_with_symbol(
                                Int32(expansionSpaceGroup), pointer,
                                rotationBuffer.baseAddress,
                                translationBuffer.baseAddress,
                                Int32(maxOperations), &operationCount
                            )
                        }
                    } else {
                        return molenv_spglib_operations(
                            Int32(expansionSpaceGroup), rotationBuffer.baseAddress,
                            translationBuffer.baseAddress, Int32(maxOperations), &operationCount
                        )
                    }
                }
            }
            guard status == MOLENV_SPGLIB_OK else {
                let detail = String(cString: molenv_spglib_last_error())
                throw failure(spaceGroupLine,
                              "CRYSCAL space-group \(expansionSpaceGroup) expansion failed: \(detail.isEmpty ? "status \(status)" : detail)")
            }
            let operationTotal = Int(operationCount)
            guard operationTotal > 0, operationTotal <= maxOperations else {
                throw failure(spaceGroupLine, "CRYSCAL space-group \(expansionSpaceGroup) returned an invalid operation count")
            }
            let potential = natoms.multipliedReportingOverflow(by: operationTotal)
            guard !potential.overflow else {
                throw failure(spaceGroupLine, "CRYSCAL symmetry expansion atom-count multiplication overflowed")
            }
            guard potential.partialValue <= expansionAtomCap else {
                throw failure(spaceGroupLine,
                              "CRYSCAL symmetry expansion may produce \(potential.partialValue) atoms, exceeding cap \(expansionAtomCap)")
            }

            // The database operations are exact affine operations, but the input
            // coordinates are Float-backed. Quantized buckets plus a periodic
            // coordinate check make equivalent sites robust to those roundoff
            // differences while keeping expansion bounded and non-quadratic.
            let binsPerAxis: Int64 = 10_000_000
            let dedupTolerance = 1e-7
            func wrap(_ value: Double) -> Double? {
                guard value.isFinite else { return nil }
                var result = value - value.rounded(.down)
                guard result.isFinite else { return nil }
                if result < 0 { result += 1 }
                if result >= 1 { result = 0 }
                return result == 0 ? 0 : result
            }
            func bin(_ value: Double) -> Int64 {
                Int64((value * Double(binsPerAxis)).rounded(.down))
            }
            func periodicBin(_ value: Int64) -> Int64 {
                let remainder = value % binsPerAxis
                return remainder < 0 ? remainder + binsPerAxis : remainder
            }
            func periodicDifference(_ lhs: Double, _ rhs: Double) -> Double {
                let distance = abs(lhs - rhs)
                return min(distance, 1 - distance)
            }

            var expandedAtoms: [Atom] = []
            expandedAtoms.reserveCapacity(potential.partialValue)
            var buckets: [CRYSCALDedupKey: [SIMD3<Double>]] = [:]
            buckets.reserveCapacity(potential.partialValue)
            for site in fractionalSites {
                for operation in 0..<operationTotal {
                    let r = operation * 9
                    let t = operation * 3
                    let transformed = SIMD3<Double>(
                        Double(rotations[r]) * site.fractional.x +
                            Double(rotations[r + 1]) * site.fractional.y +
                            Double(rotations[r + 2]) * site.fractional.z + translations[t],
                        Double(rotations[r + 3]) * site.fractional.x +
                            Double(rotations[r + 4]) * site.fractional.y +
                            Double(rotations[r + 5]) * site.fractional.z + translations[t + 1],
                        Double(rotations[r + 6]) * site.fractional.x +
                            Double(rotations[r + 7]) * site.fractional.y +
                            Double(rotations[r + 8]) * site.fractional.z + translations[t + 2]
                    )
                    guard transformed.x.isFinite, transformed.y.isFinite, transformed.z.isFinite,
                          let fx = wrap(transformed.x), let fy = wrap(transformed.y),
                          let fz = wrap(transformed.z) else {
                        throw failure(spaceGroupLine,
                                      "CRYSCAL space-group \(expansionSpaceGroup) produced a non-finite fractional position")
                    }
                    let baseKey = CRYSCALDedupKey(atomicNumber: site.atomicNumber,
                                                   x: bin(fx), y: bin(fy), z: bin(fz))
                    var duplicate = false
                    for dx in -1...1 {
                        for dy in -1...1 {
                            for dz in -1...1 {
                                let key = CRYSCALDedupKey(
                                    atomicNumber: site.atomicNumber,
                                    x: periodicBin(baseKey.x + Int64(dx)),
                                    y: periodicBin(baseKey.y + Int64(dy)),
                                    z: periodicBin(baseKey.z + Int64(dz))
                                )
                                guard let candidates = buckets[key] else { continue }
                                for existing in candidates {
                                    if periodicDifference(fx, existing.x) <= dedupTolerance &&
                                        periodicDifference(fy, existing.y) <= dedupTolerance &&
                                        periodicDifference(fz, existing.z) <= dedupTolerance {
                                        duplicate = true
                                        break
                                    }
                                }
                                if duplicate { break }
                            }
                            if duplicate { break }
                        }
                        if duplicate { break }
                    }
                    if !duplicate {
                        let cartesian = cell.cartesian(SIMD3<Float>(Float(fx), Float(fy), Float(fz)))
                        guard cartesian.x.isFinite, cartesian.y.isFinite, cartesian.z.isFinite else {
                            throw failure(spaceGroupLine,
                                          "CRYSCAL symmetry expansion produced a non-finite Cartesian position")
                        }
                        guard expandedAtoms.count < expansionAtomCap else {
                            throw failure(spaceGroupLine, "CRYSCAL symmetry expansion exceeded atom cap \(expansionAtomCap)")
                        }
                        expandedAtoms.append(Atom(coord: cartesian,
                                                  atomicNumber: site.atomicNumber,
                                                  label: site.label))
                        buckets[baseKey, default: []].append(SIMD3(fx, fy, fz))
                    }
                }
            }
            guard !expandedAtoms.isEmpty else {
                throw failure(spaceGroupLine, "CRYSCAL symmetry expansion produced no atoms")
            }
            atoms = expandedAtoms
            completeness = .complete
        }

        // Optional SLAB record (CRYSCAL/YCrySDen semantics): after an expanded
        // CRYSTAL atom block, a SLAB record cuts a 2D periodic surface.
        // Format:
        //   SLAB
        //   <h> <k> <l>          Miller indices of the surface plane
        //   <NSLAB> <VACUUM>     number of atomic layers; vacuum thickness (Å)
        var appliedSlab = false
        if !isPolymer, atoms.isEmpty == false, kind == "CRYSTAL" {
            if let peek = lines.indices.contains(idx) ? lines[idx] : nil,
               peek.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "SLAB" {
                _ = next() // consume SLAB line
                let slabLine = idx
                guard let millerLine = next() else {
                    throw failure(slabLine, "truncated CRYSCAL SLAB Miller indices")
                }
                let millerTok = tok(millerLine)
                guard millerTok.count >= 3,
                      let h = Int(millerTok[0]), let k = Int(millerTok[1]), let l = Int(millerTok[2]) else {
                    throw failure(slabLine, "malformed CRYSCAL SLAB Miller indices")
                }
                guard h != 0 || k != 0 || l != 0 else {
                    throw failure(slabLine, "CRYSCAL SLAB Miller indices (0 0 0) are degenerate")
                }
                let millerCap = 1_000_000
                guard (-millerCap...millerCap).contains(h),
                      (-millerCap...millerCap).contains(k),
                      (-millerCap...millerCap).contains(l) else {
                    throw failure(slabLine, "CRYSCAL SLAB Miller index exceeds cap \(millerCap)")
                }
                guard let paramLine = next() else {
                    throw failure(slabLine, "truncated CRYSCAL SLAB parameter record")
                }
                let paramTok = tok(paramLine)
                guard paramTok.count >= 2,
                      let nSlab = Int(paramTok[0]), let vacuum = Float(paramTok[1]) else {
                    throw failure(slabLine, "malformed CRYSCAL SLAB parameter record")
                }
                guard nSlab > 0 else {
                    throw failure(slabLine, "CRYSCAL SLAB layer count must be positive")
                }
                guard nSlab <= 1000 else {
                    throw failure(slabLine, "CRYSCAL SLAB layer count exceeds cap")
                }
                guard vacuum.isFinite, vacuum >= 0 else {
                    throw failure(slabLine, "CRYSCAL SLAB vacuum must be finite and non-negative")
                }
                guard vacuum <= 10_000 else {
                    throw failure(slabLine, "CRYSCAL SLAB vacuum exceeds cap")
                }
                let slabResult = try CRYSCALSlabBuilder.build(
                    atoms: atoms, cell: cell, h: h, k: k, l: l,
                    nSlab: nSlab, vacuum: vacuum,
                    url: url, slabLineIndex: slabLine
                )
                atoms = slabResult.atoms
                cell = slabResult.cell
                appliedSlab = true
            }
        }

        var out = LoadedScene()
        out.title = url.lastPathComponent
        out.atoms = atoms
        out.symmetryInputCompleteness = completeness
        out.isCrystal = true
        out.periodicDim = 3
        if isPolymer {
            // POLYMER is a 1D periodic crystal along x. Build a non-singular
            // finite embedding: a is the period; b and c are orthogonal to a
            // and sized to bound the Cartesian atom positions with a margin.
            out.cell = Self.makePolymerCell(period: lats[0], atoms: atoms)
            out.periodicDim = 1
        } else if kind == "SLAB" && !appliedSlab {
            // Top-level SLAB: the parsed cell is the 2D surface cell.
            out.cell = cell
            out.periodicDim = 2
        } else {
            out.cell = cell
            if appliedSlab {
                out.periodicDim = 2
            }
        }
        return out
    }

    /// Build a non-singular finite-embedding cell for a 1D polymer.
    ///
    /// The period is along x. The y/z padding is derived from the Cartesian
    /// atom extent so the cell tightly bounds the atoms with a small margin.
    /// This is a mathematical embedding; only the a direction is physically
    /// periodic (periodicDim = 1).
    private static func makePolymerCell(period: Float, atoms: [Atom]) -> Cell {
        var minY: Float = 0, maxY: Float = 0, minZ: Float = 0, maxZ: Float = 0
        for atom in atoms {
            minY = min(minY, atom.coord.y)
            maxY = max(maxY, atom.coord.y)
            minZ = min(minZ, atom.coord.z)
            maxZ = max(maxZ, atom.coord.z)
        }
        let margin: Float = 5.0
        let bY = max(1.0, maxY - minY + margin)
        let cZ = max(1.0, maxZ - minZ + margin)
        return Cell(a: SIMD3<Float>(period, 0, 0),
                    b: SIMD3<Float>(0, bY, 0),
                    c: SIMD3<Float>(0, 0, cZ))
    }

    private static let b2a: Float = 0.52917721067

    private static func loadCube(_ url: URL) throws -> LoadedScene {
        let raw = try readCappedText(url)
        let allLines = raw.components(separatedBy: "\n")
        guard allLines.count >= 2 else {
            throw ParseError.parse(path: url.path, line: 1, reason: "missing cube comments")
        }
        var lineIdx = 2
        func nextTokenLine() -> [String]? {
            while lineIdx < allLines.count {
                let line = allLines[lineIdx]
                lineIdx += 1
                if line.isEmpty { continue }
                return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
            return nil
        }
        // natoms, origin (Bohr). If natoms < 0 there are multiple orbitals.
        // Reject Int.min outright: abs(Int.min) traps on overflow in Swift, and an
        // out-of-range header count must never reach the allocation path.
        guard let h = nextTokenLine(), h.count >= 4, let nAtomsT = Int(h[0]) else {
            throw ParseError.parse(path: url.path, line: 3, reason: "bad cube header")
        }
        guard nAtomsT != Int.min else {
            throw ParseError.parse(path: url.path, line: 3, reason: "cube atom count out of range")
        }
        let multiOrb = nAtomsT < 0
        let natoms = abs(nAtomsT)
        // Cap declared atoms to a sane upper bound: the atom loop below reads this
        // many records, so an absurd count must be rejected before it is honored.
        guard natoms <= Scene.superCellAtomCap else {
            throw ParseError.parse(path: url.path, line: 3, reason: "cube atom count out of range")
        }
        // origin is in the same units as the axes; the per-axis unit flag (above)
        // decides the conversion. Use Bohr default when there are no axes to read.
        // Reject non-finite origin components: a NaN/Inf origin would silently
        // corrupt every atom and grid position built from it.
        guard let ox0 = Float(h[1]), ox0.isFinite,
              let oy0 = Float(h[2]), oy0.isFinite,
              let oz0 = Float(h[3]), oz0.isFinite else {
            throw ParseError.parse(path: url.path, line: 3, reason: "bad cube origin")
        }
        let originRaw = SIMD3<Float>(ox0, oy0, oz0)

        // axis counts + step vectors. Gaussian cube writes a SIGNED voxel count per
        // axis: the magnitude is the sample count and the sign is the unit flag
        // (negative = Angstrom, positive = Bohr). All three axes must agree on the
        // unit (mixed signs are rejected); the origin, atoms and grid vectors are all
        // converted Bohr->Angstrom only when the file is in Bohr units.
        var nAxis = [0, 0, 0]
        var dx = [SIMD3<Float>(0,0,0), SIMD3<Float>(0,0,0), SIMD3<Float>(0,0,0)]
        var bohrUnits: Bool? = nil
        // Per-axis upper bound (samples along one axis). A single axis beyond this
        // is unrealistic and keeps the triple-product within Int64 range so the
        // overflow-checked multiply below cannot wrap.
        let axisCap = 25_000_000
        for i in 0..<3 {
            guard let t = nextTokenLine(), t.count >= 4, let ni = Int(t[0]) else { throw ParseError.parse(path: url.path, line: 4+i, reason: "bad cube axis") }
            guard ni != Int.min else { throw ParseError.parse(path: url.path, line: 4+i, reason: "cube axis count out of range") }
            let axisBohr = ni >= 0
            if let prev = bohrUnits, prev != axisBohr {
                throw ParseError.parse(path: url.path, line: 4+i, reason: "mixed-sign cube axes (units must agree)")
            }
            bohrUnits = axisBohr
            let n = abs(ni)
            guard n <= axisCap else { throw ParseError.parse(path: url.path, line: 4+i, reason: "cube axis count out of range") }
            nAxis[i] = n
            // Reject non-finite axis step vectors — a NaN step would silently
            // zero out the corresponding grid span and mis-surface the volume.
            guard let ax0 = Float(t[1]), ax0.isFinite,
                  let ay0 = Float(t[2]), ay0.isFinite,
                  let az0 = Float(t[3]), az0.isFinite else {
                throw ParseError.parse(path: url.path, line: 4+i, reason: "bad cube axis vector")
            }
            dx[i] = SIMD3<Float>(ax0, ay0, az0)
        }
        let scale = (bohrUnits ?? true) ? b2a : 1.0
        dx = dx.map { $0 * scale }
        let nx = nAxis[0], ny = nAxis[1], nz = nAxis[2]
        guard nx > 0, ny > 0, nz > 0 else {
            throw ParseError.parse(path: url.path, line: 0, reason: "zero cube grid dimension")
        }
        // Overflow-checked product before allocating. A raw Int64*Int64*Int64 can
        // silently wrap to a positive value that passes a naive bound check.
        guard let perOrb64 = mulOrOverflow(Int64(nx), Int64(ny), Int64(nz)),
              perOrb64 > 0, perOrb64 <= 25_000_000 else {
            throw ParseError.parse(path: url.path, line: 0, reason: "cube grid dimensions overflow")
        }
        let perOrb = Int(perOrb64)
        let nxUI = nx, nyUI = ny, nzUI = nz
        // spanning vectors v(i) = (n(i)-1)*dx(i)
        let vec = [dx[0]*Float(max(1,nxUI)-1), dx[1]*Float(max(1,nyUI)-1), dx[2]*Float(max(1,nzUI)-1)]

        // atom records: Z, charge, x, y, z (in the same units as the axes).
        // Reject non-finite coordinates (a NaN atom position is meaningless).
        let origin = originRaw * scale
        var atoms: [Atom] = []
        for _ in 0..<natoms {
            guard let t = nextTokenLine(), t.count >= 5, let Z = Int(t[0]) else { throw ParseError.parse(path: url.path, line: 0, reason: "short cube atoms") }
            guard let ax0 = Float(t[2]), ax0.isFinite,
                  let ay0 = Float(t[3]), ay0.isFinite,
                  let az0 = Float(t[4]), az0.isFinite else {
                throw ParseError.parse(path: url.path, line: 0, reason: "bad cube atom coordinate")
            }
            let p = SIMD3<Float>(ax0, ay0, az0) * scale
            atoms.append(Atom(coord: p, atomicNumber: Z, label: Table.id(Z)))
        }
        // optional MO record if multiple orbitals: the next token line gives the
        // number of orbitals followed by their 1-based indices, e.g. "2  1  2".
        // The record is the count PLUS exactly that many indices; any surplus
        // token on the line is a malformed header. The declared count also cannot
        // exceed the realistic orbital cap.
        var nOrbitals = 1
        if multiOrb {
            if let moLine = nextTokenLine(), let nOrb = Int(moLine.first ?? ""), nOrb >= 1, nOrb <= 4096 {
                // moLine = [nOrb, idx_1, ..., idx_nOrb]; reject surplus tokens.
                guard moLine.count == nOrb + 1 else {
                    throw ParseError.parse(path: url.path, line: 0, reason: "cube MO header token count mismatch")
                }
                let ids = moLine.dropFirst().compactMap(Int.init)
                guard ids.count == nOrb, ids.allSatisfy({ $0 > 0 }), Set(ids).count == nOrb else {
                    throw ParseError.parse(path: url.path, line: 0, reason: "bad cube MO orbital indices")
                }
                nOrbitals = nOrb
            } else {
                throw ParseError.parse(path: url.path, line: 0, reason: "bad cube MO header")
            }
        }

        // Gaussian cube writes voxels with the third axis varying fastest. For an
        // MO cube, values are additionally interleaved by orbital at every voxel.
        // Read the complete stream, then transpose it into ScalarField's x-fastest
        // layout and one independent value array per orbital.
        // The MO record's orbital count can be arbitrarily large, so this product is
        // also overflow-checked (perOrb * nOrbitals) and capped against memory.
        guard let totalNeeded64 = mulOrOverflow(Int64(perOrb), Int64(nOrbitals)),
              totalNeeded64 > 0, totalNeeded64 <= 25_000_000 else {
            throw ParseError.parse(path: url.path, line: 0, reason: "cube value count overflow")
        }
        let totalNeeded = Int(totalNeeded64)
        var allValues: [Float] = []
        allValues.reserveCapacity(totalNeeded)
        while allValues.count < totalNeeded, let tok = nextTokenLine() {
            for s in tok {
                guard allValues.count < totalNeeded else {
                    throw ParseError.parse(path: url.path, line: 0, reason: "surplus cube values")
                }
                guard let v = Float(s), v.isFinite else {
                    throw ParseError.parse(path: url.path, line: 0, reason: "non-finite cube value")
                }
                allValues.append(v)
            }
        }
        guard allValues.count == totalNeeded else {
            throw ParseError.parse(path: url.path, line: 0, reason: "cube grid short (\(allValues.count)/\(totalNeeded))")
        }
        if nextTokenLine() != nil {
            throw ParseError.parse(path: url.path, line: 0, reason: "surplus cube values")
        }

        var valuesByOrbital = Array(repeating: [Float](repeating: 0, count: perOrb), count: nOrbitals)
        var src = 0
        for ix in 0..<nx {
            for iy in 0..<ny {
                for iz in 0..<nz {
                    let dst = ix + nx * (iy + ny * iz)
                    for orbital in 0..<nOrbitals {
                        valuesByOrbital[orbital][dst] = allValues[src]
                        src += 1
                    }
                }
            }
        }

        var multiOrbitalFields: [ScalarField] = []
        multiOrbitalFields.reserveCapacity(nOrbitals)
        var scalarField: ScalarField?
        for o in 0..<nOrbitals {
            let orbValues = valuesByOrbital[o]
            var minV = orbValues[0], maxV = orbValues[0]
            for v in orbValues { if v < minV { minV = v }; if v > maxV { maxV = v } }
            let field = ScalarField(nx: nx, ny: ny, nz: nz, origin: origin, vec: vec,
                                    values: orbValues, minValue: minV, maxValue: maxV)
            if o == 0 { scalarField = field }
            multiOrbitalFields.append(field)
        }

        var out = LoadedScene()
        out.atoms = atoms
        out.scalarField = scalarField
        out.multiOrbitalFields = multiOrbitalFields
        out.title = url.lastPathComponent
        return out
    }

    /// Overflow-checked product. Returns the product of the given non-negative
    /// Int64 factors, or nil if it overflows the Int64 range. Used to size cube /
    /// BXSF allocations where a wrapped (negative or spuriously small) product
    /// must not pass a magnitude bound check.
    private static func mulOrOverflow(_ a: Int64, _ b: Int64) -> Int64? {
        let (p, o) = a.multipliedReportingOverflow(by: b)
        return o ? nil : p
    }
    private static func mulOrOverflow(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64? {
        guard let p = mulOrOverflow(a, b) else { return nil }
        return mulOrOverflow(p, c)
    }

    /// QE PWscf `.pwo` / `.out`: atoms + cell come from the C `parse_pwo`; forces,
    /// total force, total energy and optional stress come from the Swift ForceParser
    /// reading the SAME raw text. Per-atom forces are placed on the atoms by the
    /// printed index (`atom N` -> atom N-1), so they stay aligned even if an earlier
    /// block is malformed. The whole LoadedScene (structure + forceSet) bridges to
    /// `Scene`, so a QE output can finally expose forces, energy and arrows.
    private static func loadPWO(_ url: URL, frameIndex: Int) throws -> LoadedScene {
        let raw = try readCappedText(url)
        let cPath = url.path.cString(using: .utf8)!
        guard let scene = parse_pwo(cPath, Int32(frameIndex)) else {
            let msg = String(cString: molenv_last_error())
            var path = url.path, line = 0, reason = msg
            if let match = msg.range(of: #"^(.+):(\d+):\s?(.*)$"#, options: .regularExpression) {
                let body = String(msg[match]); let parts = body.components(separatedBy: ":")
                if parts.count >= 3, let n = Int(parts[parts.count-2]) {
                    path = parts[0..<parts.count-2].joined(separator: ":"); line = n
                    reason = parts[parts.count-1].trimmingCharacters(in: .whitespaces)
                }
            }
            throw ParseError.parse(path: path, line: line, reason: reason)
        }
        defer { molenv_scene_free(scene) }
        var out = copyOut(scene.pointee)
        out.title = out.title.isEmpty ? url.lastPathComponent : out.title
        // Converged forces of the requested SCF frame (frameIndex selects it via the geometry
        // block windows; see ForceParser.parse). Requires the block to match the parsed atom
        // count so a truncated block is rejected.
        if let fs = ForceParser.parse(raw, frameIndex: frameIndex, atomCount: out.atoms.count) {
            for i in 0..<min(fs.forces.count, out.atoms.count) {
                out.atoms[i].force = fs.forces[i]
            }
            out.forceSet = fs
        }
        return out
    }
}

// MARK: - CRYSCAL slab construction

/// CRYSCAL/YCrySDen slab construction from an expanded bulk crystal.
///
/// The SLAB record specifies a surface by Miller indices (h,k,l), the
/// number of atomic layers NSLAB, and the vacuum thickness VACUUM (Å).
/// Construction uses exact integer-lattice algebra:
///   1. Reduce (h,k,l) by gcd.
///   2. Derive integer step s with h*s.a+k*s.b+l*s.c=1 (extended GCD).
///   3. Derive primitive in-plane kernel basis t1, t2 (exact Bezout).
///   4. Replicate expanded-bulk atoms along s to produce ≥NSLAB planes.
///   5. Wrap into the primitive in-plane parallelogram.
///   6. Group into distinct atomic planes; keep NSLAB consecutive.
///   7. Deduplicate periodically in-plane by species.
///   8. Shift z to nonnegative; set c = actual slab extent + user vacuum.
enum CRYSCALSlabBuilder {
    struct Result {
        let atoms: [Atom]
        let cell: Cell
    }

    static func build(atoms: [Atom], cell: Cell, h: Int, k: Int, l: Int,
                      nSlab: Int, vacuum: Float, url: URL,
                      slabLineIndex: Int) throws -> Result {
        func err(_ reason: String) -> ParseError {
            ParseError.parse(path: url.path, line: max(1, slabLineIndex + 1), reason: reason)
        }
        let request = SurfaceCellRequest(h: h, k: k, l: l,
                                          layers: nSlab, vacuum: vacuum,
                                          termination: 0, stackCount: 1)
        switch SurfaceCellBuilder.build(atoms: atoms, cell: cell, request: request) {
        case .success(let built):
            return Result(atoms: built.atoms, cell: built.cell)
        case .failure(let error):
            throw err(error.description)
        }
    }
}

// Element-symbol helper used by the cube + WIEN2k readers. Delegates to the
// full ElementTable (Z=0..118, pure data — no renderer dependency) so heavy
// elements resolve correctly. Fallbacks match prior behavior: unknown symbol
// -> 0 (Table.z), out-of-range Z -> "\(z)" (Table.id).
enum Table {
    static func id(_ z: Int) -> String {
        guard z >= 1, z <= 118 else { return "\(z)" }
        return ElementTable.symbol(z)
    }
    /// Parse an element symbol to atomic number; returns 0 if unknown.
    static func z(_ s: String) -> Int {
        return ElementTable.atomicNumber(s)
    }
}

// Orca geometry-optimization(.out) log: a sequence of CARTESIAN COORDINATES
// (ANGSTROEM) blocks, one per optimization cycle => multi-frame molecule. Each
// atom line is "Symbol x y z" in Angstrom (Cartesian, no cell). Mirrors how QE
// .pwo treats ionic steps as frames: frameIndex -1 => last (final) geometry,
// 0..<count => that cycle's snapshot.
enum OrcaParser {
    private static let coordHeader = "CARTESIAN COORDINATES (ANGSTROEM)"
    private static let coordSeparator = "---"

    /// Count coordinate blocks (= optimization cycles).
    static func cycleCount(_ url: URL) -> Int {
        guard let raw = try? readCappedText(url) else { return 0 }
        return raw.components(separatedBy: "\n").filter { $0.contains(coordHeader) }.count
    }

    /// Parse one coordinate block into a molecule. frameIndex -1 => last block.
    static func load(_ url: URL, frameIndex: Int) throws -> LoadedScene {
        guard let raw = try? readCappedText(url) else {
            enum E: Error { case io }
            throw E.io
        }
        let lines = raw.components(separatedBy: "\n")
        // Collect the start line of every coordinate block.
        var blockStarts: [Int] = []
        for (i, line) in lines.enumerated() where line.contains(coordHeader) {
            // Cap the number of tracked blocks: a file with an absurd number of
            // coordinate blocks is malformed and must not allocate unboundedly.
            if blockStarts.count >= 100_000 { break }
            blockStarts.append(i)
        }
        guard !blockStarts.isEmpty else { enum E: Error { case noCoords }; throw E.noCoords }
        guard frameIndex < 0 || frameIndex < blockStarts.count else {
            enum E: Error { case noCoords }; throw E.noCoords
        }
        let target = frameIndex < 0 ? blockStarts.count - 1 : frameIndex
        let start = blockStarts[target]

        // The block begins after the "-------------------" separator following the
        // header; atom lines run until a blank line or another section header.
        var idx = start
        // advance past header + separator
        while idx < lines.count, !(lines[idx].contains(coordSeparator)) { idx += 1 }
        idx += 1   // first atom line (or beyond if file is malformed)
        var atoms: [Atom] = []
        while idx < lines.count {
            let line = lines[idx].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { break }
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Reject non-finite coordinates: Float("nan")/Float("inf") return
            // non-nil, so the plain `Float(tok) != nil` check is not enough — a
            // NaN coordinate poisons framingSphere/defaultCamera downstream.
            guard toks.count >= 4, let x = Float(toks[1]), x.isFinite,
                  let y = Float(toks[2]), y.isFinite,
                  let z = Float(toks[3]), z.isFinite else { break }   // next section reached
            // Cap total atoms: a file with an absurd number of atoms must not
            // allocate unboundedly.
            if atoms.count >= 500_000 { break }
            let Z = ElementTable.atomicNumber(toks[0])
            let sym = Z == 0 ? toks[0] : ElementTable.symbol(Z)
            atoms.append(Atom(coord: SIMD3<Float>(x, y, z), atomicNumber: Z, label: sym))
            idx += 1
        }
        guard !atoms.isEmpty else { enum E: Error { case noAtoms }; throw E.noAtoms }
        var out = LoadedScene()
        out.atoms = atoms
        out.isCrystal = false
        out.title = url.lastPathComponent
        return out
    }
}

// Bohr -> Angstrom conversion shared by the file-level structure parsers
// (FHI-aims, Gaussian .cube) that live outside the Parser enum.
fileprivate let bohr2ang: Float = 0.52917721067

// Bridge used by Parser.load — matches the frame-aware dispatch above.
internal func loadOrca(_ url: URL, frameIndex: Int) throws -> LoadedScene {
    try OrcaParser.load(url, frameIndex: frameIndex)
}
internal func orcaCycleCount(_ url: URL) -> Int {
    OrcaParser.cycleCount(url)
}

// FHI-aims structure parser. Detects one of two formats from the first
// non-blank line and dispatches accordingly:
//   (a) XCrySDen-style coord.out (ported from F/fhi_coord2xcr.f):
//       <a1> <a2> <a3>        (lattice vectors as 3 columns, Bohr -> Angstrom)
//       <n_all_species>
//       [per species:]
//       <n_i_species>
//       <name>                 (element name, e.g. "Gallium", "hy_1.25")
//       (<x> <y> <z> <T/F>)*n  (Cartesian coords, Bohr -> Angstrom; flag ignored)
//   (b) Standard FHI-aims geometry.in / FHI98MD:
//       lattice_vector  x y z   (×3, Angstrom)
//       atom_frac       x y z Element   (fractional)
//       atom            x y z Element   (Cartesian, Angstrom)
internal func loadFHIaims(_ url: URL) throws -> LoadedScene {
    let raw = try readCappedText(url)
    let lines = raw.components(separatedBy: "\n")
    enum E: Error { case malformed(String) }
    func tok(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }

    // Find first non-blank line to decide format.
    let firstNonBlank = lines.first {
        let line = $0.trimmingCharacters(in: .whitespaces)
        return !line.isEmpty && !line.hasPrefix("#")
    }
    let isStandard = firstNonBlank?.lowercased().hasPrefix("lattice_vector") == true ||
                     firstNonBlank?.lowercased().hasPrefix("atom_frac") == true ||
                     firstNonBlank?.lowercased().hasPrefix("atom") == true

    if isStandard {
        return try loadFHIaimsGeometryIn(lines: lines, url: url)
    }
    return try loadFHIaimsCoordOut(lines: lines)
}

/// Parse a standard FHI-aims `geometry.in` / `FHI98MD` file. Keywords:
///   `lattice_vector x y z`  — 3×, Angstrom
///   `atom_frac x y z Elem`  — fractional coordinate
///   `atom x y z Elem`       — Cartesian coordinate (Angstrom)
///   `constrain_relaxation .true.` / `.false.` — ignored
internal func loadFHIaimsGeometryIn(lines: [String], url: URL) throws -> LoadedScene {
    enum E: Error { case malformed(String) }
    func tok(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }

    // Orbit关键词不敏感的匹配。
    var latticeVecs: [SIMD3<Float>] = []
    var fracAtoms: [(SIMD3<Float>, String)] = []
    var cartAtoms: [(SIMD3<Float>, String)] = []

    for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let t = tok(line)
        guard let kw = t.first?.lowercased() else { continue }
        switch kw {
        case "lattice_vector":
            // Reject non-finite components: Float("nan")/Float("inf") parse as
            // non-nil, so isFinite is required on every component.
            guard t.count >= 4, let x = Float(t[1]), x.isFinite,
                  let y = Float(t[2]), y.isFinite,
                  let z = Float(t[3]), z.isFinite else {
                throw E.malformed("bad lattice_vector: \(line)")
            }
            latticeVecs.append(SIMD3<Float>(x, y, z))
        case "atom_frac":
            guard t.count >= 5, let x = Float(t[1]), x.isFinite,
                  let y = Float(t[2]), y.isFinite,
                  let z = Float(t[3]), z.isFinite else {
                throw E.malformed("bad atom_frac: \(line)")
            }
            fracAtoms.append((SIMD3<Float>(x, y, z), t[4]))
        case "atom":
            guard t.count >= 5, let x = Float(t[1]), x.isFinite,
                  let y = Float(t[2]), y.isFinite,
                  let z = Float(t[3]), z.isFinite else {
                throw E.malformed("bad atom: \(line)")
            }
            cartAtoms.append((SIMD3<Float>(x, y, z), t[4]))
        default:
            break   // ignore `constrain_relaxation`, `empty`, etc.
        }
    }

    let hasCell = latticeVecs.count == 3
    if latticeVecs.count > 0 && !hasCell {
        throw E.malformed("geometry.in needs exactly 3 lattice_vector lines (found \(latticeVecs.count))")
    }
    if !fracAtoms.isEmpty && !hasCell {
        throw ParseError.parse(path: url.path, line: 0, reason: "atom_frac coordinates require a lattice (3 lattice_vector lines)")
    }
    let cell = hasCell ? Cell(a: latticeVecs[0], b: latticeVecs[1], c: latticeVecs[2]) : nil

    func fracToCart(_ f: SIMD3<Float>) -> SIMD3<Float> {
        f.x * latticeVecs[0] + f.y * latticeVecs[1] + f.z * latticeVecs[2]
    }

    var atoms: [Atom] = []
    for (coord, sym) in fracAtoms {
        let Z = ElementTable.atomicNumber(sym)
        if hasCell {
            let cart = fracToCart(coord)
            // fracToCart can overflow to inf with extreme fractional coords or
            // a degenerate cell; reject non-finite results.
            guard cart.x.isFinite, cart.y.isFinite, cart.z.isFinite else {
                throw E.malformed("non-finite fractional-to-Cartesian coordinate")
            }
            atoms.append(Atom(coord: cart, atomicNumber: Z, label: Z == 0 ? sym : ElementTable.symbol(Z)))
        }
    }
    for (coord, sym) in cartAtoms {
        let Z = ElementTable.atomicNumber(sym)
        atoms.append(Atom(coord: coord, atomicNumber: Z, label: Z == 0 ? sym : ElementTable.symbol(Z)))
    }
    // Cap total atoms: an absurd number of atom_frac/atom lines must not
    // allocate unboundedly.
    if atoms.count > 500_000 {
        throw E.malformed("too many atoms")
    }

    var out = LoadedScene()
    out.atoms = atoms
    if hasCell {
        out.cell = cell
        out.isCrystal = true
        out.periodicDim = 3
    } else {
        out.cell = nil
        out.isCrystal = false
        out.periodicDim = 0
    }
    out.title = "geometry.in"
    return out
}

/// Parse an XCrySDen-style FHI-aims `coord.out`.
internal func loadFHIaimsCoordOut(lines: [String]) throws -> LoadedScene {
    enum E: Error { case malformed(String) }
    func tok(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
    var idx = 0
    func next() -> String? { guard idx < lines.count else { return nil }; defer { idx += 1 }; return lines[idx] }

    // 3 lattice columns (read row-major but they are columns: a(j,i)).
    var cols = [SIMD3<Float>]()
    for _ in 0..<3 {
        guard let line = next() else { throw E.malformed("short lattice") }
        let t = tok(line)
        // Reject non-finite components: Float("nan")/Float("inf") parse as
        // non-nil, so isFinite is required on every component.
        guard t.count >= 3, let x = Float(t[0]), x.isFinite,
              let y = Float(t[1]), y.isFinite,
              let z = Float(t[2]), z.isFinite else {
            throw E.malformed("bad lattice vector")
        }
        let col = SIMD3<Float>(x, y, z) * bohr2ang
        // The Bohr->Angstrom scaled column must also be finite.
        guard col.x.isFinite, col.y.isFinite, col.z.isFinite else {
            throw E.malformed("non-finite lattice vector")
        }
        cols.append(col)
    }
    let cell = Cell(a: cols[0], b: cols[1], c: cols[2])
    // The derived cell vectors must all be finite: a degenerate or
    // extreme lattice can produce inf/NaN cell edges.
    let cellVals = [cell.a.x, cell.a.y, cell.a.z, cell.b.x, cell.b.y, cell.b.z,
                    cell.c.x, cell.c.y, cell.c.z]
    guard cellVals.allSatisfy(\.isFinite) else {
        throw E.malformed("non-finite cell")
    }

    // number of species
    // Cap nSpecies: an absurd species count must not drive unbounded work.
    guard let nsLine = next(), let nSpecies = Int(tok(nsLine).first ?? ""), nSpecies > 0, nSpecies <= 500_000 else {
        throw E.malformed("bad n_all_species")
    }
    var atoms: [Atom] = []
    for _ in 0..<nSpecies {
        guard let cLine = next(), let count = Int(tok(cLine).first ?? ""), count > 0, count <= 500_000 else {
            throw E.malformed("bad species count")
        }
        // Running total cap: the per-species count feeds the atom loop below,
        // so the cumulative total must stay bounded.
        if atoms.count + count > 500_000 {
            throw E.malformed("too many atoms")
        }
        guard let nameLine = next() else { throw E.malformed("bad species name") }
        let speciesName = nameLine.trimmingCharacters(in: .whitespaces)
        let Z = fhiSpeciesZ(speciesName)
        let sym = Z == 0 ? speciesName : ElementTable.symbol(Z)
        for _ in 0..<count {
            guard let line = next() else { throw E.malformed("short atom") }
            let t = tok(line)
            // Reject non-finite coordinates: Float("nan")/Float("inf") parse as
            // non-nil, so isFinite is required on every component.
            guard t.count >= 4, let x = Float(t[0]), x.isFinite,
                  let y = Float(t[1]), y.isFinite,
                  let z = Float(t[2]), z.isFinite else {
                throw E.malformed("bad atom coord")
            }
            let coord = SIMD3<Float>(x, y, z) * bohr2ang
            // The Bohr->Angstrom scaled coordinate must also be finite.
            guard coord.x.isFinite, coord.y.isFinite, coord.z.isFinite else {
                throw E.malformed("non-finite atom coord")
            }
            atoms.append(Atom(coord: coord, atomicNumber: Z, label: sym))
        }
    }

    var out = LoadedScene()
    out.atoms = atoms
    out.cell = cell
    out.isCrystal = true
    out.title = "coord.out"
    return out
}

/// QE PWscf band structure (`.bands` file, or a `.out` forced with `--bands`):
/// parse the `bands (ev):` k-point blocks in Swift into a BandStructure and wrap
/// it in a band-only LoadedScene (no atoms/cell). The MainWindowController swaps
/// the 3D canvas for the 2D Grapher when scene.bandStructure != nil.
internal func loadBands(_ url: URL) throws -> LoadedScene {
    let raw = try readCappedText(url)
    guard let bands = BandParser.parse(raw) else {
        throw ParseError.parse(path: url.path, line: 0, reason: "no `bands (ev):` block found")
    }
    var out = LoadedScene()
    out.bandStructure = bands
    out.title = url.lastPathComponent
    return out
}

/// Map an FHI-aims species label to an atomic number. FHI-aims writes element
/// names ("Gallium","Arsenic"); hydrogen sites are labelled "hy_<n>". XCrySDen's
/// external converter disambiguates via a separate species-list file; here we
/// resolve in-process: "hy_*" -> H, otherwise match the leading alphabetic run
/// against the element table by full name OR by symbol prefix.
private func fhiSpeciesZ(_ name: String) -> Int {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("hy") { return 1 }
    // FHI-aims labels species by element NAME ("Gallium","Arsenic"). Resolve it
    // by matching the leading alphabetic run against the element symbols: prefer
    // a 2-letter match ("As" for Arsenic) over a 1-letter one ("A"... doesn't
    // exist, but "Ar" would wrongly match Argon), so try symbol lengths 2 then 1.
    // Because a name like "Arsenic" starts with "Ar" (Argon) yet its true symbol
    // is "As", we align the symbol against the NAME: the symbol's letters must
    // appear at the start of the name in order. "As" matches "Arsenic" (A...s),
    // "Ar" matches "Argonic" — we pick the symbol whose name-equality holds.
    let letters = String(trimmed.prefix(while: { $0.isLetter }))
    let upper = letters.uppercased()
    // Exact full-name -> symbol is unambiguous.
    if let z = fhiNameTable[upper] { return z }
    // Otherwise fall back to 2- then 1-letter symbol prefix against the full
    // 118-element table so heavy elements resolve instead of returning 0.
    if upper.count >= 2 {
        let z = ElementTable.atomicNumber(String(upper.prefix(2)))
        if z != 0 { return z }
    }
    return ElementTable.atomicNumber(String(upper.prefix(1)))
}

/// FHI-aims element names (uppercased) -> atomic number. Covers all 118
/// elements plus common alternative spellings; built once.
private let fhiNameTable: [String: Int] = {
    var t: [String: Int] = [:]
    let pairs: [(String,Int)] = [
        ("HYDROGEN",1),("HELIUM",2),("LITHIUM",3),("BERYLLIUM",4),("BORON",5),
        ("CARBON",6),("NITROGEN",7),("OXYGEN",8),("FLUORINE",9),("NEON",10),
        ("SODIUM",11),("MAGNESIUM",12),("ALUMINIUM",13),("ALUMINUM",13),("SILICON",14),
        ("PHOSPHORUS",15),("SULFUR",16),("SULPHUR",16),("CHLORINE",17),("ARGON",18),
        ("POTASSIUM",19),("CALCIUM",20),("SCANDIUM",21),("TITANIUM",22),("VANADIUM",23),
        ("CHROMIUM",24),("MANGANESE",25),("IRON",26),("COBALT",27),("NICKEL",28),
        ("COPPER",29),("ZINC",30),("GALLIUM",31),("GERMANIUM",32),("ARSENIC",33),
        ("SELENIUM",34),("BROMINE",35),("KRYPTON",36),("RUBIDIUM",37),("STRONTIUM",38),
        ("YTTRIUM",39),("ZIRCONIUM",40),("NIOBIUM",41),("MOLYBDENUM",42),("TECHNETIUM",43),
        ("RUTHENIUM",44),("RHODIUM",45),("PALLADIUM",46),("SILVER",47),("CADMIUM",48),
        ("INDIUM",49),("TIN",50),("ANTIMONY",51),("TELLURIUM",52),("IODINE",53),
        ("XENON",54),("CESIUM",55),("BARIUM",56),("LANTHANUM",57),("CERIUM",58),
        ("PRASEODYMIUM",59),("NEODYMIUM",60),("PROMETHIUM",61),("SAMARIUM",62),
        ("EUROPIUM",63),("GADOLINIUM",64),("TERBIUM",65),("DYSPROSIUM",66),("HOLMIUM",67),
        ("ERBIUM",68),("THULIUM",69),("YTTERBIUM",70),("LUTETIUM",71),("HAFNIUM",72),
        ("TANTALUM",73),("TUNGSTEN",74),("RHENIUM",75),("OSMIUM",76),("IRIDIUM",77),
        ("PLATINUM",78),("GOLD",79),("MERCURY",80),("THALLIUM",81),("LEAD",82),
        ("BISMUTH",83),("POLONIUM",84),("ASTATINE",85),("RADON",86),("FRANCIUM",87),
        ("RADIUM",88),("ACTINIUM",89),("THORIUM",90),("PROTACTINIUM",91),("URANIUM",92),
        ("NEPTUNIUM",93),("PLUTONIUM",94),("AMERICIUM",95),("CURIUM",96),("BERKELIUM",97),
        ("CALIFORNIUM",98),("EINSTEINIUM",99),("FERMIUM",100),("MENDELEVIUM",101),
        ("NOBELIUM",102),("LAWRENCIUM",103),("RUTHERFORDIUM",104),("DUBNIUM",105),
        ("SEABORGIUM",106),("BOHRIUM",107),("HASSIUM",108),("MEITNERIUM",109),
        ("DARMSTADTIUM",110),("ROENTGENIUM",111),("COPERNICIUM",112),("NIHONIUM",113),
        ("FLEROVIUM",114),("MOSCOVIUM",115),("LIVERMORIUM",116),("TENNESSINE",117),
        ("OGANESSON",118)
    ]
    for (n, z) in pairs { t[n] = z }
    return t
}()
