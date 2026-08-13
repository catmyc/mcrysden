import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for BandMeshInterpolator + BandSurfaceBuilder. Synthetic BandStructure
/// values are built directly (memberwise inits); one integration case loads the
/// real QE mesh fixture CH3Rh111.out via BandParser.parse.
final class BandMeshSurfaceTests: XCTestCase {

    // MARK: - Helpers

    /// Build a synthetic mesh BandStructure: axis-aligned product grid over the
    /// given per-axis node lists, with energies linear in (a*x + b*y + c*z) per
    /// band plus a per-band constant (so bands occupy disjoint ranges).
    private static func makeMesh(
        nodeLists: [[Float]],
        nBands: Int,
        nSpin: Int = 1,
        bandSlope: (Float, Float, Float) = (1, 2, 3),
        channelOffset: [Float] = []
    ) -> BandStructure {
        let dims = nodeLists.map { $0.count }
        let perSpin = dims[0] * dims[1] * dims[2]
        var kPoints: [BandKPoint] = []
        for s in 0..<nSpin {
            let off = s < channelOffset.count ? channelOffset[s] : 0
            for ix in 0..<dims[0] {
                for iy in 0..<dims[1] {
                    for iz in 0..<dims[2] {
                        let k = SIMD3<Float>(nodeLists[0][ix], nodeLists[1][iy], nodeLists[2][iz])
                        let x = nodeLists[0][ix], y = nodeLists[1][iy], z = nodeLists[2][iz]
                        let base = bandSlope.0 * x + bandSlope.1 * y + bandSlope.2 * z + off
                        let energies = (0..<nBands).map { base + Float($0) * 5.0 }
                        kPoints.append(BandKPoint(k: k, weight: 1, label: "", energies: energies))
                    }
                }
            }
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: nil, nSpin: nSpin,
                             kPointsAreCrystal: true,
                             kPointsPerSpin: perSpin, isMesh: true, periodicDim: 3)
    }

