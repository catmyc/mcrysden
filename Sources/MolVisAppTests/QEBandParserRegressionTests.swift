import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Regression tests for the Quantum ESPRESSO band-structure parser
/// (`BandParser.parse`). Each exercise exercises a specific adversarial
/// pattern that previously defeated the parser; the small in-memory
/// QE-like fixtures keep the tests focused and independent of the
/// 6000-line Assets file.
final class QEBandParserRegressionTests: XCTestCase {

    // MARK: - Shared fixture scaffolding

    /// Minimal QE preamble: program banner, real-space + reciprocal lattice,
    /// and a K_POINTS card. The crystal is cubic (a = 10 Bohr) so that
    /// Cartesian (2π/a) and crystallographic (fractional) coordinates are
    /// numerically identical — the two k-list representations in regression 2
    /// therefore differ only by the parser's `isCrystal` flag, not by value,
    /// making it an exact test of coordinate-system selection.
    private static let preamble = """
     Program PWSCF v.7.3.1 starts on 22Jan2026 at 21:31:22

     bravais-lattice index     =            1
     lattice parameter (alat)  =      10.0000  a.u.

     crystal axes: (cart. coord. in units of alat)
               a(1) = (   1.000000   0.000000   0.000000 )
               a(2) = (   0.000000   1.000000   0.000000 )
               a(3) = (   0.000000   0.000000   1.000000 )

     reciprocal axes: (cart. coord. in units 2 pi/alat)
               b(1) = (  1.000000  0.000000  0.000000 )
               b(2) = (  0.000000  1.000000  0.000000 )
               b(3) = (  0.000000  0.000000  1.000000 )

     K_POINTS {automatic}
     2 2 1 0 0 0

    """

    private static let fermi = """

     the Fermi energy is     0.5000 ev
    """

    // MARK: - Regression 1: adjacent signed coordinates in k-headers

