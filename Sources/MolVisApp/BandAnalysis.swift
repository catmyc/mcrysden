import Foundation

// Band-structure analysis: band gap, effective mass, and convenience accessors
// over a parsed . All methods are pure functions of the input -
// they never mutate the scene and never crash on malformed data (return nil).

/// Result of a band-gap analysis for one spin channel.
struct BandGapResult {
    /// Valence-band maximum (highest occupied level) in eV.
    let vbm: Float
    /// Conduction-band minimum (lowest unoccupied level) in eV.
    let cbm: Float
    /// Gap = cbm - vbm in eV. Negative when the bands overlap the Fermi level
    /// (metallic); the magnitude is the overlap.
    let gap: Float
    /// True when the VBM and CBM occur at the same k-point index within the
    /// channel (direct gap). False for an indirect gap.
    let isDirect: Bool
    /// True when gap <= 0: the valence and conduction manifolds overlap the Fermi
    /// level, so the material is metallic/semi-metallic within this channel.
    let isMetallic: Bool
    /// Index into  of the k-point hosting the VBM.
    let vbmKPointIndex: Int
    /// Index into  of the k-point hosting the CBM.
    let cbmKPointIndex: Int
    /// Spin channel this result was computed for (0 = up, 1 = down, ...).
    let spinChannel: Int
}

/// Electron (conduction) and hole (valence) effective masses at the band edges,
/// in units of the free-electron rest mass m0. Values are signed exactly as
/// `effectiveMass` returns: `electronMass` > 0 (CBM is a minimum), `holeMass` <
/// 0 (VBM is a maximum, d2E/dk2 < 0). A physical (positive) hole mass is
/// `-holeMass`; `ElectronicAnalysisPresentation` negates at display.
struct GapMassResult {
    /// Electron effective mass at the CBM (m*_e / m0); always positive.
    let electronMass: Float
    /// Hole effective mass at the VBM (m*_h / m0); ALWAYS NEGATIVE — the raw
    /// signed hbar^2/(d2E/dk2) at a band maximum. Physical hole mass = -holeMass.
    let holeMass: Float
    /// Band index (within the k-point energies array) of the CBM.
    let electronBand: Int
    /// Band index of the VBM.
    let holeBand: Int
    /// k-point index of the CBM.
    let electronKIndex: Int
    /// k-point index of the VBM.
    let holeKIndex: Int
}

/// Namespaced band-structure analysis. All entry points are static methods that
/// take a  and return an optional result - nil means the analysis
/// could not be performed (missing Fermi level, mesh data, degenerate input).
enum BandAnalysis {

    // MARK: - Constants

    /// hbar^2/m0 expressed in eV*Ang^2. Derived from the CODATA relation
    /// hbar^2/(2m0) = 3.80998 eV*Ang^2, so hbar^2/m0 = 2 * 3.80998.
    /// Used to convert a curvature d2E/dk2 (eV*Ang^2) to a dimensionless effective
    /// mass via m*/m0 = (hbar^2/m0) / (d2E/dk2).
    static let hbarSquaredOverM0: Float = 7.61996

    // MARK: - Band gap

