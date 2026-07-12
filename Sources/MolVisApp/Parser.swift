import Foundation
import simd

import MolEnvParse

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
}

/// A parser format that can be forced via a CLI flag (`--xsf`, `--pdb`, ...).
/// When omitted, `Parser.load` falls back to the file extension.
enum ParseFormat {
    case xsf, axsf, xyz, pdb, pwi, pwo, cif, poscar, cube, bxsf, struct_, crystal, orca, fhi, bands
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
        case "cube": self = .cube
        case "bxsf": self = .bxsf
        case "struct": self = .struct_
        case "r1": self = .crystal
        case "orca": self = .orca
        case "fhi", "coord": self = .fhi
        case "bands": self = .bands
        default: return nil
        }
    }

    /// Resolve a format from a URL, peeling a trailing `.gz` layer so gzip-wrapped
    /// formats (`.bxsf.gz`) dispatch to their own parser. `pathExtension` alone would
    /// yield only `gz`; when it is, we look one layer deeper at the stem's extension.
    static func from(url: URL) -> ParseFormat? {
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
        out.isCrystal = s.is_crystal != 0
        out.periodicDim = Int(s.periodic_dim)
        out.title = withUnsafePointer(to: &s.title) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        out.atoms = readAtoms(s)
        out.bonds = readBonds(s)
        out.scalarField = readGrid(s)
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
        let stride = MemoryLayout<MolEnvAtom>.stride
        return (0..<natoms).map { idx -> Atom in
            let base = UnsafeRawPointer(atomsPtr).advanced(by: idx * stride)
            let coord = base.withMemoryRebound(to: Float.self, capacity: 3) {
                SIMD3<Float>($0[0], $0[1], $0[2])
            }
            let atomicNumber = Int(base.load(fromByteOffset: MemoryLayout<Float>.stride * 3, as: Int32.self))
            let label = String(cString: base.advanced(by: MemoryLayout<Float>.stride * 3 + MemoryLayout<Int32>.stride).assumingMemoryBound(to: CChar.self))
            return Atom(coord: coord, atomicNumber: atomicNumber, label: label)
        }
    }

    private static func readBonds(_ s: MolEnvScene) -> [Bond] {
        let nbonds = Int(s.nbonds)
        guard nbonds > 0, let bondsPtr = s.bonds else { return [] }
        let buf = UnsafeBufferPointer(start: bondsPtr, count: nbonds)
        return buf.map { Bond(i: Int($0.i), j: Int($0.j)) }
    }

    /// Bridge a C `MolEnvGrid` (a DATAGRID block) into a Swift `ScalarField`.
    /// Returns nil when the scene carries no grid. The grid index layout in C is
    /// x-fastest (i + nx*(j + ny*k)), matching `ScalarField.index`.
    private static func readGrid(_ s: MolEnvScene) -> ScalarField? {
        guard let gPtr = s.grid else { return nil }
        let g = gPtr.pointee
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
        let raw = try String(contentsOf: url, encoding: .utf8)
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
        guard let natoms = latToks.last.flatMap(Int.init), natoms > 0 else {
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
        guard params.count >= 6 else { throw E.malformed("bad cell params") }
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
            guard firstIsAtom, let x = parseVal("X=", t), let y = parseVal("Y=", t),
                  let z = parseVal("Z=", t) else {
                // not a site-start line (symmetry ops, stray text) -> skip
                continue
            }
            var positions = [SIMD3<Float>(x, y, z)]
            // MULT line directly follows the first position line
            let mult = parseInt("MULT=", tok(nextLine() ?? "")) ?? 1
            // read the remaining (m-1) position lines, each "<i>: X=.. Y=.. Z=.."
            while positions.count < mult, let pline = nextLine() {
                let pt = tok(pline)
                if let px = parseVal("X=", pt), let py = parseVal("Y=", pt), let pz = parseVal("Z=", pt) {
                    positions.append(SIMD3<Float>(px, py, pz))
                }
            }
            // element + Z line
            let elemLine = nextLine() ?? ""
            let eTok = tok(elemLine)
            var Z = 0
            for (i, tk) in eTok.enumerated() where tk == "Z:" && i+1 < eTok.count {
                Z = Int(Float(eTok[i+1]) ?? 0)   // "78.0" -> Float -> Int
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
                atoms.append(Atom(coord: cell.cartesian(frac), atomicNumber: Z, label: sym))
            }
        }

        var out = LoadedScene()
        out.atoms = atoms
        out.cell = cell
        out.isCrystal = true
        out.title = url.lastPathComponent
        return out
    }

    // CRYSCAL .r1 (XCRYSDEN's native input). Three sub-formats share a header:
    //   <title>
    //   CRYSTAL | POLYMER | SLAB
    //   <i> <j> <k>
    //   <space group: integer number OR symbol "F M 3 M"/"P M C N" ...>
    //   <lattice constants: 1..6, in Angstrom — count set by crystal system>
    //   <natoms>
    //   <Z> <xf> <yf> <zf>          (natoms lines, fractional for CRYSTAL/SLAB,
    //   EXPT | SUPERCELL | COORPRT | STOP | END     Cartesian for POLYMER)
    // The space group -> crystal system -> lattice-param count + cell angles are the
    // standard crystallographic mapping. Lattice constants are already in Angstrom.
    private static func loadCRYSCALr1(_ url: URL) throws -> LoadedScene {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.components(separatedBy: "\n")
        enum E: Error { case malformed(String) }
        func tok(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        var idx = 0
        func next() -> String? { guard idx < lines.count else { return nil }; defer { idx += 1 }; return lines[idx] }

        _ = next()                                     // title
        guard let kind = next()?.trimmingCharacters(in: .whitespaces).uppercased() else {
            throw E.malformed("no record kind")
        }
        _ = next()                                     // <i> <j> <k>

        // space group: integer number or a symbol like "F M 3 M".
        let spgTok = tok(next() ?? "")
        let spgNumber: Int = {
            if spgTok.count == 1, let n = Int(spgTok[0]) { return n }
            // symbol form: map the few that appear in the fixtures
            let sym = spgTok.joined().uppercased()
            if sym == "FM3M" { return 225 }            // cubic
            if sym == "PMCN" { return 53 }             // orthorhombic
            return 0
        }()

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
            default: return spgNumber == 53 ? .orthorhombic : .cubic
            }
        }()
        // how many numbers the lattice-parameter line carries for this system
        let nLat: Int = { switch system {
            case .cubic: return 1
            case .tetragonal, .trigonal, .hexagonal: return 2
            case .orthorhombic: return 3
            case .mono: return 4                 // a, b, c, beta
            case .tri: return 6                  // a, b, c, alpha, beta, gamma
        }}()

        // lattice constants across possibly several lines — take the first nLat floats.
        var lats: [Float] = []
        while lats.count < nLat, let line = next() {
            for t in tok(line) { if let v = Float(t) { lats.append(v); if lats.count == nLat { break } } }
        }
        guard lats.count == nLat else { throw E.malformed("bad lattice constants") }

        let cell: Cell = {
            switch system {
            case .cubic:
                return Cell.fromLattice(a: lats[0], b: lats[0], c: lats[0], alpha: 90, beta: 90, gamma: 90)
            case .tetragonal, .hexagonal:
                let gamma: Float = (system == .hexagonal) ? 120 : 90
                return Cell.fromLattice(a: lats[0], b: lats[0], c: lats[1], alpha: 90, beta: 90, gamma: gamma)
            case .trigonal:
                // hexagonal setting: a=b, gamma=120 (the form the fixtures use).
                return Cell.fromLattice(a: lats[0], b: lats[0], c: lats[1], alpha: 90, beta: 90, gamma: 120)
            case .orthorhombic:
                return Cell.fromLattice(a: lats[0], b: lats[1], c: lats[2], alpha: 90, beta: 90, gamma: 90)
            case .mono:
                // standard setting: unique axis b, beta = lats[3]; a,b,c = lats[0..3].
                return Cell.fromLattice(a: lats[0], b: lats[1], c: lats[2], alpha: 90, beta: lats[3], gamma: 90)
            case .tri:
                return Cell.fromLattice(a: lats[0], b: lats[1], c: lats[2], alpha: lats[3], beta: lats[4], gamma: lats[5])
            }
        }()

        // natoms, then atom lines. CRYSTAL/SLAB coords are fractional; POLYMER are Cartesian.
        let isPolymer = (kind == "POLYMER")
        let natoms = Int(tok(next() ?? "").first ?? "") ?? 0
        var atoms: [Atom] = []
        for _ in 0..<natoms {
            guard let line = next() else { break }
            let t = tok(line)
            guard t.count >= 4, let Z = Int(t[0]) else { continue }
            guard let x = Float(t[1]), let y = Float(t[2]), let z = Float(t[3]) else { continue }
            let sym = Table.id(Z)
            if isPolymer {
                atoms.append(Atom(coord: SIMD3<Float>(x, y, z), atomicNumber: Z, label: sym))
            } else {
                atoms.append(Atom(coord: cell.cartesian(SIMD3<Float>(x, y, z)), atomicNumber: Z, label: sym))
            }
            if isPolymer {
                // polymer atom lines occasionally carry extra integers (bonding) — ignore
            }
        }

        var out = LoadedScene()
        out.title = url.lastPathComponent
        out.atoms = atoms
        out.isCrystal = !isPolymer
        if !isPolymer { out.cell = cell }
        return out
    }

    private static let b2a: Float = 0.52917721067

    private static func loadCube(_ url: URL) throws -> LoadedScene {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var lines = raw.components(separatedBy: "\n")
        // tolerate files that lack a trailing newline by trimming empties between
        // records but KEEP blank comment lines (lines 0-1) — index by reading.
        func nextTokenLine() -> [String]? {
            while !lines.isEmpty {
                let line = lines.removeFirst()
                // only skip truly-empty separator lines; keep lines with content
                // (even if just whitespace) as they may carry tokens.
                if line.isEmpty { continue }
                return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
            return nil
        }
        // two comment lines (discard)
        _ = nextTokenLine(); _ = nextTokenLine()

        // natoms, origin (Bohr). If natoms < 0 there are multiple orbitals.
        guard let h = nextTokenLine(), let nAtomsT = Int(h[0]) else {
            throw ParseError.parse(path: url.path, line: 3, reason: "bad cube header")
        }
        let multiOrb = nAtomsT < 0
        let natoms = abs(nAtomsT)
        // origin is in the same units as the axes; the per-axis unit flag (above)
        // decides the conversion. Use Bohr default when there are no axes to read.
        let originRaw = SIMD3<Float>(Float(h[1]) ?? 0, Float(h[2]) ?? 0, Float(h[3]) ?? 0)

        // axis counts + step vectors. Gaussian cube writes a SIGNED voxel count per
        // axis: the magnitude is the sample count and the sign is the unit flag
        // (negative = Angstrom, positive = Bohr). All three axes must agree on the
        // unit (mixed signs are rejected); the origin, atoms and grid vectors are all
        // converted Bohr->Angstrom only when the file is in Bohr units.
        var nAxis = [0, 0, 0]
        var dx = [SIMD3<Float>(0,0,0), SIMD3<Float>(0,0,0), SIMD3<Float>(0,0,0)]
        var bohrUnits: Bool? = nil
        for i in 0..<3 {
            guard let t = nextTokenLine(), let ni = Int(t[0]) else { throw ParseError.parse(path: url.path, line: 4+i, reason: "bad cube axis") }
            let axisBohr = ni >= 0
            if let prev = bohrUnits, prev != axisBohr {
                throw ParseError.parse(path: url.path, line: 4+i, reason: "mixed-sign cube axes (units must agree)")
            }
            bohrUnits = axisBohr
            nAxis[i] = abs(ni)
            dx[i] = SIMD3<Float>(Float(t[1]) ?? 0, Float(t[2]) ?? 0, Float(t[3]) ?? 0)
        }
        let scale = (bohrUnits ?? true) ? b2a : 1.0
        dx = dx.map { $0 * scale }
        let nx = nAxis[0], ny = nAxis[1], nz = nAxis[2]
        // spanning vectors v(i) = (n(i)-1)*dx(i)
        let vec = [dx[0]*Float(max(1,nx)-1), dx[1]*Float(max(1,ny)-1), dx[2]*Float(max(1,nz)-1)]

        // atom records: Z, charge, x, y, z (in the same units as the axes)
        let origin = originRaw * scale
        var atoms: [Atom] = []
        for _ in 0..<natoms {
            guard let t = nextTokenLine(), let Z = Int(t[0]) else { throw ParseError.parse(path: url.path, line: 0, reason: "short cube atoms") }
            let p = SIMD3<Float>(Float(t[2]) ?? 0, Float(t[3]) ?? 0, Float(t[4]) ?? 0) * scale
            atoms.append(Atom(coord: p, atomicNumber: Z, label: Table.id(Z)))
        }
        // optional MO record if multiple orbitals: consume the MO-count/indices
        // line so its integer tokens aren't mistaken for grid values.
        if multiOrb {
            _ = nextTokenLine()
        }

        // remaining tokens are the grid values, x-fastest, flattened across all
        // sub-grids (orbitals). Take the first nx*ny*nz block as the field; any
        // further orbitals are ignored (single isosurface per file for now).
        let needed = nx * ny * nz
        var values: [Float] = []
        values.reserveCapacity(needed)
        while values.count < needed, let tok = nextTokenLine() {
            for s in tok { if values.count < needed, let v = Float(s) { values.append(v) } }
        }
        guard values.count == needed else {
            throw ParseError.parse(path: url.path, line: 0, reason: "cube grid short (\(values.count)/\(needed))")
        }
        var minV = values[0], maxV = values[0]
        for v in values { if v < minV { minV = v }; if v > maxV { maxV = v } }

        var out = LoadedScene()
        out.atoms = atoms
        out.scalarField = ScalarField(nx: nx, ny: ny, nz: nz, origin: origin, vec: vec,
                                      values: values, minValue: minV, maxValue: maxV)
        out.title = url.lastPathComponent
        return out
    }
}

