import Foundation

// Density-of-states analysis: band center, bandwidth, gap detection, spin
// moment, and electron-count consistency. All methods are pure functions of
// the input DensityOfStates - they never mutate the structure and never crash
// on malformed data (return nil).

/// Result of a DOS gap (insulating/semiconducting region) analysis.
struct DOSTransitionResult {
    /// Lower edge of the gap region in eV (last energy where DOS rose above the
    /// threshold approaching from below).
    let gapStart: Float
    /// Upper edge of the gap region in eV (first energy where DOS rises above
    /// the threshold approaching from above).
    let gapEnd: Float
    /// gapEnd - gapStart in eV.
    let gapWidth: Float
    /// Estimate of the valence-band maximum: equal to gapStart.
    let vbmEstimate: Float
    /// Estimate of the conduction-band minimum: equal to gapEnd.
    let cbmEstimate: Float
}

/// Namespaced density-of-states analysis. All entry points are static methods
/// that take a DensityOfStates and return an optional result - nil means the
/// analysis could not be performed (invalid index, empty data, mismatched
/// grids, missing Fermi level where required).
enum DOSAnalysis {

    // MARK: - Trapezoidal integration helper

    /// Trapezoidal integral of `integrand(e, v)` over the DOS energies, optionally
    /// clipped to `range` with linear interpolation of the DOS value at
    /// partial-interval boundaries.
    ///
    /// For each energy interval [e_i, e_{i+1}] overlapping the requested range,
    /// the interval is clipped to [max(e_i, lo), min(e_{i+1}, hi)] and the DOS
    /// value at each clipped boundary is obtained by linear interpolation
    /// between the bracketing samples. The contribution is the standard
    /// trapezoid 0.5 * (f_a + f_b) * (b - a).
    ///
    /// Returns nil when the series index is out of bounds, the value/energy
    /// counts differ, there are fewer than two samples, or the range is empty.
    private static func integrate(
        _ dos: DensityOfStates,
        seriesIndex: Int,
        range: ClosedRange<Float>?,
        _ integrand: (_ e: Float, _ v: Float) -> Float
    ) -> Float? {
        guard seriesIndex >= 0, seriesIndex < dos.series.count else { return nil }
        let values = dos.series[seriesIndex].values
        let energies = dos.energies
        guard values.count == energies.count, energies.count >= 2 else { return nil }

        let lo = range?.lowerBound ?? energies.first!
        let hi = range?.upperBound ?? energies.last!
        guard lo < hi else { return nil }

        var sum: Float = 0
        for i in 0..<(energies.count - 1) {
            let e0 = energies[i]
            let e1 = energies[i + 1]
            let v0 = values[i]
            let v1 = values[i + 1]
            // Clip interval [e0, e1] to [lo, hi].
            let a = max(e0, lo)
            let b = min(e1, hi)
            guard a < b else { continue }

            let de = e1 - e0
            guard de > 0 else { continue }

            // Linear interpolation of DOS at the clipped boundaries.
            let fa = v0 + (v1 - v0) * (a - e0) / de
            let fb = v0 + (v1 - v0) * (b - e0) / de

            let ia = integrand(a, fa)
            let ib = integrand(b, fb)
            sum += 0.5 * (ia + ib) * (b - a)
        }
        return sum
    }

    // MARK: - Band center

    /// Weighted mean energy (first moment) of the DOS, in eV:
    ///     E_center = ∫ E·DOS(E) dE / ∫ DOS(E) dE
    /// via trapezoidal integration.
    ///
    /// When `range` is supplied the integrals are restricted to energies within
    /// that range, with linear interpolation at the boundaries for partial
    /// intervals. When nil the full energy range is used.
    ///
    /// Returns nil when the series index is out of bounds, the series is empty,
    /// or the total weight ∫DOS dE is zero (e.g. an identically zero DOS).
    static func bandCenter(_ dos: DensityOfStates, seriesIndex: Int = 0, range: ClosedRange<Float>? = nil) -> Float? {
        func weightIntegrand(_ e: Float, _ v: Float) -> Float { v }
        func momentIntegrand(_ e: Float, _ v: Float) -> Float { e * v }
        guard let weight = integrate(dos, seriesIndex: seriesIndex, range: range, weightIntegrand),
              weight != 0 else { return nil }
        guard let moment = integrate(dos, seriesIndex: seriesIndex, range: range, momentIntegrand) else { return nil }
        return moment / weight
    }

    // MARK: - Band width