    /// Compute the band gap of  for spin channel 0 (or the first channel that
    /// yields a valid gap).
    ///
    /// Returns nil when the gap is undefined: no Fermi level reported, the data
    /// is a uniform sampling mesh (not a band path), there are no bands or
    /// k-points, or the channel layout is invalid.
    ///
    /// Per channel the valence-band maximum (VBM) is the highest occupied level
    /// across all k-points, and the conduction-band minimum (CBM) is the lowest
    /// unoccupied level. A channel whose bands all lie on one side of the Fermi
    /// level (no occupied or no unoccupied states) is skipped.
    ///
    /// **Metallicity detection.** A channel is metallic when any band crosses the
    /// Fermi level along the path — i.e. that band's minimum energy <= Ef and its
    /// maximum energy >= Ef. The simple occupied/unoccupied partition can never
    /// produce a negative gap, so band-crossing is the physically correct metallic
    /// signal here. A metallic channel is reported with gap 0.
    static func bandGap(_ bs: BandStructure) -> BandGapResult? {
        guard let ef = bs.fermiEnergy else { return nil }
        guard !bs.isMesh else { return nil }
        guard bs.nBands > 0, bs.nKPoints > 0 else { return nil }
        guard bs.hasValidChannelLayout else { return nil }

        let perSpin = bs.kPointsPerSpin

        for s in 0..<bs.nSpin {
            let base = s * perSpin
            var vbmValue: Float = -.infinity
            var cbmValue: Float = .infinity
            var vbmIndex = -1
            var cbmIndex = -1
            var hasOccupied = false
            var hasUnoccupied = false

            // Per-band min/max across the channel, for crossing detection.
            var bandMin = [Float](repeating: .infinity, count: bs.nBands)
            var bandMax = [Float](repeating: -.infinity, count: bs.nBands)

            for ik in 0..<perSpin {
                let idx = base + ik
                let energies = bs.kPoints[idx].energies
                guard !energies.isEmpty else { continue }

                // Highest occupied band at this k-point (<= Ef).
                var occMax: Float = -.infinity
                // Lowest unoccupied band at this k-point (> Ef).
                var unoccMin: Float = .infinity
                for (ib, e) in energies.enumerated() {
                    if ib < bs.nBands {
                        if e < bandMin[ib] { bandMin[ib] = e }
                        if e > bandMax[ib] { bandMax[ib] = e }
                    }
                    if e <= ef {
                        if e > occMax { occMax = e }
                    } else {
                        if e < unoccMin { unoccMin = e }
                    }
                }
                if occMax.isFinite {
                    hasOccupied = true
                    if occMax > vbmValue { vbmValue = occMax; vbmIndex = idx }
                }
                if unoccMin.isFinite {
                    hasUnoccupied = true
                    if unoccMin < cbmValue { cbmValue = unoccMin; cbmIndex = idx }
                }
            }

            // Skip a channel with no occupied or no unoccupied states.
            guard hasOccupied, hasUnoccupied else { continue }

            // Metallic if any band crosses Ef along the path.
            var isMetallic = false
            for ib in 0..<bs.nBands {
                if bandMin[ib] <= ef && bandMax[ib] >= ef { isMetallic = true; break }
            }

            let gap = isMetallic ? 0 : (cbmValue - vbmValue)
            return BandGapResult(
                vbm: vbmValue,
                cbm: cbmValue,
                gap: gap,
                isDirect: vbmIndex == cbmIndex,
                isMetallic: isMetallic,
                vbmKPointIndex: vbmIndex,
                cbmKPointIndex: cbmIndex,
                spinChannel: s
            )
        }
        return nil
    }

    // MARK: - Effective mass

