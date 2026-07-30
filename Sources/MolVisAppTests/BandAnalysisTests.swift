import XCTest
import simd

@testable import MolVisApp

/// Synthetic band-structure fixtures and tests for `BandAnalysis`.
///
/// All fixtures are built by direct construction of `BandStructure` so the
/// energies, Fermi level, and k-path are fully under test control. Parabolic
/// bands E(k) = A*k^2 are used where the effective mass is known analytically:
/// d2E/dk2 = 2A and m*/m0 = 7.61996/(2A).
final class BandAnalysisTests: XCTestCase {

    // MARK: - Fixtures

    /// A k-point at position `x` along a 1D path, with the given per-band energies.
    private func kPoint(x: Float, energies: [Float], label: String = "") -> BandKPoint {
        BandKPoint(k: SIMD3(x, 0, 0), weight: 1, label: label, energies: energies)
    }

    /// A uniform 1D path of `count` k-points from 0 to 1 (in Ang^-1-equivalent
    /// units), each carrying the same per-band energies.
    private func uniformPath(count: Int, energies: [Float]) -> [BandKPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let x = count > 1 ? Float(i) / Float(count - 1) : 0
            return kPoint(x: x, energies: energies)
        }
    }

    /// A parabolic band E(k) = amplitude * k^2 evaluated on a uniform path.
    private func parabolicPath(count: Int, amplitude: Float) -> [BandKPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let x = count > 1 ? Float(i) / Float(count - 1) : 0
            return kPoint(x: x, energies: [amplitude * x * x])
        }
    }

    /// Assemble a `BandStructure` from a single channel worth of k-points.
    private func makeStructure(
        kPoints: [BandKPoint],
        fermi: Float?,
        nSpin: Int = 1,
        kPointsPerSpin: Int? = nil,
        isMesh: Bool = false
    ) -> BandStructure {
        let perSpin = kPointsPerSpin ?? kPoints.count
        return BandStructure(
            kPoints: kPoints,
            fermiEnergy: fermi,
            nSpin: nSpin,
            reciprocal: nil,
            kPointsAreCrystal: false,
            kPointsPerSpin: perSpin,
            isMesh: isMesh
        )
    }

    // MARK: - Band gap tests

    /// Direct gap: VBM and CBM at the same k-point.
    func testDirectBandGap() {
        // Two bands: valence flat at -1 eV, conduction flat at +1 eV, Ef = 0.
        // Both extrema occur at the first k-point -> direct.
        let kps = uniformPath(count: 5, energies: [-1, 1])
        let bs = makeStructure(kPoints: kps, fermi: 0)

        let r = BandAnalysis.bandGap(bs)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.vbm, -1, accuracy: 1e-6)
        XCTAssertEqual(r!.cbm, 1, accuracy: 1e-6)
        XCTAssertEqual(r!.gap, 2, accuracy: 1e-6)
        XCTAssertEqual(r!.isDirect, true)
        XCTAssertEqual(r!.isMetallic, false)
        XCTAssertEqual(r!.spinChannel, 0)
    }

    /// Indirect gap: VBM and CBM at different k-points.
    func testIndirectBandGap() {
        // Ef = 0. Valence band maximum (highest energy <= 0) is -1 at k=0.
        // Conduction band minimum (lowest energy > 0) is 1 at k=1.
        let kps = [
            kPoint(x: 0.0, energies: [-1, 3]),
            kPoint(x: 0.25, energies: [-3, 1]),
            kPoint(x: 0.5, energies: [-4, 2]),
            kPoint(x: 0.75, energies: [-5, 4]),
            kPoint(x: 1.0, energies: [-6, 5]),
        ]
        let bs = makeStructure(kPoints: kps, fermi: 0)

        let r = BandAnalysis.bandGap(bs)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.vbm, -1, accuracy: 1e-6)
        XCTAssertEqual(r!.cbm, 1, accuracy: 1e-6)
        XCTAssertEqual(r!.gap, 2, accuracy: 1e-6)
        XCTAssertEqual(r!.isDirect, false)
        XCTAssertEqual(r!.vbmKPointIndex, 0)
        XCTAssertEqual(r!.cbmKPointIndex, 1)
    }

    /// Metallic case: a band crosses the Fermi level. The physically correct
    /// signature of a metal is a band whose energy straddles Ef along the path
    /// (min <= Ef <= max). bandGap detects this via per-band crossing, reporting
    /// isMetallic = true and gap = 0.
    func testMetallicBandStraddlesFermi() {
        // Band 0 crosses Ef=0: -0.5 at k=0 (occupied), +0.5 at k=1 (unoccupied).
        let kps = [
            kPoint(x: 0.0, energies: [-0.5, 2]),
            kPoint(x: 1.0, energies: [0.5, 3]),
        ]
        let bs = makeStructure(kPoints: kps, fermi: 0)
        let r = BandAnalysis.bandGap(bs)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.isMetallic, true)
        XCTAssertEqual(r!.gap, 0, accuracy: 1e-6)
    }

    /// A purely insulating structure (no band crosses Ef) is NOT metallic.
    func testInsulatingNotMetallic() {
        let kps = uniformPath(count: 5, energies: [-2, 3])
        let bs = makeStructure(kPoints: kps, fermi: 0)
        let r = BandAnalysis.bandGap(bs)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.isMetallic, false)
        XCTAssertEqual(r!.gap, 5, accuracy: 1e-6)
    }

    /// nil Fermi energy -> band gap undefined.
    func testNilFermiReturnsNil() {
        let kps = uniformPath(count: 3, energies: [-1, 1])
        let bs = makeStructure(kPoints: kps, fermi: nil)
        XCTAssertNil(BandAnalysis.bandGap(bs))
    }

    /// A uniform sampling mesh -> band gap meaningless -> nil.
    func testIsMeshReturnsNil() {
        let kps = uniformPath(count: 3, energies: [-1, 1])
        let bs = makeStructure(kPoints: kps, fermi: 0, isMesh: true)
        XCTAssertNil(BandAnalysis.bandGap(bs))
    }

    // MARK: - Effective mass tests

    /// Parabolic band E = 3.80998*k^2 (k in Ang^-1) has d2E/dk2 = 7.61996 eV*Ang^2,
    /// so m*/m0 = 7.61996 / 7.61996 = 1.0.
    func testEffectiveMassParabolicUnit() {
        let amplitude: Float = 3.80998
        let kps = parabolicPath(count: 21, amplitude: amplitude)
        let bs = makeStructure(kPoints: kps, fermi: 0)

        // Interior k-point (not at boundary).
        let m = BandAnalysis.effectiveMass(bs, band: 0, atKIndex: 10, channel: 0)
        XCTAssertNotNil(m)
        XCTAssertEqual(m!, 1.0, accuracy: 0.05, "m* should be ~1.0 m0 within 5%")
    }

    /// Nonuniform k-spacing: E = A*k^2 on an uneven grid. The nonuniform three-point
    /// formula is exact for a quadratic, so m* = 1.0 m0 regardless of spacing.
    func testEffectiveMassNonuniform() {
        // Uneven positions 0, 1, 3 with E = k^2 (A=3.80998 -> m*=1).
        let a: Float = 3.80998
        let xs: [Float] = [0.0, 1.0, 3.0]
        let kps = xs.map { kPoint(x: $0, energies: [a * $0 * $0]) }
        let bs = makeStructure(kPoints: kps, fermi: 0)

        let m = BandAnalysis.effectiveMass(bs, band: 0, atKIndex: 1, channel: 0)
        XCTAssertNotNil(m)
        XCTAssertEqual(m!, 1.0, accuracy: 0.02, "nonuniform quadratic should give m* = 1.0")
    }

    /// effectiveMass rejects mesh data (no meaningful band path).
    func testEffectiveMassRejectsMesh() {
        let kps = parabolicPath(count: 11, amplitude: 3.80998)
        let bs = makeStructure(kPoints: kps, fermi: 0, isMesh: true)
        XCTAssertNil(BandAnalysis.effectiveMass(bs, band: 0, atKIndex: 5, channel: 0))
    }

    /// Effective mass at a channel boundary cannot be central-differenced -> nil.
    func testEffectiveMassAtBoundaryNil() {
        let kps = parabolicPath(count: 11, amplitude: 3.80998)
        let bs = makeStructure(kPoints: kps, fermi: 0)

        XCTAssertNil(BandAnalysis.effectiveMass(bs, band: 0, atKIndex: 0, channel: 0))
        XCTAssertNil(BandAnalysis.effectiveMass(bs, band: 0, atKIndex: 10, channel: 0))
    }

    // MARK: - Gap mass tests

    /// effectiveMassesNearGap returns electron + hole mass for a known structure
    /// with band edges at INTERIOR k-points.
    func testEffectiveMassesNearGapInterior() {
        // Valence band peaks AWAY from k=0: E = -1 + 3.80998*(k-0.5)^2 - 3.80998*0.25
        // so the maximum is at k=0.5 (interior). Conduction band minimum also
        // at k=0.5. Both parabolic with |m*| = 1.0.
        let count = 21
        var kps: [BandKPoint] = []
        for i in 0..<count {
            let x = Float(i) / Float(count - 1)
            let dk = x - 0.5
            let e = 3.80998 * dk * dk
            // Valence: maximum at k=0.5 (energy -1), decreasing outward.
            // Conduction: minimum at k=0.5 (energy 1), increasing outward.
            kps.append(kPoint(x: x, energies: [-1 - (e - 3.80998 * 0.25), 1 + (e - 3.80998 * 0.25)]))
        }
        let bs = makeStructure(kPoints: kps, fermi: 0)

        let gm = BandAnalysis.effectiveMassesNearGap(bs)
        XCTAssertNotNil(gm)
        // Electron mass (CBM, upward parabola) should be positive ~1.0.
        XCTAssertEqual(gm!.electronMass, 1.0, accuracy: 0.05)
        // Hole mass (VBM, downward parabola) has negative curvature, so the
        // raw m* is negative; the sign is preserved by the formula.
        XCTAssertEqual(gm!.holeMass, -1.0, accuracy: 0.05)
    }

    // MARK: - Spin-polarized tests

    /// Spin-polarized (nSpin=2): channel 0 analyzed correctly, channel 1 independent.
    func testSpinPolarizedChannels() {
        // Channel 0: valence -1, conduction +1 (gap 2). Channel 1: valence -3,
        // conduction +2 (gap 5). Each channel has 3 k-points.
        let count = 3
        var kps: [BandKPoint] = []
        // Channel 0 (spin up)
        for i in 0..<count {
            let x = Float(i) / Float(count - 1)
            kps.append(kPoint(x: x, energies: [-1, 1]))
        }
        // Channel 1 (spin down)
        for i in 0..<count {
            let x = Float(i) / Float(count - 1)
            kps.append(kPoint(x: x, energies: [-3, 2]))
        }
        let bs = makeStructure(kPoints: kps, fermi: 0, nSpin: 2, kPointsPerSpin: count)

        // Channel 0 via bandGap (returns first channel).
        let r0 = BandAnalysis.bandGap(bs)
        XCTAssertNotNil(r0)
        XCTAssertEqual(r0!.gap, 2, accuracy: 1e-6)
        XCTAssertEqual(r0!.spinChannel, 0)

        // Channel 1 via valenceBandMaximum / conductionBandMinimum.
        let vbm1 = BandAnalysis.valenceBandMaximum(bs, channel: 1)
        let cbm1 = BandAnalysis.conductionBandMinimum(bs, channel: 1)
        XCTAssertNotNil(vbm1)
        XCTAssertEqual(vbm1!.energy, -3, accuracy: 1e-6)
        XCTAssertNotNil(cbm1)
        XCTAssertEqual(cbm1!.energy, 2, accuracy: 1e-6)
        XCTAssertEqual(cbm1!.energy - vbm1!.energy, 5, accuracy: 1e-6)
    }

    // MARK: - Convenience accessors

    func testValenceBandMaximumConvenience() {
        let kps = [
            kPoint(x: 0, energies: [-2, 3]),
            kPoint(x: 1, energies: [-1, 4]),
        ]
        let bs = makeStructure(kPoints: kps, fermi: 0)
        let vbm = BandAnalysis.valenceBandMaximum(bs)
        XCTAssertNotNil(vbm)
        XCTAssertEqual(vbm!.energy, -1, accuracy: 1e-6)
        XCTAssertEqual(vbm!.kIndex, 1)
    }

    func testConductionBandMinimumConvenience() {
        let kps = [
            kPoint(x: 0, energies: [-2, 3]),
            kPoint(x: 1, energies: [-1, 2]),
        ]
        let bs = makeStructure(kPoints: kps, fermi: 0)
        let cbm = BandAnalysis.conductionBandMinimum(bs)
        XCTAssertNotNil(cbm)
        XCTAssertEqual(cbm!.energy, 2, accuracy: 1e-6)
        XCTAssertEqual(cbm!.kIndex, 1)
    }
}