    /// Root-mean-square band width (standard deviation of the DOS), in eV:
    ///     W = sqrt( ∫ (E - E_center)^2 · DOS(E) dE / ∫ DOS(E) dE )
    /// via trapezoidal integration, where E_center is the band center.
    ///
    /// When `range` is supplied the integrals are restricted to energies within
    /// that range, with boundary interpolation. When nil the full range is used.
    ///
    /// Returns nil when `bandCenter` is nil (invalid index, empty, or zero weight).
    static func bandWidth(_ dos: DensityOfStates, seriesIndex: Int = 0, range: ClosedRange<Float>? = nil) -> Float? {
        guard let center = bandCenter(dos, seriesIndex: seriesIndex, range: range) else { return nil }
        guard seriesIndex >= 0, seriesIndex < dos.series.count else { return nil }
        let values = dos.series[seriesIndex].values
        let energies = dos.energies
        guard values.count == energies.count, energies.count >= 2 else { return nil }

        let lo = range?.lowerBound ?? energies.first!
        let hi = range?.upperBound ?? energies.last!
        guard lo < hi else { return nil }

        // Trapezoidal accumulation of weight and second moment over the
        // (optionally clipped) grid, keeping the two integrals consistent.
        var weight: Float = 0
        var secondMoment: Float = 0
        for i in 0..<(energies.count - 1) {
            let e0 = energies[i]
            let e1 = energies[i + 1]
            let v0 = values[i]
            let v1 = values[i + 1]
            let a = max(e0, lo)
            let b = min(e1, hi)
            guard a < b else { continue }
            let de = e1 - e0
            guard de > 0 else { continue }
            let fa = v0 + (v1 - v0) * (a - e0) / de
            let fb = v0 + (v1 - v0) * (b - e0) / de
            weight += 0.5 * (fa + fb) * (b - a)
            let da = a - center
            let db = b - center
            secondMoment += 0.5 * (da * da * fa + db * db * fb) * (b - a)
        }
        guard weight != 0 else { return nil }
        return sqrt(secondMoment / weight)
    }

    // MARK: - DOS gap

    /// Detect the widest contiguous gap region where |DOS(E)| < threshold, in eV.
    ///
    /// A gap region is a maximal run of consecutive samples whose magnitude is
    /// strictly below `threshold`. The region edges (gapStart, gapEnd) are
    /// estimated by linear interpolation at the threshold crossing between the
    /// last above-threshold sample and the first below-threshold sample (and
    /// vice versa at the far edge). When a run touches the edge of the energy
    /// grid, the grid edge is used directly.
    ///
    /// Selection rule:
    /// - If `fermiEnergy` is present, the gap whose midpoint is nearest to the
    ///   Fermi level is returned (anchors the gap to the physically relevant one).
    /// - Otherwise the widest gap (largest gapWidth) is returned.
    ///
    /// Returns nil when no sample lies below the threshold (no gap region).
    static func dosGap(_ dos: DensityOfStates, seriesIndex: Int = 0, threshold: Float = 0.05) -> DOSTransitionResult? {
        guard seriesIndex >= 0, seriesIndex < dos.series.count else { return nil }
        let values = dos.series[seriesIndex].values
        let energies = dos.energies
        guard values.count == energies.count, energies.count >= 2 else { return nil }
        guard threshold > 0 else { return nil }

        // Find maximal contiguous runs where |DOS| < threshold. Gap edges are
        // interpolated to the threshold crossing between the last above-threshold
        // sample and the first below-threshold sample (and vice versa at the far
        // edge). When a run touches the energy-grid edge, that edge is used directly.
        //
        // crossing(belowIndex, aboveIndex): both indices valid, values straddle the
        // threshold. Returns the energy where |DOS| == threshold by linear interpolation.
        func crossing(belowIndex: Int, aboveIndex: Int) -> Float {
            let e0 = energies[belowIndex], e1 = energies[aboveIndex]
            let v0 = abs(values[belowIndex]) - threshold   // <= 0
            let v1 = abs(values[aboveIndex]) - threshold   // >= 0
            let denom = v1 - v0
            if denom == 0 { return (e0 + e1) * 0.5 }
            let t = -v0 / denom   // fraction from belowIndex toward aboveIndex
            return e0 + (e1 - e0) * t
        }
        var regions: [(start: Float, end: Float)] = []
        var i = 0
        let n = energies.count
        while i < n {
            if abs(values[i]) < threshold {
                let runStart = i
                while i < n && abs(values[i]) < threshold { i += 1 }
                let runEnd = i - 1
                // Left edge: crossing between runStart-1 (above) and runStart (below).
                let startE: Float = (runStart == 0) ? energies[0]
                    : crossing(belowIndex: runStart, aboveIndex: runStart - 1)
                // Right edge: crossing between runEnd (below) and runEnd+1 (above).
                let endE: Float = (runEnd == n - 1) ? energies[n - 1]
                    : crossing(belowIndex: runEnd, aboveIndex: runEnd + 1)
                regions.append((start: startE, end: endE))
            } else {
                i += 1
            }
        }

        guard !regions.isEmpty else { return nil }

        let chosen: (start: Float, end: Float)
        if let ef = dos.fermiEnergy, ef.isFinite {
            // Prefer a gap region that CONTAINS the Fermi level; if none does, fall
            // back to the gap whose edge is nearest Ef.
            let containing = regions.first(where: { ef >= $0.start && ef <= $0.end })
            if let c = containing {
                chosen = c
            } else {
                chosen = regions.min(by: {
                    min(abs($0.start - ef), abs($0.end - ef)) < min(abs($1.start - ef), abs($1.end - ef))
                })!
            }
        } else {
            // No Fermi level: return the widest gap.
            chosen = regions.max(by: { ($0.end - $0.start) < ($1.end - $1.start) })!
        }

        return DOSTransitionResult(
            gapStart: chosen.start,
            gapEnd: chosen.end,
            gapWidth: chosen.end - chosen.start,
            vbmEstimate: chosen.start,
            cbmEstimate: chosen.end
        )
    }

