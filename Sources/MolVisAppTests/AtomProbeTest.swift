import XCTest
import simd
@testable import MolVisApp
final class AtomProbeTest: XCTestCase {
    // Regression for a real QE `.pwi` whose atoms were rendered at the origin: the C parser only
    // handled the braced "ATOMIC_POSITIONS {unit}" form, so the brace-less "ATOMIC_POSITIONS
    // crystal" form left pos_unit stuck at the "alat" default. With ibrav=0 (+CELL_PARAMETERS,
    // no celldm(1)) that made pos_scale = celldm[1]*BOHR_TO_ANG = 0, zeroing every atom. Fix was
    // in molenv_parse.c to parse the brace-less unit keyword.
    func testPwiBraceLessAtomicPositions() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // MolVisAppTests/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Assets/qe_band.in")
        let s = try Parser.load(url, as: .pwi)
        XCTAssertEqual(s.atoms.count, 10, "qe_band.in has 10 atoms")
        XCTAssertTrue(s.isCrystal, "a cell-bearing .pwi is a crystal")
        // Atoms must NOT all sit at the origin — Fe1 has fractional ~(0.779,0.779,0.779) which
        // maps to several Å in Cartesian space once the cell is applied.
        // The bug collapsed every atom to (0,0,0). The invariant is that the structure has real
        // spatial extent: the widest-spread atom must sit several Å from the origin. (Some atoms
        // legitimately sit near the origin, so we check the extreme, not the nearest.)
        var maxExtent: Float = 0
        for a in s.atoms { maxExtent = max(maxExtent, length(a.coord)) }
        XCTAssertGreaterThan(maxExtent, 5.0,
                             "force-bearing qe_band.in must render with a real crystal extent, not "
                             + "all atoms at the origin (maxExtent=\(maxExtent))")
    }
}
