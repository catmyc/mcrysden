import XCTest
import simd
@testable import MolVisApp

final class ReciprocalDistanceTests: XCTestCase {
    private func assertApproximately(_ value: Float?, _ expected: Float,
                                     accuracy: Float = 1e-5,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        guard let value else {
            XCTFail("expected \(expected), got nil", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, accuracy: accuracy, file: file, line: line)
    }

    private func scene(cell: Cell, points: [KPoint], breaks: Set<Int> = []) -> Scene {
        var result = Scene()
        result.cell = cell
        result.isCrystal = true
        result.kPathPoints = points
        result.kPathBreaks = breaks
        return result
    }

    func testOrthogonalCellUsesPhysicalTwoPiMetric() {
        let cell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 8))
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "G"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
            KPoint(SIMD3(0.5, 0.25, 0), "M"),
        ])

        let distances = path.reciprocalDistanceReadouts(cell: cell)
        XCTAssertEqual(distances.count, 3)
        XCTAssertTrue(distances[0].isComponentStart)
        XCTAssertNil(distances[0].incomingDistance)
        assertApproximately(distances[0].cumulativeDistance, 0)
        assertApproximately(distances[1].incomingDistance, Float.pi / 2)
        assertApproximately(distances[1].cumulativeDistance, Float.pi / 2)
        assertApproximately(distances[2].incomingDistance, Float.pi / 8)
        assertApproximately(distances[2].cumulativeDistance, 5 * Float.pi / 8)
    }

    func testSkewCellUsesReciprocalVectorCombination() {
        let cell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(1, 3, 0), c: SIMD3(0.5, 0.25, 4))
        let first = SIMD3<Float>(0.25, -0.5, 0.125)
        let second = SIMD3<Float>(-0.125, 0.25, 0.375)
        let path = KPath(points: [KPoint(.zero, "A"), KPoint(first, "B"), KPoint(second, "C")])
        let reciprocal = cell.reciprocalVectors

        func physicalDistance(_ delta: SIMD3<Float>) -> Float {
            let cartesian = reciprocal.a * delta.x
                + reciprocal.b * delta.y
                + reciprocal.c * delta.z
            return sqrt(dot(cartesian, cartesian))
        }

        let firstDistance = physicalDistance(first)
        let secondDistance = physicalDistance(second - first)
        let distances = path.reciprocalDistanceReadouts(cell: cell)

        assertApproximately(distances[1].incomingDistance, firstDistance)
        assertApproximately(distances[1].cumulativeDistance, firstDistance)
        assertApproximately(distances[2].incomingDistance, secondDistance)
        assertApproximately(distances[2].cumulativeDistance, firstDistance + secondDistance)
    }

    func testBreaksStopIncomingDistanceAndHoldCumulativeValue() {
        let cell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(0.25, 0, 0), "B"),
            KPoint(SIMD3(0.5, 0, 0), "C"),
            KPoint(SIMD3(0.75, 0, 0), "D"),
        ], breaks: [1, -1, 99])

        let distances = path.reciprocalDistanceReadouts(cell: cell)
        let edge = Float.pi / 4
        XCTAssertTrue(distances[0].isComponentStart)
        XCTAssertFalse(distances[1].isComponentStart)
        assertApproximately(distances[1].incomingDistance, edge)
        assertApproximately(distances[1].cumulativeDistance, edge)
        XCTAssertTrue(distances[2].isComponentStart)
        XCTAssertNil(distances[2].incomingDistance)
        assertApproximately(distances[2].cumulativeDistance, edge)
        XCTAssertFalse(distances[3].isComponentStart)
        assertApproximately(distances[3].incomingDistance, edge)
        assertApproximately(distances[3].cumulativeDistance, 2 * edge)
    }

    func testEmptyAndSingletonRoutesAreSafe() {
        let cell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        XCTAssertTrue(KPath(points: []).reciprocalDistanceReadouts(cell: cell).isEmpty)

        let singleton = KPath(points: [KPoint(SIMD3(0.5, 0, 0), "A")], breaks: [-1, 4])
        let distances = singleton.reciprocalDistanceReadouts(cell: cell)
        XCTAssertEqual(distances.count, 1)
        XCTAssertTrue(distances[0].isComponentStart)
        XCTAssertNil(distances[0].incomingDistance)
        assertApproximately(distances[0].cumulativeDistance, 0)
    }

    func testInvalidGeometryAndNumericalOverflowProduceInvalidReadouts() {
        let points = [KPoint(SIMD3(0, 0, 0), "A"), KPoint(SIMD3(0.5, 0, 0), "B")]
        let singular = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        let singularReadouts = KPath(points: points).reciprocalDistanceReadouts(cell: singular)
        XCTAssertEqual(singularReadouts.count, 2)
        XCTAssertNil(singularReadouts[0].cumulativeDistance)
        XCTAssertNil(singularReadouts[1].incomingDistance)
        XCTAssertNil(singularReadouts[1].cumulativeDistance)

        let nonFiniteCell = Cell(a: SIMD3(Float.nan, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        let nonFiniteReadouts = KPath(points: points).reciprocalDistanceReadouts(cell: nonFiniteCell)
        XCTAssertEqual(nonFiniteReadouts.count, 2)
        XCTAssertNil(nonFiniteReadouts[0].cumulativeDistance)
        XCTAssertNil(nonFiniteReadouts[1].cumulativeDistance)

        let validCell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        let nonFinitePoint = KPath(points: [
            KPoint(SIMD3(Float.nan, 0, 0), "bad"),
            KPoint(SIMD3(0.5, 0, 0), "B"),
        ]).reciprocalDistanceReadouts(cell: validCell)
        XCTAssertEqual(nonFinitePoint.count, 2)
        XCTAssertNil(nonFinitePoint[0].cumulativeDistance)
        XCTAssertNil(nonFinitePoint[1].cumulativeDistance)

        // The cell volume passes Cell.reciprocalVectors' guard, but the finite
        // reciprocal distance is larger than Float can represent.
        let highMetricCell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1e-6, 0), c: SIMD3(0, 0, 2e-6))
        let overflowPath = KPath(points: [
            KPoint(.zero, "A"),
            KPoint(SIMD3(Float.greatestFiniteMagnitude, 0, 0), "B"),
        ])
        let overflowReadouts = overflowPath.reciprocalDistanceReadouts(cell: highMetricCell)
        XCTAssertEqual(overflowReadouts.count, 2)
        XCTAssertNil(overflowReadouts[1].incomingDistance)
        XCTAssertNil(overflowReadouts[1].cumulativeDistance)
    }

    func testValidIncomingDistanceSurvivesEarlierInvalidComponent() {
        let cell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        let path = KPath(points: [
            KPoint(.zero, "A"),
            KPoint(SIMD3(Float.nan, 0, 0), "bad"),
            KPoint(SIMD3(0.5, 0, 0), "C"),
            KPoint(SIMD3(0.75, 0, 0), "D"),
        ], breaks: [1])

        let distances = path.reciprocalDistanceReadouts(cell: cell)
        XCTAssertNil(distances[1].incomingDistance)
        XCTAssertNil(distances[1].cumulativeDistance)
        XCTAssertTrue(distances[2].isComponentStart)
        XCTAssertNil(distances[2].incomingDistance)
        XCTAssertNil(distances[2].cumulativeDistance)
        assertApproximately(distances[3].incomingDistance, Float.pi / 4)
        XCTAssertNil(distances[3].cumulativeDistance)
    }

    func testValidIncomingDistanceSurvivesEarlierOverflowingComponent() {
        let highMetricCell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1e-6, 0), c: SIMD3(0, 0, 2e-6))
        let path = KPath(points: [
            KPoint(.zero, "A"),
            KPoint(SIMD3(Float.greatestFiniteMagnitude, 0, 0), "overflow"),
            KPoint(.zero, "C"),
            KPoint(SIMD3(0.5, 0, 0), "D"),
        ], breaks: [1])

        let distances = path.reciprocalDistanceReadouts(cell: highMetricCell)
        XCTAssertNil(distances[1].incomingDistance)
        XCTAssertNil(distances[1].cumulativeDistance)
        XCTAssertTrue(distances[2].isComponentStart)
        XCTAssertNil(distances[2].incomingDistance)
        XCTAssertNil(distances[2].cumulativeDistance)
        assertApproximately(distances[3].incomingDistance, Float.pi)
        XCTAssertNil(distances[3].cumulativeDistance)
    }

    func testStateRefreshesReadoutsForKPathMutationsWithoutCallbackRecursion() {
        let cell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        let points = [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(0.5, 0, 0), "B"),
            KPoint(SIMD3(1, 0, 0), "C"),
        ]
        let state = SideBarState()
        state.syncFromScene(scene(cell: cell, points: points))
        assertApproximately(state.kPathDistanceReadouts[1].incomingDistance, Float.pi / 2)

        var changes = 0
        state.onChange = { changes += 1 }
        state.updateKPathPoint(at: 1, fractionalCoordinate: SIMD3(0.25, 0, 0), label: "B")
        XCTAssertEqual(changes, 1, "derived readouts must not recursively invoke onChange")
        assertApproximately(state.kPathDistanceReadouts[1].incomingDistance, Float.pi / 4)
        assertApproximately(state.kPathDistanceReadouts[2].cumulativeDistance, Float.pi)

        state.toggleBreak(at: 0)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(state.kPathDistanceReadouts[1].isComponentStart)
        XCTAssertNil(state.kPathDistanceReadouts[1].incomingDistance)
        assertApproximately(state.kPathDistanceReadouts[1].cumulativeDistance, 0)
        assertApproximately(state.kPathDistanceReadouts[2].cumulativeDistance, 3 * Float.pi / 4)

        state.append(KPoint(SIMD3(1.25, 0, 0), "D"))
        XCTAssertEqual(state.kPathDistanceReadouts.count, 4)
        assertApproximately(state.kPathTotalDistance, Float.pi)
    }

    func testStateSyncRefreshesReciprocalMetricFromLoadedSceneCell() {
        let points = [KPoint(SIMD3(0, 0, 0), "A"), KPoint(SIMD3(0.5, 0, 0), "B")]
        let firstCell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        let secondCell = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        let state = SideBarState()

        state.syncFromScene(scene(cell: firstCell, points: points))
        assertApproximately(state.kPathDistanceReadouts[1].incomingDistance, Float.pi / 2)

        state.syncFromScene(scene(cell: secondCell, points: points))
        assertApproximately(state.kPathDistanceReadouts[1].incomingDistance, Float.pi / 4)
        XCTAssertEqual(state.kPathDistanceReadouts.count, points.count)
    }
}
