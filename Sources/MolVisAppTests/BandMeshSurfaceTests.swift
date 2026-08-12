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
        // 3 bands: band 0 = x (range [0,0.75]), band 1 = x+4 (range [4,4.75]),
        // band 2 = x+10 (range [10,10.75]).
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 3, bandSlope: (1, 0, 0))
        var bandsWithFermi = bands
        bandsWithFermi.fermiEnergy = 6.0 // just above band 1 max (5.75)

        let region = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(0.5, 0.5, 0)]
        let opts = BandSurfaceOptions(energyWindowEV: 1.0, maxBands: 16, gridSize: 16)
        let surface = try! BandSurfaceBuilder.build(bands: bandsWithFermi, region: region,
                                                     regionLabels: ["G", "X", "M"], options: opts)

        XCTAssertEqual(surface.region.count, 4)
        XCTAssertEqual(surface.gridSize, 16)
        XCTAssertEqual(surface.spinCount, 1)
        XCTAssertEqual(surface.fermiEnergy, 6.0)
        // Only band 1 intersects [5.0, 7.0].
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

        // Error: tiny window selecting nothing.
        let tinyOpts = BandSurfaceOptions(energyWindowEV: 0.001, maxBands: 16, gridSize: 8)
        XCTAssertThrowsError(try BandSurfaceBuilder.build(bands: bandsWithFermi, region: region,
                                                           regionLabels: ["", "", ""], options: tinyOpts)) { err in
            XCTAssertEqual(err as? BandSurfaceError, .noBandsNearFermi)
        }
    }

    // MARK: - 4. Fixture integration

    func testFixtureIntegration() {
        let fixtureURL = Self.fixtureURL("CH3Rh111.out")
        let raw = try! String(contentsOf: fixtureURL, encoding: .utf8)
        guard let parsed = BandParser.parse(raw) else {
            return XCTFail("QE mesh fixture should parse")
        }
        XCTAssertTrue(parsed.isMesh)
        XCTAssertEqual(parsed.periodicDim, 3)

        let grid = try! BandMeshInterpolator.meshGrid(from: parsed)
        XCTAssertEqual(grid.pointCount, parsed.kPointsPerSpin)

        // Path interpolation over the SC canonical path succeeds with finite energies.
        let path = KPath.defaultPath(lattice: .sc)
        let result = try! BandMeshInterpolator.interpolateAlongPath(bands: parsed, path: path, pointsPerSegment: 12)
        XCTAssertFalse(result.isMesh)
        XCTAssertTrue(result.kPoints.count > 0)
        for kp in result.kPoints {
            XCTAssertTrue(kp.energies.allSatisfy { $0.isFinite })
        }

        // Surface builder with defaultRegion.
        guard let region = BandSurfaceBuilder.defaultRegion(path: path) else {
            return XCTFail("SC path should yield a default region")
        }
        XCTAssertEqual(region.count, 3)
        let labels = BandSurfaceBuilder.regionLabels(for: path, region: region)
        XCTAssertEqual(labels.count, 4)
        let opts = BandSurfaceOptions(energyWindowEV: 3.0, maxBands: 16, gridSize: 24)
        let surface = try! BandSurfaceBuilder.build(bands: parsed, region: region,
                                                     regionLabels: Array(labels.prefix(3)), options: opts)
        XCTAssertEqual(surface.region.count, 4)
        XCTAssertTrue(surface.sheets.count > 0)
        XCTAssertTrue(surface.sheets.allSatisfy { $0.values.allSatisfy { $0.isFinite } })
    }
}