    /// Effective mass of  at k-point index  (within ), in units
    /// of the free-electron rest mass m0.
    ///
    /// Physics: near an extremum the dispersion is parabolic,
    ///     E(k) ~ E0 + (hbar^2/2m*) (k - k0)^2
    /// so the curvature d2E/dk2 = hbar^2/m* and therefore
    ///     m* = hbar^2 / (d2E/dk2).
    /// In m0 units:
    ///     m*/m0 = (hbar^2/m0) / (d2E/dk2).
    ///
    /// The curvature is estimated by a three-point finite difference over the band
    /// energies at k-1, k, k+1. For uniform spacing this reduces to
    ///     d2E/dk2 ~ (E_{+1} - 2E_0 + E_{-1}) / (dk)^2
    /// but band paths commonly have unequal adjacent steps, so the nonuniform form
    /// is used:
    ///     d2E/dk2 = 2 * ((E2-E1)/h2 - (E1-E0)/h1) / (h1 + h2)
    /// where h1 = k1 - k0 and h2 = k2 - k1. This is exact for a quadratic and
    /// first-order accurate on nonuniform grids.
    ///
    /// **Length-unit assumption:** distances must be in Ang^-1 for the result to be
    /// a true m*/m0. When kPointsAreCrystal the distances are in units of 2pi/a and
    /// the caller is responsible for the lattice-scale conversion; the returned mass
    /// is then in corresponding (2pi/a)^-2 units. If the distances are not in
    /// Ang^-1 the caller must rescale.
    ///
    /// **Sign contract:** this returns the raw signed value hbar^2/d2 — NOT a
    /// magnitude. At a band MINIMUM (CBM, d2E/dk2 > 0) the result is positive; at
    /// a band MAXIMUM (VBM, d2E/dk2 < 0) it is negative. `GapMassResult` stores the
    /// value exactly as signed: `electronMass` is positive and `holeMass` is
    /// negative. Callers wanting a physical (positive) hole mass for display must
    /// negate `holeMass`; `ElectronicAnalysisPresentation` does this and labels it.
    static func effectiveMass(_ bs: BandStructure, band: Int, atKIndex k: Int, channel: Int = 0) -> Float? {
        guard !bs.isMesh else { return nil }
        guard bs.hasValidChannelLayout else { return nil }
        guard channel >= 0, channel < bs.nSpin else { return nil }
        let perSpin = bs.kPointsPerSpin
        let base = channel * perSpin
        // Central difference needs both neighbours inside the channel.
        guard k >= 1, k < perSpin - 1 else { return nil }
        guard band >= 0 else { return nil }

        let i0 = base + k - 1
        let i1 = base + k
        let i2 = base + k + 1
        guard band < bs.kPoints[i0].energies.count,
              band < bs.kPoints[i1].energies.count,
              band < bs.kPoints[i2].energies.count else { return nil }

        let distances = bs.kDistances
        let e0 = bs.kPoints[i0].energies[band]
        let e1 = bs.kPoints[i1].energies[band]
        let e2 = bs.kPoints[i2].energies[band]

        // Adjacent steps from the cumulative path distances.
        let h1 = distances[i1] - distances[i0]
        let h2 = distances[i2] - distances[i1]
        guard h1 > 0, h2 > 0, h1.isFinite, h2.isFinite else { return nil }

        // Nonuniform three-point second derivative.
        let d2 = 2.0 * ((e2 - e1) / h2 - (e1 - e0) / h1) / (h1 + h2)
        guard d2 != 0, d2.isFinite else { return nil }

        return hbarSquaredOverM0 / d2
    }

