import simd
import XCTest
@testable import MolVisApp

/// Powder XRD computation engine: peak positions, multiplicities, systematic
/// absences (NaCl, diamond), wavelength dependence, Cromer–Mann form-factor
/// normalization, multiplicity rules (explicit ops + hexagonal), and the
/// electron-density projection path.
final class PowderXRDTests: XCTestCase {

    private static let cuAlpha: Float = 1.540598

    /// Consolidated: peak positions, multiplicities, systematic absences,
    /// wavelength/form-factor rules, and the atom-cap guard.
    func testXRDPeakPositionsMultiplicityAbsencesWavelengthAndAtomCap() {
        // MARK: - Peak positions, multiplicities, and systematic absences
        //
        // Rock-salt NaCl (Fm-3m, a = 5.6402 Å, Cl 0 0 0, Na ½ ½ ½). Asserts the
        // Cu Kα₁ peak positions (±0.15°), exact multiplicities, d(200), and that the
        // fcc-forbidden 200 is absent. Diamond Si (a = 5.4310 Å, 8-atom basis)
        // asserts its allowed peaks and the absence of the fcc-forbidden 200.
        do {
            let a: Float = 5.6402
            let naclCell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
            let nacl = [
                Atom(coord: SIMD3(0, 0, 0), atomicNumber: 17, label: "Cl"),
                Atom(coord: SIMD3(a / 2, a / 2, a / 2), atomicNumber: 11, label: "Na"),
            ]
            let pattern = PowderXRD.analyze(cell: naclCell, atoms: nacl, periodicDim: 3,
                                            wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 6)
            XCTAssertTrue(pattern.isAvailable)

            // Stored hkl is the powder-canonical (sorted |h|,|k|,|l|), all ≥ 0.
            func peak(_ h: Int, _ k: Int, _ l: Int) -> XRDPeak? {
                let key = [abs(h), abs(k), abs(l)].sorted()
                return pattern.peaks.first(where: { [$0.h, $0.k, $0.l].sorted() == key })
            }

            guard let p111 = peak(1, 1, 1) else { return XCTFail("NaCl 111 missing") }
            XCTAssertEqual(p111.twoTheta, 27.34, accuracy: 0.15)
            XCTAssertEqual(p111.multiplicity, 8)
            XCTAssertEqual(p111.dSpacing, a / sqrt(3), accuracy: 0.01)

            guard let p200 = peak(2, 0, 0) else { return XCTFail("NaCl 200 missing") }
            XCTAssertEqual(p200.twoTheta, 31.71, accuracy: 0.15)
            XCTAssertEqual(p200.multiplicity, 6)
            XCTAssertEqual(p200.dSpacing, 2.8201, accuracy: 0.005)

            guard let p220 = peak(2, 2, 0) else { return XCTFail("NaCl 220 missing") }
            XCTAssertEqual(p220.twoTheta, 45.45, accuracy: 0.15)
            XCTAssertEqual(p220.multiplicity, 12)

            guard let p311 = peak(3, 1, 1) else { return XCTFail("NaCl 311 missing") }
            XCTAssertEqual(p311.twoTheta, 53.88, accuracy: 0.15)
            XCTAssertEqual(p311.multiplicity, 24)

            guard let p222 = peak(2, 2, 2) else { return XCTFail("NaCl 222 missing") }
            XCTAssertEqual(p222.twoTheta, 56.48, accuracy: 0.15)
            XCTAssertEqual(p222.multiplicity, 8)

            guard let p400 = peak(4, 0, 0) else { return XCTFail("NaCl 400 missing") }
            XCTAssertEqual(p400.twoTheta, 66.24, accuracy: 0.15)
            XCTAssertEqual(p400.multiplicity, 6)

            // Diamond Si (8-atom conventional cell, Fd-3m).
            let aSi: Float = 5.4310
            let siCell = Cell(a: SIMD3(aSi, 0, 0), b: SIMD3(0, aSi, 0), c: SIMD3(0, 0, aSi))
            let fcc = [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0.5, 0.5), SIMD3<Float>(0.5, 0, 0.5), SIMD3<Float>(0.5, 0.5, 0),
            ]
            let basis = [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.25, 0.25, 0.25),
            ]
            var siAtoms: [Atom] = []
            for t in fcc {
                for b in basis {
                    let frac = (t + b)
                    siAtoms.append(Atom(coord: SIMD3(aSi * frac.x, aSi * frac.y, aSi * frac.z),
                                        atomicNumber: 14, label: "Si"))
                }
            }
            let siPattern = PowderXRD.analyze(cell: siCell, atoms: siAtoms, periodicDim: 3,
                                              wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 6)
            XCTAssertTrue(siPattern.isAvailable)
            func siPeak(_ h: Int, _ k: Int, _ l: Int) -> XRDPeak? {
                let key = [abs(h), abs(k), abs(l)].sorted()
                return siPattern.peaks.first(where: { [$0.h, $0.k, $0.l].sorted() == key })
            }
            guard let si111 = siPeak(1, 1, 1) else { return XCTFail("Si 111 missing") }
            XCTAssertEqual(si111.twoTheta, 28.44, accuracy: 0.15)
            guard let si220 = siPeak(2, 2, 0) else { return XCTFail("Si 220 missing") }
            XCTAssertEqual(si220.twoTheta, 47.30, accuracy: 0.15)
            guard let si311 = siPeak(3, 1, 1) else { return XCTFail("Si 311 missing") }
            XCTAssertEqual(si311.twoTheta, 56.12, accuracy: 0.15)
            guard let si400 = siPeak(4, 0, 0) else { return XCTFail("Si 400 missing") }
            XCTAssertEqual(si400.twoTheta, 69.13, accuracy: 0.15)

