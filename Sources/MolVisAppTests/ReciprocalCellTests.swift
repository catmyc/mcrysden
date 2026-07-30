import simd
import XCTest

@testable import MolVisApp

final class ReciprocalCellTests: XCTestCase {
    private func vectorLength(_ vector: SIMD3<Float>) -> Double {
        sqrt(Double(dot(vector, vector)))
    }

    private func angle(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Double {
        let cosine = Double(dot(lhs, rhs)) / (vectorLength(lhs) * vectorLength(rhs))
        return acos(min(1, max(-1, cosine))) * 180 / Double.pi
    }

    private func assertZeroCell(_ cell: Cell, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(cell.a.isFinite && cell.b.isFinite && cell.c.isFinite,
                      file: file, line: line)
        XCTAssertEqual(cell.a, .zero, file: file, line: line)
        XCTAssertEqual(cell.b, .zero, file: file, line: line)
        XCTAssertEqual(cell.c, .zero, file: file, line: line)
    }

    private func assertZeroReciprocal(for cell: Cell,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let reciprocal = cell.reciprocalVectors
        let vectors = [reciprocal.a, reciprocal.b, reciprocal.c]
        XCTAssertTrue(vectors.allSatisfy { $0.isFinite }, file: file, line: line)
        XCTAssertTrue(vectors.allSatisfy { $0 == .zero }, file: file, line: line)
    }

    private func assertDualBasis(_ cell: Cell, accuracy: Float,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let reciprocal = cell.reciprocalVectors
        let direct = [cell.a, cell.b, cell.c]
        let dual = [reciprocal.a, reciprocal.b, reciprocal.c]
        for i in 0..<3 {
            for j in 0..<3 {
                let expected: Float = i == j ? 2 * .pi : 0
                XCTAssertEqual(dot(direct[i], dual[j]), expected, accuracy: accuracy,
                               "direct vector \(i), reciprocal vector \(j)",
                               file: file, line: line)
            }
        }
    }

    func testTriclinicParametersRoundTrip() {
        let cell = Cell.fromLattice(a: 4, b: 5, c: 6,
                                    alpha: 74, beta: 83, gamma: 67)

        XCTAssertEqual(vectorLength(cell.a), 4, accuracy: 1e-5)
        XCTAssertEqual(vectorLength(cell.b), 5, accuracy: 1e-5)
        XCTAssertEqual(vectorLength(cell.c), 6, accuracy: 1e-5)
        XCTAssertEqual(angle(cell.b, cell.c), 74, accuracy: 1e-4)
        XCTAssertEqual(angle(cell.a, cell.c), 83, accuracy: 1e-4)
        XCTAssertEqual(angle(cell.a, cell.b), 67, accuracy: 1e-4)
        XCTAssertGreaterThan(dot(cell.a, cross(cell.b, cell.c)), 0)
    }

    func testMonoclinicAndOrthogonalCells() {
        let monoclinic = Cell.fromLattice(a: 4, b: 5, c: 6,
                                          alpha: 90, beta: 110, gamma: 90)
        XCTAssertEqual(monoclinic.a, SIMD3(4, 0, 0))
        XCTAssertEqual(monoclinic.b.x, 0, accuracy: 1e-5)
        XCTAssertEqual(monoclinic.b.y, 5, accuracy: 1e-5)
        XCTAssertEqual(monoclinic.c.x, 6 * cos(Float(110) * .pi / 180), accuracy: 1e-5)
        XCTAssertEqual(monoclinic.c.y, 0, accuracy: 1e-5)
        XCTAssertEqual(monoclinic.c.z, 6 * sin(Float(110) * .pi / 180), accuracy: 1e-5)

        let orthogonal = Cell.fromLattice(a: 2, b: 3, c: 4,
                                          alpha: 90, beta: 90, gamma: 90)
        XCTAssertEqual(orthogonal.a.x, 2, accuracy: 1e-5)
        XCTAssertEqual(orthogonal.b.y, 3, accuracy: 1e-5)
        XCTAssertEqual(orthogonal.c.z, 4, accuracy: 1e-5)
        XCTAssertEqual(orthogonal.a.y, 0, accuracy: 1e-5)
        XCTAssertEqual(orthogonal.b.x, 0, accuracy: 1e-5)
        XCTAssertEqual(orthogonal.c.x, 0, accuracy: 1e-5)
        XCTAssertEqual(orthogonal.c.y, 0, accuracy: 1e-5)
    }

    func testReciprocalVectorsAreTheDualBasis() {
        let cell = Cell.fromLattice(a: 4, b: 5, c: 6,
                                    alpha: 74, beta: 83, gamma: 67)
        assertDualBasis(cell, accuracy: 1e-4)
    }

    func testExactAndNearCoplanarMetricsReturnZeroCell() {
        let exact = Cell.fromLattice(a: 3, b: 4, c: 5,
                                     alpha: 60, beta: 60, gamma: 120)
        assertZeroCell(exact)

        let justOutside = Cell.fromLattice(a: 3, b: 4, c: 5,
                                            alpha: 60, beta: 60, gamma: 120.00001)
        assertZeroCell(justOutside)
    }

    func testValidNearBoundaryCellRemainsRightHandedAndFinite() {
        let cell = Cell.fromLattice(a: 3, b: 4, c: 5,
                                    alpha: 60, beta: 60, gamma: 119.999)

        XCTAssertTrue(cell.a.isFinite && cell.b.isFinite && cell.c.isFinite)
        XCTAssertGreaterThan(dot(cell.a, cross(cell.b, cell.c)), 0)
        XCTAssertGreaterThan(cell.c.z, 0)
        assertDualBasis(cell, accuracy: 1e-3)
    }

    func testReciprocalVectorsPreserveDualityUnderUniformDownScaling() {
        let base = Cell.fromLattice(a: 4, b: 5, c: 6,
                                    alpha: 74, beta: 83, gamma: 67)
        for factor in [Float(1e-3), 1e-6, 1e-9, 1e-12, 1e-18] {
            let cell = Cell(a: base.a * factor, b: base.b * factor, c: base.c * factor)
            assertDualBasis(cell, accuracy: 2e-3)
        }
    }

    func testSkewSmallCellHasFiniteDualReciprocalBasis() {
        let factor: Float = 1e-12
        let cell = Cell(a: SIMD3(4, 0, 0) * factor,
                        b: SIMD3(1, 3, 0) * factor,
                        c: SIMD3(0.5, 0.75, 2.5) * factor)

        assertDualBasis(cell, accuracy: 2e-3)
    }

    func testFractionalCoordinatesAndCenteringSurviveUniformScale() {
        let fractions = [SIMD3<Float>(0, 0, 0),
                         SIMD3<Float>(0, 0.5, 0.5),
                         SIMD3<Float>(0.5, 0, 0.5),
                         SIMD3<Float>(0.5, 0.5, 0)]

        for factor in [Float(1e-20), Float(1e20)] {
            let a = 5.43 * factor
            let cell = Cell(a: SIMD3<Float>(a, 0, 0),
                            b: SIMD3<Float>(0, a, 0),
                            c: SIMD3<Float>(0, 0, a))
            let atoms = fractions.map { Atom(coord: cell.cartesian($0), atomicNumber: 14, label: "Si") }
            let actual = Lattice.fractional(atoms.map(\.coord), cell: cell)

            XCTAssertEqual(actual.count, fractions.count)
            for (expected, value) in zip(fractions, actual) {
                XCTAssertEqual(value.x, expected.x, accuracy: 1e-5, "scale \(factor)")
                XCTAssertEqual(value.y, expected.y, accuracy: 1e-5, "scale \(factor)")
                XCTAssertEqual(value.z, expected.z, accuracy: 1e-5, "scale \(factor)")
            }
            if case .face = Lattice.detectCentering(atoms, cell: cell) {
                // Expected for the four equivalent fcc basis sites.
            } else {
                XCTFail("fcc centering was lost at scale \(factor)")
            }

            let bodyFractions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0.5, 0.5)]
            let bodyAtoms = bodyFractions.map {
                Atom(coord: cell.cartesian($0), atomicNumber: 14, label: "Si")
            }
            if case .body = Lattice.detectCentering(bodyAtoms, cell: cell) {
                // Expected for the two equivalent bcc basis sites.
            } else {
                XCTFail("bcc centering was lost at scale \(factor)")
            }
        }
    }

    func testFractionalInvalidInputUsesFinitePerAtomZeroSentinels() {
        let cell = Cell(a: SIMD3<Float>(2, 0, 0),
                        b: SIMD3<Float>(0, 3, 0),
                        c: SIMD3<Float>(0, 0, 4))
        let actual = Lattice.fractional([SIMD3<Float>(.nan, 0, 0), SIMD3<Float>(1, 2, 3)], cell: cell)
        XCTAssertEqual(actual[0], .zero)
        XCTAssertEqual(actual[1].x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(actual[1].y, 2 / 3, accuracy: 1e-6)
        XCTAssertEqual(actual[1].z, 0.75, accuracy: 1e-6)

        let singular = Cell(a: SIMD3<Float>(1, 0, 0),
                            b: SIMD3<Float>(1, 0, 0),
                            c: SIMD3<Float>(0, 0, 1))
        let fallback = Lattice.fractional([SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6)], cell: singular)
        XCTAssertEqual(fallback, [.zero, .zero])
    }

    func testTinyWellConditionedCellBuildsBrillouinZone() {
        let factor: Float = 1e-12
        let cell = Cell(a: SIMD3(4, 0, 0) * factor,
                        b: SIMD3(1, 3, 0) * factor,
                        c: SIMD3(0.5, 0.75, 2.5) * factor)

        let bz = BrillouinZone.build(cell: cell, atoms: [])
        XCTAssertNotNil(bz)
    }

    func testInvalidParametersReturnFiniteDegenerateFallback() {
        let cases: [(Float, Float, Float, Float, Float, Float)] = [
            (.nan, 1, 1, 90, 90, 90),
            (1, .infinity, 1, 90, 90, 90),
            (0, 1, 1, 90, 90, 90),
            (1, 1, 1, 90, 90, 0),
            (1, 1, 1, 90, 90, 180),
            (1, 1, 1, 10, 10, 170)
        ]

        for (a, b, c, alpha, beta, gamma) in cases {
            assertZeroCell(Cell.fromLattice(a: a, b: b, c: c,
                                            alpha: alpha, beta: beta, gamma: gamma))
        }
    }

    func testReciprocalVectorsRejectInvalidNearSingularAndUnrepresentableCells() {
        let cases = [
            Cell(a: .zero, b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1)),
            Cell(a: SIMD3(1, 0, 0), b: SIMD3(1, 1e-20, 0), c: SIMD3(0, 0, 1)),
            Cell(a: SIMD3(Float.nan, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1)),
            Cell(a: SIMD3(Float.infinity, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1)),
            Cell(a: SIMD3(Float.leastNonzeroMagnitude, 0, 0),
                 b: SIMD3(0, Float.leastNonzeroMagnitude, 0),
                 c: SIMD3(0, 0, Float.leastNonzeroMagnitude))
        ]

        for cell in cases {
            assertZeroReciprocal(for: cell)
        }
    }

    func testGammaSineIsUsedForNonEquivalentAlphaAndGamma() {
        let a: Float = 3
        let b: Float = 4
        let c: Float = 5
        let alpha: Float = 73
        let beta: Float = 81
        let gamma: Float = 57
        let cell = Cell.fromLattice(a: a, b: b, c: c,
                                    alpha: alpha, beta: beta, gamma: gamma)

        let alphaRadians = alpha * .pi / 180
        let betaRadians = beta * .pi / 180
        let gammaRadians = gamma * .pi / 180
        XCTAssertEqual(cell.b.y, b * sin(gammaRadians), accuracy: 1e-5)

        let expectedCY = c * (cos(alphaRadians) - cos(betaRadians) * cos(gammaRadians))
            / sin(gammaRadians)
        let oldAlphaDenominatorCY = c * (cos(alphaRadians) - cos(betaRadians) * cos(gammaRadians))
            / sin(alphaRadians)
        XCTAssertEqual(cell.c.y, expectedCY, accuracy: 1e-5)
        XCTAssertNotEqual(cell.c.y, oldAlphaDenominatorCY, accuracy: 1e-3)
    }
}