    // MARK: - Spin moment

    /// Net spin moment: ∫ (DOS_up(E) - DOS_down(E)) dE via trapezoidal
    /// integration over the shared energy grid.
    ///
    /// Returns nil when either series index is out of bounds, or when the two
    /// series (or the energy grid) differ in sample count, so the subtraction
    /// is undefined.
    static func spinMoment(_ dos: DensityOfStates, upSeriesIndex: Int, downSeriesIndex: Int) -> Float? {
        guard upSeriesIndex >= 0, upSeriesIndex < dos.series.count else { return nil }
        guard downSeriesIndex >= 0, downSeriesIndex < dos.series.count else { return nil }
        let up = dos.series[upSeriesIndex].values
        let down = dos.series[downSeriesIndex].values
        let energies = dos.energies
        guard up.count == down.count, up.count == energies.count, energies.count >= 2 else { return nil }

        var moment: Float = 0
        for i in 0..<(energies.count - 1) {
            let de = energies[i + 1] - energies[i]
            let diff0 = up[i] - down[i]
            let diff1 = up[i + 1] - down[i + 1]
            moment += 0.5 * (diff0 + diff1) * de
        }
        return moment
    }

    // MARK: - Electron-count consistency

    /// Check whether the integrated DOS up to the Fermi level is consistent
    /// with a given electron count.
    ///
    /// The total number of states is ∫_{-inf}^{E_f} DOS(E) dE via trapezoidal
    /// integration (with boundary interpolation at E_f). For an unpolarized
    /// calculation each state holds two electrons, so
    ///     electrons = totalStates / 2.
    /// Returns true when this is within ±1 of electronsPerAtom * atomCount.
    ///
    /// Returns nil when fermiEnergy is absent, the series index is out of bounds,
    /// or the data is degenerate (mismatched counts, fewer than two samples).
    static func isConsistentWithElectronCount(_ dos: DensityOfStates, seriesIndex: Int = 0, electronsPerAtom: Int, atomCount: Int) -> Bool? {
        guard let ef = dos.fermiEnergy else { return nil }
        guard seriesIndex >= 0, seriesIndex < dos.series.count else { return nil }
        let values = dos.series[seriesIndex].values
        guard values.count == dos.energies.count, dos.energies.count >= 2 else { return nil }

        let expected = Float(electronsPerAtom * atomCount)
        // Integrate from the bottom of the grid up to the Fermi level. If the
        // Fermi level lies below the grid the integrated total is zero.
        guard let eMin = dos.energies.first, ef >= eMin else {
            return abs(expected) <= 1   // no occupied states; consistent only if none expected
        }
        let totalStates = integrate(dos, seriesIndex: seriesIndex, range: eMin...ef) { _, v in v } ?? 0
        let electrons = totalStates * 0.5
        return abs(electrons - expected) <= 1
    }
}
