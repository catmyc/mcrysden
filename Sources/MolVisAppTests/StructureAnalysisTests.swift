import AppKit
import simd
import XCTest
@testable import MolVisApp

/// Focused coverage for structure-information and analysis: first-shell
/// polyhedron volume/distortion metrics and two-structure comparison with RMS
/// displacement.
final class StructureAnalysisTests: XCTestCase {

    func testPolyhedronMetricsAndStructureComparison() {
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
        // volumeRatio 1.
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
        XCTAssertNotNil(cubeIdeal)
        XCTAssertEqual(cubeMetrics.volumeRatio!, 1, accuracy: 1e-2)

        // Asymmetric shell: non-zero distortion, volumeRatio < 1.
        let distorted: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(-1, -1, -1),
        ]
        let dMetrics = PolyhedronAnalyzer.metrics(for: .zero, shell: distorted)
        XCTAssertEqual(dMetrics.neighborCount, 4)
        XCTAssertNotNil(dMetrics.bondLengthDistortion)
        XCTAssertGreaterThan(dMetrics.bondLengthDistortion!, 0)

        // --- Two-structure comparison with RMS displacement ---
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

        // Element mismatch and missing atoms are reported unmatched.
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

        // Singular-cell rejection: b = 2a gives a zero-volume cell.
        let singularCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(20, 0, 0), c: SIMD3(0, 0, 10))
        let singularSource = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]
        let singularTarget = [Atom(coord: SIMD3(1, 0, 0), atomicNumber: 6, label: "C")]
        XCTAssertNil(StructureComparator.compare(source: singularSource, target: singularTarget,
                                                 sourceCell: singularCell, periodicDim: 2))
    }
}
