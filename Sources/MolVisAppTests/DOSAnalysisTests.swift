import XCTest
@testable import MolVisApp

// Tests for DOSAnalysis. Each case builds a synthetic DensityOfStates and
// checks the analysis result against a hand-computed reference value.

final class DOSAnalysisTests: XCTestCase {

    // MARK: - Helpers

    /// Build a DOS with a single series of constant `value` over a uniform
    /// grid from `e0` to `e1` (inclusive) with `count` samples.
    private func flatDOS(e0: Float, e1: Float, count: Int, value: Float, fermi: Float? = nil) -> DensityOfStates {
        var energies: [Float] = []
        energies.reserveCapacity(count)
        for i in 0..<count {
            let t = count > 1 ? Float(i) / Float(count - 1) : 0
            energies.append(e0 + (e1 - e0) * t)
        }
        return DensityOfStates(
            energies: energies,
            series: [DOSSeries(label: "Total DOS", values: Array(repeating: value, count: count))],
            fermiEnergy: fermi
        )
    }

    // MARK: - bandCenter

    /// 1. Flat DOS = 1.0 over [0,10] eV → center of mass at 5.0.
    func testBandCenterFlatDOS() {
        let dos = flatDOS(e0: 0, e1: 10, count: 1001, value: 1.0)
        let center = DOSAnalysis.bandCenter(dos)
        XCTAssertNotNil(center)
        XCTAssertEqual(center!, 5.0, accuracy: 0.01)
    }

    /// 2. Flat DOS = 1.0 over [0,10] eV → RMS width = sqrt(∫(E-5)² dE / ∫1 dE)
    ///    = sqrt( (10^3/12) / 10 ) = sqrt(100/12) ≈ 2.887.
    func testBandWidthFlatDOS() {
        let dos = flatDOS(e0: 0, e1: 10, count: 1001, value: 1.0)
        let width = DOSAnalysis.bandWidth(dos)
        XCTAssertNotNil(width)
        XCTAssertEqual(width!, 2.887, accuracy: 0.01)
    }

    /// 3. Restricted range on a flat DOS gives the midpoint of that range.
    func testBandCenterRestrictedRange() {
        let dos = flatDOS(e0: 0, e1: 10, count: 1001, value: 1.0)
        let center = DOSAnalysis.bandCenter(dos, range: 2.0...8.0)
        XCTAssertNotNil(center)
        XCTAssertEqual(center!, 5.0, accuracy: 0.01)
    }

    /// 4. Empty series → nil.
    func testBandCenterEmptySeries() {
        let dos = DensityOfStates(
            energies: [0, 1, 2],
            series: [DOSSeries(label: "empty", values: [])],
            fermiEnergy: nil
        )
        XCTAssertNil(DOSAnalysis.bandCenter(dos))
    }

    // MARK: - dosGap

