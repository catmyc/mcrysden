import XCTest
import simd
@testable import MolVisApp

// Integration tests for the k-path import feature across SideBarState,
// MainWindowController, App.applyKPathImport, CLI argument parsing, and the
// export -> import round trip for the existing QE/VASP writers.
@MainActor
final class KPathImportIntegrationTests: XCTestCase {

    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kpath-integ-\(UUID().uuidString)-\(name)")
    }

    private func writeTemp(_ text: String, _ name: String) -> URL {
        let url = tempURL(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    /// A small real crystal scene (cubic cell + 1 atom) so `cell != nil`.
    private func crystalScene() -> Scene {
        Scene(loaded: try! Parser.load(fixture("si110.xsf")))
    }

    /// A molecule scene (cell == nil).
    private func moleculeScene() -> Scene {
        Scene(loaded: try! Parser.load(fixture("h2o.xyz")))
    }

    // MARK: - SideBarState.importKPath

    func testSideBarStateImportSetsRouteAndProvenance() {
        let s = SideBarState()
        s.kPathPoints = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0, 0), "X")]
        s.kPathBreaks = []
        s.kPathProvenance = .generated
        s.kPathSignature = "orig-sig"

        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        s.importKPath(points: imported, breaks: [0])

        XCTAssertEqual(s.kPathPoints, imported)
        XCTAssertEqual(s.kPathBreaks, [0])
        XCTAssertEqual(s.kPathProvenance, .userEdited)
        XCTAssertNil(s.kPathSignature)
        XCTAssertTrue(s.canUndo, "import must push an undo entry")
    }

    func testSideBarStateImportUndoRestoresPreImportRoute() {
        let s = SideBarState()
        let original = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0, 0), "X")]
        s.kPathPoints = original
        s.kPathBreaks = [0]
        s.kPathProvenance = .generated
        s.kPathSignature = "orig-sig"

        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        s.importKPath(points: imported, breaks: [])
        XCTAssertEqual(s.kPathPoints, imported)

        s.undoLast()
        XCTAssertEqual(s.kPathPoints, original)
        XCTAssertEqual(s.kPathBreaks, [0])
        XCTAssertEqual(s.kPathProvenance, .generated)
        XCTAssertEqual(s.kPathSignature, "orig-sig")
    }

    func testSideBarStateImportEmptyIsNoOp() {
        let s = SideBarState()
        let original = [KPoint(SIMD3(0, 0, 0), "G")]
        s.kPathPoints = original
        s.kPathBreaks = []
        s.kPathProvenance = .generated
        s.kPathSignature = "sig"
        XCTAssertFalse(s.canUndo)

        s.importKPath(points: [], breaks: [])

        XCTAssertEqual(s.kPathPoints, original, "empty import must not change the route")
        XCTAssertEqual(s.kPathBreaks, [])
        XCTAssertEqual(s.kPathProvenance, .generated)
        XCTAssertEqual(s.kPathSignature, "sig")
        XCTAssertFalse(s.canUndo, "empty import must not push an undo entry")
    }

    // MARK: - MainWindowController.importKPath

    func testControllerImportKPathCrystal() throws {
        let scene = crystalScene()
        XCTAssertNotNil(scene.cell, "test fixture must be a crystal")
        let c = MainWindowController(scene: scene, showWindow: false)

        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0, 0), "X"),
                        KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        let kpf = try KPathExport.export(KPath(points: imported, pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        try c.importKPath(from: url)

        XCTAssertEqual(c.scene.kPathPoints.count, imported.count)
        for (a, b) in zip(c.scene.kPathPoints, imported) {
            XCTAssertTrue(allComponentsEqual(a.frac, b.frac, 1e-4))
        }
        XCTAssertEqual(c.scene.kPathProvenance, .userEdited)
        XCTAssertNil(c.scene.kPathSignature)
        XCTAssertEqual(c.state.kPathPoints.count, imported.count)
        XCTAssertEqual(c.state.kPathProvenance, .userEdited)
    }

    func testControllerImportKPathMoleculeThrowsNotAPath() throws {
        let scene = moleculeScene()
        XCTAssertNil(scene.cell, "test fixture must be a molecule")
        let c = MainWindowController(scene: scene, showWindow: false)

        let kpf = try KPathExport.export(KPath(points: [KPoint(SIMD3(0, 0, 0), "G")], pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try c.importKPath(from: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    func testControllerImportKPathUndoRestoresStateRoute() throws {
        let scene = crystalScene()
        let c = MainWindowController(scene: scene, showWindow: false)
        let s = c.state

        // Capture the seeded route (full identity: geometry, breaks, provenance,
        // and signature).
        let originalPoints = s.kPathPoints
        let originalBreaks = s.kPathBreaks
        let originalProvenance = s.kPathProvenance
        let originalSignature = s.kPathSignature
        XCTAssertFalse(originalPoints.isEmpty, "crystal must seed a default route")

        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        let kpf = try KPathExport.export(KPath(points: imported, pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        try c.importKPath(from: url)
        XCTAssertEqual(s.kPathPoints.count, imported.count)

        // Undo restores the pre-import route in the sidebar state...
        s.undoLast()
        XCTAssertEqual(s.kPathPoints, originalPoints, "undo must restore the pre-import route")
        XCTAssertEqual(s.kPathBreaks, originalBreaks)
        XCTAssertEqual(s.kPathProvenance, originalProvenance)
        XCTAssertEqual(s.kPathSignature, originalSignature)
        // ...and the scene must mirror the restored identity through syncFromState.
        XCTAssertEqual(c.scene.kPathPoints, originalPoints, "scene must mirror the restored route")
        XCTAssertEqual(c.scene.kPathBreaks, originalBreaks)
        XCTAssertEqual(c.scene.kPathProvenance, originalProvenance)
        XCTAssertEqual(c.scene.kPathSignature, originalSignature)
    }

    // MARK: - App.applyKPathImport

    func testApplyKPathImportCrystal() throws {
        var scene = crystalScene()
        XCTAssertNotNil(scene.cell)

        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0, 0), "X")]
        let kpf = try KPathExport.export(KPath(points: imported, pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        var kPathSampling = 20
        try App.applyKPathImport(to: &scene, from: url, kPathSampling: &kPathSampling)

        XCTAssertEqual(scene.kPathPoints.count, imported.count)
        for (a, b) in zip(scene.kPathPoints, imported) {
            XCTAssertTrue(allComponentsEqual(a.frac, b.frac, 1e-4))
        }
        XCTAssertEqual(scene.kPathProvenance, .userEdited)
        XCTAssertNil(scene.kPathSignature)
    }

    func testApplyKPathImportMoleculeThrows() throws {
        var scene = moleculeScene()
        XCTAssertNil(scene.cell)

        let kpf = try KPathExport.export(KPath(points: [KPoint(SIMD3(0, 0, 0), "G")], pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        var kPathSampling = 20
        XCTAssertThrowsError(try App.applyKPathImport(to: &scene, from: url, kPathSampling: &kPathSampling)) { err in
            guard case App.CLIError.invalid(let msg) = err else {
                return XCTFail("expected CLIError.invalid, got \(err)")
            }
            XCTAssertTrue(msg.contains("crystal"), "error should mention crystal, got \(msg)")
        }
    }

    func testApplyKPathImportOverridesGeneratedRoute() throws {
        var scene = crystalScene()
        // Simulate a generated route already present.
        let generated = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0, 0), "X"),
                         KPoint(SIMD3(0.5, 0.5, 0), "M")]
        scene.kPathPoints = generated
        scene.kPathBreaks = []
        scene.kPathProvenance = .generated
        scene.kPathSignature = "gen-sig"

        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        let kpf = try KPathExport.export(KPath(points: imported, pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        var kPathSampling = 20
        try App.applyKPathImport(to: &scene, from: url, kPathSampling: &kPathSampling)

        XCTAssertEqual(scene.kPathPoints.count, imported.count, "import must override the generated route")
        XCTAssertEqual(scene.kPathProvenance, .userEdited)
        XCTAssertNil(scene.kPathSignature)
    }

    // MARK: - Imported pointsPerSegment propagation

    func testControllerImportVASPClampsSamplingLow() throws {
        let scene = crystalScene()
        let c = MainWindowController(scene: scene, showWindow: false)
        let content = """
        title
        1
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        defer { try? FileManager.default.removeItem(at: url) }
        try c.importKPath(from: url)
        XCTAssertEqual(c.state.kPathSampling, 2, "N=1 must clamp up to 2")
    }

    func testControllerImportVASPClampsSamplingHigh() throws {
        let scene = crystalScene()
        let c = MainWindowController(scene: scene, showWindow: false)
        let content = """
        title
        5000
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        defer { try? FileManager.default.removeItem(at: url) }
        try c.importKPath(from: url)
        XCTAssertEqual(c.state.kPathSampling, 200, "N=5000 must clamp down to 200")
    }

    func testControllerImportVASPSamplingN40() throws {
        let scene = crystalScene()
        let c = MainWindowController(scene: scene, showWindow: false)
        let content = """
        title
        40
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        defer { try? FileManager.default.removeItem(at: url) }
        try c.importKPath(from: url)
        XCTAssertEqual(c.state.kPathSampling, 40, "N=40 passes through unchanged")
    }

    func testControllerImportKPFPreservesSampling() throws {
        let scene = crystalScene()
        let c = MainWindowController(scene: scene, showWindow: false)
        c.state.kPathSampling = 137

        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        let kpf = try KPathExport.export(KPath(points: imported, pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        try c.importKPath(from: url)
        XCTAssertEqual(c.state.kPathSampling, 137, "KPF import must preserve the existing sampling")
    }

    func testApplyKPathImportKPFPreservesSampling() throws {
        var scene = crystalScene()
        let imported = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0.5, 0.5), "L")]
        let kpf = try KPathExport.export(KPath(points: imported, pointsPerSegment: 20), as: .kpf)
        let url = writeTemp(kpf, "route.kpf")
        defer { try? FileManager.default.removeItem(at: url) }

        var kPathSampling = 137
        try App.applyKPathImport(to: &scene, from: url, kPathSampling: &kPathSampling)
        XCTAssertEqual(kPathSampling, 137, "KPF import must preserve the existing sampling")
    }

    // MARK: - CLI state-vs-import precedence

    func testStateRouteAndSamplingLoseToCLIImport() throws {
        // A companion state file restores a user route (G-L | X, three points with
        // a break at index 1) and sampling 100; the --kpath import (VASP N=40,
        // connected G-X) must win on BOTH the route identity and the sampling.
        // The saved route differs from the imported one in endpoint AND break
        // topology, so the "import wins" assertion is observable, not vacuous.
        // Exercises App.loadScene's production ordering (state first, import
        // last) instead of a test-side mirror.
        let base = crystalScene()
        var saved = base
        saved.kPathPoints = [KPoint(SIMD3(0, 0, 0), "G"),
                             KPoint(SIMD3(0.5, 0.5, 0.5), "L"),
                             KPoint(SIMD3(0.5, 0, 0), "X")]
        saved.kPathBreaks = [1]
        saved.kPathProvenance = .userEdited
        saved.kPathSignature = nil
        let stateURL = tempURL("state.mvis-state")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        try StateStore.save(saved, camera: nil, sourceURL: fixture("si110.xsf"),
                            to: stateURL, kPathSampling: 100)

        let content = """
        title
        40
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let kpathURL = writeTemp(content, "KPOINTS")
        defer { try? FileManager.default.removeItem(at: kpathURL) }

        var kPathSampling = 20
        let (scene, _) = try App.loadScene(from: fixture("si110.xsf"), format: nil, cliFrame: -1,
                                           stateURL: stateURL, kPathImportURL: kpathURL,
                                           kPathSampling: &kPathSampling)

        XCTAssertEqual(scene.kPathPoints.count, 2, "final route must be the imported G-X, not the saved 3-point route")
        XCTAssertTrue(allComponentsEqual(scene.kPathPoints[0].frac, SIMD3(0, 0, 0), 1e-3))
        XCTAssertTrue(allComponentsEqual(scene.kPathPoints[1].frac, SIMD3(0.5, 0, 0), 1e-3))
        XCTAssertTrue(scene.kPathBreaks.isEmpty, "imported connected route must have no breaks; the saved break must not survive")
        XCTAssertEqual(scene.kPathProvenance, .userEdited, "imported route must win over the state route")
        XCTAssertNil(scene.kPathSignature)
        XCTAssertEqual(kPathSampling, 40, "VASP import sampling must beat the state-restored sampling")
    }

    // MARK: - CLI parseArguments --kpath

    func testCLIKPathImportURLSet() throws {
        let opts = try App.parseArguments(["file.cif", "--kpath", "route.kpf"])
        XCTAssertEqual(opts.kPathImportURL?.lastPathComponent, "route.kpf")
        XCTAssertEqual(opts.inputURL?.lastPathComponent, "file.cif")
    }

    func testCLIKPathMissingValue() {
        XCTAssertThrowsError(try App.parseArguments(["file.cif", "--kpath"]))
    }

    func testCLIKPathDuplicateRejected() {
        XCTAssertThrowsError(try App.parseArguments(["file.cif", "--kpath", "a.kpf", "--kpath", "b.kpf"]))
    }

    func testCLIKPathWithoutInputFile() {
        XCTAssertThrowsError(try App.parseArguments(["--kpath", "route.kpf"])) { err in
            guard case App.CLIError.invalid(let msg) = err else {
                return XCTFail("expected CLIError.invalid, got \(err)")
            }
            XCTAssertTrue(msg.contains("structure file is required"), "got \(msg)")
        }
    }

    func testCLIKPathAliasesInputFile() {
        XCTAssertThrowsError(try App.parseArguments(["file.cif", "--kpath", "file.cif"])) { err in
            guard case App.CLIError.invalid(let msg) = err else {
                return XCTFail("expected CLIError.invalid, got \(err)")
            }
            XCTAssertTrue(msg.contains("aliases"), "got \(msg)")
        }
    }

    func testCLIKPathAliasesStateFile() {
        XCTAssertThrowsError(try App.parseArguments(["file.cif", "state.mvis-state", "--kpath", "state.mvis-state"])) { err in
            guard case App.CLIError.invalid(let msg) = err else {
                return XCTFail("expected CLIError.invalid, got \(err)")
            }
            XCTAssertTrue(msg.contains("aliases"), "got \(msg)")
        }
    }

    // MARK: - Existing export writers round-trip through KPathImport

    func testQEExportRoundTripsThroughImport() throws {
        // pointsPerSegment = 2 makes interpolated() return the route's own points
        // (one sample per endpoint, no interior samples) so the count is stable.
        let route = KPath(points: [KPoint(SIMD3(0, 0, 0), "G"),
                                    KPoint(SIMD3(0.5, 0, 0), "X"),
                                    KPoint(SIMD3(0.5, 0.5, 0.5), "L")],
                           pointsPerSegment: 2)
        // The writer emits only the card body (count + k-point lines); wrap it in
        // the K_POINTS card line so the text is a real QE input fragment.
        let text = "K_POINTS crystal\n" + KPathExport.qeKPointsCrystal(route)
        let url = writeTemp(text, "scf.in")
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try KPathImport.parse(text: text, url: url)

        // Geometry preserved (first/last points match the route endpoints).
        XCTAssertFalse(parsed.points.isEmpty)
        XCTAssertTrue(allComponentsEqual(parsed.points.first!.frac, SIMD3(0, 0, 0), 1e-3))
        XCTAssertTrue(allComponentsEqual(parsed.points.last!.frac, SIMD3(0.5, 0.5, 0.5), 1e-3))
        // QE writer emits interpolated points; the import parser accepts them all.
        XCTAssertEqual(parsed.pointsPerSegment, 20)
        XCTAssertTrue(parsed.breaks.isEmpty)
    }

    func testVASPExportRoundTripsThroughImport() throws {
        // A connected route: G-X-M (shared endpoints → continuous, no breaks).
        let route = KPath(points: [KPoint(SIMD3(0, 0, 0), "G"),
                                    KPoint(SIMD3(0.5, 0, 0), "X"),
                                    KPoint(SIMD3(0.5, 0.5, 0), "M")],
                           pointsPerSegment: 20)
        let text = try KPathExport.vaspKPoints(route)
        let url = writeTemp(text, "KPOINTS")
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try KPathImport.parse(text: text, url: url)

        // VASP emits endpoint pairs with the shared endpoint duplicated: G,X,X,M →
        // 4 coords assembled into 2 segments sharing X. Coalescing merges the
        // shared X, so the result is 3 points [G,X,M], continuous, no breaks.
        XCTAssertEqual(parsed.points.count, 3, "shared endpoint coalesces, got \(parsed.points.map(\.frac))")
        XCTAssertTrue(parsed.breaks.isEmpty, "connected route must have no breaks")
        XCTAssertTrue(allComponentsEqual(parsed.points[0].frac, SIMD3(0, 0, 0), 1e-3))
        XCTAssertTrue(allComponentsEqual(parsed.points[1].frac, SIMD3(0.5, 0, 0), 1e-3))
        XCTAssertTrue(allComponentsEqual(parsed.points[2].frac, SIMD3(0.5, 0.5, 0), 1e-3))
        // Labels survive the round trip: the writer emits "x y z ! label" suffix
        // labels, which the importer must recover on re-parse.
        XCTAssertEqual(parsed.points[0].label, "G")
        XCTAssertEqual(parsed.points[1].label, "X")
        XCTAssertEqual(parsed.points[2].label, "M")
    }

    func testVASPExportDisconnectedPreservesBreaks() throws {
        // G-X | M-G (break at index 1). Two disconnected single-edge components.
        let route = KPath(points: [KPoint(SIMD3(0, 0, 0), "G"),
                                    KPoint(SIMD3(0.5, 0, 0), "X"),
                                    KPoint(SIMD3(0.5, 0.5, 0), "M"),
                                    KPoint(SIMD3(0, 0, 0), "G")],
                           pointsPerSegment: 20, breaks: [1])
        let text = try KPathExport.vaspKPoints(route)
        let url = writeTemp(text, "KPOINTS")
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try KPathImport.parse(text: text, url: url)

        // Pairs: G,X and M,G — not sharing an endpoint → break at index 1.
        XCTAssertEqual(parsed.points.count, 4)
        XCTAssertEqual(parsed.breaks, [1], "disconnected segments must preserve the break")
    }
}