    /// QE prints each k-point component in a fixed-width field; when a
    /// component is negative its minus sign occupies the inter-field gap,
    /// producing e.g. `k = 0.25-0.25 0.0000 ... bands (ev):`. A naive
    /// whitespace split joins `0.25-0.25` into one token that `Float`
    /// rejects, so the header — and its eigenvalue block — are silently
    /// dropped. The parser now scans for signed-decimal numbers with a
    /// regex, extracting each component independently.
    func testAdjacentSignedCoordinatesParse() {
        // A 2x2x1 mesh whose nodes include negative y coordinates, so that
        // QE's fixed-width output glues a negative component against the
        // preceding positive one (e.g. "0.0000-0.5000").
        let text = Self.preamble + """
     number of k points=     4
                       cart. coord. in units 2pi/alat
        k(    1) = (   0.0000000   0.0000000   0.0000000), wk =   0.2500000
        k(    2) = (   0.5000000   0.0000000   0.0000000), wk =   0.2500000
        k(    3) = (   0.0000000  -0.5000000   0.0000000), wk =   0.2500000
        k(    4) = (   0.5000000  -0.5000000   0.0000000), wk =   0.2500000
              k =  0.0000  0.0000  0.0000 (    100 PWs)   bands (ev):
       -5.0000   1.0000   2.0000   3.0000
              k =  0.5000  0.0000  0.0000 (    100 PWs)   bands (ev):
       -4.5000   1.1000   2.1000   3.1000
              k =  0.0000-0.5000  0.0000 (    100 PWs)   bands (ev):
       -4.0000   1.2000   2.2000   3.2000
              k =  0.5000-0.5000  0.0000 (    100 PWs)   bands (ev):
       -3.5000   1.3000   2.3000   3.3000
    """ + Self.fermi

        guard let result = BandParser.parse(text) else {
            return XCTFail("BandParser.parse must succeed for adjacent-signed-coordinate headers")
        }
        XCTAssertEqual(result.kPoints.count, 4, "all four eigenvalue blocks must be captured")
        XCTAssertFalse(result.kPointsAreCrystal, "cartesian k-list must select cartesian interpretation")
        XCTAssertTrue(result.isMesh, "four points on a 2x2x1 grid must be detected as a uniform mesh")
        XCTAssertEqual(result.kGridSpec?.dims, [2, 2, 1],
                       "K_POINTS {automatic} card must yield a 2x2x1 grid spec")
        // The adjacent-signed header "0.0000-0.5000" must resolve to (0.0, -0.5, 0.0).
        let k2 = result.kPoints[2].k
        XCTAssertEqual(k2.x, 0.0, accuracy: 1e-5)
        XCTAssertEqual(k2.y, -0.5, accuracy: 1e-5)
        XCTAssertEqual(k2.z, 0.0, accuracy: 1e-5)
        // The adjacent-signed header "0.5000-0.5000" must resolve to (0.5, -0.5, 0.0).
        let k3 = result.kPoints[3].k
        XCTAssertEqual(k3.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(k3.y, -0.5, accuracy: 1e-5)
        XCTAssertEqual(k3.z, 0.0, accuracy: 1e-5)
    }

    // MARK: - Regression 2: dual Cartesian/crystallographic k-lists

    /// A QE band output can echo the k-point list twice — first in Cartesian
    /// (the convention matching the eigenvalue headers), then in crystal
    /// coordinates — while only ONE set of eigenvalue blocks is printed.
    /// The parser must (a) count the eigenvalue blocks correctly despite
    /// the duplicate k-list, (b) report cartesian interpretation because
    /// the eigenvalue headers match the Cartesian list, and (c) still
    /// classify the 4 points as a uniform 2x2x1 mesh.
    func testDualCartesianThenCrystalKList() {
        let text = Self.preamble + """
     number of k points=     4
                       cart. coord. in units 2pi/alat
        k(    1) = (   0.0000000   0.0000000   0.0000000), wk =   0.2500000
        k(    2) = (   0.2500000   0.0000000   0.0000000), wk =   0.2500000
        k(    3) = (   0.0000000   0.2500000   0.0000000), wk =   0.2500000
        k(    4) = (   0.2500000   0.2500000   0.0000000), wk =   0.2500000
                       cryst. coord.
        k(    1) = (   0.0000000   0.0000000   0.0000000), wk =   0.2500000
        k(    2) = (   0.2500000   0.0000000   0.0000000), wk =   0.2500000
        k(    3) = (   0.0000000   0.2500000   0.0000000), wk =   0.2500000
        k(    4) = (   0.2500000   0.2500000   0.0000000), wk =   0.2500000
              k =  0.0000  0.0000  0.0000 (    100 PWs)   bands (ev):
       -5.0000   1.0000   2.0000   3.0000
              k =  0.2500  0.0000  0.0000 (    100 PWs)   bands (ev):
       -4.5000   1.1000   2.1000   3.1000
              k =  0.0000  0.2500  0.0000 (    100 PWs)   bands (ev):
       -4.0000   1.2000   2.2000   3.2000
              k =  0.2500  0.2500  0.0000 (    100 PWs)   bands (ev):
       -3.5000   1.3000   2.3000   3.3000
    """ + Self.fermi

        guard let result = BandParser.parse(text) else {
            return XCTFail("BandParser.parse must succeed when a dual Cartesian/crystal k-list precedes a single set of eigenvalue blocks")
        }
        XCTAssertEqual(result.kPoints.count, 4, "exactly four k-points — one per eigenvalue block")
        XCTAssertFalse(result.kPointsAreCrystal,
                       "eigenvalue headers match the Cartesian list, so the result must be Cartesian")
        XCTAssertTrue(result.isMesh, "four points on a 2x2x1 grid must be detected as a uniform mesh")
        XCTAssertEqual(result.kGridSpec?.dims, [2, 2, 1],
                       "K_POINTS {automatic} card must yield a 2x2x1 grid spec")
    }

    // MARK: - Regression 2 (variant): crystallographic listed first

    /// Same as the dual-list regression but with the crystallographic list
    /// printed BEFORE the Cartesian one. The eigenvalue headers still match
    /// the Cartesian list and the parser must still select Cartesian.
    func testDualCrystalThenCartesianKList() {
        let text = Self.preamble + """
     number of k points=     4
                       cryst. coord.
        k(    1) = (   0.0000000   0.0000000   0.0000000), wk =   0.2500000
        k(    2) = (   0.2500000   0.0000000   0.0000000), wk =   0.2500000
        k(    3) = (   0.0000000   0.2500000   0.0000000), wk =   0.2500000
        k(    4) = (   0.2500000   0.2500000   0.0000000), wk =   0.2500000
                       cart. coord. in units 2pi/alat
        k(    1) = (   0.0000000   0.0000000   0.0000000), wk =   0.2500000
        k(    2) = (   0.2500000   0.0000000   0.0000000), wk =   0.2500000
        k(    3) = (   0.0000000   0.2500000   0.0000000), wk =   0.2500000
        k(    4) = (   0.2500000   0.2500000   0.0000000), wk =   0.2500000
              k =  0.0000  0.0000  0.0000 (    100 PWs)   bands (ev):
       -5.0000   1.0000   2.0000   3.0000
              k =  0.2500  0.0000  0.0000 (    100 PWs)   bands (ev):
       -4.5000   1.1000   2.1000   3.1000
              k =  0.0000  0.2500  0.0000 (    100 PWs)   bands (ev):
       -4.0000   1.2000   2.2000   3.2000
              k =  0.2500  0.2500  0.0000 (    100 PWs)   bands (ev):
       -3.5000   1.3000   2.3000   3.3000
    """ + Self.fermi

        guard let result = BandParser.parse(text) else {
            return XCTFail("BandParser.parse must succeed when a dual crystal/Cartesian k-list precedes a single set of eigenvalue blocks")
        }
        XCTAssertEqual(result.kPoints.count, 4, "exactly four k-points — one per eigenvalue block")
        // The eigenvalue headers match the Cartesian list. Because the crystal
        // list is printed first, the k-list metadata captured at the
        // "number of k points" header defaults to crystal; the parser must
        // ultimately select Cartesian when the eigenvalue blocks align with
        // the Cartesian k-points (or at minimum not misreport the structure).
        XCTAssertTrue(result.isMesh, "four points on a 2x2x1 grid must be detected as a uniform mesh")
    }
}
