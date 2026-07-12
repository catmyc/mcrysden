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
}

/// A parser format that can be forced via a CLI flag (`--xsf`, `--pdb`, ...).
/// When omitted, `Parser.load` falls back to the file extension.
enum ParseFormat {
    case xsf, axsf, xyz, pdb, pwi, pwo, cif, poscar, cube, bxsf
    /// Map a lowercased path extension to a format. Returns nil if unknown.
    init?(ext: String) {
        switch ext {
        case "xsf": self = .xsf
        case "axsf": self = .axsf
        case "xyz": self = .xyz
        case "pdb": self = .pdb
        case "pwi", "in", "inp": self = .pwi
        case "pwo", "out": self = .pwo
        case "cif": self = .cif
        case "poscar", "contcar", "vasp": self = .poscar
        case "cube": self = .cube
        case "bxsf": self = .bxsf
        default: return nil
        }
    }
}

enum Parser {
    /// Load a structure file. When `format` is nil, the parser is chosen from
    /// the URL's path extension; otherwise the forced format wins.
    /// Load a structure file, optionally forcing the parser format AND/OR a
    /// specific AXSF animation frame. When `frameIndex > 0` the frame-indexed
    /// AXSF path is used (format is ignored — animation is an AXSF-only feature);
    /// otherwise `load(_:as:)` is used. This single entry point backs both the
    /// GUI open path and the `--frame` CLI flag.
    static func load(_ url: URL, as format: ParseFormat? = nil, frameIndex: Int = 0) throws -> LoadedScene {
        if frameIndex > 0 {
            // Honor a forced format for animated files too (e.g. a renamed
            // .pwo passed as --pwo --frame 1); otherwise fall back to extension.
            return try load(url, frameIndex: frameIndex, as: format)
        }
        return try load(url, as: format)
    }

    static func load(_ url: URL, as format: ParseFormat? = nil) throws -> LoadedScene {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParseError.io(path: url.path, reason: "file not found")
        }
        let effective = format ?? ParseFormat(ext: url.pathExtension.lowercased())
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
        let effective = format ?? ParseFormat(ext: url.pathExtension.lowercased())
        switch effective {
        case .pwo: return Int(molenv_pwo_frame_count(cPath))
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
        let effective = format ?? ParseFormat(ext: url.pathExtension.lowercased())
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
        out.scalarField = fs.bands.first
        out.fermiSurface = fs
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
        let originBohr = SIMD3<Float>(Float(h[1]) ?? 0, Float(h[2]) ?? 0, Float(h[3]) ?? 0)
        let origin = originBohr * b2a

        // axis counts + step vectors (Bohr)
        var nAxis = [0, 0, 0]
        var dx = [SIMD3<Float>(0,0,0), SIMD3<Float>(0,0,0), SIMD3<Float>(0,0,0)]
        for i in 0..<3 {
            guard let t = nextTokenLine(), let ni = Int(t[0]) else { throw ParseError.parse(path: url.path, line: 4+i, reason: "bad cube axis") }
            nAxis[i] = ni
            dx[i] = SIMD3<Float>(Float(t[1]) ?? 0, Float(t[2]) ?? 0, Float(t[3]) ?? 0) * b2a
        }
        let nx = nAxis[0], ny = nAxis[1], nz = nAxis[2]
        // spanning vectors v(i) = (n(i)-1)*dx(i)
        let vec = [dx[0]*Float(max(1,nx)-1), dx[1]*Float(max(1,ny)-1), dx[2]*Float(max(1,nz)-1)]

        // atom records: Z, charge, x, y, z (Bohr)
        var atoms: [Atom] = []
        for _ in 0..<natoms {
            guard let t = nextTokenLine(), let Z = Int(t[0]) else { throw ParseError.parse(path: url.path, line: 0, reason: "short cube atoms") }
            let p = SIMD3<Float>(Float(t[2]) ?? 0, Float(t[3]) ?? 0, Float(t[4]) ?? 0) * b2a
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

// Minimal element-symbol helper used by the cube reader (avoids ElementTable's
// full API which needs the renderer).
enum Table {
    static func id(_ z: Int) -> String {
        let sym = ["H","He","Li","Be","B","C","N","O","F","Ne","Na","Mg","Al","Si","P","S","Cl","Ar",
                   "K","Ca","Sc","Ti","V","Cr","Mn","Fe","Co","Ni","Cu","Zn","Ga","Ge","As","Se","Br","Kr"]
        return (z >= 1 && z <= sym.count) ? sym[z-1] : "\(z)"
    }
}
