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

enum Parser {
    static func load(_ url: URL) throws -> LoadedScene {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParseError.io(path: url.path, reason: "file not found")
        }
        let cPath = url.path.cString(using: .utf8)!
        let ext = url.pathExtension.lowercased()
        let scene: UnsafeMutablePointer<MolEnvScene>?
        switch ext {
        case "xsf": scene = parse_xsf(cPath)
        case "xyz": scene = parse_xyz(cPath)
        case "pdb": scene = parse_pdb(cPath)
        case "axsf": scene = parse_axsf(cPath, 0)
        default: throw ParseError.io(path: url.path, reason: "unknown extension \(ext)")
        }
        guard let scene else {
            let msg = String(cString: molenv_last_error())
            // "path:line: reason" or "path: reason"
            let parts = msg.components(separatedBy: ": ")
            if parts.count >= 3, let ln = Int(parts[1]) {
                throw ParseError.parse(path: String(parts[0]), line: ln, reason: parts.dropFirst(2).joined(separator: ": "))
            }
            throw ParseError.parse(path: url.path, line: 0, reason: msg)
        }
        defer { molenv_scene_free(scene) }
        var s = scene.pointee
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