    /// Electron (CBM) and hole (VBM) effective masses at the band edges of .
    ///
    /// Uses  to locate the VBM and CBM k-points, identifies the band
    /// indices at those points via deterministic curvature-aware tie-breaking,
    /// and computes the effective mass at each via . Returns nil if the band gap
    /// is undefined.
    static func effectiveMassesNearGap(_ bs: BandStructure) -> GapMassResult? {
        guard let g = bandGap(bs) else { return nil }

        // Identify the band indices at the VBM and CBM k-points.
        let vbmEnergies = bs.kPoints[g.vbmKPointIndex].energies
        let cbmEnergies = bs.kPoints[g.cbmKPointIndex].energies

        // Degenerate bands at the gap edge share the extremum energy; the
        // historical "first band at that energy" pick is arbitrary in curvature.
        // For a deterministic, physically meaningful choice, gather every band at
        // the edge within `degeneracyTolerance` of the extremum energy and compute
        // each band's curvature at that k-point via `effectiveMass`. The band with
        // the SMALLEST |effective mass| (largest curvature |d2E/dk2|) is the most
        // strongly dispersive and dominates transport; that is the physical edge
        // band. If no band yields a valid curvature (edge of the path, zero step),
        // fall back to the deterministic first-band-at-extremum so the result
        // stays stable across calls.
        let ef = bs.fermiEnergy!
        let perSpin = bs.kPointsPerSpin
        let vbmLocalK = g.vbmKPointIndex - g.spinChannel * perSpin
        let cbmLocalK = g.cbmKPointIndex - g.spinChannel * perSpin
        let degeneracyTolerance: Float = 1e-4  // eV

        func selectEdgeBand(
            energies: [Float],
            isHole: Bool,
            kIndex: Int
        ) -> (band: Int, energy: Float)? {
            // Step 1: the deterministic extremum energy (highest occupied for VBM,
            // lowest unoccupied for CBM) and the first band attaining it.
            var extremumEnergy: Float = isHole ? -.infinity : .infinity
            var firstBand = -1
            for (i, e) in energies.enumerated() {
                let valid = isHole ? (e <= ef) : (e > ef)
                guard valid else { continue }
                if isHole ? (e > extremumEnergy) : (e < extremumEnergy) {
                    extremumEnergy = e
                    firstBand = i
                }
            }
            guard firstBand >= 0 else { return nil }

            // Step 2: among bands degenerate with the extremum, keep the one with
            // the smallest |effective mass| (largest curvature).
            var bestBand = firstBand
            var bestCurvature: Float = 0
            var foundCurvature = false
            for (i, e) in energies.enumerated() {
                let valid = isHole ? (e <= ef) : (e > ef)
                guard valid else { continue }
                guard abs(e - extremumEnergy) <= degeneracyTolerance else { continue }
                guard let m = effectiveMass(bs, band: i, atKIndex: kIndex, channel: g.spinChannel),
                      m.isFinite, m != 0 else { continue }
                let curvature = abs(BandAnalysis.hbarSquaredOverM0 / m)  // |d2E/dk2|
                if !foundCurvature || curvature > bestCurvature {
                    bestCurvature = curvature
                    bestBand = i
                    foundCurvature = true
                }
            }
            return (band: bestBand, energy: extremumEnergy)
        }

        guard let hole = selectEdgeBand(energies: vbmEnergies, isHole: true, kIndex: vbmLocalK),
              let electron = selectEdgeBand(energies: cbmEnergies, isHole: false, kIndex: cbmLocalK) else {
            return nil
        }
        let (holeBand, holeEnergy) = (hole.band, hole.energy)
        let (electronBand, electronEnergy) = (electron.band, electron.energy)
        _ = holeEnergy
        _ = electronEnergy

        guard let holeMass = effectiveMass(bs, band: holeBand, atKIndex: vbmLocalK, channel: g.spinChannel),
              let electronMass = effectiveMass(bs, band: electronBand, atKIndex: cbmLocalK, channel: g.spinChannel) else {
            return nil
        }

        return GapMassResult(
            electronMass: electronMass,
            holeMass: holeMass,
            electronBand: electronBand,
            holeBand: holeBand,
            electronKIndex: g.cbmKPointIndex,
            holeKIndex: g.vbmKPointIndex
        )
    }

    // MARK: - Convenience accessors

    /// Valence-band maximum (highest occupied level) and its k-point index for
    /// . Returns nil when the VBM is undefined.
    static func valenceBandMaximum(_ bs: BandStructure, channel: Int = 0) -> (energy: Float, kIndex: Int)? {
        guard let ef = bs.fermiEnergy else { return nil }
        guard bs.hasValidChannelLayout else { return nil }
        guard channel >= 0, channel < bs.nSpin else { return nil }
        let perSpin = bs.kPointsPerSpin
        let base = channel * perSpin

        var vbmValue: Float = -.infinity
        var vbmIndex = -1
        for ik in 0..<perSpin {
            let idx = base + ik
            for e in bs.kPoints[idx].energies {
                if e <= ef && e > vbmValue { vbmValue = e; vbmIndex = idx }
            }
        }
        guard vbmIndex >= 0 else { return nil }
        return (energy: vbmValue, kIndex: vbmIndex)
    }

    /// Conduction-band minimum (lowest unoccupied level) and its k-point index
    /// for . Returns nil when the CBM is undefined.
    static func conductionBandMinimum(_ bs: BandStructure, channel: Int = 0) -> (energy: Float, kIndex: Int)? {
        guard let ef = bs.fermiEnergy else { return nil }
        guard bs.hasValidChannelLayout else { return nil }
        guard channel >= 0, channel < bs.nSpin else { return nil }
        let perSpin = bs.kPointsPerSpin
        let base = channel * perSpin

        var cbmValue: Float = .infinity
        var cbmIndex = -1
        for ik in 0..<perSpin {
            let idx = base + ik
            for e in bs.kPoints[idx].energies {
                if e > ef && e < cbmValue { cbmValue = e; cbmIndex = idx }
            }
        }
        guard cbmIndex >= 0 else { return nil }
        return (energy: cbmValue, kIndex: cbmIndex)
    }
}
