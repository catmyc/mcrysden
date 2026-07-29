import simd
import XCTest
@testable import MolVisApp

/// Brute-force minimum-image oracle: enumerate all integer lattice images in a
/// window and return the displacement to the closest one. Used to validate the
/// QR/sphere-decoding implementation, especially for skew cells where naive
/// fractional rounding fails.
func bruteForceMinImageDisplacement(source: SIMD3<Float>, target: SIMD3<Float>,
                                    cell: Cell, periodicDim: Int,
                                    range: Int = 6) -> SIMD3<Float> {
    let d = target - source
    let a = cell.a, b = cell.b, c = cell.c
    var bestDisp = d
    var bestDistSq = dot(d, d)
    let jRange = periodicDim >= 2 ? (-range)...range : 0...0
    let kRange = periodicDim >= 3 ? (-range)...range : 0...0
    for i in -range...range {
        for j in jRange {
            for k in kRange {
                let lattice = a * Float(i) + b * Float(j) + c * Float(k)
                let disp = d - lattice
                let distSq = dot(disp, disp)
                if distSq < bestDistSq {
                    bestDistSq = distSq
                    bestDisp = disp
                }
            }
        }
    }
    return bestDisp
}

final class PeriodicGeometryTests: XCTestCase {

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4,
                             file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(allComponentsEqual(a, b, eps),
                      "expected \(a) ≈ \(b)", file: file, line: line)
    }

    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    // MARK: - Non-periodic (molecule)

    func testNonPeriodicReturnsDirectDisplacement() {
        let source = SIMD3<Float>(1, 2, 3)
        let target = SIMD3<Float>(4, 6, 8)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: nil, periodicDim: 0)
        assertClose(disp!, SIMD3<Float>(3, 4, 5))
    }

    func testNonPeriodicIgnoresCellWhenDimZero() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        let source = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(12, 0, 0)
        // periodicDim == 0 → direct displacement even though a cell is present.
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 0)
        assertClose(disp!, SIMD3<Float>(12, 0, 0))
    }

    func testNonPeriodicDistance() {
        let source = SIMD3<Float>(1, 2, 3)
        let target = SIMD3<Float>(4, 6, 8)
        let dist = PeriodicGeometry.minimumImageDistance(from: source, to: target,
                                                          cell: nil, periodicDim: 0)
        let expected = sqrt(Float(3 * 3 + 4 * 4 + 5 * 5))
        XCTAssertEqual(dist!, expected, accuracy: 1e-4)
    }

    // MARK: - Orthogonal 1D / 2D / 3D

    func testOrthogonal1D() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        let source = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(12, 0, 0)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 1)
        // 12 mod 5 → closest image at 2 (distance 2), not -3 (distance 3).
        assertClose(disp!, SIMD3<Float>(2, 0, 0))
    }

    func testOrthogonal2D() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 1))
        let source = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(12, 7, 0)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 2)
        // 12 mod 5 → 2, 7 mod 3 → 1.
        assertClose(disp!, SIMD3<Float>(2, 1, 0))
    }

    func testOrthogonal3D() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 4))
        let source = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(12, 7, 9)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 3)
        // 12 mod 5 → 2, 7 mod 3 → 1, 9 mod 4 → 1.
        assertClose(disp!, SIMD3<Float>(2, 1, 1))
    }

    func testOrthogonal3DNegativeDisplacement() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 4))
        let source = SIMD3<Float>(1, 1, 1)
        let target = SIMD3<Float>(-11, -5, -7)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 3)
        // d = (-12, -6, -8): x wraps to nearest multiple of 5 (-10) → -2;
        // y is a multiple of 3 → 0; z is a multiple of 4 → 0.
        assertClose(disp!, SIMD3<Float>(-2, 0, 0))
    }

    // MARK: - Skew cell where naive fractional rounding is wrong

    /// Cell a=(1,0,0), b=(0.4,0.6,0): for d=(0.56,0.24,0) the naive rounded
    /// fractional solution is k=(0,0) but the true closest image is k=(0,1).
    func testSkewCellNaiveRoundingWrong() {
        let cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0.4, 0.6, 0), c: SIMD3(0, 0, 1))
        let source = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(0.56, 0.24, 0)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 2)
        let expected = bruteForceMinImageDisplacement(source: source, target: target,
                                                       cell: cell, periodicDim: 2)
        assertClose(disp!, expected)
        // The true closest image is k=(0,1): displacement (0.16, -0.36, 0).
        assertClose(disp!, SIMD3<Float>(0.16, -0.36, 0), 1e-3)
    }

    /// Sweep several points in a skew cell and compare against the brute-force
    /// oracle. Catches any case where the decoder returns a suboptimal image.
    func testSkewCellBruteForceAgreement() {
        let cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0.4, 0.6, 0), c: SIMD3(0, 0, 1))
        let points: [SIMD3<Float>] = [
            SIMD3(0.56, 0.24, 0),
            SIMD3(0.1, 0.9, 0),
            SIMD3(0.9, 0.1, 0),
            SIMD3(0.3, 0.7, 0),
            SIMD3(0.7, 0.3, 0),
            SIMD3(1.5, -0.5, 0),
            SIMD3(-0.5, 1.5, 0),
        ]
        for p in points {
            let disp = PeriodicGeometry.minimumImageDisplacement(from: .zero, to: p,
                                                                  cell: cell, periodicDim: 2)!
            let expected = bruteForceMinImageDisplacement(source: .zero, target: p,
                                                           cell: cell, periodicDim: 2)
            // Compare distances to be robust to ties.
            let d1 = sqrt(dot(disp, disp))
            let d2 = sqrt(dot(expected, expected))
            XCTAssertEqual(d1, d2, accuracy: 1e-3,
                           "mismatch at point \(p): got \(disp) (d=\(d1)), expected \(expected) (d=\(d2))")
        }
    }

    /// Distinct costs at a small scale must not be treated as a coefficient tie.
    func testSmallScaleStrictCostOrderingAgainstBruteForce() {
        let scale = Float(1e-4)
        let cell = Cell(a: SIMD3<Float>(scale, 0, 0),
                        b: SIMD3<Float>(0.4 * scale, 0.6 * scale, 0),
                        c: SIMD3<Float>(0, 0, scale))
        let target = SIMD3<Float>(0.49 * scale, 0.12 * scale, 0)
        let actual = PeriodicGeometry.minimumImageDisplacement(from: .zero, to: target,
                                                                cell: cell, periodicDim: 2)!
        let expected = bruteForceMinImageDisplacement(source: .zero, target: target,
                                                       cell: cell, periodicDim: 2)
        let actualCost = dot(actual, actual)
        let expectedCost = dot(expected, expected)
        let directCost = dot(target, target)

        XCTAssertLessThan(expectedCost, directCost)
        XCTAssertLessThan(directCost - expectedCost, Float(1e-9))
        XCTAssertEqual(actualCost, expectedCost, accuracy: Float(1e-18))
    }

    /// A triclinic 3D cell: verify against brute force for a few points.
    func testTriclinic3DBruteForceAgreement() {
        let cell = Cell(a: SIMD3(1, 0, 0),
                        b: SIMD3(0.4, 0.6, 0),
                        c: SIMD3(0.2, 0.1, 0.8))
        let points: [SIMD3<Float>] = [
            SIMD3(0.56, 0.24, 0.3),
            SIMD3(0.9, 0.8, 0.7),
            SIMD3(0.1, 0.2, 0.95),
        ]
        for p in points {
            let disp = PeriodicGeometry.minimumImageDisplacement(from: .zero, to: p,
                                                                  cell: cell, periodicDim: 3)!
            let expected = bruteForceMinImageDisplacement(source: .zero, target: p,
                                                           cell: cell, periodicDim: 3)
            let d1 = sqrt(dot(disp, disp))
            let d2 = sqrt(dot(expected, expected))
            XCTAssertEqual(d1, d2, accuracy: 1e-3,
                           "mismatch at point \(p): got \(disp) (d=\(d1)), expected \(expected) (d=\(d2))")
        }
    }

    // MARK: - Translation invariance

    /// Shifting source or target by any lattice vector must not change the
    /// minimum-image displacement.
    func testTranslationInvariance() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 4))
        let source = SIMD3<Float>(1, 1, 1)
        let target = SIMD3<Float>(7, 4, 5)
        let base = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 3)!

        let latticeVectors: [SIMD3<Float>] = [
            cell.a, cell.b, cell.c,
            cell.a * 2 + cell.b * -1,
            cell.a + cell.b + cell.c,
            cell.a * -3 + cell.c * 2,
        ]
        for L in latticeVectors {
            let d1 = PeriodicGeometry.minimumImageDisplacement(from: source + L, to: target,
                                                                cell: cell, periodicDim: 3)!
            assertClose(base, d1, 1e-3, line: #line)
            let d2 = PeriodicGeometry.minimumImageDisplacement(from: source, to: target + L,
                                                                cell: cell, periodicDim: 3)!
            assertClose(base, d2, 1e-3, line: #line)
        }
    }

    // MARK: - Partial periodicity

    func testPartialPeriodicity1D() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 4))
        let source = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(12, 7, 9)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 1)
        // Only a is periodic: 12 mod 5 → 2; b, c components are direct.
        assertClose(disp!, SIMD3<Float>(2, 7, 9))
    }

    func testPartialPeriodicity2D() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 4))
        let source = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(12, 7, 9)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 2)
        // a periodic: 12 mod 5 → 2; b periodic: 7 mod 3 → 1; c direct: 9.
        assertClose(disp!, SIMD3<Float>(2, 1, 9))
    }

    // MARK: - Invalid dimensions

    func testInvalidDimensionNegative() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: SIMD3(1, 0, 0),
                                                                cell: cell, periodicDim: -1))
    }

    func testInvalidDimensionTooLarge() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: SIMD3(1, 0, 0),
                                                                cell: cell, periodicDim: 4))
    }

    // MARK: - Non-finite input

    func testNonFiniteSource() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: SIMD3(Float.nan, 0, 0),
                                                                to: SIMD3(1, 0, 0),
                                                                cell: cell, periodicDim: 3))
    }

    func testNonFiniteTarget() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero,
                                                                to: SIMD3(Float.infinity, 0, 0),
                                                                cell: cell, periodicDim: 3))
    }

    func testNonFiniteCellVector() {
        let cell = Cell(a: SIMD3(Float.nan, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: SIMD3(1, 0, 0),
                                                                cell: cell, periodicDim: 3))
    }

    func testTinyFiniteBasisWithHugeCoefficientReturnsNil() {
        let cell = Cell(a: SIMD3(Float.leastNonzeroMagnitude, 0, 0),
                        b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        let target = SIMD3(Float.greatestFiniteMagnitude, 0, 0)
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: target,
                                                                cell: cell, periodicDim: 1))
    }

    func testLargeRepresentableCoefficientDoesNotOverflowNorm() {
        let cell = Cell(a: SIMD3(Float(1e20), 0, 0),
                        b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        let target = SIMD3(Float(1e30), 0, 0)
        let displacement = PeriodicGeometry.minimumImageDisplacement(from: .zero, to: target,
                                                                       cell: cell, periodicDim: 1)
        XCTAssertNotNil(displacement)
        XCTAssertTrue(displacement?.isFinite == true)
    }

    func testIllConditionedFiniteBasisReturnsNilWhenSearchCapWouldTruncate() {
        let cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0),
                        c: SIMD3(0, 0, Float(1e-6)))
        let target = SIMD3<Float>(0.5, 0, 0)
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: target,
                                                                cell: cell, periodicDim: 3))
    }

    // MARK: - Singular / dependent periodic basis

    func testDependentBasisParallelVectors() {
        // a and b are parallel → linearly dependent for 2D.
        let cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 5))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: SIMD3(1, 0, 0),
                                                                cell: cell, periodicDim: 2))
    }

    func testDependentBasis3D() {
        // c = a + b → coplanar, volume zero.
        let cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(1, 1, 0))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: SIMD3(1, 0, 0),
                                                                cell: cell, periodicDim: 3))
    }

    func testZeroVectorBasis() {
        let cell = Cell(a: SIMD3(0, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        XCTAssertNil(PeriodicGeometry.minimumImageDisplacement(from: .zero, to: SIMD3(1, 0, 0),
                                                                cell: cell, periodicDim: 1))
    }

    // MARK: - Distance / displacement agreement

    func testDistanceEqualsLengthOfDisplacement() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 4))
        let source = SIMD3<Float>(1, 1, 1)
        let target = SIMD3<Float>(13, 8, 10)
        let disp = PeriodicGeometry.minimumImageDisplacement(from: source, to: target,
                                                              cell: cell, periodicDim: 3)!
        let dist = PeriodicGeometry.minimumImageDistance(from: source, to: target,
                                                          cell: cell, periodicDim: 3)!
        let expected = sqrt(dot(disp, disp))
        XCTAssertEqual(dist, expected, accuracy: 1e-3)
    }

    func testDistanceRejectsNonFinite() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        XCTAssertNil(PeriodicGeometry.minimumImageDistance(from: .zero,
                                                           to: SIMD3(Float.nan, 0, 0),
                                                           cell: cell, periodicDim: 3))
    }

    // MARK: - Distance used by Scene.computeMeasurement (integration)

    /// The distance mode of `Scene.computeMeasurement` must route through
    /// `PeriodicGeometry` when a cell is present, matching the brute-force
    /// minimum-image distance.
    func testComputeMeasurementDistanceUsesPeriodicGeometry() {
        let cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0.4, 0.6, 0), c: SIMD3(0, 0, 1))
        let atoms = [
            Atom(coord: SIMD3<Float>(0, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3<Float>(0.56, 0.24, 0), atomicNumber: 1, label: "H"),
        ]
        let result = Scene.computeMeasurement(mode: .distance, atoms: atoms, selected: [0, 1],
                                              cell: cell, periodicDim: 2)
        let expectedDisp = bruteForceMinImageDisplacement(source: atoms[0].coord,
                                                           target: atoms[1].coord,
                                                           cell: cell, periodicDim: 2)
        let expectedDist = sqrt(dot(expectedDisp, expectedDisp))
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.value, expectedDist, accuracy: 1e-3)
    }
}
