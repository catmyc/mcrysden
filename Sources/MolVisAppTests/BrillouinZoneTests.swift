import XCTest
import simd
@testable import MolVisApp

// Brillouin-zone geometry. The heavy Wigner-Seitz construction
// (Geometry.polyhedronFaces) validates the fcc BZ = truncated octahedron
// (14 faces); the result is checked against the analytic face count.
final class BrillouinZoneTests: XCTestCase {

    func testFCCBrillouinZone() {
        let a: Float = 5.43
        // Conventional fcc cell: 4 atoms at the corners + face centers, all Si.
        // Centering offsets (0,½,½) etc. must be detected as face-centered (F).
        let atoms: [Atom] = [SIMD3(0,0,0), SIMD3(0, 0.5*a, 0.5*a),
                             SIMD3(0.5*a, 0, 0.5*a), SIMD3(0.5*a, 0.5*a, 0)]
            .map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
        let cell = Cell(a: SIMD3<Float>(5.43, 0, 0),
                        b: SIMD3<Float>(0, 5.43, 0),
                        c: SIMD3<Float>(0, 0, 5.43))
        let bz = BrillouinZone.build(cell: cell, atoms: atoms)
        XCTAssertNotNil(bz, "fcc BZ build returned nil")
        XCTAssertEqual(bz?.faces.count, 14, "fcc BZ = truncated octahedron = 14 faces")
    }

    // Regression: a highly anisotropic SLAB cell (GaAsH) must also build a valid
    // (6-face) BZ — the isotropic shellCutoff filter previously returned nil here.
    func testSlabBZBuilds() throws {
        let scene = Scene(loaded: try Parser.load(
            URL(fileURLWithPath: #file).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/zns_like.xsf")))
        XCTAssertNotNil(scene.cell)
        let bz = BrillouinZone.build(cell: scene.cell!, atoms: scene.baseAtoms)
        XCTAssertNotNil(bz, "anisotropic crystal BZ must build (was nil before fix)")
        XCTAssertGreaterThanOrEqual(bz!.faces.count, 4,
            "BZ must be a closed polyhedron (>= 4 faces)")
    }
}
