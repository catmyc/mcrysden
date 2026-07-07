import XCTest
import Metal
import simd
@testable import MolVisApp
private enum Thrown: Error { case msg(String) }

// Ground-truth: an atom is "inside the displayed unit cell" iff its fractional
// coordinates w.r.t. the cell edges are in [0, 1). This is the invariant
// drawCell must guarantee.
final class CellEnclosureTests: XCTestCase {
    private func load(_ path: String) throws -> Scene {
        return Scene(loaded: try Parser.load(URL(fileURLWithPath: path)))
    }

    // Replicates drawCell's centering so the test checks the SAME corners the
    // renderer draws.
    private func displayedCorners(_ scene: Scene) -> [SIMD3<Float>]? {
        guard let cell = scene.cell else { return nil }
        let a = cell.a, b = cell.b, c = cell.c
        let n = max(1, scene.atoms.count)
        var centroid = SIMD3<Float>.zero
        for at in scene.atoms { centroid += at.coord }
        centroid /= Float(n)
        let cellCenter = (a + b + c) * 0.5
        let offset = centroid - cellCenter
        let o = offset
        return [o, a + o, a + b + o, b + o, c + o, a + c + o, b + c + o, a + b + c + o]
    }

    private func fractional(_ p: SIMD3<Float>, o: SIMD3<Float>, a: SIMD3<Float>,
                            b: SIMD3<Float>, c: SIMD3<Float>) -> SIMD3<Float> {
        let d = p - o
        let det = a.x * (b.y * c.z - c.y * b.z)
                - b.x * (a.y * c.z - c.y * a.z)
                + c.x * (a.y * b.z - b.y * a.z)
        let fx = (d.x * (b.y * c.z - c.y * b.z) - b.x * (d.y * c.z - c.y * d.z) + c.x * (d.y * b.z - b.y * d.z)) / det
        let fy = (a.x * (d.y * c.z - c.y * d.z) - d.x * (a.y * c.z - c.y * a.z) + c.x * (a.y * d.z - d.y * a.z)) / det
        let fz = (a.x * (b.y * d.z - d.y * b.z) - b.x * (a.y * d.z - d.y * a.z) + d.x * (a.y * b.z - b.y * a.z)) / det
        return SIMD3<Float>(fx, fy, fz)
    }

    private func inside(_ f: SIMD3<Float>) -> Bool {
        let lo: Float = -0.02, hi: Float = 1.02
        return f.x >= lo && f.x <= hi && f.y >= lo && f.y <= hi && f.z >= lo && f.z <= hi
    }

    func testDisplayedCellEnclosesAtoms() throws {
        let files: [(String, String)] = [
            ("si110", "/Users/mao/dev/mcrysden/Sources/MolVisAppTests/Fixtures/si110.xsf"),
            ("ZnS",   "/Users/mao/dev/mcrysden/Sources/MolVisAppTests/Fixtures/zns_like.xsf"),
        ]
        for (tag, path) in files {
            let s = try load(path)
            guard let cell = s.cell else { print("[cell3d] " + tag + ": no cell"); continue }
            guard let corners = displayedCorners(s) else { continue }
            let o = corners[0]
            let a = corners[1] - corners[0]
            let b = corners[3] - corners[0]
            let c = corners[4] - corners[0]
            var allInside = true
            for (k, at) in s.atoms.enumerated() {
                let f = fractional(at.coord, o: o, a: a, b: b, c: c)
                let inCell = inside(f)
                if !inCell { allInside = false }
                print("[cell3d] " + tag + " atom" + String(k) + " coord=" + String(describing: at.coord) + " fractional=" + String(describing: f) + " inside=" + String(inCell))
            }
            print("[cell3d] " + tag + " allAtomsEnclosed=" + String(allInside))
            XCTAssertTrue(allInside, tag + ": displayed cell must enclose all atoms")
        }
    }
}
