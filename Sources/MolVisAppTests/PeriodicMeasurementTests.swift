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

    func testMoleculeOrthogonalAndTwoDimensionalDistanceBehavior() {
        // Molecules use direct Cartesian distance when no periodic cell exists.
        let moleculeAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(3, 4, 0), atomicNumber: 1, label: "H"),
        ]
        let moleculeResult = Scene.computeMeasurement(mode: .distance,
                                                      atoms: moleculeAtoms,
                                                      selected: [0, 1])
        XCTAssertNotNil(moleculeResult)
        XCTAssertEqual(moleculeResult!.value, 5.0, accuracy: 1e-5)
        XCTAssertTrue(moleculeResult!.summary.contains("Å"))

        // An orthogonal boundary pair must use the shorter wrapped distance.
        let orthogonalCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let orthogonalAtoms = [
            Atom(coord: SIMD3(0.5, 5, 5), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 5, 5), atomicNumber: 1, label: "H"),
        ]
        let direct = length(orthogonalAtoms[1].coord - orthogonalAtoms[0].coord)
        XCTAssertEqual(direct, 9.0, accuracy: 1e-5)
        let orthogonalResult = Scene.computeMeasurement(mode: .distance,
                                                         atoms: orthogonalAtoms,
                                                         selected: [0, 1],
                                                         cell: orthogonalCell,
                                                         periodicDim: 3)
        XCTAssertNotNil(orthogonalResult)
        XCTAssertEqual(orthogonalResult!.value, 1.0, accuracy: 1e-4)

        // Two-dimensional periodicity wraps x/y but leaves z unwrapped.
        let twoDimensionalCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 100))
        let twoDimensionalAtoms = [
            Atom(coord: SIMD3(0.5, 5, 10), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 5, 90), atomicNumber: 1, label: "H"),
        ]
        let twoDimensionalResult = Scene.computeMeasurement(mode: .distance,
                                                            atoms: twoDimensionalAtoms,
                                                            selected: [0, 1],
                                                            cell: twoDimensionalCell,
                                                            periodicDim: 2)
        XCTAssertNotNil(twoDimensionalResult)
        // x wraps (1.0), z does not (80.0): sqrt(1^2 + 80^2).
        let expected = sqrtf(1.0 + 80.0 * 80.0)
        XCTAssertEqual(twoDimensionalResult!.value, expected, accuracy: 1e-3)
    }

    func testSkewInvalidAndAngleMeasurementBehavior() {
        // A skew cell is checked against explicit enumeration of all 27 images.
        let skewCell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(3, 4, 0), c: SIMD3(0, 0, 10))
        let skewAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(4.9, 0.1, 0), atomicNumber: 1, label: "H"),
        ]
        let expected = bruteForceMinImage(from: skewAtoms[0].coord,
                                          to: skewAtoms[1].coord,
                                          cell: skewCell,
                                          periodicDim: 3)
        let skewResult = Scene.computeMeasurement(mode: .distance,
                                                  atoms: skewAtoms,
                                                  selected: [0, 1],
                                                  cell: skewCell,
                                                  periodicDim: 3)
        XCTAssertNotNil(skewResult)
        XCTAssertEqual(skewResult!.value, expected, accuracy: 1e-4)
        XCTAssertLessThan(skewResult!.value,
                          length(skewAtoms[1].coord - skewAtoms[0].coord) / 2)

        // A singular periodic cell must fail rather than fabricate a distance.
        let singularCell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        let singularAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0.5, 0.5, 0), atomicNumber: 1, label: "H"),
        ]
        let invalidResult = Scene.computeMeasurement(mode: .distance,
                                                     atoms: singularAtoms,
                                                     selected: [0, 1],
                                                     cell: singularCell,
                                                     periodicDim: 3)
        XCTAssertNil(invalidResult)

        // Angles remain direct-vector measurements even when a cell is supplied.
        let angleAtoms = [
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 1, 0), atomicNumber: 1, label: "H"),
        ]
        let plain = Scene.computeMeasurement(mode: .angle,
                                             atoms: angleAtoms,
                                             selected: [0, 1, 2])
        let withCell = Scene.computeMeasurement(mode: .angle,
                                                atoms: angleAtoms,
                                                selected: [0, 1, 2],
                                                cell: Cell(a: SIMD3(10, 0, 0),
                                                           b: SIMD3(0, 10, 0),
                                                           c: SIMD3(0, 0, 10)),
                                                periodicDim: 3)
        XCTAssertNotNil(plain)
        XCTAssertNotNil(withCell)
        XCTAssertEqual(plain!.value, 90.0, accuracy: 1e-5)
        XCTAssertEqual(withCell!.value, 90.0, accuracy: 1e-5)
    }
}