    /// 5. A DOS with a zero region finds the gap and reports its width. Gap edges are
    /// interpolated to the threshold crossing (not raw sample positions).
    func testDosGapFindsGap() {
        // DOS = 1.0 everywhere except indices 3..7 (energies 3..7) where it is 0.
        // With threshold 0.05, the left crossing interpolates to 2.95 and the right
        // crossing to 7.05 (linear interp between the bracketing samples).
        let count = 11
        let values: [Float] = [1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1]
        let dos = DensityOfStates(
            energies: (0..<count).map { Float($0) },
            series: [DOSSeries(label: "total", values: values)],
            fermiEnergy: nil
        )
        let gap = DOSAnalysis.dosGap(dos)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap!.gapStart, 2.95, accuracy: 0.01)
        XCTAssertEqual(gap!.gapEnd, 7.05, accuracy: 0.01)
        XCTAssertEqual(gap!.gapWidth, 4.1, accuracy: 0.05)
        XCTAssertEqual(gap!.vbmEstimate, gap!.gapStart, accuracy: 0.001)
        XCTAssertEqual(gap!.cbmEstimate, gap!.gapEnd, accuracy: 0.001)
    }

    /// 6. Flat DOS everywhere → no gap → nil.
    func testDosGapNoGap() {
        let dos = flatDOS(e0: 0, e1: 10, count: 101, value: 1.0)
        XCTAssertNil(DOSAnalysis.dosGap(dos))
    }

    // MARK: - spinMoment

    /// 7. up = 1.0 flat, down = 0.5 flat over [0,10] → moment = 0.5 * 10 = 5.0.
    func testSpinMoment() {
        let count = 101
        let energies = (0..<count).map { Float($0) * 10.0 / Float(count - 1) }
        let up = DOSSeries(label: "up", values: Array(repeating: Float(1.0), count: count))
        let down = DOSSeries(label: "down", values: Array(repeating: Float(0.5), count: count))
        let dos = DensityOfStates(energies: energies, series: [up, down], fermiEnergy: nil)
        let moment = DOSAnalysis.spinMoment(dos, upSeriesIndex: 0, downSeriesIndex: 1)
        XCTAssertNotNil(moment)
        XCTAssertEqual(moment!, 5.0, accuracy: 0.01)
    }

    /// 8. Mismatched energy grids → nil.
    func testSpinMomentMismatchedGrids() {
        let dos = DensityOfStates(
            energies: Array(repeating: Float(0), count: 5),
            series: [
                DOSSeries(label: "up", values: Array(repeating: Float(1.0), count: 5)),
                DOSSeries(label: "down", values: Array(repeating: Float(0.5), count: 4))
            ],
            fermiEnergy: nil
        )
        XCTAssertNil(DOSAnalysis.spinMoment(dos, upSeriesIndex: 0, downSeriesIndex: 1))
    }

    // MARK: - isConsistentWithElectronCount

    /// 9. Flat DOS = 2 states/eV over [0,10], Ef = 5 → total states = 10,
    ///    unpolarized → 5 electrons. Consistent with 5 electrons (1 per atom × 5).
    func testIsConsistentWithElectronCount() {
        let dos = flatDOS(e0: 0, e1: 10, count: 1001, value: 2.0, fermi: 5.0)
        let consistent = DOSAnalysis.isConsistentWithElectronCount(dos, electronsPerAtom: 1, atomCount: 5)
        XCTAssertNotNil(consistent)
        XCTAssertTrue(consistent!)
    }

    /// 10. Two gap regions present with fermiEnergy set → returns the gap nearest
    ///     the Fermi level.
    func testDosGapAnchoredToFermi() {
        // Two zero regions: around energy 2 and around energy 8.
        let count = 21
        var values = Array(repeating: Float(1.0), count: count)
        for i in 3...5 { values[i] = 0 }   // gap near energy 4 (indices 3..5)
        for i in 15...17 { values[i] = 0 }  // gap near energy 16 (indices 15..17)
        let dos = DensityOfStates(
            energies: (0..<count).map { Float($0) },
            series: [DOSSeries(label: "total", values: values)],
            fermiEnergy: 4.0
        )
        let gap = DOSAnalysis.dosGap(dos)
        XCTAssertNotNil(gap)
        // Ef=4.0 lies inside the first gap region (indices 3..5, i.e. energies
        // 3..5), so the containing-gap rule selects it. Edges are interpolated to
        // the threshold crossing (2.95 .. 5.05).
        XCTAssertEqual(gap!.gapStart, 2.95, accuracy: 0.01)
        XCTAssertEqual(gap!.gapEnd, 5.05, accuracy: 0.01)
    }

    /// 11. Fermi level below the energy grid must not trap on an invalid range.
    func testElectronCountFermiBelowGrid() {
        // Grid starts at energy 0, but Ef = -1 (below the grid). Must return a
        // result (no occupied states) rather than trapping on `0...(-1)`.
        let dos = flatDOS(e0: 0, e1: 10, count: 1001, value: 1.0, fermi: -1.0)
        let consistent = DOSAnalysis.isConsistentWithElectronCount(dos, electronsPerAtom: 0, atomCount: 1)
        XCTAssertEqual(consistent, true)   // zero electrons expected, zero integrated
    }
}