// Minimal element-symbol helper used by the cube + WIEN2k readers (avoids
// ElementTable's full API which needs the renderer).
enum Table {
    static func id(_ z: Int) -> String {
        let sym = ["H","He","Li","Be","B","C","N","O","F","Ne","Na","Mg","Al","Si","P","S","Cl","Ar",
                   "K","Ca","Sc","Ti","V","Cr","Mn","Fe","Co","Ni","Cu","Zn","Ga","Ge","As","Se","Br","Kr"]
        return (z >= 1 && z <= sym.count) ? sym[z-1] : "\(z)"
    }
    /// Parse an element symbol to atomic number; returns 0 if unknown.
    static func z(_ s: String) -> Int {
        let table: [String: Int] = [
            "H":1,"HE":2,"LI":3,"BE":4,"B":5,"C":6,"N":7,"O":8,"F":9,"NE":10,"NA":11,"MG":12,
            "AL":13,"SI":14,"P":15,"S":16,"CL":17,"AR":18,"K":19,"CA":20,"SC":21,"TI":22,
            "V":23,"CR":24,"MN":25,"FE":26,"CO":27,"NI":28,"CU":29,"ZN":30,"GA":31,"GE":32,
            "AS":33,"SE":34,"BR":35,"KR":36,"RB":37,"SR":38,"Y":39,"ZR":40,"NB":41,"MO":42
        ]
        return table[s.uppercased()] ?? 0
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
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return raw.components(separatedBy: "\n").filter { $0.contains(coordHeader) }.count
    }

