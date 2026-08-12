import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for the electronic-structure CLI flags: parseArguments matrix,
/// applyElectronicStructureFlags on synthetic and real meshes, and the
/// parser-level computeMeshDOS gating.
final class ElectronicFlagsCLITests: XCTestCase {

    // MARK: - Synthetic mesh builder

    /// Build an axis-aligned mesh with the given per-axis node lists (crystal
    /// coords), energies linear in x+y+z per band (4 bands). Defaults to a 2D
    /// slab mesh (z degenerate); periodicDim follows the mesh dimensionality
    /// (2 for slabs, 3 for bulk) so DOS normalization uses the right measure.
    private func makeSyntheticMesh(
        nodeLists: [[Float]] = [[0, 0.5], [0, 0.5], [0]],
        kPathPoints: [KPoint] = []
    ) -> (Scene, BandStructure) {
        let perSpin = nodeLists[0].count * nodeLists[1].count * nodeLists[2].count
        var kps: [BandKPoint] = []
        kps.reserveCapacity(perSpin)
        for x in nodeLists[0] {
            for y in nodeLists[1] {
                for z in nodeLists[2] {
                    let k = SIMD3(x, y, z)
                    let base = x + y + z
                    kps.append(BandKPoint(k: k, weight: 1.0 / Float(perSpin), label: "",
                                          energies: (0..<4).map { base + Float($0) }))
                }
            }
        }
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        let meshDim = nodeLists.filter { $0.count > 1 }.count
        let bands = BandStructure(kPoints: kps, fermiEnergy: 5.0, nSpin: 1,
                                   kPointsAreCrystal: true, kPointsPerSpin: perSpin,
                                   isMesh: true, cell: cell,
                                   periodicDim: meshDim >= 3 ? 3 : 2)
        var scene = Scene()
        scene.bandStructure = bands
        scene.kPathPoints = kPathPoints
        return (scene, bands)
    }

    // MARK: - parseArguments matrix

    func testParseArgumentsMatrix() throws {
        // --bands -> format == .bands && bandPlot
        var opts = try App.parseArguments(["x.out", "--bands"])
        XCTAssertEqual(opts.format, .bands)
        XCTAssertTrue(opts.bandPlot)
        XCTAssertFalse(opts.dosPlot)
        XCTAssertFalse(opts.bandSurf)

        // --dos -> dosPlot && format nil
        opts = try App.parseArguments(["x.out", "--dos"])
        XCTAssertNil(opts.format)
        XCTAssertTrue(opts.dosPlot)
        XCTAssertFalse(opts.bandPlot)

        // --band-surf -> bandSurf
        opts = try App.parseArguments(["x.out", "--band-surf"])
        XCTAssertTrue(opts.bandSurf)
        XCTAssertFalse(opts.bandPlot)

        // Duplicate --bands throws
        XCTAssertThrowsError(try App.parseArguments(["x.out", "--bands", "--bands"]))
        // Duplicate --dos throws
        XCTAssertThrowsError(try App.parseArguments(["x.out", "--dos", "--dos"]))
        // Duplicate --band-surf throws
        XCTAssertThrowsError(try App.parseArguments(["x.out", "--band-surf", "--band-surf"]))

        // --bands --band-surf throws
        XCTAssertThrowsError(try App.parseArguments(["x.out", "--bands", "--band-surf"]))

        // Each flag without an input file throws
        XCTAssertThrowsError(try App.parseArguments(["--bands"]))
        XCTAssertThrowsError(try App.parseArguments(["--dos"]))
        XCTAssertThrowsError(try App.parseArguments(["--band-surf"]))

        // --dos-table -> format == .dos
        opts = try App.parseArguments(["x.out", "--dos-table"])
        XCTAssertEqual(opts.format, .dos)
        XCTAssertFalse(opts.dosPlot)
    }

    // MARK: - applyElectronicStructureFlags on a synthetic mesh

