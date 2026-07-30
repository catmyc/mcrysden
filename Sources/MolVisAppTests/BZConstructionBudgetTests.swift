import XCTest
import simd
@testable import MolVisApp

final class BZConstructionBudgetTests: XCTestCase {
    func testFeasibilityEstimateHasAStableExplicitBudget() {
        XCTAssertEqual(BrillouinZone.estimatedPolyhedronFeasibilityOperations(forNeighborCount: 26), 67_600)
        let boundedAttempts = [6, 12, 18, 24]
        let cumulative = BrillouinZone.estimatedCumulativePolyhedronFeasibilityOperations(forNeighborCounts: boundedAttempts)!
        XCTAssertEqual(cumulative, boundedAttempts.reduce(0) {
            $0 + BrillouinZone.estimatedPolyhedronFeasibilityOperations(forNeighborCount: $1)!
        })
        XCTAssertLessThanOrEqual(cumulative, BrillouinZone.totalPolyhedronFeasibilityOperationBudget)
        XCTAssertGreaterThan(
            BrillouinZone.estimatedCumulativePolyhedronFeasibilityOperations(forNeighborCounts: [42, 42, 42, 42])!,
            BrillouinZone.totalPolyhedronFeasibilityOperationBudget)
        XCTAssertLessThanOrEqual(
            BrillouinZone.estimatedPolyhedronFeasibilityOperations(forNeighborCount: 42)!,
            BrillouinZone.polyhedronFeasibilityOperationBudget)
        XCTAssertGreaterThan(
            BrillouinZone.estimatedPolyhedronFeasibilityOperations(forNeighborCount: 43)!,
            BrillouinZone.polyhedronFeasibilityOperationBudget)
        XCTAssertNil(BrillouinZone.estimatedPolyhedronFeasibilityOperations(forNeighborCount: -1))
    }

    func testGaAsHUsesSmallPrefixWithinCumulativeBudget() {
        let cell = Cell(a: SIMD3<Float>(5.52460788, 0, 0),
                        b: SIMD3<Float>(0, 3.9064878, 0),
                        c: SIMD3<Float>(0, 0, 19.5324385))
        var diagnostics = BZConstructionDiagnostics()
        let bz = BrillouinZone.build(cell: cell,
                                     atoms: [Atom(coord: .zero, atomicNumber: 31, label: "Ga")],
                                     diagnostics: &diagnostics)

        XCTAssertNotNil(bz)
        XCTAssertGreaterThan(diagnostics.candidateCount, diagnostics.initialNeighborCount)
        XCTAssertEqual(diagnostics.initialNeighborCount, 6,
                       "GaAsH must not enter Geometry with the oversized prefix")
        XCTAssertEqual(diagnostics.solverNeighborCounts, [6],
                       "GaAsH's omitted bisectors must certify from the small prefix")
        XCTAssertEqual(diagnostics.cumulativeEstimatedOperations,
                       BrillouinZone.estimatedCumulativePolyhedronFeasibilityOperations(
                           forNeighborCounts: diagnostics.solverNeighborCounts))
        XCTAssertLessThanOrEqual(diagnostics.cumulativeEstimatedOperations,
                                  BrillouinZone.totalPolyhedronFeasibilityOperationBudget)
        XCTAssertTrue(diagnostics.certified)
        XCTAssertEqual(diagnostics.geometryFailureCount, 0)
    }

    func testCenteredLatticeRefinesByBoundedShells() {
        let a: Float = 5.43
        let cell = Cell(a: SIMD3<Float>(a, 0, 0),
                        b: SIMD3<Float>(0, a, 0),
                        c: SIMD3<Float>(0, 0, a))
        let atoms: [Atom] = [SIMD3(0, 0, 0), SIMD3(0, 0.5 * a, 0.5 * a),
                             SIMD3(0.5 * a, 0, 0.5 * a), SIMD3(0.5 * a, 0.5 * a, 0)]
            .map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
        var diagnostics = BZConstructionDiagnostics()
        let bz = BrillouinZone.build(cell: cell, atoms: atoms, diagnostics: &diagnostics)

        XCTAssertNotNil(bz)
        XCTAssertGreaterThan(diagnostics.solverNeighborCounts.count, 1)
        XCTAssertEqual(diagnostics.cumulativeEstimatedOperations,
                       BrillouinZone.estimatedCumulativePolyhedronFeasibilityOperations(
                           forNeighborCounts: diagnostics.solverNeighborCounts))
        XCTAssertLessThanOrEqual(diagnostics.cumulativeEstimatedOperations,
                                  BrillouinZone.totalPolyhedronFeasibilityOperationBudget)
        XCTAssertTrue(diagnostics.certified)
    }

    func testPathologicalExpansionFailsFastAndDeterministically() {
        // The initial ratio box is admissible, but proving the exterior of this
        // highly anisotropic box would exceed the bounded candidate domain.
        let twoPi = Float(2 * Double.pi)
        // Reciprocal columns are (8,7,0), (7,6,0), and (0,0,1). The inverse
        // has coefficients of magnitude 7 and 8, so the proof needs shells
        // well beyond the initial length-ratio box before it can certify the
        // exterior. The candidate cap must stop that expansion.
        let cell = Cell(a: SIMD3<Float>(-6 * twoPi, 7 * twoPi, 0),
                        b: SIMD3<Float>(7 * twoPi, -8 * twoPi, 0),
                        c: SIMD3<Float>(0, 0, twoPi))
        let atoms = [Atom(coord: .zero, atomicNumber: 14, label: "Si")]

        let start = DispatchTime.now().uptimeNanoseconds
        let first = BrillouinZone.build(cell: cell, atoms: atoms)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        XCTAssertNil(first, "a domain that exceeds the candidate budget must be skipped")
        XCTAssertLessThan(elapsed, 250_000_000, "a pathological BZ must fail before a long geometry scan")
        var diagnostics = BZConstructionDiagnostics()
        let second = BrillouinZone.build(cell: cell, atoms: atoms, diagnostics: &diagnostics)
        XCTAssertNil(second)
        XCTAssertFalse(diagnostics.certified)
        XCTAssertFalse(diagnostics.exteriorCertified)
        XCTAssertLessThanOrEqual(diagnostics.candidateEnumerationWork,
                                 BrillouinZone.coefficientEnumerationWorkBudget)
    }

}
