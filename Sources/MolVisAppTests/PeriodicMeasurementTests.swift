import simd
import XCTest
@testable import MolVisApp

final class PeriodicMeasurementTests: XCTestCase {

    /// Brute-force minimum image distance by enumerating all 27 neighboring
    /// cells. Used as the oracle for the skew-cell test.
    private func bruteForceMinImage(from p: SIMD3<Float>, to q: SIMD3<Float>,
                                    cell: Cell, periodicDim: Int) -> Float {
        let rangeA = periodicDim >= 1 ? [-1, 0, 1] : [0]
        let rangeB = periodicDim >= 2 ? [-1, 0, 1] : [0]
        let rangeC = periodicDim >= 3 ? [-1, 0, 1] : [0]
        var best = Float.greatestFiniteMagnitude
        for i in rangeA { for j in rangeB { for k in rangeC {
            let image = q + cell.a * Float(i) + cell.b * Float(j) + cell.c * Float(k)
            best = min(best, length(image - p))
        }}}
        return best
    }

    func testMoleculeOrthogonalAndTwoDimensionalDistanceBehavior() {
        // Molecules use direct Cartesian distance when no periodic cell exists.
        let moleculeAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(3, 4, 0), atomicNumber: 1, label: "H"),
        ]
        let moleculeResult = Scene.computeMeasurement(mode: .distance,
                                                      atoms: moleculeAtoms,
                                                      selected: [0, 1])
        XCTAssertNotNil(moleculeResult)
        XCTAssertEqual(moleculeResult!.value, 5.0, accuracy: 1e-5)
        XCTAssertTrue(moleculeResult!.summary.contains("Å"))

        // An orthogonal boundary pair must use the shorter wrapped distance.
        let orthogonalCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let orthogonalAtoms = [
            Atom(coord: SIMD3(0.5, 5, 5), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 5, 5), atomicNumber: 1, label: "H"),
        ]
        let direct = length(orthogonalAtoms[1].coord - orthogonalAtoms[0].coord)
        XCTAssertEqual(direct, 9.0, accuracy: 1e-5)
        let orthogonalResult = Scene.computeMeasurement(mode: .distance,
                                                         atoms: orthogonalAtoms,
                                                         selected: [0, 1],
                                                         cell: orthogonalCell,
                                                         periodicDim: 3)
        XCTAssertNotNil(orthogonalResult)
        XCTAssertEqual(orthogonalResult!.value, 1.0, accuracy: 1e-4)

        // Two-dimensional periodicity wraps x/y but leaves z unwrapped.
        let twoDimensionalCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 100))
        let twoDimensionalAtoms = [
            Atom(coord: SIMD3(0.5, 5, 10), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 5, 90), atomicNumber: 1, label: "H"),
        ]
        let twoDimensionalResult = Scene.computeMeasurement(mode: .distance,
                                                            atoms: twoDimensionalAtoms,
                                                            selected: [0, 1],
                                                            cell: twoDimensionalCell,
                                                            periodicDim: 2)
        XCTAssertNotNil(twoDimensionalResult)
        // x wraps (1.0), z does not (80.0): sqrt(1^2 + 80^2).
        let expected = sqrtf(1.0 + 80.0 * 80.0)
        XCTAssertEqual(twoDimensionalResult!.value, expected, accuracy: 1e-3)
    
        // --- merged (isolated scope) ---
        do {

        // A skew cell is checked against explicit enumeration of all 27 images.
        let skewCell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(3, 4, 0), c: SIMD3(0, 0, 10))
        let skewAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(4.9, 0.1, 0), atomicNumber: 1, label: "H"),
        ]
        let expected = bruteForceMinImage(from: skewAtoms[0].coord,
                                          to: skewAtoms[1].coord,
                                          cell: skewCell,
                                          periodicDim: 3)
        let skewResult = Scene.computeMeasurement(mode: .distance,
                                                  atoms: skewAtoms,
                                                  selected: [0, 1],
                                                  cell: skewCell,
                                                  periodicDim: 3)
        XCTAssertNotNil(skewResult)
        XCTAssertEqual(skewResult!.value, expected, accuracy: 1e-4)
        XCTAssertLessThan(skewResult!.value,
                          length(skewAtoms[1].coord - skewAtoms[0].coord) / 2)

        // A singular periodic cell must fail rather than fabricate a distance.
        let singularCell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        let singularAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0.5, 0.5, 0), atomicNumber: 1, label: "H"),
        ]
        let invalidResult = Scene.computeMeasurement(mode: .distance,
                                                     atoms: singularAtoms,
                                                     selected: [0, 1],
                                                     cell: singularCell,
                                                     periodicDim: 3)
        XCTAssertNil(invalidResult)

        // Angles remain direct-vector measurements even when a cell is supplied.
        let angleAtoms = [
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 1, 0), atomicNumber: 1, label: "H"),
        ]
        let plain = Scene.computeMeasurement(mode: .angle,
                                             atoms: angleAtoms,
                                             selected: [0, 1, 2])
        let withCell = Scene.computeMeasurement(mode: .angle,
                                                atoms: angleAtoms,
                                                selected: [0, 1, 2],
                                                cell: Cell(a: SIMD3(10, 0, 0),
                                                           b: SIMD3(0, 10, 0),
                                                           c: SIMD3(0, 0, 10)),
                                                periodicDim: 3)
        XCTAssertNotNil(plain)
        XCTAssertNotNil(withCell)
        XCTAssertEqual(plain!.value, 90.0, accuracy: 1e-5)
        XCTAssertEqual(withCell!.value, 90.0, accuracy: 1e-5)

        // MARK: Minimum-image angle across orthogonal and skew boundaries.
        let orthoCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let wrapAngleAtoms = [
            Atom(coord: SIMD3(0.5, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.5, 1, 0), atomicNumber: 1, label: "H"),
        ]
        let wrapAngle = Scene.computeMeasurement(mode: .angle,
                                                 atoms: wrapAngleAtoms,
                                                 selected: [0, 1, 2],
                                                 cell: orthoCell, periodicDim: 3)
        XCTAssertNotNil(wrapAngle)
        XCTAssertEqual(wrapAngle!.value, 90.0, accuracy: 1e-4)

        // Skew-cell angle.
        let skewAngleAtoms = [
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 1, 0), atomicNumber: 1, label: "H"),
        ]
        let skewAngle = Scene.computeMeasurement(mode: .angle,
                                                 atoms: skewAngleAtoms,
                                                 selected: [0, 1, 2],
                                                 cell: skewCell, periodicDim: 3)
        XCTAssertNotNil(skewAngle)
        XCTAssertEqual(skewAngle!.value, 90.0, accuracy: 1e-3)

        // Singular cell rejects angle.
        let singularAngle = Scene.computeMeasurement(mode: .angle,
                                                     atoms: angleAtoms,
                                                     selected: [0, 1, 2],
                                                     cell: singularCell, periodicDim: 3)
        XCTAssertNil(singularAngle)

        // MARK: Unsigned dihedral across boundaries.
        let dihedralAtoms = [
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 0, 1.5), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(1, 0, 1.5), atomicNumber: 1, label: "H"),
        ]
        let dihedralResult = Scene.computeMeasurement(mode: .dihedral,
                                                       atoms: dihedralAtoms,
                                                       selected: [0, 1, 2, 3],
                                                       cell: orthoCell, periodicDim: 3)
        XCTAssertNotNil(dihedralResult)
        XCTAssertEqual(dihedralResult!.value, 0.0, accuracy: 1e-3)
        XCTAssertGreaterThanOrEqual(dihedralResult!.value, 0.0)

        let piVal = Float.pi
        let staggeredAtoms = [
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 0, 1.5), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(cos(piVal / 3), sin(piVal / 3), 1.5), atomicNumber: 1, label: "H"),
        ]
        let staggeredDihedral = Scene.computeMeasurement(mode: .dihedral,
                                                          atoms: staggeredAtoms,
                                                          selected: [0, 1, 2, 3],
                                                          cell: orthoCell, periodicDim: 3)
        XCTAssertNotNil(staggeredDihedral)
        XCTAssertEqual(staggeredDihedral!.value, 60.0, accuracy: 1e-3)

        // Degenerate vectors reject.
        let degenAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
        ]
        let degenDihedral = Scene.computeMeasurement(mode: .dihedral,
                                                      atoms: degenAtoms,
                                                      selected: [0, 1, 2, 3],
                                                      cell: orthoCell, periodicDim: 3)
        XCTAssertNil(degenDihedral)

        // Singular cell rejects dihedral.
        let singularDihedral = Scene.computeMeasurement(mode: .dihedral,
                                                        atoms: staggeredAtoms,
                                                        selected: [0, 1, 2, 3],
                                                        cell: singularCell, periodicDim: 3)
        XCTAssertNil(singularDihedral)

        // MARK: Distribution analysis — bond histogram, RDF, NeighborTableView
        let dCell = Cell(a: SIMD3(5.43, 0, 0), b: SIMD3(0, 5.43, 0), c: SIMD3(0, 0, 5.43))
        let dAtoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3(1.3575, 1.3575, 1.3575), atomicNumber: 14, label: "Si"),
        ]
        guard let dAnalysis = CoordinationAnalyzer.analyze(atoms: dAtoms, cell: dCell,
                                                           periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("coordination analysis failed")
            return
        }
        guard let d = DistributionAnalyzer.analyze(dAnalysis, atoms: dAtoms,
                                                    cell: dCell, periodicDim: 3) else {
            XCTFail("distribution analysis failed")
            return
        }
        XCTAssertFalse(d.bondLengthHistogram.isEmpty)
        XCTAssertGreaterThan(d.uniquePairCount, 0)
        XCTAssertTrue(d.radialDistribution.isAvailable)
        XCTAssertLessThanOrEqual(d.radialDistribution.maxRadius, 5.43 / 2.0 + 0.01)
        let rdfCSV = d.radialDistribution.csv()
        XCTAssertTrue(rdfCSV.hasPrefix("r (Å),g(r),count"))
        let csvLines = rdfCSV.split(separator: "\n")
        XCTAssertGreaterThan(csvLines.count, 1)
        XCTAssertEqual(csvLines[1].split(separator: ",").count, 3)
        let maxG = d.radialDistribution.bins.map { $0.g }.max() ?? 0
        XCTAssertGreaterThan(maxG, 0)
        XCTAssertTrue(maxG.isFinite)

        let dist2D = DistributionAnalyzer.analyze(dAnalysis, atoms: dAtoms, cell: dCell, periodicDim: 2)!
        XCTAssertFalse(dist2D.radialDistribution.isAvailable)
        let distMolecule = DistributionAnalyzer.analyze(dAnalysis, atoms: dAtoms, cell: nil, periodicDim: 0)!
        XCTAssertFalse(distMolecule.radialDistribution.isAvailable)
        let bigN = DistributionAnalyzer.defaultMaxRDFAtoms + 1
        var bigAtoms: [Atom] = []
        bigAtoms.reserveCapacity(bigN)
        for i in 0..<bigN {
            bigAtoms.append(Atom(
                coord: SIMD3(Float(i % 10) * 5.0, Float((i / 10) % 10) * 5.0, Float(i / 100) * 5.0),
                atomicNumber: 14, label: "Si"))
        }
        let bigCell = Cell(a: SIMD3(50, 0, 0), b: SIMD3(0, 50, 0), c: SIMD3(0, 0, 50))
        guard let bigAnalysis = CoordinationAnalyzer.analyze(atoms: bigAtoms, cell: bigCell,
                                                              periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("big coordination analysis failed")
            return
        }
        guard let bigDist = DistributionAnalyzer.analyze(bigAnalysis, atoms: bigAtoms,
                                                           cell: bigCell, periodicDim: 3) else {
            XCTFail("big distribution analysis failed")
            return
        }
        XCTAssertFalse(bigDist.radialDistribution.isAvailable)

        let superCell = Cell(a: SIMD3(5.43 * 2, 0, 0), b: SIMD3(0, 5.43, 0), c: SIMD3(0, 0, 5.43))
        let superAtoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3(1.3575, 1.3575, 1.3575), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3(2.715, 0, 0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3(4.0725, 1.3575, 1.3575), atomicNumber: 14, label: "Si"),
        ]
        guard let superAnalysis = CoordinationAnalyzer.analyze(atoms: superAtoms, cell: superCell,
                                                                periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("supercell coordination analysis failed")
            return
        }
        guard let superDist = DistributionAnalyzer.analyze(superAnalysis, atoms: superAtoms,
                                                             cell: superCell, periodicDim: 3) else {
            XCTFail("supercell distribution analysis failed")
            return
        }
        XCTAssertTrue(superDist.radialDistribution.isAvailable)
        XCTAssertGreaterThan(superDist.radialDistribution.bins.map { $0.g }.max() ?? 0, 0)

        // RDF fractional-torus brute-force parity: orthogonal boundary.
        let boundaryCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let boundaryAtoms = [
            Atom(coord: SIMD3(0.1, 5, 5), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.9, 5, 5), atomicNumber: 1, label: "H"),
        ]
        guard let boundaryAnalysis = CoordinationAnalyzer.analyze(atoms: boundaryAtoms, cell: boundaryCell,
                                                                   periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("boundary coordination analysis failed")
            return
        }
        guard let boundaryDist = DistributionAnalyzer.analyze(boundaryAnalysis, atoms: boundaryAtoms,
                                                                cell: boundaryCell, periodicDim: 3) else {
            XCTFail("boundary distribution analysis failed")
            return
        }
        XCTAssertTrue(boundaryDist.radialDistribution.isAvailable)
        let bfBoundary = bruteForceRDF(atoms: boundaryAtoms, cell: boundaryCell,
                                        periodicDim: 3, maxRadius: boundaryDist.radialDistribution.maxRadius,
                                        bins: boundaryDist.radialDistribution.bins.count)
        XCTAssertTrue(rdfsMatch(boundaryDist.radialDistribution, bfBoundary),
                      "orthogonal-boundary RDF does not match brute-force")

        // Rotated/skew cell brute-force parity.
        let rdfSkewCell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(3, 4, 0), c: SIMD3(0, 0, 10))
        let rdfSkewAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(4.9, 0.1, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(1, 1, 5), atomicNumber: 1, label: "H"),
        ]
        guard let skewAnalysis = CoordinationAnalyzer.analyze(atoms: rdfSkewAtoms, cell: rdfSkewCell,
                                                                periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("skew coordination analysis failed")
            return
        }
        guard let skewDist = DistributionAnalyzer.analyze(skewAnalysis, atoms: rdfSkewAtoms,
                                                            cell: rdfSkewCell, periodicDim: 3) else {
            XCTFail("skew distribution analysis failed")
            return
        }
        XCTAssertTrue(skewDist.radialDistribution.isAvailable)
        let bfSkew = bruteForceRDF(atoms: rdfSkewAtoms, cell: rdfSkewCell,
                                    periodicDim: 3, maxRadius: skewDist.radialDistribution.maxRadius,
                                    bins: skewDist.radialDistribution.bins.count)
        XCTAssertTrue(rdfsMatch(skewDist.radialDistribution, bfSkew),
                      "skew-cell RDF does not match brute-force")

        // Identical-distance bond single bin.
        let identAtoms = [
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0.5, 0, 0), atomicNumber: 1, label: "H"),
        ]
        let identCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        guard let identAnalysis = CoordinationAnalyzer.analyze(atoms: identAtoms, cell: identCell,
                                                                 periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("identical-distance coordination analysis failed")
            return
        }
        guard let identDist = DistributionAnalyzer.analyze(identAnalysis, atoms: identAtoms,
                                                              cell: identCell, periodicDim: 3) else {
            XCTFail("identical-distance distribution analysis failed")
            return
        }
        XCTAssertEqual(identDist.bondLengthHistogram.bins.count, 1)
        XCTAssertGreaterThan(identDist.bondLengthHistogram.bins[0].count, 0)
        XCTAssertGreaterThan(identDist.uniquePairCount, 0)

        // Periodic self-image canonicalization.
        let siAtoms = [Atom(coord: SIMD3(0.1, 0, 0), atomicNumber: 1, label: "H")]
        let siCell = Cell(a: SIMD3(0.6, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        guard let siAnalysis = CoordinationAnalyzer.analyze(atoms: siAtoms, cell: siCell,
                                                              periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("self-image coordination analysis failed")
            return
        }
        guard let siDist = DistributionAnalyzer.analyze(siAnalysis, atoms: siAtoms,
                                                          cell: siCell, periodicDim: 3) else {
            XCTFail("self-image distribution analysis failed")
            return
        }
        XCTAssertGreaterThan(siDist.uniquePairCount, 0)

        // Bond-angle histogram uses stored periodic displacement.
        let angleChain = [
            Atom(coord: SIMD3(0.5, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: .zero, atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 0.5, 0), atomicNumber: 1, label: "H"),
        ]
        guard let angleAnalysis = CoordinationAnalyzer.analyze(atoms: angleChain, cell: identCell,
                                                                periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("angle chain coordination analysis failed")
            return
        }
        guard let angleDist = DistributionAnalyzer.analyze(angleAnalysis, atoms: angleChain,
                                                            cell: identCell, periodicDim: 3) else {
            XCTFail("angle distribution analysis failed")
            return
        }
        XCTAssertGreaterThan(angleDist.uniqueAngleCount, 0)
        XCTAssertGreaterThan(angleDist.bondAngleHistogram.bins.reduce(0) { $0 + $1.count }, 0)

        // NeighborTableView UI seams.
        let tvAtoms3 = [
            Atom(coord: SIMD3(0.1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(9.9, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(5, 5, 5), atomicNumber: 1, label: "H"),
        ]
        guard let tvAnalysis = CoordinationAnalyzer.analyze(atoms: tvAtoms3, cell: identCell,
                                                             periodicDim: 3, radiusScale: 1.15) else {
            XCTFail("tv coordination analysis failed")
            return
        }
        let tv = NeighborTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        tv.update(analysis: tvAnalysis, atoms: tvAtoms3)
        XCTAssertEqual(tv.recordCount, tvAnalysis.neighbors.count)
        XCTAssertGreaterThanOrEqual(tv.omittedCount, 0)
        XCTAssertFalse(tv.isTruncated)
        XCTAssertFalse(tv.statusField.stringValue.isEmpty)
        let nRows = tv.numberOfRows(in: tv.tableView)
        XCTAssertGreaterThan(nRows, 0)
        for row in 0..<nRows {
            let v = tv.value(atRow: row, columnIdentifier: NeighborTableView.colDistance)
            XCTAssertNotNil(v)
            XCTAssertFalse(v!.isEmpty)
        }
        XCTAssertTrue(tv.tableView.tableColumns.contains { $0.sortDescriptorPrototype != nil })
        let initDesc = tv.tableView.sortDescriptors.first
        XCTAssertNotNil(initDesc)
        XCTAssertEqual(initDesc!.key, NeighborTableSortKey.distance.descriptorKey)
        XCTAssertTrue(initDesc!.ascending)
        tv.tableView.sortDescriptors = [
            NSSortDescriptor(key: NeighborTableSortKey.sourceIndex.descriptorKey, ascending: false)
        ]
        tv.tableView(tv.tableView, sortDescriptorsDidChange: [])
        XCTAssertFalse(tv.tableView.sortDescriptors.first!.ascending)
        }
}

    func testHBondPeriodicImageUsesMinimumImageDisplacement() {
        // A skew cell where the acceptor's nearest periodic image — not its base
        // position — satisfies the H-bond criteria. The acceptor O1 sits near the
        // -a boundary; its image at (10.4, 2.4) is only ~1.28 Å from the H while
        // the base position is ~9.3 Å away. The donor O0 is near the H, so the
        // D-H-A angle via the wrapped image is obtuse (>= 90°) while the reverse
        // donor assignment fails the angle gate, leaving exactly one pair.
        let skewCell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(2, 8, 0), c: SIMD3(0, 0, 12))
        let atoms = [
            Atom(coord: SIMD3(9.2, 4.2, 0), atomicNumber: 8, label: "O"),  // donor (index 0)
            Atom(coord: SIMD3(0.4, 2.4, 0), atomicNumber: 8, label: "O"),  // acceptor (index 1)
            Atom(coord: SIMD3(9.6, 3.4, 0), atomicNumber: 1, label: "H"),  // H near donor (index 2)
        ]
        var scene = Scene()
        scene.atoms = atoms
        scene.cell = skewCell
        scene.periodicDim = 3
        scene.hbondSettings = HbondSettings(enabled: true, maxDistance: 3.0, minAngleDegrees: 90)

        let pairs = HbondAnalysis.detect(scene: scene)
        // Exactly one pair: donor O0 -- H -- acceptor O1 via the wrapped image.
        XCTAssertEqual(pairs.count, 1, "expected exactly one H-bond pair")
        if let pair = pairs.first {
            XCTAssertEqual(pair.donor, 0)
            XCTAssertEqual(pair.acceptor, 1)
            XCTAssertEqual(pair.hydrogen, 2)
            // The acceptor image must be the wrapped nearest image (10.4, 2.4, 0),
            // not the base position (0.4, 2.4, 0) which is ~9.3 Å from the H.
            XCTAssertNotNil(pair.acceptorImage)
            let base = atoms[1].coord
            XCTAssertNotEqual(pair.acceptorImage, base, "acceptor image should be the wrapped nearest image")
            XCTAssertEqual(pair.acceptorImage?.x ?? -1, Float(10.4), accuracy: 0.01)
            XCTAssertEqual(pair.acceptorImage?.y ?? -1, Float(2.4), accuracy: 0.01)
        }
    }

    /// Brute-force i<j minimum-image RDF oracle.
    private func bruteForceRDF(atoms: [Atom], cell: Cell, periodicDim: Int,
                                maxRadius: Float, bins: Int = 50) -> [(center: Float, count: Int)] {
        let n = atoms.count
        let binWidth = maxRadius / Float(bins)
        var counts = [Int](repeating: 0, count: bins)
        for i in 0..<n {
            for j in (i + 1)..<n {
                guard let d = PeriodicGeometry.minimumImageDistance(
                    from: atoms[i].coord, to: atoms[j].coord,
                    cell: cell, periodicDim: periodicDim) else { continue }
                guard d > 0, d <= maxRadius else { continue }
                var idx = Int(d / binWidth)
                if idx >= bins { idx = bins - 1 }
                if idx < 0 { idx = 0 }
                counts[idx] += 1
            }
        }
        return (0..<bins).map { i in ((Float(i) + 0.5) * binWidth, counts[i]) }
    }

    private func rdfsMatch(_ result: RDFResult, _ brute: [(center: Float, count: Int)]) -> Bool {
        guard result.bins.count == brute.count else { return false }
        for (a, b) in zip(result.bins, brute) {
            if abs(a.center - b.center) > 0.01 { return false }
            if a.pairCount != b.count { return false }
        }
        return true
    }
}
