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
        XCTAssertEqual(filter("x>"), [])
        XCTAssertEqual(filter("box:1,2,3"), [])
        XCTAssertEqual(filter("box:6,6,6,0,0,0"), [])   // inverted box
        XCTAssertEqual(filter("sphere:0,0,0,-1"), [])

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
        XCTAssertEqual(labels[0].symbol, "1.00")
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
    }
}
