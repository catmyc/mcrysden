import AppKit
import simd
import XCTest
@testable import MolVisApp

/// Focused coverage for the structure-information and analysis additions:
/// first-shell polyhedron volume/distortion metrics, two-structure comparison
/// with RMS displacement, atom-table region/expression filtering, and on-screen
/// bond-distance labels.
final class StructureAnalysisTests: XCTestCase {

    // MARK: - Polyhedron volume / distortion metrics

    func testPolyhedronVolumeAndDistortionMetrics() {
        // A regular tetrahedron around the origin (CN 4): hull volume must equal
        // the ideal tetrahedron volume for the mean bond length, and the bond
        // distortion must be ~0. The ideal angle is 109.47°.
        let tetrahedron: [SIMD3<Float>] = [
            SIMD3(1, 1, 1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1),
        ]
        let meanBond = tetrahedron.reduce(0.0 as Float) { $0 + simd_length($1) } / 4
        let ideal = PolyhedronAnalyzer.idealPolyhedronVolume(coordination: 4,
                                                             meanBondLength: meanBond)
        let metrics = PolyhedronAnalyzer.metrics(for: .zero, shell: tetrahedron)
        XCTAssertEqual(metrics.neighborCount, 4)
        XCTAssertNotNil(metrics.volume)
        XCTAssertEqual(metrics.volume!, ideal!, accuracy: 0.02)
        XCTAssertNotNil(metrics.bondLengthDistortion)
        XCTAssertEqual(metrics.bondLengthDistortion!, 0, accuracy: 1e-3)
        XCTAssertNotNil(metrics.angleDeviation)
        XCTAssertEqual(metrics.angleDeviation!, 0, accuracy: 1e-3)
        XCTAssertEqual(metrics.idealAngle!, 109.4712, accuracy: 1e-3)
        XCTAssertNotNil(metrics.volumeRatio)
        XCTAssertEqual(metrics.volumeRatio!, 1, accuracy: 1e-2)

        // A regular octahedron (CN 6): volume = 4r³/3 for circumradius r = 2.
        let octahedron: [SIMD3<Float>] = [
            SIMD3(2, 0, 0), SIMD3(-2, 0, 0), SIMD3(0, 2, 0),
            SIMD3(0, -2, 0), SIMD3(0, 0, 2), SIMD3(0, 0, -2),
        ]
        let octa = PolyhedronAnalyzer.metrics(for: .zero, shell: octahedron)
        XCTAssertEqual(octa.volume!, 4 * 8 / 3, accuracy: 0.05)
        XCTAssertEqual(octa.angleDeviation!, 0, accuracy: 1e-3)
        XCTAssertEqual(octa.idealAngle!, 90, accuracy: 1e-3)

        // A regular cube (CN 8): vertices at +/-1 must give volume 8 and
        // volumeRatio 1. The hull-edge angle is arccos(1/3) = 70.53°, so the
        // angle deviation is 0. Face-diagonal and body-diagonal pairs must
        // not be mixed into the angle metric.
        let cube: [SIMD3<Float>] = [
            SIMD3(1, 1, 1), SIMD3(1, 1, -1), SIMD3(1, -1, 1), SIMD3(1, -1, -1),
            SIMD3(-1, 1, 1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(-1, -1, -1),
        ]
        let cubeMeanBond = cube.reduce(0.0 as Float) { $0 + simd_length($1) } / 8
        let cubeIdeal = PolyhedronAnalyzer.idealPolyhedronVolume(coordination: 8,
                                                                  meanBondLength: cubeMeanBond)
        let cubeMetrics = PolyhedronAnalyzer.metrics(for: .zero, shell: cube)
        XCTAssertEqual(cubeMetrics.neighborCount, 8)
        XCTAssertNotNil(cubeMetrics.volume)
        XCTAssertEqual(cubeMetrics.volume!, 8, accuracy: 0.05)
        XCTAssertNotNil(cubeMetrics.bondLengthDistortion)
        XCTAssertEqual(cubeMetrics.bondLengthDistortion!, 0, accuracy: 1e-3)
        XCTAssertNotNil(cubeMetrics.angleDeviation)
        XCTAssertEqual(cubeMetrics.angleDeviation!, 0, accuracy: 1e-3)
        XCTAssertEqual(cubeMetrics.idealAngle!, 70.5288, accuracy: 1e-3)
        XCTAssertNotNil(cubeMetrics.volumeRatio)
        XCTAssertEqual(cubeMetrics.volumeRatio!, 1, accuracy: 0.05)

        // Distorted shell: moving one vertex outward raises both metrics and
        // shrinks the volume ratio below 1.
        var distorted = tetrahedron
        distorted[0] = SIMD3(1.6, 1.6, 1.6)
        let distortedMetrics = PolyhedronAnalyzer.metrics(for: .zero, shell: distorted)
        XCTAssertNotNil(distortedMetrics.bondLengthDistortion)
        XCTAssertGreaterThan(distortedMetrics.bondLengthDistortion!,
                             metrics.bondLengthDistortion!)
        XCTAssertNotNil(distortedMetrics.volumeRatio)
        XCTAssertLessThan(distortedMetrics.volumeRatio!, 1)

        // Degenerate shells are unavailable, never traps: < 4 points (no hull),
        // coplanar points (zero volume), and non-finite input.
        let three = PolyhedronAnalyzer.metrics(for: .zero, shell: Array(tetrahedron.prefix(3)))
        XCTAssertNil(three.volume)
        XCTAssertNotNil(three.angleDeviation)
        let coplanar: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0.5, 0.5, 0),
        ]
        XCTAssertNil(PolyhedronAnalyzer.metrics(for: .zero, shell: coplanar).volume)
        let nonFinite: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(.infinity, 0, 0),
        ]
        XCTAssertNil(PolyhedronAnalyzer.metrics(for: .zero, shell: nonFinite).volume)

        // Full-analysis path: a coordination analysis over a tiny crystal, then
        // metrics aligned to the atom array; oversized inputs are rejected.
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        // Bond length 0.9·√3 ≈ 1.56 Å stays inside the C–C covalent cutoff
        // (1.15 × 2 × 0.76 ≈ 1.75 Å) so the central atom has CN 4.
        let atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(0.9, 0.9, 0.9), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(0.9, -0.9, -0.9), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(-0.9, 0.9, -0.9), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(-0.9, -0.9, 0.9), atomicNumber: 6, label: "C"),
        ]
        guard let analysis = CoordinationAnalyzer.analyze(atoms: atoms, cell: cell,
                                                          periodicDim: 3) else {
            return XCTFail("coordination analysis must succeed")
        }
        let all = PolyhedronAnalyzer.analyze(analysis: analysis, atoms: atoms)
        XCTAssertNotNil(all)
        XCTAssertEqual(all!.count, atoms.count)
        XCTAssertEqual(all![0].neighborCount, 4)
        XCTAssertNotNil(all![0].volume)

        let tooMany = [Atom](repeating: atoms[0],
                             count: PolyhedronAnalyzer.maxAtoms + 1)
        XCTAssertNil(PolyhedronAnalyzer.analyze(analysis: analysis, atoms: tooMany))

        // Multi-shell exclusion: a coordination analysis with two distinct
        // neighbor shells must contribute only the first shell to the
        // polyhedron; later shells are never silently appended.
        let multiShellRecords: [CoordinationNeighbor] = {
            var records: [CoordinationNeighbor] = []
            // First shell: 4 neighbors at distance sqrt(3) (tetrahedral).
            let firstDisplacements: [SIMD3<Float>] = [
                SIMD3(1, 1, 1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1),
            ]
            for (i, d) in firstDisplacements.enumerated() {
                records.append(CoordinationNeighbor(atomIndex: i + 1,
                                                    imageOffset: .zero,
                                                    displacement: d,
                                                    distance: simd_length(d)))
            }
            // Second shell: 8 neighbors at distance 2*sqrt(3) (cubic).
            let secondDisplacements: [SIMD3<Float>] = [
                SIMD3(2, 2, 2), SIMD3(2, 2, -2), SIMD3(2, -2, 2), SIMD3(2, -2, -2),
                SIMD3(-2, 2, 2), SIMD3(-2, 2, -2), SIMD3(-2, -2, 2), SIMD3(-2, -2, -2),
            ]
            for (i, d) in secondDisplacements.enumerated() {
                records.append(CoordinationNeighbor(atomIndex: i + 5,
                                                    imageOffset: .zero,
                                                    displacement: d,
                                                    distance: simd_length(d)))
            }
            return records
        }()
        guard let multiShellAnalysis = CoordinationAnalysis(
            records: multiShellRecords, offsets: [0, 12], counts: [12], candidateChecks: 0
        ) else {
            return XCTFail("multi-shell coordination analysis must construct")
        }
        let multiShellAtoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]
        let firstShellOnly = PolyhedronAnalyzer.firstShell(
            of: 0, analysis: multiShellAnalysis, atoms: multiShellAtoms
        )
        XCTAssertEqual(firstShellOnly.count, 4)
        let multiShellMetrics = PolyhedronAnalyzer.analyze(
            analysis: multiShellAnalysis, atoms: multiShellAtoms
        )
        XCTAssertNotNil(multiShellMetrics)
        XCTAssertEqual(multiShellMetrics![0].neighborCount, 4)

        // Overflow: a first shell exceeding maxNeighborsPerAtom must yield
        // unavailable metrics while preserving the actual neighbor count.
        // firstShell returns the full shell (no truncation); metrics/analyze
        // enforce the cap and report the real count with derived fields nil.
        let overflowRecords: [CoordinationNeighbor] = {
            var records: [CoordinationNeighbor] = []
            for i in 0..<30 {
                let angle = Float(i) * 2 * .pi / 30
                let d = SIMD3<Float>(cos(angle), sin(angle), 0)
                records.append(CoordinationNeighbor(atomIndex: i + 1,
                                                    imageOffset: .zero,
                                                    displacement: d,
                                                    distance: 1.0))
            }
            return records
        }()
        guard let overflowAnalysis = CoordinationAnalysis(
            records: overflowRecords, offsets: [0, 30], counts: [30], candidateChecks: 0
        ) else {
            return XCTFail("overflow coordination analysis must construct")
        }
        let overflowAtoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]
        let overflowShell = PolyhedronAnalyzer.firstShell(
            of: 0, analysis: overflowAnalysis, atoms: overflowAtoms
        )
        // firstShell preserves the actual count; no truncation.
        XCTAssertEqual(overflowShell.count, 30)
        let overflowMetrics = PolyhedronAnalyzer.analyze(
            analysis: overflowAnalysis, atoms: overflowAtoms
        )
        XCTAssertNotNil(overflowMetrics)
        // Real neighbor count preserved; all derived fields unavailable.
        XCTAssertEqual(overflowMetrics![0].neighborCount, 30)
        XCTAssertNil(overflowMetrics![0].volume)
        XCTAssertNil(overflowMetrics![0].bondLengthDistortion)
        XCTAssertNil(overflowMetrics![0].angleDeviation)
        XCTAssertNil(overflowMetrics![0].volumeRatio)
        XCTAssertFalse(overflowMetrics![0].isAvailable)

        // Direct metrics(for:shell:) with an oversized shell must also enforce
        // the cap without entering hull work, preserving the real count.
        let directOversized = PolyhedronAnalyzer.metrics(for: .zero, shell: overflowShell)
        XCTAssertEqual(directOversized.neighborCount, 30)
        XCTAssertNil(directOversized.volume)
        XCTAssertNil(directOversized.bondLengthDistortion)
        XCTAssertNil(directOversized.angleDeviation)
        XCTAssertNil(directOversized.volumeRatio)
        XCTAssertFalse(directOversized.isAvailable)

        // Translated and scaled regular cube: a cube at +/-2 must have volume
        // 64 (2^3 * 8) and volumeRatio 1; translating it far from the origin
        // must not change the result. Verifies scale-invariance of the
        // extent-based coplanarity tolerance and nontrapping plane keys.
        let cubeScaled: [SIMD3<Float>] = [
            SIMD3(2, 2, 2), SIMD3(2, 2, -2), SIMD3(2, -2, 2), SIMD3(2, -2, -2),
            SIMD3(-2, 2, 2), SIMD3(-2, 2, -2), SIMD3(-2, -2, 2), SIMD3(-2, -2, -2),
        ]
        let cubeScaledMetrics = PolyhedronAnalyzer.metrics(for: .zero, shell: cubeScaled)
        XCTAssertEqual(cubeScaledMetrics.neighborCount, 8)
        XCTAssertNotNil(cubeScaledMetrics.volume)
        XCTAssertEqual(cubeScaledMetrics.volume!, 64, accuracy: 0.1)
        XCTAssertEqual(cubeScaledMetrics.volumeRatio!, 1, accuracy: 0.05)
        XCTAssertEqual(cubeScaledMetrics.angleDeviation!, 0, accuracy: 1e-3)

        let shift = SIMD3<Float>(100, 100, 100)
        let cubeTranslated = cubeScaled.map { $0 + shift }
        let cubeTranslatedMetrics = PolyhedronAnalyzer.metrics(for: shift, shell: cubeTranslated)
        XCTAssertEqual(cubeTranslatedMetrics.neighborCount, 8)
        XCTAssertNotNil(cubeTranslatedMetrics.volume)
        XCTAssertEqual(cubeTranslatedMetrics.volume!, 64, accuracy: 0.1)
        XCTAssertEqual(cubeTranslatedMetrics.volumeRatio!, 1, accuracy: 0.05)
        XCTAssertEqual(cubeTranslatedMetrics.angleDeviation!, 0, accuracy: 1e-3)

        // A unit cube translated far from the origin tests that large
        // coordinates do not trap the plane-key conversion.
        let cubeUnitShifted = cube.map { $0 + shift }
        let cubeUnitShiftedMetrics = PolyhedronAnalyzer.metrics(for: shift, shell: cubeUnitShifted)
        XCTAssertEqual(cubeUnitShiftedMetrics.neighborCount, 8)
        XCTAssertNotNil(cubeUnitShiftedMetrics.volume)
        XCTAssertEqual(cubeUnitShiftedMetrics.volume!, 8, accuracy: 0.05)
        XCTAssertEqual(cubeUnitShiftedMetrics.volumeRatio!, 1, accuracy: 0.05)

        // firstShell tolerance chaining: distances 1.00, 1.04, 1.08 with
        // tolerance 0.05 must include only the first two. Comparing against
        // the fixated reference (1.00) prevents 1.08 from chaining through
        // 1.04 (1.08 - 1.04 = 0.04 < 0.05).
        let chainingRecords: [CoordinationNeighbor] = [
            CoordinationNeighbor(atomIndex: 1, imageOffset: .zero,
                                displacement: SIMD3(1.00, 0, 0), distance: 1.00),
            CoordinationNeighbor(atomIndex: 2, imageOffset: .zero,
                                displacement: SIMD3(0, 1.04, 0), distance: 1.04),
            CoordinationNeighbor(atomIndex: 3, imageOffset: .zero,
                                displacement: SIMD3(0, 0, 1.08), distance: 1.08),
        ]
        guard let chainingAnalysis = CoordinationAnalysis(
            records: chainingRecords, offsets: [0, 3], counts: [3], candidateChecks: 0
        ) else {
            return XCTFail("chaining coordination analysis must construct")
        }
        let chainingAtoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]
        let chainingShell = PolyhedronAnalyzer.firstShell(
            of: 0, analysis: chainingAnalysis, atoms: chainingAtoms
        )
        XCTAssertEqual(chainingShell.count, 2)

        // Edge case: a record at distance 1.08 with non-finite displacement
        // must still terminate the shell at the boundary check — the
        // unconditional break runs before displacement validation, so the
        // invalid displacement does not cause a skip that would let later
        // records leak in.
        let overflowDispRecords: [CoordinationNeighbor] = [
            CoordinationNeighbor(atomIndex: 1, imageOffset: .zero,
                                displacement: SIMD3(1.00, 0, 0), distance: 1.00),
            CoordinationNeighbor(atomIndex: 2, imageOffset: .zero,
                                displacement: SIMD3(.infinity, 0, 0), distance: 1.08),
            CoordinationNeighbor(atomIndex: 3, imageOffset: .zero,
                                displacement: SIMD3(0, 1.04, 0), distance: 1.04),
        ]
        guard let overflowDispAnalysis = CoordinationAnalysis(
            records: overflowDispRecords, offsets: [0, 3], counts: [3], candidateChecks: 0
        ) else {
            return XCTFail("overflow-disp coordination analysis must construct")
        }
        let overflowDispShell = PolyhedronAnalyzer.firstShell(
            of: 0, analysis: overflowDispAnalysis, atoms: chainingAtoms
        )
        XCTAssertEqual(overflowDispShell.count, 1)

        // Edge case: first record has valid distance but non-finite
        // displacement (skipped), followed by a record at distance 1.08.
        // The boundary check must fire unconditionally even though group is
        // still empty — the 1.08 must not slip in as the first valid shell
        // member.
        let emptyGroupRecords: [CoordinationNeighbor] = [
            CoordinationNeighbor(atomIndex: 1, imageOffset: .zero,
                                displacement: SIMD3(.nan, 0, 0), distance: 1.00),
            CoordinationNeighbor(atomIndex: 2, imageOffset: .zero,
                                displacement: SIMD3(0, 1.08, 0), distance: 1.08),
            CoordinationNeighbor(atomIndex: 3, imageOffset: .zero,
                                displacement: SIMD3(0, 0, 1.04), distance: 1.04),
        ]
        guard let emptyGroupAnalysis = CoordinationAnalysis(
            records: emptyGroupRecords, offsets: [0, 3], counts: [3], candidateChecks: 0
        ) else {
            return XCTFail("empty-group coordination analysis must construct")
        }
        let emptyGroupShell = PolyhedronAnalyzer.firstShell(
            of: 0, analysis: emptyGroupAnalysis, atoms: chainingAtoms
        )
        // The 1.08 record breaks unconditionally even though group is empty;
        // the valid 1.00 record contributed nothing (NaN displacement), so
        // the shell is empty.
        XCTAssertEqual(emptyGroupShell.count, 0)

        // angleDeviation availability: CN 2 must report angleDeviation nil
        // (no meaningful angular spread from a single angle), while bond
        // length distortion can still be available.
        let twoRecords: [CoordinationNeighbor] = [
            CoordinationNeighbor(atomIndex: 1, imageOffset: .zero,
                                displacement: SIMD3(1, 0, 0), distance: 1.0),
            CoordinationNeighbor(atomIndex: 2, imageOffset: .zero,
                                displacement: SIMD3(0, 1, 0), distance: 1.05),
        ]
        guard let twoAnalysis = CoordinationAnalysis(
            records: twoRecords, offsets: [0, 2], counts: [2], candidateChecks: 0
        ) else {
            return XCTFail("two-neighbor coordination analysis must construct")
        }
        let twoAtoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]
        let twoMetrics = PolyhedronAnalyzer.analyze(analysis: twoAnalysis, atoms: twoAtoms)
        XCTAssertNotNil(twoMetrics)
        XCTAssertEqual(twoMetrics![0].neighborCount, 2)
        XCTAssertNil(twoMetrics![0].angleDeviation)
        XCTAssertNotNil(twoMetrics![0].bondLengthDistortion)
        XCTAssertNil(twoMetrics![0].volume)

        // Non-finite center: direct metrics must preserve shell.count as
        // neighborCount while returning all derived metrics nil, rather than
        // fabricating count zero.
        let validShell: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(-1, -1, -1),
        ]
        let nonFiniteCenter = PolyhedronAnalyzer.metrics(
            for: SIMD3(Float.nan, 0, 0), shell: validShell
        )
        XCTAssertEqual(nonFiniteCenter.neighborCount, 4)
        XCTAssertNil(nonFiniteCenter.volume)
        XCTAssertNil(nonFiniteCenter.bondLengthDistortion)
        XCTAssertNil(nonFiniteCenter.angleDeviation)
        XCTAssertNil(nonFiniteCenter.volumeRatio)
        XCTAssertFalse(nonFiniteCenter.isAvailable)
    }

    // MARK: - Two-structure comparison with RMS displacement

    func testStructureComparisonRMSDAndUnmatchedAtoms() {
        // Periodic: every source atom displaced by (0.1, -0.2, 0.3) → RMSD equals
        // that vector's length and displacements match exactly.
        let cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let shift = SIMD3<Float>(0.1, -0.2, 0.3)
        let source = [
            Atom(coord: SIMD3(1, 1, 1), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(4, 5, 6), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(8, 2, 9), atomicNumber: 1, label: "H"),
        ]
        let target = source.map { atom in
            Atom(coord: atom.coord + shift, atomicNumber: atom.atomicNumber, label: atom.label)
        }
        let result = StructureComparator.compare(source: source, target: target,
                                                 sourceCell: cell, periodicDim: 3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.matchedPairCount, 3)
        XCTAssertEqual(result!.rmsDisplacement!, simd_length(shift), accuracy: 1e-4)
        XCTAssertEqual(result!.maxDisplacement!, simd_length(shift), accuracy: 1e-4)
        XCTAssertEqual(result!.meanDisplacement!, simd_length(shift), accuracy: 1e-4)
        XCTAssertTrue(result!.unmatchedSourceIndices.isEmpty)
        XCTAssertTrue(result!.unmatchedTargetIndices.isEmpty)
        XCTAssertEqual(result!.perElement.count, 2)   // C and H
        XCTAssertEqual(result!.perElement.first { $0.atomicNumber == 6 }!.matchedCount, 2)

        // Periodic matching uses minimum images: an atom near the cell edge
        // matches the wrapped image, and the displacement wraps accordingly.
        let edgeSource = [
            Atom(coord: SIMD3(0.2, 5, 5), atomicNumber: 6, label: "C"),
        ]
        let edgeTarget = [
            Atom(coord: SIMD3(9.9, 5, 5), atomicNumber: 6, label: "C"),
        ]
        let edgeResult = StructureComparator.compare(source: edgeSource, target: edgeTarget,
                                                     sourceCell: cell, periodicDim: 3)
        XCTAssertEqual(edgeResult!.rmsDisplacement!, 0.3, accuracy: 1e-4)

        // A molecule without a cell compares by direct distance.
        let moleculeSource = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 0, 1), atomicNumber: 8, label: "O"),
        ]
        let moleculeTarget = [
            Atom(coord: SIMD3(0.5, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 0, 1), atomicNumber: 8, label: "O"),
        ]
        let moleculeResult = StructureComparator.compare(source: moleculeSource,
                                                         target: moleculeTarget,
                                                         sourceCell: nil, periodicDim: 0)
        XCTAssertEqual(moleculeResult!.matchedPairCount, 2)
        XCTAssertEqual(moleculeResult!.rmsDisplacement!, 0.3535534, accuracy: 1e-4)

        // Element mismatch and missing atoms are reported unmatched; a species
        // with no match inside the cutoff contributes no pair.
        let mismatchSource = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(0, 0, 1), atomicNumber: 8, label: "O"),
        ]
        let mismatchTarget = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(0, 0, 1), atomicNumber: 7, label: "N"),   // wrong element
        ]
        let mismatchResult = StructureComparator.compare(source: mismatchSource,
                                                         target: mismatchTarget,
                                                         sourceCell: nil, periodicDim: 0)
        XCTAssertEqual(mismatchResult!.matchedPairCount, 1)
        XCTAssertEqual(mismatchResult!.unmatchedSourceIndices, [1])
        XCTAssertEqual(mismatchResult!.unmatchedTargetIndices, [1])

        // A tiny cutoff rejects everything; non-finite input fails cleanly.
        let strictResult = StructureComparator.compare(source: source, target: target,
                                                       sourceCell: cell, periodicDim: 3,
                                                       maxMatchDistance: 0.01)
        XCTAssertEqual(strictResult!.matchedPairCount, 0)
        XCTAssertEqual(strictResult!.unmatchedSourceIndices.count, source.count)
        let bad = [
            Atom(coord: SIMD3(.nan, 0, 0), atomicNumber: 6, label: "C"),
        ]
        XCTAssertNil(StructureComparator.compare(source: bad, target: target,
                                                 sourceCell: cell, periodicDim: 3))

        // Orthogonal >2-cell translation: a target atom translated by five whole
        // cells still matches via the minimum image, with zero displacement.
        let orthoCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let orthoSource = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]
        let orthoTarget = [Atom(coord: SIMD3(50, 0, 0), atomicNumber: 6, label: "C")]
        let orthoResult = StructureComparator.compare(source: orthoSource, target: orthoTarget,
                                                      sourceCell: orthoCell, periodicDim: 3)
        XCTAssertNotNil(orthoResult)
        XCTAssertEqual(orthoResult!.matchedPairCount, 1)
        XCTAssertEqual(orthoResult!.rmsDisplacement!, 0, accuracy: 1e-4)
        XCTAssertTrue(orthoResult!.unmatchedSourceIndices.isEmpty)
        XCTAssertTrue(orthoResult!.unmatchedTargetIndices.isEmpty)
        XCTAssertTrue(orthoResult!.isComplete)

        // Valid skew cell requiring large coefficients: a=(100,0,0), b=(99,1,0).
        // The target atom at (10,-10,0) is equivalent to the source at (0,0,0)
        // via translation by 10*(a-b); the nearest image requires coefficients
        // (-10, 10), well beyond any fixed +/-2 offset.
        let skewCell = Cell(a: SIMD3(100, 0, 0), b: SIMD3(99, 1, 0), c: SIMD3(0, 0, 10))
        let skewSource = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]
        let skewTarget = [Atom(coord: SIMD3(10, -10, 0), atomicNumber: 6, label: "C")]
        let skewResult = StructureComparator.compare(source: skewSource, target: skewTarget,
                                                     sourceCell: skewCell, periodicDim: 2)
        XCTAssertNotNil(skewResult)
        XCTAssertEqual(skewResult!.matchedPairCount, 1)
        XCTAssertEqual(skewResult!.rmsDisplacement!, 0, accuracy: 1e-4)
        XCTAssertTrue(skewResult!.unmatchedSourceIndices.isEmpty)
        XCTAssertTrue(skewResult!.unmatchedTargetIndices.isEmpty)
        XCTAssertTrue(skewResult!.isComplete)

        // Singular-cell rejection: b = 2a gives a zero-volume cell in the
        // periodic plane; compare must return nil.
        let singularCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(20, 0, 0), c: SIMD3(0, 0, 10))
        let singularSource = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]
        let singularTarget = [Atom(coord: SIMD3(1, 0, 0), atomicNumber: 6, label: "C")]
        XCTAssertNil(StructureComparator.compare(source: singularSource, target: singularTarget,
                                                 sourceCell: singularCell, periodicDim: 2))

        // Complete no-match: target atom (5,0,0) has no periodic image within
        // the cutoff of source (0,0,0) in cell (10,0,0) periodicDim=1 (minimum
        // image distance 5 > 2.5). No image intersects the box, so the analysis
        // is complete with zero matches and all atoms unmatched.
        let noMatchCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let noMatchSource = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]
        let noMatchTarget = [Atom(coord: SIMD3(5, 0, 0), atomicNumber: 6, label: "C")]
        let noMatchResult = StructureComparator.compare(source: noMatchSource, target: noMatchTarget,
                                                        sourceCell: noMatchCell, periodicDim: 1)
        XCTAssertNotNil(noMatchResult)
        XCTAssertEqual(noMatchResult!.matchedPairCount, 0)
        XCTAssertEqual(noMatchResult!.unmatchedSourceIndices, [0])
        XCTAssertEqual(noMatchResult!.unmatchedTargetIndices, [0])
        XCTAssertTrue(noMatchResult!.isComplete)

        // Cancellation: a cancelled comparison returns nil. The closure is
        // threaded into image enumeration and short-circuits via the
        // bounded leaf checkpoint.
        let alwaysCancelled: () -> Bool = { true }
        XCTAssertNil(StructureComparator.compare(
            source: skewSource, target: skewTarget,
            sourceCell: skewCell, periodicDim: 2,
            isCancelled: alwaysCancelled))

        // Matching-work cap: a tiny candidateInspectionCap is hit during
        // matching and returns the all-unmatched incomplete result (isComplete
        // false), never nil and never a partial match. Uses a non-periodic
        // setup so the cap is exercised purely in the matching stream.
        let capSource = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 6, label: "C"),
        ]
        let capTarget = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 6, label: "C"),
        ]
        let capResult = StructureComparator.compare(
            source: capSource, target: capTarget,
            sourceCell: nil, periodicDim: 0,
            candidateInspectionCap: 1)
        XCTAssertNotNil(capResult)
        XCTAssertFalse(capResult!.isComplete)
        XCTAssertEqual(capResult!.matchedPairCount, 0)
        XCTAssertEqual(capResult!.unmatchedSourceIndices, [0, 1])
        XCTAssertEqual(capResult!.unmatchedTargetIndices, [0, 1])

        // Cancellation is checked per candidate record inside the matching
        // stream, not just per source atom: a closure that fires mid-stream
        // returns nil. Non-periodic so cancellation occurs in matching.
        // Call sequence for this setup: compare-top guard (1), makeBins over
        // two image records (2, 3), source-loop guard (4), then the first
        // streamCandidates record check (5). Threshold > 4 fires on call 5,
        // proving cancellation is caught inside the candidate stream.
        var cancelTicker = 0
        let matchCancel = StructureComparator.compare(
            source: capSource, target: capTarget,
            sourceCell: nil, periodicDim: 0,
            isCancelled: {
                cancelTicker += 1
                return cancelTicker > 4
            })
        XCTAssertNil(matchCancel)
        XCTAssertEqual(cancelTicker, 5)
    }

    // MARK: - Atom-table region/expression filtering

    func testAtomTableRegionExpressionAndCoordinationFiltering() {
        let table = AtomTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let atoms = [
            Atom(coord: SIMD3(1, 1, 1), atomicNumber: 6, label: "C"),   // frac (0.1,0.1,0.1)
            Atom(coord: SIMD3(5, 5, 5), atomicNumber: 6, label: "C"),   // frac (0.5,0.5,0.5)
            Atom(coord: SIMD3(9, 9, 9), atomicNumber: 8, label: "O"),   // frac (0.9,0.9,0.9)
            Atom(coord: SIMD3(2, 8, 4), atomicNumber: 1, label: "H"),   // frac (0.2,0.8,0.4)
        ]
        table.update(atoms: atoms, cell: cell, selectedAtoms: [], coordinationNumbers: [4, 2, 6, 1])

        func filter(_ text: String) -> [Int] {
            table.searchField.stringValue = text
            table.searchField.sendAction(table.searchField.action, to: table.searchField.target)
            return table.filteredAtomIndices
        }

        // Cartesian comparison expressions.
        XCTAssertEqual(filter("x>4"), [1, 2])
        XCTAssertEqual(filter("x>=9"), [2])
        XCTAssertEqual(filter("z<2"), [0])
        XCTAssertEqual(filter("y=8"), [3])
        XCTAssertEqual(filter("y==8"), [3])
        XCTAssertEqual(filter("x<=1"), [0])

        // Fractional comparisons use the cell.
        XCTAssertEqual(filter("a>0.25"), [1, 2])
        XCTAssertEqual(filter("b<0.5"), [0])
        XCTAssertEqual(filter("b<=0.5"), [0, 1])
        XCTAssertEqual(filter("c>=0.8"), [2])

        // Region filters: box and sphere in Cartesian Å.
        XCTAssertEqual(filter("box:0,0,0,6,6,6"), [0, 1])
        XCTAssertEqual(filter("sphere:1,1,1,0.5"), [0])
        XCTAssertEqual(filter("sphere:5,5,5,1"), [1])

        // Coordination terms still combine with coordinate terms (AND).
        XCTAssertEqual(filter("cn:>=4 x>4"), [2])
        XCTAssertEqual(filter("cn:2"), [1])

        // Element text + coordinate expression combine.
        XCTAssertEqual(filter("c x>4"), [1])

        // Malformed structured terms suppress all rows instead of mis-filtering.
        XCTAssertEqual(filter("cn:abc"), [])
        XCTAssertEqual(filter(">"), [])
        XCTAssertEqual(filter("box:1,2,3"), [])
        XCTAssertEqual(filter("box:6,6,6,0,0,0"), [])   // inverted box
        XCTAssertEqual(filter("sphere:0,0,0,-1"), [])

        // A term that begins with an axis letter + comparison-operator is
        // structured intent and must fail closed (not fall through to label
        // text matching). "x>" with no number must suppress every row.
        XCTAssertEqual(filter("x>"), [])
        // An atom labeled "y>foo" must NOT match the bare text "y>" — the
        // structured intent check takes precedence and fails closed.
        let yLabelTable = AtomTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        yLabelTable.update(atoms: [Atom(coord: .zero, atomicNumber: 6, label: "y>foo")],
                          cell: nil, selectedAtoms: [])
        yLabelTable.searchField.stringValue = "y>"
        yLabelTable.searchField.sendAction(yLabelTable.searchField.action,
                                           to: yLabelTable.searchField.target)
        XCTAssertEqual(yLabelTable.filteredAtomIndices, [])

        // Box filter must reject empty/whitespace comma fields (an empty field
        // must not parse as 0 and silently match).
        XCTAssertEqual(filter("box:0,0,0,,0,0"), [])
        XCTAssertEqual(filter("box:0,0,0, ,0,0"), [])
        // Sphere filter must reject empty fields too.
        XCTAssertEqual(filter("sphere:0,0,0,"), [])
        XCTAssertEqual(filter("sphere:0,0,,1"), [])

        // Sphere matching uses finite Double arithmetic: an atom at
        // Float.greatestFiniteMagnitude must not match a radius that would
        // overflow Float (squaring -> infinity <= infinity -> true) but is
        // correctly outside in Double.
        let farCoord = Float.greatestFiniteMagnitude
        let farTable = AtomTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        farTable.update(atoms: [Atom(coord: SIMD3(farCoord, 0, 0), atomicNumber: 6, label: "C")],
                        cell: nil, selectedAtoms: [])
        // radius 1e19: farCoord² in Float = inf, so inf <= inf would be true.
        // In Double (farCoord ≈ 1.8e38)² ≈ 3.2e76, radius² = 1e38, so the
        // atom is correctly outside.
        farTable.searchField.stringValue = "sphere:0,0,0,1e19"
        farTable.searchField.sendAction(farTable.searchField.action, to: farTable.searchField.target)
        XCTAssertEqual(farTable.filteredAtomIndices, [])

        // Fractional comparisons without a valid cell fail closed.
        let noCellTable = AtomTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        noCellTable.update(atoms: atoms, cell: nil, selectedAtoms: [])
        noCellTable.searchField.stringValue = "a>0.25"
        noCellTable.searchField.sendAction(noCellTable.searchField.action,
                                           to: noCellTable.searchField.target)
        XCTAssertEqual(noCellTable.filteredAtomIndices, [])

        // Blank query restores all rows.
        XCTAssertEqual(filter(""), [0, 1, 2, 3])
    }

    // MARK: - On-screen bond-distance labels

    func testBondDistanceLabelsAndDisplacementArrows() {
        // A single bond of length 1 Å centered at the origin produces exactly
        // one bond-distance label with the formatted distance, positioned near
        // the projected midpoint.
        var scene = Scene()
        scene.atoms = [
            Atom(coord: SIMD3(-0.5, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0.5, 0, 0), atomicNumber: 1, label: "H"),
        ]
        scene.bonds = [Bond(i: 0, j: 1)]
        var camera = Camera()
        camera.center = .zero
        camera.distance = 10
        camera.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let viewport = SIMD2<Float>(400, 300)

        let labels = MainWindowController.bondDistanceLabels(scene: scene,
                                                             camera: camera,
                                                             viewport: viewport)
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0].symbol, "1.00 Å")
        XCTAssertEqual(labels[0].style, .bondDistance)
        XCTAssertTrue(labels[0].isExportable)
        // The label must sit inside the viewport near the midpoint.
        let rect = LabelOverlayView.drawingRect(for: labels[0])
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, CGFloat(viewport.x))

        // The cap bounds the label count and malformed bonds are skipped.
        var many = Scene()
        many.atoms = (0..<10).map { Atom(coord: SIMD3(Float($0) * 1.1, 0, 0),
                                         atomicNumber: 1, label: "H") }
        many.bonds = (0..<9).map { Bond(i: $0, j: $0 + 1) }
        many.bonds.append(Bond(i: 0, j: 99))   // out of range
        let capped = MainWindowController.bondDistanceLabels(scene: many,
                                                             camera: camera,
                                                             viewport: viewport,
                                                             maxLabels: 4)
        XCTAssertEqual(capped.count, 4)
        let uncapped = MainWindowController.bondDistanceLabels(scene: many,
                                                               camera: camera,
                                                               viewport: viewport)
        XCTAssertEqual(uncapped.count, 9)

        // The inspected-bond cap bounds traversal: place 10 malformed
        // (out-of-range) bonds first, followed by exactly one valid visible
        // bond. With maxInspectedBonds=10 the valid bond is never reached so
        // zero labels are produced; with maxInspectedBonds=11 it is reached
        // and exactly one label is produced.
        var cappedScene = Scene()
        cappedScene.showStructure = true
        cappedScene.atoms = [
            Atom(coord: SIMD3(-0.5, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0.5, 0, 0), atomicNumber: 1, label: "H"),
        ]
        // 10 malformed bonds (out-of-range indices) followed by one good one.
        cappedScene.bonds = (0..<10).map { _ in Bond(i: 0, j: 99) }
        cappedScene.bonds.append(Bond(i: 0, j: 1))
        let cap10 = MainWindowController.bondDistanceLabels(
            scene: cappedScene, camera: camera, viewport: viewport, maxInspectedBonds: 10)
        XCTAssertEqual(cap10.count, 0,
                       "cap=10 must skip the valid bond after 10 malformed ones")
        let cap11 = MainWindowController.bondDistanceLabels(
            scene: cappedScene, camera: camera, viewport: viewport, maxInspectedBonds: 11)
        XCTAssertEqual(cap11.count, 1,
                       "cap=11 must reach the valid bond and produce one label")

        // Bond labels include an explicit Å unit.
        XCTAssertTrue(labels[0].symbol.contains("Å"), "bond label must include Å unit")

        // Bond labels are hidden when the structure itself is hidden.
        var hiddenScene = scene
        hiddenScene.showStructure = false
        let hiddenLabels = MainWindowController.bondDistanceLabels(scene: hiddenScene,
                                                                  camera: camera,
                                                                  viewport: viewport)
        XCTAssertEqual(hiddenLabels.count, 0, "bond labels must be hidden when showStructure is false")

        // Bond labels near the right edge are translated to fit: a bond whose
        // natural label position would overflow the right edge must be
        // clamped inside ALL four viewport edges. Use a bond whose midpoint
        // projects near the right edge of a narrow viewport.
        var edgeScene = Scene()
        edgeScene.showStructure = true
        edgeScene.atoms = [
            Atom(coord: SIMD3(3.0, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(3.5, 0, 0), atomicNumber: 1, label: "H"),
        ]
        edgeScene.bonds = [Bond(i: 0, j: 1)]
        // Narrow viewport so the label would naturally overflow the right edge.
        let narrowViewport = SIMD2<Float>(100, 100)
        let edgeLabels = MainWindowController.bondDistanceLabels(
            scene: edgeScene, camera: camera, viewport: narrowViewport)
        XCTAssertEqual(edgeLabels.count, 1,
                       "exactly one edge bond label must be produced")
        let edgeRect = LabelOverlayView.drawingRect(for: edgeLabels[0])
        XCTAssertLessThanOrEqual(edgeRect.maxX, CGFloat(narrowViewport.x),
                                "bond label must be clamped inside the right viewport edge")
        XCTAssertGreaterThanOrEqual(edgeRect.minX, 0,
                                    "bond label must be clamped inside the left viewport edge")
        XCTAssertLessThanOrEqual(edgeRect.maxY, CGFloat(narrowViewport.y),
                                "bond label must be clamped inside the top viewport edge")
        XCTAssertGreaterThanOrEqual(edgeRect.minY, 0,
                                    "bond label must be clamped inside the bottom viewport edge")

        // Displacement arrows are renderer-facing runtime state gated by the
        // toggle; the controller rebuilds them from the current atom ordering.
        let controller = MainWindowController(scene: scene, showWindow: false)
        let result = StructureComparisonResult(
            matches: [AtomMatch(sourceIndex: 0, targetIndex: 0,
                                displacement: SIMD3(0.2, 0, 0), distance: 0.2)],
            unmatchedSourceIndices: [], unmatchedTargetIndices: [],
            rmsDisplacement: 0.2, meanDisplacement: 0.2, maxDisplacement: 0.2,
            perElement: [], maxMatchDistance: 2.5, isComplete: true)
        controller.installComparisonForTesting(result, referenceTitle: "ref.xsf")
        XCTAssertEqual(controller.comparisonResult, result)
        XCTAssertEqual(controller.comparisonReferenceTitle, "ref.xsf")
        XCTAssertFalse(controller.state.comparisonStatusText.isEmpty)
        if let renderer = controller.renderer {
            XCTAssertEqual(renderer.displacementArrows.count, 1)
            XCTAssertEqual(renderer.displacementArrows[0].start.x, -0.5, accuracy: 1e-5)
            XCTAssertEqual(renderer.displacementArrows[0].vector.x, 0.2, accuracy: 1e-5)
        }

        // Clearing drops arrows, status, and the toggle.
        controller.state.showComparisonArrows = true
        controller.clearComparison()
        XCTAssertNil(controller.comparisonResult)
        XCTAssertTrue(controller.state.comparisonStatusText.isEmpty)
        XCTAssertEqual(controller.renderer?.displacementArrows.count ?? 0, 0)
        XCTAssertFalse(controller.renderer?.showDisplacementArrows ?? true)
        XCTAssertFalse(controller.state.showComparisonArrows)

        // --- CSV regression: a label with percent/comma/quote/newline must ---
        // not crash and must produce valid RFC-4180 escaping. The pure helper
        // is exercised directly so no save panel is needed.
        let trickyAtoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "100% pure, \"good\"" ),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "line1\nline2"),
        ]
        let trickyResult = StructureComparisonResult(
            matches: [
                AtomMatch(sourceIndex: 0, targetIndex: 0,
                          displacement: SIMD3(0.1, 0.2, 0.3), distance: 0.374),
                AtomMatch(sourceIndex: 1, targetIndex: 1,
                          displacement: SIMD3(0.4, 0.5, 0.6), distance: 0.877),
            ],
            unmatchedSourceIndices: [], unmatchedTargetIndices: [],
            rmsDisplacement: 0.626, meanDisplacement: 0.626, maxDisplacement: 0.626,
            perElement: [], maxMatchDistance: 2.5, isComplete: true)
        let trickyTitle = "Ref: 50%\nalpha, \"test\""
        let csv = MainWindowController.comparisonCSV(for: trickyResult,
                                                     referenceTitle: trickyTitle,
                                                     sourceAtoms: trickyAtoms)
        // Must not crash and must contain the header row.
        XCTAssertTrue(csv.contains("source_index,target_index,element,label,dx,dy,dz,distance_angstrom"))
        // Quotes must be doubled inside quoted fields; the label contains a
        // comma and quotes so the whole field must be wrapped.
        XCTAssertTrue(csv.contains("\"100% pure, \"\"good\"\"\""),
                      "embedded quotes must be doubled")
        // Newlines in the title must be sanitized (collapsed) in comment lines.
        XCTAssertFalse(csv.contains("Ref: 50%\nalpha"),
                       "title newlines must be sanitized in comment lines")
        // The second atom's label contains a literal newline; that field must
        // be quoted with the newline preserved inside.
        XCTAssertTrue(csv.contains("\"line1\nline2\""),
                      "newline inside a field must be quoted")
        // The helper must never interpolate a label into a format string: no
        // bare percent-sequence injection. Assert exact row fragments.
        XCTAssertTrue(csv.contains("1,1,C,\"100% pure, \"\"good\"\"\""),
                      "first data row must start 1,1,C,escaped-label")
        XCTAssertTrue(csv.contains("2,2,H,\"line1\nline2\""),
                      "second data row must start 2,2,H,escaped-label")
        // The numeric tail of the first row must be the four formatted floats.
        XCTAssertTrue(csv.contains(",0.100000,0.200000,0.300000,0.374000"),
                      "first row numeric fragment must be present")

        // --- Geometry invalidation regression: a coordinate edit must clear ---
        // an installed comparison so stale displacement arrows from the old
        // atom ordering are never shown or exported.
        controller.installComparisonForTesting(result, referenceTitle: "ref.xsf")
        XCTAssertNotNil(controller.comparisonResult)
        // Populate the atom table so commitAtomEdit can resolve the row.
        controller.atomTable.update(atoms: controller.scene.atoms, cell: controller.scene.cell,
                                     selectedAtoms: controller.scene.selectedAtoms)
        // Edit atom 0's x-coordinate through the same seam the table uses.
        let accepted = controller.commitAtomEdit(
            row: 0, columnIdentifier: AtomTableView.colX, value: "0.7")
        XCTAssertEqual(accepted, .accepted)
        XCTAssertNil(controller.comparisonResult,
                     "coordinate edit must invalidate the comparison")
        XCTAssertTrue(controller.state.comparisonStatusText.isEmpty)
        XCTAssertEqual(controller.renderer?.displacementArrows.count ?? 0, 0)

        // Undo must also invalidate: reinstall, repopulate the table, undo the
        // edit, verify cleared.
        controller.installComparisonForTesting(result, referenceTitle: "ref.xsf")
        XCTAssertNotNil(controller.comparisonResult)
        controller.atomTable.update(atoms: controller.scene.atoms, cell: controller.scene.cell,
                                     selectedAtoms: controller.scene.selectedAtoms)
        controller.undoCoordinateEdit()
        XCTAssertNil(controller.comparisonResult,
                     "undo must invalidate the comparison")
        XCTAssertEqual(controller.renderer?.displacementArrows.count ?? 0, 0)

        // --- Export-option propagation: displacement arrows reach the
        // RenderExportOptions built for the visible Metal canvas only when the
        // toggle is on and a result is installed. Defaults/headless stay empty.
        controller.installComparisonForTesting(result, referenceTitle: "ref.xsf")
        controller.state.showComparisonArrows = true
        var optsWithArrows: RenderExportOptions?
        var optsNoArrows: RenderExportOptions?
        do {
            optsWithArrows = try controller.exportRenderOptions(for: CGSize(width: 200, height: 200))
            controller.state.showComparisonArrows = false
            optsNoArrows = try controller.exportRenderOptions(for: CGSize(width: 200, height: 200))
        } catch {
            XCTFail("exportRenderOptions threw: \(error)")
        }
        guard let unwrapped = optsWithArrows else {
            return XCTFail("exportRenderOptions must return options when arrows enabled")
        }
        XCTAssertTrue(unwrapped.showDisplacementArrows,
                      "arrow toggle must propagate to export options")
        XCTAssertEqual(unwrapped.displacementArrows.count, 1)
        XCTAssertEqual(unwrapped.displacementArrows[0].vector.x, 0.2, accuracy: 1e-5)
        // Toggle off: export options must drop the arrows.
        guard let unwrappedNo = optsNoArrows else {
            return XCTFail("exportRenderOptions must return options when arrows disabled")
        }
        XCTAssertFalse(unwrappedNo.showDisplacementArrows)
        XCTAssertTrue(unwrappedNo.displacementArrows.isEmpty)

        // --- Export showDisplacementArrows is false when the arrow list is
        // empty even though the toggle is on. A comparison result whose
        // matches all fall outside the current atom range yields no arrows.
        let emptyMatchResult = StructureComparisonResult(
            matches: [AtomMatch(sourceIndex: 99, targetIndex: 0,
                                displacement: SIMD3(0.2, 0, 0), distance: 0.2)],
            unmatchedSourceIndices: [], unmatchedTargetIndices: [],
            rmsDisplacement: 0.2, meanDisplacement: 0.2, maxDisplacement: 0.2,
            perElement: [], maxMatchDistance: 2.5, isComplete: true)
        controller.installComparisonForTesting(emptyMatchResult, referenceTitle: "out-of-range")
        controller.state.showComparisonArrows = true
        var emptyArrowOpts: RenderExportOptions?
        do {
            emptyArrowOpts = try controller.exportRenderOptions(for: CGSize(width: 200, height: 200))
        } catch {
            XCTFail("exportRenderOptions threw: \(error)")
        }
        guard let unwrappedEmpty = emptyArrowOpts else {
            return XCTFail("exportRenderOptions must return options for empty-match result")
        }
        XCTAssertTrue(unwrappedEmpty.displacementArrows.isEmpty)
        XCTAssertFalse(unwrappedEmpty.showDisplacementArrows,
                       "showDisplacementArrows must be false when no arrows compute")
        controller.clearComparison()

        // --- Geometry invalidation must not add extra renders. A coordinate
        // edit already renders (via its own lifecycle + the syncFromState
        // triggered by replaceKPath). The render-suppressed invalidation must
        // not add any additional renders on top of that baseline.
        // Baseline: edit with no comparison installed.
        let baselineBefore = controller.renderRequestCount
        _ = controller.commitAtomEdit(row: 0, columnIdentifier: AtomTableView.colX, value: "0.9")
        let baselineDelta = controller.renderRequestCount - baselineBefore
        XCTAssertGreaterThan(baselineDelta, 0, "edit must render at least once")
        // Now install a comparison and repeat the same edit.
        controller.installComparisonForTesting(result, referenceTitle: "ref.xsf")
        controller.atomTable.update(atoms: controller.scene.atoms, cell: controller.scene.cell,
                                     selectedAtoms: controller.scene.selectedAtoms)
        let beforeCount = controller.renderRequestCount
        _ = controller.commitAtomEdit(row: 0, columnIdentifier: AtomTableView.colX, value: "0.8")
        XCTAssertNil(controller.comparisonResult)
        XCTAssertEqual(controller.renderRequestCount - beforeCount, baselineDelta,
                       "comparison invalidation must not add extra renders beyond the edit baseline")
        controller.clearComparison()

        // --- Clear must cancel an in-flight comparison immediately and reset
        // the calculating flag. Simulate an in-flight request by setting the
        // calculating state directly, then verify Clear resets it.
        controller.installComparisonForTesting(result, referenceTitle: "ref.xsf")
        controller.state.comparisonCalculating = true
        controller.state.comparisonStatusText = "Calculating…"
        controller.clearComparison()
        XCTAssertNil(controller.comparisonResult)
        XCTAssertFalse(controller.state.comparisonCalculating,
                       "Clear must reset comparisonCalculating even when true")
        XCTAssertTrue(controller.state.comparisonStatusText.isEmpty)

        // --- Geometry invalidation must reset showComparisonArrows even when
        // the panel is not visible, and must not trigger a render beyond the
        // edit lifecycle's own. The isSyncingState guard prevents the didSet
        // callback from causing a nested sync/render.
        controller.installComparisonForTesting(result, referenceTitle: "ref.xsf")
        controller.atomTable.update(atoms: controller.scene.atoms, cell: controller.scene.cell,
                                     selectedAtoms: controller.scene.selectedAtoms)
        controller.state.showComparisonArrows = true
        XCTAssertTrue(controller.state.comparisonCalculating == false)
        let arrowsOnHash = controller.renderer?.showDisplacementArrows ?? false
        XCTAssertTrue(arrowsOnHash)
        // Geometry mutation must clear the comparison AND reset the toggle.
        let geoBeforeCount = controller.renderRequestCount
        _ = controller.commitAtomEdit(row: 0, columnIdentifier: AtomTableView.colX, value: "0.6")
        XCTAssertNil(controller.comparisonResult)
        XCTAssertFalse(controller.state.showComparisonArrows,
                       "geometry invalidation must reset showComparisonArrows")
        // The didSet → onChange → syncFromState must have early-returned via
        // isSyncingState: no extra render beyond the edit lifecycle baseline.
        let geoDelta = controller.renderRequestCount - geoBeforeCount
        XCTAssertGreaterThan(geoDelta, 0)
        // Baseline (no comparison) delta was captured earlier in this test;
        // here we just confirm it's the same small number, not doubled.
        XCTAssertLessThanOrEqual(geoDelta, 2,
            "showComparisonArrows reset must not double-render")
        controller.clearComparison()

        // --- Synchronous loadComparisonReference supersedes any prior async
        // request and installs a result without leaving the UI in a disabled
        // Calculating state. Exercise the real seam against a fixture file.
        let fixtureDirectory = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fixture = fixtureDirectory.appendingPathComponent("Fixtures/h2o.xyz")
        // Simulate an in-flight async request, then call the sync seam.
        controller.state.comparisonCalculating = true
        controller.state.comparisonStatusText = "Calculating…"
        var syncError: Error?
        do {
            try controller.loadComparisonReference(from: fixture)
        } catch {
            syncError = error
        }
        XCTAssertNil(syncError, "sync loadComparisonReference must not throw for a valid fixture")
        XCTAssertNotNil(controller.comparisonResult,
                        "sync loadComparisonReference must install a result")
        XCTAssertFalse(controller.state.comparisonCalculating,
                       "sync seam must clear comparisonCalculating")
        XCTAssertFalse(controller.state.comparisonStatusText.isEmpty)
        controller.clearComparison()
        XCTAssertNil(controller.comparisonResult)
        XCTAssertFalse(controller.state.comparisonCalculating)
        XCTAssertFalse(controller.state.showComparisonArrows)
        XCTAssertNil(controller.renderer?.displacementArrows.first)
    }
}