            // The fcc-forbidden 200 (and its Friedel-negative) must be absent.
            XCTAssertNil(siPeak(2, 0, 0), "diamond 200 should be systematically absent")
            XCTAssertNil(siPeak(-2, 0, 0), "diamond -200 should be systematically absent")
        }

        // MARK: - Wavelength, form factors, and multiplicity rules
        //
        // NaCl at Mo Kα: (200) 2θ ≈ 14.45°, and Cu 2θ > Mo 2θ for the same line.
        // hcp Mg multiplicities from the hexagonal Laue class. The Cromer–Mann
        // accessor satisfies f(Z,0) ≈ Z for every Z in 1…118 (fabricated-data
        // detector). A single identity symmetry op collapses every multiplicity to 1.
        do {
            let a: Float = 5.6402
            let naclCell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
            let nacl = [
                Atom(coord: SIMD3(0, 0, 0), atomicNumber: 17, label: "Cl"),
                Atom(coord: SIMD3(a / 2, a / 2, a / 2), atomicNumber: 11, label: "Na"),
            ]
            let moAlpha: Float = 0.70930
            let moPattern = PowderXRD.analyze(cell: naclCell, atoms: nacl, periodicDim: 3,
                                              wavelength: moAlpha, maxTwoTheta: 90, hklLimit: 6)
            guard let mo200 = moPattern.peaks.first(where: { [abs($0.h),abs($0.k),abs($0.l)].sorted() == [0,0,2] }) else {
                return XCTFail("NaCl 200 missing at Mo Kα")
            }
            // 2θ = 2·arcsin(λ/(2d)), d(200) = a/2 = 2.8201.
            let expected = 2 * asin(moAlpha / (2 * 2.8201)) * 180 / .pi
            XCTAssertEqual(mo200.twoTheta, expected, accuracy: 0.15)

            let cuPattern = PowderXRD.analyze(cell: naclCell, atoms: nacl, periodicDim: 3,
                                              wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 6)
            guard let cu200 = cuPattern.peaks.first(where: { [abs($0.h), abs($0.k), abs($0.l)].sorted() == [0, 0, 2] }) else {
                return XCTFail("NaCl 200 missing at Cu Kα")
            }
            XCTAssertGreaterThan(cu200.twoTheta, mo200.twoTheta)

            // hcp Mg: a = 3.209, c = 5.211, Mg at 0 0 0 and ⅓ ⅔ ½.
            let mgCell = Cell.fromLattice(a: 3.209, b: 3.209, c: 5.211, alpha: 90, beta: 90, gamma: 120)
            let mg = [
                Atom(coord: mgCell.cartesian(SIMD3<Float>(0, 0, 0)), atomicNumber: 12, label: "Mg"),
                Atom(coord: mgCell.cartesian(SIMD3<Float>(1.0 / 3, 2.0 / 3, 0.5)), atomicNumber: 12, label: "Mg"),
            ]
            let mgPattern = PowderXRD.analyze(cell: mgCell, atoms: mg, periodicDim: 3,
                                              wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 6)
            XCTAssertTrue(mgPattern.isAvailable)
            func mgPeak(_ h: Int, _ k: Int, _ l: Int) -> XRDPeak? {
                // Match the stored canonical (first-nonzero-positive) hkl.
                let query: (Int, Int, Int) = h > 0 || (h == 0 && k > 0) || (h == 0 && k == 0 && l > 0)
                    ? (h, k, l) : (-h, -k, -l)
                return mgPattern.peaks.first(where: { $0.h == query.0 && $0.k == query.1 && $0.l == query.2 })
            }
            XCTAssertEqual(mgPeak(1, 0, 0)?.multiplicity, 6)
            XCTAssertEqual(mgPeak(0, 0, 2)?.multiplicity, 2)
            XCTAssertEqual(mgPeak(1, 0, 1)?.multiplicity, 12)
            XCTAssertEqual(mgPeak(1, 0, 2)?.multiplicity, 12)

            // Form factors: f(Z,0) == Z within 0.05 for every element 1…118.
            for z in 1...118 {
                let f0 = PowderXRD.scatteringFactor(Z: z, s: 0)
                XCTAssertEqual(f0, Float(z), accuracy: 0.05, "f(0) for Z=\(z)")
            }

            // Explicit identity-only symmetry op (P1/triclinic): the Friedel factor
            // makes every multiplicity even — (hkl) and (−h,−k,−l) always diffract into
            // the same Debye ring. Distinct (hkl) families that happen to share a
            // d-spacing (e.g. (hk0) and (h,−k,0), since d depends on k²) are correctly
            // merged by the engine, so a peak may exceed 2 — but it is never odd.
            let identity = CrystalSymmetryOperation(rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1], translation: .zero)
            let triclinicCell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 6, 0), c: SIMD3(0, 0, 7))
            let triclinicAtoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 11, label: "Na")]
            let idPattern = PowderXRD.analyze(cell: triclinicCell, atoms: triclinicAtoms, periodicDim: 3,
                                              wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 2,
                                              symmetryOps: [identity])
            XCTAssertTrue(idPattern.isAvailable)
            for peak in idPattern.peaks {
                XCTAssertEqual(peak.multiplicity % 2, 0, "multiplicity with identity op must be even for (\(peak.h)\(peak.k)\(peak.l))")
                XCTAssertGreaterThanOrEqual(peak.multiplicity, 2, "multiplicity with identity op for (\(peak.h)\(peak.k)\(peak.l))")
            }
            // In an orthorhombic cell the (100) family has a unique d-spacing, so its
            // peak is exactly one Friedel pair with multiplicity 2.
            let p100 = idPattern.peaks.first(where: { $0.h == 1 && $0.k == 0 && $0.l == 0 })
            XCTAssertEqual(p100?.multiplicity, 2, "(100) with identity op")
        }

        // --- Atom cap ---
        // The atomic-form-factor path is O(reflections × atoms); a 100k-atom
        // cell would hang. The cap must fail closed with .unavailable.
        let capA: Float = 5.0
        let capCell = Cell(a: SIMD3(capA, 0, 0), b: SIMD3(0, capA, 0), c: SIMD3(0, 0, capA))
        var capAtoms: [Atom] = []
        capAtoms.reserveCapacity(2001)
        for i in 0..<2001 {
            capAtoms.append(Atom(coord: SIMD3(Float(i % 10) * 0.5, Float((i / 10) % 10) * 0.5, Float(i / 100) * 0.5),
                                 atomicNumber: 6, label: "C"))
        }
        let capPattern = PowderXRD.analyze(cell: capCell, atoms: capAtoms, periodicDim: 3,
                                           wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 6)
        XCTAssertFalse(capPattern.isAvailable)
        XCTAssertNotNil(capPattern.unavailableReason)
        XCTAssertTrue((capPattern.unavailableReason ?? "").contains("too many atoms"),
                      "reason should name the atom cap, got: \(capPattern.unavailableReason ?? "")")

        // Just under the cap: should proceed (and produce a valid pattern).
        let okAtoms = Array(capAtoms.prefix(2000))
        let okPattern = PowderXRD.analyze(cell: capCell, atoms: okAtoms, periodicDim: 3,
                                          wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 6)
        XCTAssertTrue(okPattern.isAvailable, "2000 atoms should be within the cap")
    }

    func testXRDElectronDensityProjectionAndFiniteParams() {
        // MARK: - Electron-density projection
        //
        // A 64³ grid with ρ = 1 + cos(2π·fx) in a cubic a = 5.0 cell projects to a
        // strong (100) peak and weak higher orders; a constant field yields zero
        // peaks; a skewed grid and a 2D periodicDim fail closed.
        do {
            let a: Float = 5.0
            let cell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
            let atom = [Atom(coord: SIMD3(a / 2, a / 2, a / 2), atomicNumber: 6, label: "C")]

            let n = 64
            var values = [Float]()
            for k in 0..<n { for j in 0..<n { for i in 0..<n {
                let fx = Float(i) / Float(n)
                values.append(1 + cos(2 * Float.pi * fx))
            } } }
            let grid = ScalarField(nx: n, ny: n, nz: n, origin: .zero,
                                   vec: [SIMD3(a, 0, 0), SIMD3(0, a, 0), SIMD3(0, 0, a)],
                                   values: values, minValue: values.min() ?? 0, maxValue: values.max() ?? 0)

            let pattern = PowderXRD.analyze(cell: cell, atoms: atom, periodicDim: 3,
                                            wavelength: Self.cuAlpha, maxTwoTheta: 90, hklLimit: 6,
                                            electronDensity: grid)
            XCTAssertTrue(pattern.isAvailable)
            XCTAssertEqual(pattern.sourceDescription, "electron density")

            guard let p100 = pattern.peaks.first(where: { [abs($0.h), abs($0.k), abs($0.l)].sorted() == [0, 0, 1] }) else {
                return XCTFail("ED (100) missing")
            }
            let expected = 2 * asin(Self.cuAlpha / (2 * a)) * 180 / .pi
            XCTAssertEqual(p100.twoTheta, expected, accuracy: 0.2)
            XCTAssertEqual(p100.h * p100.h + p100.k * p100.k + p100.l * p100.l, 1)

            // Physical pin: ρ = 1 + cos(2π·fx), mean-subtracted. The (100) DFT of the
            // cosine over the grid is exactly N/2, so |F(100)| = (V/N)·(N/2) = V/2.
            // With the cubic Laue multiplicity 6 for (h00) and the LP factor, the raw
            // intensity must equal (V/2)²·6·LP. Locks in both the V_cell scale fix and
            // the multiplicity-in-intensity factor.
            let Vcell = Double(a * a * a) // 125
            let sinTheta = Self.cuAlpha / (2 * p100.dSpacing)
            let cosTheta = cos(Float(asin(min(1, sinTheta))))
            let twoT = p100.twoTheta * .pi / 180
            let lp = (1 + cos(twoT) * cos(twoT)) / (sinTheta * sinTheta * cosTheta)
            let expectedI = (Vcell / 2) * (Vcell / 2) * 6 * Double(lp)
            XCTAssertEqual(p100.intensity, Float(expectedI), accuracy: Float(expectedI) * 0.02)

            // (100) relative intensity must dominate all others by ≥ 10⁴.
            guard let idx = pattern.peaks.firstIndex(where: { $0.h == p100.h && $0.k == p100.k && $0.l == p100.l }) else {
                return XCTFail("ED (100) index missing")
            }
            let others = pattern.peaks.enumerated().filter { $0.offset != idx }.map { $0.element }
            let maxOther = others.map { $0.relativeIntensity }.max() ?? 0
            XCTAssertGreaterThan(p100.relativeIntensity, maxOther * 1e4)

            // Constant field -> available pattern with zero peaks.
            let constValues = [Float](repeating: 1, count: n * n * n)
            let constGrid = ScalarField(nx: n, ny: n, nz: n, origin: .zero,
                                        vec: [SIMD3(a, 0, 0), SIMD3(0, a, 0), SIMD3(0, 0, a)],
                                        values: constValues, minValue: 1, maxValue: 1)
            let constPattern = PowderXRD.analyze(cell: cell, atoms: atom, periodicDim: 3,
                                                 wavelength: Self.cuAlpha, hklLimit: 6,
                                                 electronDensity: constGrid)
            XCTAssertTrue(constPattern.isAvailable)
            XCTAssertEqual(constPattern.peaks.count, 0)

            // Skewed grid (vec not parallel to cell) -> unavailable, reason "align".
            let skewGrid = ScalarField(nx: 8, ny: 8, nz: 8, origin: .zero,
                                       vec: [SIMD3(a, 1.0, 0), SIMD3(0, a, 0), SIMD3(0, 0, a)],
                                       values: [Float](repeating: 1, count: 8 * 8 * 8),
                                       minValue: 1, maxValue: 1)
            let skewPattern = PowderXRD.analyze(cell: cell, atoms: atom, periodicDim: 3,
                                                electronDensity: skewGrid)
            XCTAssertFalse(skewPattern.isAvailable)
            XCTAssertTrue((skewPattern.unavailableReason ?? "").contains("align"))

            // 2D periodicDim -> unavailable.
            let flatPattern = PowderXRD.analyze(cell: cell, atoms: atom, periodicDim: 2)
            XCTAssertFalse(flatPattern.isAvailable)

            // Non-finite atom -> unavailable.
            let badAtom = [Atom(coord: SIMD3(Float.nan, 0, 0), atomicNumber: 6, label: "C")]
            let badPattern = PowderXRD.analyze(cell: cell, atoms: badAtom, periodicDim: 3)
            XCTAssertFalse(badPattern.isAvailable)
        }

        // MARK: - Non-finite parameters and explicit-op d-merging
        //
        // Non-finite analysis parameters fail closed (never trap). Explicit 48-op
        // cubic symmetry merges the d-degenerate (330)/(411) family into one peak
        // combining both orbits: multiplicity 12 + 24 = 36 and two hklLabels.
        do {
            let a: Float = 5.0
            let cell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
            let atom = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]

            // Non-finite maxTwoTheta and curveStep -> unavailable, never trap.
            // (hklLimit is an Int and so is always finite at the type level; the
            // Float(hklLimit) gate in analyze guards a Float-coded call site.)
            XCTAssertFalse(PowderXRD.analyze(cell: cell, atoms: atom, periodicDim: 3,
                                            maxTwoTheta: .nan).isAvailable)
            XCTAssertFalse(PowderXRD.analyze(cell: cell, atoms: atom, periodicDim: 3,
                                            curveStep: .nan).isAvailable)

            // Build the 48 signed-permutation cubic rotation ops (no inversions).
            var cubicOps: [CrystalSymmetryOperation] = []
            let perms: [[Int]] = [
                [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
            ]
            let signs: [[Int]] = [
                [1, 1, 1], [1, 1, -1], [1, -1, 1], [1, -1, -1],
                [-1, 1, 1], [-1, 1, -1], [-1, -1, 1], [-1, -1, -1],
            ]
            for p in perms {
                for s in signs {
                    var rot = [Int](repeating: 0, count: 9)
                    for row in 0..<3 {
                        rot[row * 3 + p[row]] = s[row]
                    }
                    cubicOps.append(CrystalSymmetryOperation(rotation: rot, translation: .zero))
                }
            }
            XCTAssertEqual(cubicOps.count, 48)

            let pattern = PowderXRD.analyze(cell: cell, atoms: atom, periodicDim: 3,
                                            wavelength: Self.cuAlpha, maxTwoTheta: 120, hklLimit: 6,
                                            symmetryOps: cubicOps)
            XCTAssertTrue(pattern.isAvailable)

            // (330) orbit (hh0-type) has size 12; (411) orbit (hkk-type) has size 24.
            // They share d = a/√18 ≈ 1.1785 Å and merge into one peak.
            let targetD = a / sqrt(18) // ≈ 1.1785
            let merged = pattern.peaks.first(where: { abs($0.dSpacing - targetD) < 1e-3 * targetD })
            XCTAssertNotNil(merged, "merged (330)/(411) peak missing")
            guard let peak = merged else { return }
            XCTAssertEqual(peak.hklLabels.count, 2, "merged peak should list both (330) and (411)")
            XCTAssertEqual(peak.multiplicity, 36, "multiplicity = 12 + 24 = 36")
            // Raw intensity = f(s)² · 36 · LP(s) for the single-atom cell.
            let sinTheta = Self.cuAlpha / (2 * peak.dSpacing)
            let s = sinTheta / Self.cuAlpha
            let fElectrons = Double(PowderXRD.scatteringFactor(Z: 6, s: s))
            let cosTheta = cos(Float(asin(min(1, sinTheta))))
            let twoT = peak.twoTheta * .pi / 180
            let lp = (1 + cos(twoT) * cos(twoT)) / (sinTheta * sinTheta * cosTheta)
            let expectedI = fElectrons * fElectrons * 36 * Double(lp)
            XCTAssertEqual(peak.intensity, Float(expectedI), accuracy: Float(expectedI) * 1e-4)
        }
    }
}