    /// Shuffle k-points within each channel so detection relies on coordinates,
    /// not input order.
    private static func shuffled(_ bands: BandStructure) -> BandStructure {
        let perSpin = bands.kPointsPerSpin
        let nSpin = bands.nSpin
        var kPoints: [BandKPoint] = []
        for s in 0..<nSpin {
            var channel = Array(bands.kPoints[s * perSpin..<(s + 1) * perSpin])
            channel.shuffle()
            kPoints.append(contentsOf: channel)
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: bands.fermiEnergy, nSpin: nSpin,
                             kPointsAreCrystal: bands.kPointsAreCrystal,
                             kPointsPerSpin: perSpin, isMesh: bands.isMesh,
                             cell: bands.cell, periodicDim: bands.periodicDim)
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    /// SIMD3<Float> equality within tolerance (XCTAssertEqual accuracy: needs Double).
    private static func assertVecEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                       _ tol: Float, _ message: String = "",
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: Float(tol), message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: Float(tol), message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: Float(tol), message, file: file, line: line)
    }

    // MARK: - 1. Grid detection + periodic trilinear interpolation

    func testGridDetectionAndInterpolation() {
        let oneThird: Float = 1.0 / 3.0
        let twoThirds: Float = 2.0 / 3.0
        let nodes: [[Float]] = [[0, oneThird, twoThirds], [0, oneThird, twoThirds], [0, oneThird, twoThirds]]
        let bands = Self.shuffled(Self.makeMesh(nodeLists: nodes, nBands: 2, bandSlope: (1, 2, 3)))

        let grid = try! BandMeshInterpolator.meshGrid(from: bands)
        XCTAssertEqual(grid.dims, [3, 3, 3])
        XCTAssertEqual(grid.pointCount, 27)
        XCTAssertEqual(grid.degenerateAxes, [])
        for a in 0..<3 {
            let expectedRow: [Float] = [0, oneThird, twoThirds]
            XCTAssertEqual(grid.nodes[a].count, expectedRow.count)
            for j in 0..<expectedRow.count {
                XCTAssertEqual(grid.nodes[a][j], expectedRow[j], accuracy: 1e-6)
            }
        }

        // Linear energy (x + 2y + 3z): periodic trilinear interpolation is
        // exact for any query point that does not fall in a periodic
        // wrap-around cell (the test function is not periodic, so cells
        // straddling the 0/1 boundary would alias). Use a point in the
        // interior of the grid's non-wrap cells.
        let perSpin = bands.kPointsPerSpin
        let channel = Array(bands.kPoints[0..<perSpin])
        let values = channel.map { $0.energies[0] }
        let k = SIMD3<Float>(0.25, 0.5, 0.5)
        let expected: Float = 0.25 + 2 * 0.5 + 3 * 0.5 // 2.75
        let v = grid.interpolate(values, at: k)!
        XCTAssertEqual(v, expected, accuracy: 1e-4)

        // Periodic wrap: (1.25, -0.5, 1.5) == (0.25, 0.5, 0.5) mod 1.
        let vWrap = grid.interpolate(values, at: SIMD3<Float>(1.25, -0.5, 1.5))!
        XCTAssertEqual(vWrap, expected, accuracy: 1e-4)

        // 2D slab mesh: z degenerate.
        let slabNodes: [[Float]] = [[0, 0.5], [0, 0.5], [0]]
        let slab = Self.makeMesh(nodeLists: slabNodes, nBands: 1, bandSlope: (1, 1, 0))
        let slabGrid = try! BandMeshInterpolator.meshGrid(from: slab)
        XCTAssertEqual(slabGrid.dims, [2, 2, 1])
        XCTAssertEqual(slabGrid.degenerateAxes, [2])

        // Gamma-centered shifted grid: nodes {1/6, 1/2, 5/6}.
        let sixth: Float = 1.0 / 6.0
        let half: Float = 1.0 / 2.0
        let fiveSixths: Float = 5.0 / 6.0
        let shiftedNodes: [[Float]] = [[sixth, half, fiveSixths],
                                        [sixth, half, fiveSixths],
                                        [sixth, half, fiveSixths]]
        let shifted = Self.makeMesh(nodeLists: shiftedNodes, nBands: 1, bandSlope: (1, 2, 3))
        let shiftedGrid = try! BandMeshInterpolator.meshGrid(from: shifted)
        XCTAssertEqual(shiftedGrid.dims, [3, 3, 3])
        let shiftedExpected: [Float] = [sixth, half, fiveSixths]
        XCTAssertEqual(shiftedGrid.nodes[0].count, shiftedExpected.count)
        for j in 0..<shiftedExpected.count {
            XCTAssertEqual(shiftedGrid.nodes[0][j], shiftedExpected[j], accuracy: 1e-6)
        }

        // Sparse path-like point set (1D along x): not a mesh (only 1 non-degen axis).
        let pathNodes: [[Float]] = [[0, 0.25, 0.5, 0.75], [0], [0]]
        let pathLike = Self.makeMesh(nodeLists: pathNodes, nBands: 1)
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: pathLike)) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .notAxisAlignedGrid)
        }
    }

    // MARK: - 2. Path interpolation

    func testPathInterpolation() {
        let nodes: [[Float]] = [[0, 0.25, 0.5, 0.75],
                                 [0, 0.25, 0.5, 0.75],
                                 [0, 0.25, 0.5, 0.75]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2, bandSlope: (1, 0, 0))
        // Energies: band 0 = x, band 1 = x + 5.

        let path = KPath(points: [
            KPoint(SIMD3<Float>(0, 0, 0), "G"),
            KPoint(SIMD3<Float>(0.5, 0, 0), "X"),
            KPoint(SIMD3<Float>(0.5, 0.5, 0), "M"),
        ], pointsPerSegment: 20)

        let result = try! BandMeshInterpolator.interpolateAlongPath(bands: bands, path: path, pointsPerSegment: 20)
        XCTAssertFalse(result.isMesh)

        let samples = path.interpolated()
        XCTAssertEqual(result.kPointsPerSpin, samples.count)
        XCTAssertEqual(result.nSpin, 1)
        XCTAssertEqual(result.kPoints.count, samples.count)

        // Route labels at endpoints.
        XCTAssertEqual(result.kPoints[0].label, "G")
        XCTAssertEqual(result.kPoints[result.kPoints.count - 1].label, "M")

        // All energies finite and within the mesh energy range.
        for kp in result.kPoints {
            XCTAssertEqual(kp.energies.count, 2)
            XCTAssertTrue(kp.energies[0].isFinite)
            XCTAssertTrue(kp.energies[1].isFinite)
            XCTAssertGreaterThanOrEqual(kp.energies[0], -0.01)
            XCTAssertLessThanOrEqual(kp.energies[0], 0.76)
            XCTAssertGreaterThanOrEqual(kp.energies[1], 4.99)
            XCTAssertLessThanOrEqual(kp.energies[1], 5.76)
        }

        // Adjacent-sample continuity for linear energies.
        for i in 1..<result.kPoints.count {
            let d = abs(result.kPoints[i].energies[0] - result.kPoints[i - 1].energies[0])
            XCTAssertLessThan(d, 0.1)
        }

        // Spin-polarized: each channel interpolates from its own data.
        let spBands = Self.makeMesh(nodeLists: nodes, nBands: 1, nSpin: 2,
                                    bandSlope: (1, 0, 0), channelOffset: [0, 100])
        let spResult = try! BandMeshInterpolator.interpolateAlongPath(bands: spBands, path: path, pointsPerSegment: 10)
        XCTAssertEqual(spResult.nSpin, 2)
        XCTAssertEqual(spResult.kPointsPerSpin, spResult.kPoints.count / 2)
        let perSpin = spResult.kPointsPerSpin
        let mid = perSpin / 2
        let upMid = spResult.kPoints[mid].energies[0]
        let downMid = spResult.kPoints[perSpin + mid].energies[0]
        XCTAssertEqual(downMid - upMid, 100, accuracy: 0.1)
    }

    // MARK: - 3. Surface builder

    func testSurfaceBuilder() {
        // 2D slab mesh (z degenerate): band surfaces are limited to 2D k-grids.
        let nodes: [[Float]] = [[0, 0.25, 0.5, 0.75],
                                [0, 0.25, 0.5, 0.75],
                                [0]]
        // 3 bands: band 0 = x (range [0,0.75]), band 1 = x+5 (range [5,5.75]),
        // band 2 = x+10 (range [10,10.75]).
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 3, bandSlope: (1, 0, 0))
        var bandsWithFermi = bands
        bandsWithFermi.fermiEnergy = 6.0 // just above band 1 max (5.75)

        let region = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(0.5, 0.5, 0)]

        // --- Default fs.x-style ±1 eV window around E_f ---
        // Window [5,7] intersects only band 1 (range [5,5.75]); band 2 starts
        // at 10 and band 0 ends at 0.75.
        let opts = BandSurfaceOptions(maxBands: 16, gridSize: 16)
        let surface = try! BandSurfaceBuilder.build(bands: bandsWithFermi, region: region,
                                                     regionLabels: ["G", "X", "M"], options: opts)

        XCTAssertEqual(surface.region.count, 4)
        XCTAssertEqual(surface.gridSize, 16)
        XCTAssertEqual(surface.spinCount, 1)
        XCTAssertEqual(surface.fermiEnergy, 6.0)
        XCTAssertEqual(surface.sheets.count, 1)
        XCTAssertEqual(surface.sheets[0].band, 1)
        XCTAssertEqual(surface.sheets[0].label, "band 2")
        XCTAssertEqual(surface.sheets[0].values.count, 16 * 16)
        XCTAssertTrue(surface.sheets[0].values.allSatisfy { $0.isFinite })
        XCTAssertTrue(surface.energyMin <= surface.energyMax)

        // 4th corner is the parallelogram completion.
        let p3 = surface.region[3]
        let expectedP3 = region[0] + (region[1] - region[0]) + (region[2] - region[0])
        Self.assertVecEqual(p3, expectedP3, 1e-5)

        // --- bandCount = 1 -> still the window-selected single sheet, band 1 ---
        let oneOpts = BandSurfaceOptions(maxBands: 16, gridSize: 16, bandCount: 1)
        let oneSurface = try! BandSurfaceBuilder.build(bands: bandsWithFermi, region: region,
                                                        regionLabels: ["G", "X", "M"], options: oneOpts)
        XCTAssertEqual(oneSurface.sheets.count, 1)
        XCTAssertEqual(oneSurface.sheets[0].band, 1)

        // An empty window (Ef far from every band) falls back to bandCount
        // closest-to-Ef ordering.
        var distantEf = bandsWithFermi
        distantEf.fermiEnergy = 100
        let fallbackSurface = try! BandSurfaceBuilder.build(
            bands: distantEf, region: region,
            regionLabels: ["G", "X", "M"],
            options: BandSurfaceOptions(maxBands: 16, gridSize: 16))
        // closestBands order [2,1] is re-sorted spin-major/band-minor by build().
        XCTAssertEqual(fallbackSurface.sheets.map(\.band), [1, 2])

        // --- Explicit selectedBands: keys {band 0, band 2} -> sheets [0, 2] ---
        let explicitOpts = BandSurfaceOptions(maxBands: 16, gridSize: 16,
                                              selectedBands: [0 * 10_000 + 0, 0 * 10_000 + 2])
        let explicitSurface = try! BandSurfaceBuilder.build(bands: bandsWithFermi, region: region,
                                                             regionLabels: ["G", "X", "M"], options: explicitOpts)
        XCTAssertEqual(explicitSurface.sheets.count, 2)
        XCTAssertEqual(explicitSurface.sheets[0].band, 0)
        XCTAssertEqual(explicitSurface.sheets[1].band, 2)

        // --- Explicit EMPTY selectedBands -> no sheets (axes only) ---
        let emptyOpts = BandSurfaceOptions(maxBands: 16, gridSize: 16, selectedBands: [])
        let emptySurface = try! BandSurfaceBuilder.build(bands: bandsWithFermi, region: region,
                                                          regionLabels: ["G", "X", "M"], options: emptyOpts)
        XCTAssertTrue(emptySurface.sheets.isEmpty)
        XCTAssertEqual(emptySurface.region.count, 4)
        XCTAssertLessThanOrEqual(emptySurface.energyMin, emptySurface.energyMax)
        XCTAssertTrue(emptySurface.energyMin.isFinite)
        XCTAssertTrue(emptySurface.energyMax.isFinite)

        // --- closestBands ---
        XCTAssertEqual(BandSurfaceBuilder.closestBands(bandsWithFermi, count: 2),
                       [0 * 10_000 + 1, 0 * 10_000 + 2])
        XCTAssertEqual(BandSurfaceBuilder.closestBands(bandsWithFermi, count: 1),
                       [0 * 10_000 + 1])

        // --- bandInfos: Ef=6, windowEV=1.0 -> only band 1 intersects [5,7] ---
        let infos = BandSurfaceBuilder.bandInfos(bandsWithFermi, windowEV: 1.0)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].selectionKey, 0 * 10_000 + 1)
        XCTAssertEqual(infos[0].isOccupied, true)   // maxE 5.75 <= 6
        // bandInfos without E_f -> first maxCandidates bands.
        let infosNoEf = BandSurfaceBuilder.bandInfos(bands)
        XCTAssertEqual(infosNoEf.count, 3)          // all 3 bands, under the 32 cap

        // --- kBasis: cell present -> reciprocal basis in Angstrom^-1 ---
        var bandsWithCell = bandsWithFermi
        bandsWithCell.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        let cellSurface = try! BandSurfaceBuilder.build(bands: bandsWithCell, region: region,
                                                         regionLabels: ["G", "X", "M"], options: opts)
        let kBasis = cellSurface.kBasis!
        XCTAssertEqual(kBasis.count, 3)
        XCTAssertTrue(kBasis.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        // |b*| = 2pi/5 for each axis.
        let expectedLen = 2.0 * Float.pi / 5.0
        for v in kBasis {
            XCTAssertEqual(simd_length(v), expectedLen, accuracy: 1e-3)
        }

        // Error: non-mesh input.
        var nonMesh = bands
        nonMesh.isMesh = false
        XCTAssertThrowsError(try BandSurfaceBuilder.build(bands: nonMesh, region: region,
                                                           regionLabels: ["", "", ""], options: opts)) { err in
            XCTAssertEqual(err as? BandSurfaceError, .notMesh)
        }

        // Error: 3D bulk mesh is rejected — band surfaces require a 2D k-grid.
        let bulkNodes: [[Float]] = [[0, 0.5], [0, 0.5], [0, 0.5]]
        let bulk = Self.makeMesh(nodeLists: bulkNodes, nBands: 3, bandSlope: (1, 0, 0))
        XCTAssertThrowsError(try BandSurfaceBuilder.build(bands: bulk, region: region,
                                                           regionLabels: ["", "", ""], options: opts)) { err in
            XCTAssertEqual(err as? BandSurfaceError, .requiresTwoDimensionalMesh)
        }

        // Error: collinear region.
        let collinear = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(1, 0, 0)]
        XCTAssertThrowsError(try BandSurfaceBuilder.build(bands: bandsWithFermi, region: collinear,
                                                           regionLabels: ["", "", ""], options: opts)) { err in
            XCTAssertEqual(err as? BandSurfaceError, .degenerateRegion)
        }
    }

    // MARK: - 4. Fixture integration

    /// Time-reversal classification by the parser: detection is bound to the
    /// LAST calculation in the file (from the final "Program PWSCF" banner in
    /// either spelling), echoed values are parsed (lspinorb/total
    /// magnetization/atomic moments), and the run MODE only matters when the
    /// calculation is actually magnetized — QE enforces time reversal for
    /// zero-magnetization noncollinear/SOC runs.
    func testParserDetectsTimeReversalBreaking() {
        let fixtureURL = Self.fixtureURL("CH3Rh111.out")
        let raw = try! String(contentsOf: fixtureURL, encoding: .utf8)

        func afterBanner(_ line: String) -> String {
            // Insert right after the "Program PWSCF" banner, inside the last
            // calculation's region (before the first Fermi boundary).
            raw.replacingOccurrences(of: "starts ...",
                                     with: "starts ...\n\(line)")
        }
        func beforeBanner(_ line: String) -> String {
            line + "\n" + raw
        }

        XCTAssertTrue(BandParser.parse(raw)!.timeReversalSymmetric,
                      "non-magnetic fixture must claim TR symmetry")

        // --- Magnetization values, in any mode, break TR ---
        XCTAssertFalse(BandParser.parse(afterBanner("total magnetization      =      1.2345"))!.timeReversalSymmetric,
                       "nonzero net magnetization breaks TR")
        // A zero net magnetization (compensated AFM / unpolarized nspin=2) does
        // NOT, by itself, break TR — the echoed VALUE is parsed.
        XCTAssertTrue(BandParser.parse(afterBanner("total magnetization      =      0.0000"))!.timeReversalSymmetric,
                      "zero net magnetization is not TR-breaking by itself")
        XCTAssertFalse(BandParser.parse(afterBanner("starting_magnetization(2)=0.7"))!.timeReversalSymmetric,
                       "nonzero starting magnetization breaks TR")
        XCTAssertTrue(BandParser.parse(afterBanner("starting_magnetization(1)=0.0"))!.timeReversalSymmetric,
                      "zero starting magnetization is not magnetic")
        // Nonzero atomic moments in the magnetization (x) table break TR.
        let momentTable = """
        magnetization (x)
             atom    1     charge     0.1711     magnetization     0.0282
             atom    2     charge     0.1711     magnetization    -0.0282
        """
        XCTAssertFalse(BandParser.parse(afterBanner(momentTable))!.timeReversalSymmetric,
                       "nonzero atomic moments break TR")
        // A zero-moment table does not.
        let zeroTable = """
        magnetization (x)
             atom    1     charge     0.1711     magnetization     0.0000
        """
        XCTAssertTrue(BandParser.parse(afterBanner(zeroTable))!.timeReversalSymmetric,
                      "zero atomic moments preserve TR")

        // --- Mode alone does not break TR: QE enforces TRS for unmagnetized ---
        // --- noncollinear/SOC runs (zero starting magnetization).          ---
        XCTAssertTrue(BandParser.parse(afterBanner("Noncollinear calculation"))!.timeReversalSymmetric,
                      "unmagnetized noncollinear preserves TR")
        XCTAssertTrue(BandParser.parse(afterBanner("lspinorb = .true."))!.timeReversalSymmetric,
                      "unmagnetized SOC preserves TR")
        XCTAssertTrue(BandParser.parse(afterBanner("lspinorb = .false."))!.timeReversalSymmetric,
                      "lspinorb = .false. preserves TR")
        // Mode + actual magnetization: still TR-breaking.
        XCTAssertFalse(BandParser.parse(afterBanner("lspinorb = .true.\nstarting_magnetization(1)=0.7"))!.timeReversalSymmetric,
                       "magnetized SOC breaks TR")
        XCTAssertFalse(BandParser.parse(afterBanner("Noncollinear calculation\ntotal magnetization      =      1.2345"))!.timeReversalSymmetric,
                       "magnetized noncollinear breaks TR")

        // --- Markers of an EARLIER calculation must not veto the last one ---
        // The fixture's banner sits at the top; text prepended before it belongs
        // to a previous calculation and must be ignored.
        XCTAssertTrue(BandParser.parse(beforeBanner("total magnetization      =      1.2345"))!.timeReversalSymmetric,
                      "an earlier calculation's markers must not veto the selected mesh")
        XCTAssertTrue(BandParser.parse(beforeBanner("lspinorb = .true."))!.timeReversalSymmetric,
                      "an earlier calculation's SOC flag must not veto the selected mesh")

        // --- The bare "Program PWSCF v.6.7" banner form (si_scf.out) is a ---
        // --- calculation boundary too, and the "stops" exit line is not.  ---
        let v67Body = raw.replacingOccurrences(of: "     Program PWSCF 1.2.0  starts ...", with: "")
        let v67Earlier = "total magnetization      =      9.9999\nProgram PWSCF v.6.7\n" + v67Body
        XCTAssertTrue(BandParser.parse(v67Earlier)!.timeReversalSymmetric,
                      "markers before the v.6.7 banner belong to an earlier run")
        let v67Inside = "Program PWSCF v.6.7\n" + v67Body.replacingOccurrences(
            of: "Today is", with: "total magnetization      =      9.9999\n     Today is")
        XCTAssertFalse(BandParser.parse(v67Inside)!.timeReversalSymmetric,
                       "markers after the v.6.7 banner are inside the selected calculation")
        // The exit line must not be mistaken for a new calculation boundary.
        let withStops = "total magnetization      =      9.9999\n" + raw
            + "\n     Program PWSCF 1.2.0  stops ...\n"
        XCTAssertTrue(BandParser.parse(withStops)!.timeReversalSymmetric,
                      "the stops line must not re-scope the calculation")
    }

    /// Restarted/concatenated QE outputs can print several "reciprocal axes"
    /// blocks; the LAST complete one must win (matching the final band iteration
    /// and last real-space cell the parser selects). A stale earlier block must
    /// not leak into the reciprocal basis.
    func testFixtureReciprocalUsesLastBlock() {
        let fixtureURL = Self.fixtureURL("CH3Rh111.out")
        let raw = try! String(contentsOf: fixtureURL, encoding: .utf8)
        // Prepend a stale reciprocal-axes block with an unmistakable basis.
        let stale = """
        reciprocal axes: (cart. coord. in units 2 pi/a_0)
                     b(1) = (   7.0000   7.0000   7.0000 )
                     b(2) = (   7.0000   7.0000   7.0000 )
                     b(3) = (   7.0000   7.0000   7.0000 )

        """
        guard let parsed = BandParser.parse(stale + raw) else {
            return XCTFail("QE mesh fixture should parse")
        }
        let recip = parsed.reciprocal
        XCTAssertEqual(recip?.count, 3)
        // The LAST (real) block wins: b1 = (1.0, 0.5774, 0.0), b3.z = 0.3704.
        XCTAssertEqual(recip?[0].x ?? 0, 1.0, accuracy: 1e-3)
        XCTAssertEqual(recip?[0].y ?? 0, 0.5774, accuracy: 1e-3)
        XCTAssertEqual(recip?[0].z ?? 0, 0.0, accuracy: 1e-3)
        XCTAssertEqual(recip?[2].z ?? 0, 0.3704, accuracy: 1e-3)
    }

    func testFixtureIntegration() {
        let fixtureURL = Self.fixtureURL("CH3Rh111.out")
        let raw = try! String(contentsOf: fixtureURL, encoding: .utf8)
        guard let parsed = BandParser.parse(raw) else {
            return XCTFail("QE mesh fixture should parse")
        }
        XCTAssertTrue(parsed.isMesh)
        XCTAssertEqual(parsed.periodicDim, 3)

        let grid = try! BandMeshInterpolator.meshGrid(from: parsed)
        // CH3Rh111.out is a TR-reduced half mesh: x={0.125,0.375} is the half of a
        // 4x4x1 grid. meshGrid unfolds it to 16 points; kPointsPerSpin stays 8.
        XCTAssertEqual(grid.pointCount, 16)
        XCTAssertEqual(grid.dims, [4, 4, 1])
        let xNodes: [Float] = [0.125, 0.375, 0.625, 0.875]
        XCTAssertEqual(grid.nodes[0].count, xNodes.count)
        for j in 0..<xNodes.count {
            XCTAssertEqual(grid.nodes[0][j], xNodes[j], accuracy: 1e-3)
        }

        // Path interpolation over the SC canonical path succeeds with finite energies.
        let path = KPath.defaultPath(lattice: .sc)
        let result = try! BandMeshInterpolator.interpolateAlongPath(bands: parsed, path: path, pointsPerSegment: 12)
        XCTAssertFalse(result.isMesh)
        XCTAssertTrue(result.kPoints.count > 0)
        for kp in result.kPoints {
            XCTAssertTrue(kp.energies.allSatisfy { $0.isFinite })
        }

        // Surface builder with defaultRegion. CH3Rh111.out reports a Fermi
        // energy, so the fs.x-style ±1 eV window selects the 27 bands that
        // intersect [Ef-1, Ef+1]; maxBands=16 caps them at the first 16
        // (0-based band indices 41...56).
        guard let region = BandSurfaceBuilder.defaultRegion(path: path) else {
            return XCTFail("SC path should yield a default region")
        }
        XCTAssertEqual(region.count, 3)
        let labels = BandSurfaceBuilder.regionLabels(for: path, region: region)
        XCTAssertEqual(labels.count, 4)
        let opts = BandSurfaceOptions(maxBands: 16, gridSize: 24)
        let surface = try! BandSurfaceBuilder.build(bands: parsed, region: region,
                                                     regionLabels: Array(labels.prefix(3)), options: opts)
        XCTAssertEqual(surface.region.count, 4)
        if parsed.fermiEnergy != nil {
            XCTAssertEqual(surface.sheets.count, 16)
            XCTAssertEqual(surface.sheets.first?.band, 41)
            XCTAssertEqual(surface.sheets.last?.band, 56)
        } else {
            XCTAssertTrue(surface.sheets.count > 0)
        }
        XCTAssertTrue(surface.sheets.allSatisfy { $0.values.allSatisfy { $0.isFinite } })
    }
}