    /// Parse one coordinate block into a molecule. frameIndex -1 => last block.
    static func load(_ url: URL, frameIndex: Int) throws -> LoadedScene {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            enum E: Error { case io }
            throw E.io
        }
        let lines = raw.components(separatedBy: "\n")
        // Collect the start line of every coordinate block.
        var blockStarts: [Int] = []
        for (i, line) in lines.enumerated() where line.contains(coordHeader) { blockStarts.append(i) }
        guard !blockStarts.isEmpty else { enum E: Error { case noCoords }; throw E.noCoords }
        let target = frameIndex < 0 ? blockStarts.count - 1 : min(max(0, frameIndex), blockStarts.count - 1)
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
            guard toks.count >= 4, let x = Float(toks[1]), let y = Float(toks[2]),
                  let z = Float(toks[3]) else { break }   // next section reached
            let Z = ElementTable.atomicNumber(toks[0])
            let sym = Z == 0 ? toks[0] : ElementTable.symbol(Z)
            atoms.append(Atom(coord: SIMD3<Float>(x, y, z), atomicNumber: Z, label: sym))
            idx += 1
        }
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

// FHI-aims coord.out structure (ported from XCrySDen's F/fhi_coord2xcr.f):
//   <a1> <a2> <a3>        (lattice vectors as 3 columns, Bohr -> Angstrom)
//   <n_all_species>
//   [per species:]
//   <n_i_species>
//   <name>                 (element name, e.g. "Gallium", "Arsenic", "hy_1.25")
//   (<x> <y> <z> <T/F>)*n  (Cartesian coords, Bohr -> Angstrom; flag ignored)
internal func loadFHIaims(_ url: URL) throws -> LoadedScene {
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = raw.components(separatedBy: "\n")
    enum E: Error { case malformed(String) }
    func tok(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
    var idx = 0
    func next() -> String? { guard idx < lines.count else { return nil }; defer { idx += 1 }; return lines[idx] }

    // 3 lattice columns (read row-major but they are columns: a(j,i)).
    var cols = [SIMD3<Float>]()
    for _ in 0..<3 {
        guard let line = next() else { throw E.malformed("short lattice") }
        let t = tok(line)
        guard t.count >= 3, let x = Float(t[0]), let y = Float(t[1]), let z = Float(t[2]) else {
            throw E.malformed("bad lattice vector")
        }
        cols.append(SIMD3<Float>(x, y, z) * bohr2ang)
    }
    let cell = Cell(a: cols[0], b: cols[1], c: cols[2])

    // number of species
    guard let nsLine = next(), let nSpecies = Int(tok(nsLine).first ?? "") else {
        throw E.malformed("bad n_all_species")
    }
    var atoms: [Atom] = []
    for _ in 0..<nSpecies {
        guard let cLine = next(), let count = Int(tok(cLine).first ?? "") else {
            throw E.malformed("bad species count")
        }
        guard let nameLine = next() else { throw E.malformed("bad species name") }
        let speciesName = nameLine.trimmingCharacters(in: .whitespaces)
        let Z = fhiSpeciesZ(speciesName)
        let sym = Z == 0 ? speciesName : ElementTable.symbol(Z)
        for _ in 0..<count {
            guard let line = next() else { throw E.malformed("short atom") }
            let t = tok(line)
            guard t.count >= 4, let x = Float(t[0]), let y = Float(t[1]), let z = Float(t[2]) else {
                throw E.malformed("bad atom coord")
            }
            atoms.append(Atom(coord: SIMD3<Float>(x, y, z) * bohr2ang, atomicNumber: Z, label: sym))
        }
    }

    var out = LoadedScene()
    out.atoms = atoms
    out.cell = cell
    out.isCrystal = true
    out.title = url.lastPathComponent
    return out
}

/// QE PWscf band structure (`.bands` file, or a `.out` forced with `--bands`):
/// parse the `bands (ev):` k-point blocks in Swift into a BandStructure and wrap
/// it in a band-only LoadedScene (no atoms/cell). The MainWindowController swaps
/// the 3D canvas for the 2D Grapher when scene.bandStructure != nil.
internal func loadBands(_ url: URL) throws -> LoadedScene {
    let raw = try String(contentsOf: url, encoding: .utf8)
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
    // Otherwise fall back to 2- then 1-letter symbol prefix.
    if upper.count >= 2, Table.z(String(upper.prefix(2))) != 0 {
        return Table.z(String(upper.prefix(2)))
    }
    return Table.z(String(upper.prefix(1)))
}

/// FHI-aims element names (uppercased) -> atomic number. Covers the names that
/// appear in the example set and common alternatives; built once.
private let fhiNameTable: [String: Int] = {
    var t: [String: Int] = [:]
    let pairs: [(String,Int)] = [
        ("HYDROGEN",1),("HELIUM",2),("LITHIUM",3),("BERYLLIUM",4),("BORON",5),
        ("CARBON",6),("NITROGEN",7),("OXYGEN",8),("FLUORINE",9),("NEON",10),
        ("SODIUM",11),("MAGNESIUM",12),("ALUMINIUM",13),("ALUMINUM",13),("SILICON",14),
        ("PHOSPHORUS",15),("SULFUR",16),("SULPHUR",16),("CHLORINE",17),("ARGON",18),
        ("POTASSIUM",19),("CALCIUM",20),("TITANIUM",22),("VANADIUM",23),("CHROMIUM",24),
        ("MANGANESE",25),("IRON",26),("COBALT",27),("NICKEL",28),("COPPER",29),("ZINC",30),
        ("GALLIUM",31),("GERMANIUM",32),("ARSENIC",33),("SELENIUM",34),("BROMINE",35),
        ("KRYPTON",36),("RUBIDIUM",37),("STRONTIUM",38),("ZIRCONIUM",40),("NIOBIUM",41),
        ("MOLYBDENUM",42),("TIN",50),("ANTIMONY",51),("IODINE",53),("XENON",54),
        ("CESIUM",55),("BARIUM",56),("LANTHANUM",57),("LEAD",82),("URANIUM",92)
    ]
    for (n, z) in pairs { t[n] = z }
    return t
}()