    func testApplyFlagsOnSyntheticMesh() throws {
        // With k-path route for interpolation / surface derivation.
        let route = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0, 0), "X"),
                     KPoint(SIMD3(0.5, 0.5, 0), "M")]
        let (scene, mesh) = makeSyntheticMesh(kPathPoints: route)

        // dosPlot -> densityOfStates non-nil with source == .bandMesh
        var dosScene = scene
        try App.applyElectronicStructureFlags(
            scene: &dosScene,
            flags: ElectronicStructureFlags(bandPlot: false, dosPlot: true, bandSurf: false),
            kPathSampling: 20)
        XCTAssertNotNil(dosScene.densityOfStates)
        XCTAssertEqual(dosScene.densityOfStates?.metadata.source, .bandMesh)

        // bandPlot -> interpolated non-mesh BandStructure with more points and G label
        var bandScene = scene
        try App.applyElectronicStructureFlags(
            scene: &bandScene,
            flags: ElectronicStructureFlags(bandPlot: true, dosPlot: false, bandSurf: false),
            kPathSampling: 20)
        guard let bs = bandScene.bandStructure else {
            return XCTFail("bandStructure should be present after interpolation")
        }
        XCTAssertFalse(bs.isMesh)
        XCTAssertGreaterThan(bs.kPointsPerSpin, 8)
        XCTAssertTrue(bs.kPoints.contains { $0.label == "G" })

        // bandSurf -> non-nil surface with 4 region corners
        var surfScene = scene
        try App.applyElectronicStructureFlags(
            scene: &surfScene,
            flags: ElectronicStructureFlags(bandPlot: false, dosPlot: false, bandSurf: true),
            kPathSampling: 20)
        XCTAssertNotNil(surfScene.bandSurface)
        XCTAssertEqual(surfScene.bandSurface?.region.count, 4)
        XCTAssertTrue(surfScene.showBandSurface)

        // NEW DEFAULT: 2 bands closest to E_f (Ef=5.0; band 3 at d=1, band 2 at d=2).
        // Sheets are spin-major/band-minor ordered, so [2, 3].
        XCTAssertEqual(surfScene.bandSurface?.sheets.count, 2)
        XCTAssertEqual(surfScene.bandSurface?.sheets.map(\.band), [2, 3])

        // Explicit selection via BandSurfaceBuilder directly: pick band 1.
        var opts = BandSurfaceOptions()
        opts.selectedBands = [0 * 10_000 + 1]
        let singleBand = try BandSurfaceBuilder.build(
            bands: mesh,
            region: [SIMD3(0, 0, 0), SIMD3(0.5, 0, 0), SIMD3(0.5, 0.5, 0)],
            regionLabels: ["G", "X", "M"],
            options: opts)
        XCTAssertEqual(singleBand.sheets.map(\.band), [1])
        // Empty selection -> no sheets, region still has 4 corners.
        var emptyOpts = BandSurfaceOptions()
        emptyOpts.selectedBands = []
        let emptySheets = try BandSurfaceBuilder.build(
            bands: mesh,
            region: [SIMD3(0, 0, 0), SIMD3(0.5, 0, 0), SIMD3(0.5, 0.5, 0)],
            regionLabels: ["G", "X", "M"],
            options: emptyOpts)
        XCTAssertTrue(emptySheets.sheets.isEmpty)
        XCTAssertEqual(emptySheets.region.count, 4)

        // closestBands: distance order (band 3 closest, then band 2).
        XCTAssertEqual(BandSurfaceBuilder.closestBands(mesh, count: 2),
                       [0 * 10_000 + 3, 0 * 10_000 + 2])

        // bandInfos: window [1,9] intersects all 4 bands; keys + labels correct.
        let infos = BandSurfaceBuilder.bandInfos(mesh, windowEV: 4.0)
        XCTAssertEqual(infos.count, 4)
        XCTAssertTrue(infos.allSatisfy {
            $0.selectionKey == $0.spin * 10_000 + $0.band && $0.label.contains("band")
        })

        // Controller round trip: install a default-built surface, then pick band 0.
        var controllerScene = Scene()
        controllerScene.bandStructure = mesh
        controllerScene.bandSurface = surfScene.bandSurface
        let wc = MainWindowController(scene: controllerScene, showWindow: false)
        wc.state.bandSurfaceBandSelection = [0 * 10_000 + 0]
        XCTAssertEqual(wc.scene.bandSurface?.sheets.map(\.band), [0])
        XCTAssertEqual(wc.state.bandSurfaceEffectiveSelection, [0 * 10_000 + 0])

        // Error: flags with no bandStructure throw
        var emptyScene = Scene()
        XCTAssertThrowsError(try App.applyElectronicStructureFlags(
            scene: &emptyScene,
            flags: ElectronicStructureFlags(bandPlot: true, dosPlot: false, bandSurf: false),
            kPathSampling: 20))
        XCTAssertThrowsError(try App.applyElectronicStructureFlags(
            scene: &emptyScene,
            flags: ElectronicStructureFlags(bandPlot: false, dosPlot: false, bandSurf: true),
            kPathSampling: 20))

        // bandSurf on a 3D bulk mesh is rejected: band surfaces are limited
        // to 2D k-grid samplings. The CLI error carries the requirement.
        let bulkNodes: [[Float]] = [[0, 0.5], [0, 0.5], [0, 0.5]]
        var bulkScene = makeSyntheticMesh(nodeLists: bulkNodes, kPathPoints: route).0
        XCTAssertThrowsError(try App.applyElectronicStructureFlags(
            scene: &bulkScene,
            flags: ElectronicStructureFlags(bandPlot: false, dosPlot: false, bandSurf: true),
            kPathSampling: 20)) { error in
            XCTAssertTrue("\(error)".contains("2D"),
                          "3D mesh must be rejected with a 2D requirement, got: \(error)")
        }
    }

    // MARK: - Parser gating with a real fixture

    func testParserGatingWithFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CH3Rh111.out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path),
                      "fixture must exist")

        // Default load -> bandStructure parsed but no DOS.
        let defaultLoad = try Parser.load(fixtureURL, as: .bands)
        XCTAssertNotNil(defaultLoad.bandStructure)
        XCTAssertNil(defaultLoad.densityOfStates,
                     "default load must NOT derive mesh DOS")

        // computeMeshDOS: true -> DOS is derived.
        let withDOS = try Parser.load(fixtureURL, as: .bands, computeMeshDOS: true)
        XCTAssertNotNil(withDOS.bandStructure)
        XCTAssertNotNil(withDOS.densityOfStates,
                        "computeMeshDOS: true must derive mesh DOS")
    }

    // MARK: - applyElectronicStructureFlags with a REAL parsed mesh

    func testApplyFlagsOnRealMesh() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CH3Rh111.out")
        let raw = try String(contentsOf: fixtureURL, encoding: .utf8)
        guard let parsed = BandParser.parse(raw) else {
            return XCTFail("QE mesh fixture should parse")
        }
        XCTAssertTrue(parsed.isMesh)

        var scene = Scene()
        scene.bandStructure = parsed
        scene.kPathPoints = [KPoint(SIMD3(0, 0, 0), "G"),
                             KPoint(SIMD3(0.5, 0, 0), "X"),
                             KPoint(SIMD3(0.5, 0.5, 0), "M")]

        // bandPlot on a real mesh -> interpolated non-mesh BandStructure
        try App.applyElectronicStructureFlags(
            scene: &scene,
            flags: ElectronicStructureFlags(bandPlot: true, dosPlot: false, bandSurf: false),
            kPathSampling: 20)
        guard let bs = scene.bandStructure else {
            return XCTFail("bandStructure should be present after interpolation")
        }
        XCTAssertFalse(bs.isMesh)
        XCTAssertTrue(bs.kPoints.allSatisfy { kp in
            kp.energies.allSatisfy(\.isFinite)
        }, "all interpolated energies must be finite")
    }
}
