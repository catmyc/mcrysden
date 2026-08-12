import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for the electronic-structure CLI flags: parseArguments matrix,
/// applyElectronicStructureFlags on synthetic and real meshes, and the
/// parser-level computeMeshDOS gating.
final class ElectronicFlagsCLITests: XCTestCase {

    // MARK: - Synthetic mesh builder

    /// Build a 2x2x2 axis-aligned mesh (8 k-points) with crystal coords and
    /// energies linear in x+y+z so interpolation is exact and deterministic.
    private func makeSyntheticMesh(kPathPoints: [KPoint] = []) -> (Scene, BandStructure) {
        var kps: [BandKPoint] = []
        let values: [[Float]] = [
            [0, 1, 2, 3],
            [1, 2, 3, 4],
            [2, 3, 4, 5],
            [3, 4, 5, 6],
            [4, 5, 6, 7],
            [5, 6, 7, 8],
            [6, 7, 8, 9],
            [7, 8, 9, 10],
        ]
        var idx = 0
        for i in 0..<2 {
            for j in 0..<2 {
                for k in 0..<2 {
                    let frac = SIMD3(Float(i), Float(j), Float(k)) / 2
                    kps.append(BandKPoint(k: frac, weight: 1.0 / 8, label: "",
                                          energies: values[idx]))
                    idx += 1
                }
            }
        }
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        let bands = BandStructure(kPoints: kps, fermiEnergy: 5.0, nSpin: 1,
                                   kPointsAreCrystal: true, kPointsPerSpin: 8,
                                   isMesh: true, cell: cell, periodicDim: 3)
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
        let (scene, _) = makeSyntheticMesh(kPathPoints: route)

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
