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
}

/// A parser format that can be forced via a CLI flag (`--xsf`, `--pdb`, ...).
/// When omitted, `Parser.load` falls back to the file extension.
enum ParseFormat {
    case xsf, axsf, xyz, pdb, pwi, pwo, cif, poscar
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
        let cPath = url.path.cString(using: .utf8)!
        let effective = format ?? ParseFormat(ext: url.pathExtension.lowercased())
        guard let effective else {
            throw ParseError.io(path: url.path, reason: "unknown extension \(url.pathExtension)")
        }
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
}
