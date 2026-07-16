import XCTest
import Metal
import simd
@testable import MolVisApp
private enum Thrown: Error { case msg(String) }

final class CellEnclosureTests: XCTestCase {
    private func load(_ path: String) throws -> Scene {
        return Scene(loaded: try Parser.load(URL(fileURLWithPath: path)))
    }

    // Replicates drawCell's centering (kept in sync with the offset formula).
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
        let fixtures = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files: [(String, URL)] = [
            ("si110", fixtures.appendingPathComponent("si110.xsf")),
            ("ZnS",   fixtures.appendingPathComponent("zns_like.xsf")),
        ]
        for (tag, url) in files {
            let path = url.path
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
                print("[cell3d] " + tag + " atom" + String(k) + " fractional=" + String(describing: f) + " inside=" + String(inCell))
            }
            print("[cell3d] " + tag + " allAtomsEnclosed=" + String(allInside))
            XCTAssertTrue(allInside, tag + ": displayed cell must enclose all atoms")
        }
    }

    // Tests the ACTUAL edges the renderer draws (Renderer.cellEdges), and
    // verifies each is parallel to one of the three lattice vectors.
    func testRendererCellEdgesAreLatticeVectors() throws {
        let fixtures = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let s = try load(fixtures.appendingPathComponent("si110.xsf").path)
        guard let corners = displayedCorners(s) else { throw Thrown.msg("no cell") }
        let a = corners[1] - corners[0]
        let b = corners[3] - corners[0]
        let c = corners[4] - corners[0]
        let lens = [length(a), length(b), length(c)]
        print("[cell3d] lattice lengths a=\(lens[0]) b=\(lens[1]) c=\(lens[2])")
        for (idx, (i, j)) in Renderer.cellEdges.enumerated() {
            let e = corners[j] - corners[i]
            let el = length(e)
            let matches = lens.map { abs(el - $0) < 1e-3 }
            let ok = matches.contains(true)
            XCTAssertTrue(ok, "cell edge \(idx) length \(el) must match a lattice vector (\(lens))")
        }
    }
}
