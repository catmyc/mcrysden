import simd
import XCTest
@testable import MolVisApp

final class PeriodicMeasurementTests: XCTestCase {

    /// Brute-force minimum image distance by enumerating all 27 neighboring
    /// cells. Used as the oracle for the skew-cell test.
    private func bruteForceMinImage(from p: SIMD3<Float>, to q: SIMD3<Float>,
                                    cell: Cell, periodicDim: Int) -> Float {
        let rangeA = periodicDim >= 1 ? [-1, 0, 1] : [0]
        let rangeB = periodicDim >= 2 ? [-1, 0, 1] : [0]
        let rangeC = periodicDim >= 3 ? [-1, 0, 1] : [0]
        var best = Float.greatestFiniteMagnitude
        for i in rangeA { for j in rangeB { for k in rangeC {
            let image = q + cell.a * Float(i) + cell.b * Float(j) + cell.c * Float(k)
            best = min(best, length(image - p))
        }}}
        return best
    }

    // Pair spanning an orthogonal boundary: the minimum image wraps across
    // the cell edge, so the measured distance is much shorter than direct.
    func testOrthogonalBoundaryWraps() {
        let cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let atoms = [
            Atom(coord: SIMD3(0.5, 5, 5), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 5, 5), atomicNumber: 1, label: "H"),
        ]
        let direct = length(atoms[1].coord - atoms[0].coord)
        XCTAssertEqual(direct, 9.0, accuracy: 1e-5)
        let result = Scene.computeMeasurement(mode: .distance, atoms: atoms, selected: [0, 1],
                                              cell: cell, periodicDim: 3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.value, 1.0, accuracy: 1e-4)
    }

    // Skew (non-orthogonal) cell: validate against explicit enumeration of all
    // 27 neighboring images. The nearest image is not axis-aligned.
    func testSkewCellMatchesBruteForce() {
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(3, 4, 0), c: SIMD3(0, 0, 10))
        let atoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(4.9, 0.1, 0), atomicNumber: 1, label: "H"),
        ]
        let expected = bruteForceMinImage(from: atoms[0].coord, to: atoms[1].coord,
                                          cell: cell, periodicDim: 3)
        let result = Scene.computeMeasurement(mode: .distance, atoms: atoms, selected: [0, 1],
                                              cell: cell, periodicDim: 3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.value, expected, accuracy: 1e-4)
        // Sanity: the minimum image is far shorter than the direct distance.
        XCTAssertLessThan(result!.value, length(atoms[1].coord - atoms[0].coord) / 2)
    }

    // 2D periodicity wraps x and y but leaves z unwrapped. A tall cell in z
    // with atoms near opposite z faces must NOT wrap that separation.
    func test2DPeriodicityDoesNotWrapZ() {
        let cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 100))
        let atoms = [
            Atom(coord: SIMD3(0.5, 5, 10), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 5, 90), atomicNumber: 1, label: "H"),
        ]
        let result = Scene.computeMeasurement(mode: .distance, atoms: atoms, selected: [0, 1],
                                              cell: cell, periodicDim: 2)
        XCTAssertNotNil(result)
        // x wraps (1.0), z does not (80.0): sqrt(1^2 + 80^2).
        let expected = sqrtf(1.0 + 80.0 * 80.0)
        XCTAssertEqual(result!.value, expected, accuracy: 1e-3)
    }

    // Molecule (no cell): direct Cartesian distance, unchanged behavior.
    func testMoleculeDirectDistance() {
        let atoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(3, 4, 0), atomicNumber: 1, label: "H"),
        ]
        let result = Scene.computeMeasurement(mode: .distance, atoms: atoms, selected: [0, 1])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.value, 5.0, accuracy: 1e-5)
        XCTAssertTrue(result!.summary.contains("Å"))
    }

    // Invalid periodic geometry (singular cell) must yield nil, not a
    // fabricated distance.
    func testInvalidPeriodicGeometryReturnsNil() {
        // b parallel to a => zero volume.
        let cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        let atoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0.5, 0.5, 0), atomicNumber: 1, label: "H"),
        ]
        let result = Scene.computeMeasurement(mode: .distance, atoms: atoms, selected: [0, 1],
                                              cell: cell, periodicDim: 3)
        XCTAssertNil(result)
    }

    // Angle behavior is unchanged: computed from direct vectors regardless of
    // cell. Passing a cell must not alter the angle.
    func testAngleBehaviorUnchanged() {
        let atoms = [
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 1, 0), atomicNumber: 1, label: "H"),
        ]
        let plain = Scene.computeMeasurement(mode: .angle, atoms: atoms, selected: [0, 1, 2])
        let withCell = Scene.computeMeasurement(mode: .angle, atoms: atoms, selected: [0, 1, 2],
                                                cell: Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10)),
                                                periodicDim: 3)
        XCTAssertNotNil(plain)
        XCTAssertNotNil(withCell)
        XCTAssertEqual(plain!.value, 90.0, accuracy: 1e-5)
        XCTAssertEqual(withCell!.value, 90.0, accuracy: 1e-5)
    }
}
