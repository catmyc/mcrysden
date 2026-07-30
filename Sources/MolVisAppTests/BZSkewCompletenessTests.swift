import XCTest
import simd
@testable import MolVisApp

final class BZSkewCompletenessTests: XCTestCase {
    // This reciprocal basis is a unimodular, badly skewed basis of Z^3:
    //   g1 = 3 e1 + 2 e2, g2 = 2 e1 + e2, g3 = e3.
    // The old length-ratio box is [1, 2, 4], but the shortest vector e2 is
    // (2, -3, 0), outside that box. Its plane is therefore an exterior-plane
    // regression rather than an ordinary in-box cutting-plane regression.
    private func skewCell() -> Cell {
        let twoPi = Float(2 * Double.pi)
        return Cell(a: SIMD3<Float>(-twoPi, 2 * twoPi, 0),
                    b: SIMD3<Float>(2 * twoPi, -3 * twoPi, 0),
                    c: SIMD3<Float>(0, 0, twoPi))
    }

    func testSkewExteriorPlaneExpandsBoxAndCertifiesCubicTopology() throws {
        let cell = skewCell()
        let reciprocal = cell.reciprocalVectors
        let basis = [reciprocal.a, reciprocal.b, reciprocal.c]
        let lengths = basis.map { Double(simd_length($0)) }
        let longest = lengths.max()!
        let oldBounds = lengths.map { Int(ceil(longest / $0)) }

        let relevant = reciprocal.a * 2 - reciprocal.b * 3
        XCTAssertEqual(oldBounds, [1, 2, 4])
        XCTAssertGreaterThan(simd_length(relevant), 0.99)
        XCTAssertLessThan(simd_length(relevant), simd_length(reciprocal.a))
        XCTAssertGreaterThan(2, oldBounds[0])
        XCTAssertGreaterThan(3, oldBounds[1])

        var diagnostics = BZConstructionDiagnostics()
        let built = BrillouinZone.build(cell: cell,
                                        atoms: [Atom(coord: .zero, atomicNumber: 14, label: "Si")],
                                        diagnostics: &diagnostics)
        let bz = try XCTUnwrap(built, "diagnostics: \(diagnostics)")

        XCTAssertTrue(diagnostics.certified)
        XCTAssertTrue(diagnostics.exteriorCertified)
        XCTAssertGreaterThan(diagnostics.coefficientDomainExpansions, 0)
        XCTAssertGreaterThanOrEqual(diagnostics.coefficientBounds.x, 2)
        XCTAssertGreaterThanOrEqual(diagnostics.coefficientBounds.y, 3)
        XCTAssertLessThanOrEqual(diagnostics.candidateEnumerationWork,
                                 BrillouinZone.coefficientEnumerationWorkBudget)

        // The larger integer-domain result is known independently here: the
        // unimodular reciprocal basis generates the ordinary cubic Z^3 lattice,
        // whose first zone is a six-faced cube with four vertices per face.
        XCTAssertEqual(bz.faces.count, 6)
        XCTAssertEqual(bz.faces.map(\.count), [4, 4, 4, 4, 4, 4])
        XCTAssertEqual(bz.normals.count, 6)
    }

    func testSkewConstructionAndDiagnosticsAreDeterministic() throws {
        let cell = skewCell()
        let atoms = [Atom(coord: .zero, atomicNumber: 14, label: "Si")]
        var firstDiagnostics = BZConstructionDiagnostics()
        var secondDiagnostics = BZConstructionDiagnostics()
        let firstBuilt = BrillouinZone.build(cell: cell, atoms: atoms, diagnostics: &firstDiagnostics)
        let secondBuilt = BrillouinZone.build(cell: cell, atoms: atoms, diagnostics: &secondDiagnostics)
        let first = try XCTUnwrap(firstBuilt, "first diagnostics: \(firstDiagnostics)")
        let second = try XCTUnwrap(secondBuilt, "second diagnostics: \(secondDiagnostics)")

        XCTAssertEqual(first.faces, second.faces)
        XCTAssertEqual(first.normals, second.normals)
        XCTAssertEqual(firstDiagnostics.solverNeighborCounts, secondDiagnostics.solverNeighborCounts)
        XCTAssertEqual(firstDiagnostics.coefficientDomainExpansions,
                       secondDiagnostics.coefficientDomainExpansions)
        XCTAssertEqual(firstDiagnostics.coefficientBounds, secondDiagnostics.coefficientBounds)
        XCTAssertEqual(firstDiagnostics.candidateEnumerationWork,
                       secondDiagnostics.candidateEnumerationWork)
    }
}
