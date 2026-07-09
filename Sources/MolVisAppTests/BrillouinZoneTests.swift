import XCTest
import simd
@testable import MolVisApp

// Brillouin-zone geometry. The heavy Wigner-Seitz construction
// (Geometry.polyhedronFaces) validates the fcc BZ = truncated octahedron
// (14 faces); the result is checked against the analytic face count.
final class BrillouinZoneTests: XCTestCase {

    func testFCCBrillouinZone() {
        let a: Float = 5.43
        let atoms: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(0, 0.5*a, 0.5*a),
                                      SIMD3(0.5*a, 0, 0.5*a), SIMD3(0.5*a, 0.5*a, 0)]
        let cell = Cell(a: SIMD3<Float>(5.43, 0, 0),
                        b: SIMD3<Float>(0, 5.43, 0),
                        c: SIMD3<Float>(0, 0, 5.43))
        let bz = BrillouinZone.build(cell: cell, atoms: atoms)
        XCTAssertNotNil(bz, "fcc BZ build returned nil")
        XCTAssertEqual(bz?.faces.count, 14, "fcc BZ = truncated octahedron = 14 faces")
    }
}
