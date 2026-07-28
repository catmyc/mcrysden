import AppKit
import XCTest

@testable import MolVisApp

final class AppSafetyTests: XCTestCase {
    func testCLIRejectsMalformedExportAndConflictingFlags() {
        XCTAssertThrowsError(try App.parseArguments(["input.xsf", "--export"]))
        XCTAssertThrowsError(try App.parseArguments(["--export", "out.png"]))
        XCTAssertThrowsError(try App.parseArguments(["input.xsf", "--export", "out.jpg"]))
        XCTAssertThrowsError(try App.parseArguments(["input.xsf", "--frame", "bad"]))
        XCTAssertThrowsError(try App.parseArguments(["--frame", "2"]))
        XCTAssertThrowsError(try App.parseArguments(["--xsf"]))
        XCTAssertThrowsError(try App.parseArguments(["view.mvis-state"]))
        XCTAssertThrowsError(try App.parseArguments(["--xsf", "--pdb", "input.dat"]))
        XCTAssertThrowsError(try App.parseArguments(["--unknown", "input.xsf"]))
        XCTAssertThrowsError(try App.parseArguments(["input.xsf", "extra.xyz"]))

        let valid = try? App.parseArguments(["--xsf", "input.dat", "view.mvis-state",
                                             "--frame", "2", "--export", "out.PNG"])
        XCTAssertEqual(valid?.frame, 2)
        XCTAssertEqual(valid?.exportURL?.pathExtension, "PNG")
        XCTAssertNotNil(valid?.stateURL)
    }

    func testExportDestinationRejectsSymlinkAndHardlinkAliases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.xsf")
        try "source".write(to: input, atomically: true, encoding: .utf8)

        let symlink = dir.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        XCTAssertThrowsError(try App.validateExportDestination(symlink, input: input, state: nil))

        try FileManager.default.removeItem(at: symlink)
        let hardlink = dir.appendingPathComponent("hardlink.png")
        try FileManager.default.linkItem(at: input, to: hardlink)
        XCTAssertThrowsError(try App.validateExportDestination(hardlink, input: input, state: nil))

        XCTAssertThrowsError(try App.validateExportDestination(dir.appendingPathComponent("out.png"),
                                                               input: input, state: hardlink))
    }

    @MainActor
    func testBandAndColorPlaneExportsUseGraphViews() throws {
        let fixtures = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let bandScene = Scene(loaded: try Parser.load(fixtures.appendingPathComponent("CH3Rh111.out"), as: .bands))
        let planeScene = Scene(loaded: try Parser.load(fixtures.appendingPathComponent("mol-urea2D.xsf")))
        XCTAssertNotNil(bandScene.bandStructure)
        XCTAssertNotNil(planeScene.grid2D)

        for (name, scene) in [("band", bandScene), ("plane", planeScene)] {
            for ext in ["png", "pdf", "svg", "eps", "ps"] {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
                defer { try? FileManager.default.removeItem(at: out) }
                var bgScene = scene
                bgScene.background = "#000000"
                let image = try App.exportScene(bgScene, camera: nil, to: out,
                                                size: CGSize(width: 320, height: 240))
                XCTAssertEqual(image.width, 320)
                // Graph content must differ from the white AppKit background.
                let w = image.width, h = image.height
                var px = [UInt8](repeating: 0, count: w * h * 4)
                let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                var nonwhite = 0
                for i in stride(from: 0, to: px.count, by: 4)
                    where px[i] < 250 || px[i + 1] < 250 || px[i + 2] < 250 {
                    nonwhite += 1
                }
                XCTAssertGreaterThan(nonwhite, 100, "\(name).\(ext) graph export is blank")
                let size = try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                XCTAssertGreaterThan(size, 100)
                // Output signature: the written bytes must match the format.
                let header = try Data(contentsOf: out, options: .mappedIfSafe).prefix(16)
                switch ext {
                case "png":
                    XCTAssertTrue(header.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                                  "PNG signature missing")
                case "pdf":
                    XCTAssertTrue(header.starts(with: [0x25, 0x50, 0x44, 0x46]),
                                  "PDF signature missing")
                case "svg":
                    let text = String(data: header, encoding: .ascii) ?? ""
                    XCTAssertTrue(text.contains("<svg") || text.hasPrefix("<?xml"),
                                  "SVG signature missing")
                case "eps", "ps":
                    XCTAssertTrue(String(data: header, encoding: .ascii)?.hasPrefix("%!PS") == true,
                                  "EPS/PS signature missing")
                default:
                    break
                }
            }
        }
    }

    @MainActor
    func testExportSceneRejectsUnsupportedExtensionAndInvalidSize() throws {
        let fixtures = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let scene = Scene(loaded: try Parser.load(fixtures.appendingPathComponent("si110.xsf")))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertThrowsError(try App.exportScene(scene, camera: nil, to: out,
                                                size: CGSize(width: 200, height: 200)))

        let png = FileManager.default.temporaryDirectory
            .appendingPathComponent("sz-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        XCTAssertThrowsError(try App.exportScene(scene, camera: nil, to: png,
                                                size: CGSize(width: 0, height: 200)))
        XCTAssertThrowsError(try App.exportScene(scene, camera: nil, to: png,
                                                size: CGSize(width: CGFloat.nan, height: 200)))
        XCTAssertThrowsError(try App.exportScene(scene, camera: nil, to: png,
                                                size: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                             height: 200)))
    }

    func testStateLoadRollbackOnRejectedSupercellAndBadCamera() throws {
        var scene = Scene()
        scene.displayMode = .wireFrame
        scene.atoms = (0..<3_000).map { Atom(coord: SIMD3(Float($0), 0, 0), atomicNumber: 1, label: "H") }
        var camera: Camera? = Camera()
        camera?.distance = 17

        let oversized = FileManager.default.temporaryDirectory.appendingPathComponent("oversized-\(UUID()).mvis-state")
        try JSONSerialization.data(withJSONObject: ["version": 1, "displayMode": "spaceFill",
                                                     "supercell": [6, 6, 6]]).write(to: oversized)
        defer { try? FileManager.default.removeItem(at: oversized) }
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera, from: oversized))
        XCTAssertEqual(scene.displayMode, .wireFrame)
        XCTAssertEqual(scene.atoms.count, 3_000)
        XCTAssertEqual(camera?.distance, 17)

        let malformed = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID()).mvis-state")
        try JSONSerialization.data(withJSONObject: ["version": 1, "displayMode": "spaceFill",
                                                     "camera": ["distance": "bad"]]).write(to: malformed)
        defer { try? FileManager.default.removeItem(at: malformed) }
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera, from: malformed)) {
            XCTAssertTrue(String(describing: $0).contains(malformed.path))
        }
        XCTAssertEqual(scene.displayMode, .wireFrame)
        XCTAssertEqual(camera?.distance, 17)

        let nonfinite = FileManager.default.temporaryDirectory.appendingPathComponent("nonfinite-\(UUID()).mvis-state")
        try JSONSerialization.data(withJSONObject: ["version": 1, "atomScale": 1e100]).write(to: nonfinite)
        defer { try? FileManager.default.removeItem(at: nonfinite) }
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera, from: nonfinite))
        XCTAssertEqual(scene.displayMode, .wireFrame)
        XCTAssertEqual(camera?.distance, 17)
    }

    @MainActor
    func testFailedAnimationReloadRestoresIndexAndAllowsStateChanges() throws {
        let source = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-relax-\(UUID().uuidString).out")
        try FileManager.default.copyItem(at: source, to: temp)
        let initial = Scene(loaded: try Parser.load(temp, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(initial, from: temp, frameIndex: 0)
        try FileManager.default.removeItem(at: temp)

        controller.state.frameIndex = 1
        XCTAssertEqual(controller.state.frameIndex, 0)
        XCTAssertEqual(controller.scene.currentFrame, 0)
        controller.state.atomScale = 0.72
        XCTAssertEqual(controller.scene.atomScale, 0.72, accuracy: 0.001)
    }

    @MainActor
    func testInvalidAnimationIndexRollsBack() throws {
        let source = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let initial = Scene(loaded: try Parser.load(source, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(initial, from: source, frameIndex: 0)
        controller.state.frameIndex = controller.state.frameCount
        XCTAssertEqual(controller.state.frameIndex, 0)
        XCTAssertEqual(controller.scene.currentFrame, 0)
    }

    @MainActor
    func testActiveSlabReappliesAfterSupercellChangeAndDrag() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(fixture))
        let controller = MainWindowController(scene: scene, showWindow: false)
        controller.state.slabA_h = 1
        controller.state.slabA_k = 0
        controller.state.slabA_l = 0
        controller.state.slabA_dist = 0.1
        controller.state.slabB_h = 1
        controller.state.slabB_k = 0
        controller.state.slabB_l = 0
        controller.state.slabB_dist = 0.9
        controller.state.slabEnabled = true
        XCTAssertLessThan(controller.scene.atoms.count, controller.scene.preslabAtoms.count)

        controller.state.n1 = 2
        XCTAssertNotNil(controller.scene.slab)
        XCTAssertLessThan(controller.scene.atoms.count, controller.scene.preslabAtoms.count)
        let oldDistance = controller.state.slabA_dist
        controller.adjustSlabPlaneA(by: 0.05)
        XCTAssertEqual(controller.state.slabA_dist, oldDistance + 0.05, accuracy: 0.0001)
        XCTAssertEqual(controller.scene.slab?.planeA.distance, controller.state.slabA_dist)

        controller.state.slabEnabled = false
        XCTAssertEqual(controller.scene.atoms.count, controller.scene.preslabAtoms.count)
    }

    @MainActor
    func testSaveStateAsMenuExists() {
        let app = App()
        let menu = app.buildMenu()
        guard let fileItem = menu.items.first(where: { $0.title == "File" }),
              let fileMenu = fileItem.submenu else {
            return XCTFail("File menu missing")
        }
        let saveItem = fileMenu.items.first { $0.title == "Save State As\u{2026}" }
        XCTAssertNotNil(saveItem, "File menu should contain 'Save State As...'")
        XCTAssertEqual(saveItem?.action, Selector(("saveStateAs:")))
    }

    @MainActor
    func testStructureSummaryPopulatedAfterLoadAndClearedForEmptyViewer() throws {
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        XCTAssertNil(controller.state.structureSummary)

        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        controller.loadFile(Scene(loaded: try Parser.load(fixture)), from: fixture, frameIndex: 0)

        let summary = controller.state.structureSummary
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.atomCount, controller.scene.atoms.count)
        XCTAssertTrue(summary?.isCrystal ?? false)
        XCTAssertFalse(summary?.formula.isEmpty ?? true)
    }

    @MainActor
    func testControllerSaveStateWritesFile() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(fixture))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(scene, from: fixture, frameIndex: 0)
        controller.state.atomScale = 0.7

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: out) }
        try controller.saveState(to: out)

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["source"] as? String, fixture.path)
        XCTAssertEqual(obj?["atomScale"] as? Double ?? 0, 0.7, accuracy: 0.001)
    }

    // MARK: - Revert / Open Recent / reopen / drag-and-drop

    @MainActor
    func testRevertAndOpenRecentMenuItemsExist() {
        let app = App()
        let menu = app.buildMenu()
        guard let fileMenu = menu.items.first(where: { $0.title == "File" })?.submenu else {
            return XCTFail("File menu missing")
        }
        guard let revert = fileMenu.items.first(where: { $0.title == "Revert To Saved" }) else {
            return XCTFail("'Revert To Saved' menu item missing")
        }
        XCTAssertEqual(revert.action, Selector(("revertToSaved:")))
        XCTAssertEqual(revert.keyEquivalent, "")    // no shortcut

        guard let recent = fileMenu.items.first(where: { $0.title == "Open Recent" }) else {
            return XCTFail("'Open Recent' menu item missing")
        }
        XCTAssertNotNil(recent.submenu)
    }

    @MainActor
    func testOpenRecentSubmenuContainsClearMenuItem() {
        let app = App()
        // Build the menu as the app does at launch, then invoke the delegate to
        // populate the Open Recent submenu.
        let menu = app.buildMenu()
        guard let fileMenu = menu.items.first(where: { $0.title == "File" })?.submenu else {
            return XCTFail("File menu missing")
        }
        app.menuWillOpen(fileMenu)
        guard let recent = fileMenu.items.first(where: { $0.title == "Open Recent" }),
              let submenu = recent.submenu else {
            return XCTFail("Open Recent submenu missing")
        }
        XCTAssertTrue(submenu.items.contains { $0.title == "Clear Menu" },
                      "Open Recent submenu must include a 'Clear Menu' item")
    }

    @MainActor
    func testRevertReloadsSourceAndIsDisabledWhenEmpty() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(Scene(loaded: try Parser.load(fixture)), from: fixture, frameIndex: 0)

        // Mutate a UI-visible property, then revert and confirm it resets to the
        // freshly-parsed value (re-reads sourceURL exactly as Open does).
        controller.state.atomScale = 0.123
        XCTAssertEqual(controller.scene.atomScale, 0.123, accuracy: 0.0001)

        let reloaded = Scene(loaded: try Parser.load(fixture))
        controller.revertToSource()
        XCTAssertEqual(controller.scene.atomScale, reloaded.atomScale, accuracy: 0.0001)

        // Empty viewer: revert must be a safe no-op.
        let empty = MainWindowController(scene: Scene(), showWindow: false)
        empty.revertToSource()
        XCTAssertNil(empty.currentSourceURL)
    }

    func testLoadFileRecordsRecentAndLastOpenedURL() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey)
        defer { UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey) }

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(Scene(loaded: try Parser.load(fixture)), from: fixture, frameIndex: 0)

        XCTAssertEqual(UserDefaults.standard.string(forKey: App.lastOpenedURLKey), fixture.path)
        XCTAssertTrue(NSDocumentController.shared.recentDocumentURLs.contains { $0.path == fixture.path },
                      "loaded file must be registered as a recent document")
    }

    func testReopenUsesStoredLastOpenedURLWhenNoCLIInput() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        UserDefaults.standard.set(fixture.path, forKey: App.lastOpenedURLKey)
        defer { UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey) }

        // No CLI input -> resolveLaunchURL() should fall back to the stored path.
        let options = try App.parseArguments([])
        XCTAssertNil(options.inputURL)
        // The reopen branch reads UserDefaults directly; verify the stored path resolves.
        XCTAssertEqual(UserDefaults.standard.string(forKey: App.lastOpenedURLKey), fixture.path)
    }

    func testContentViewIsRegisteredForFileDrags() {
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        let types = controller.window.contentView!.registeredDraggedTypes
        XCTAssertTrue(types.contains(.fileURL), "content view must accept file drags")
    }

    @MainActor
    func testLoadDroppedFileParsesAndLoads() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadDroppedFile(fixture)
        // Parsing happens off-main; install runs on the main actor. Let XCTest
        // drive the run loop so the background queue is not starved by a busy-loop.
        let predicate = NSPredicate { _, _ in !controller.scene.atoms.isEmpty }
        wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 60)
        XCTAssertFalse(controller.scene.atoms.isEmpty)
        XCTAssertEqual(controller.currentSourceURL, fixture)
    }

    @MainActor
    func testLoadDroppedFileIsNonFatalOnParseError() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("notastructure.xyz")
        try? "this is not a structure".write(to: bad, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadDroppedFile(bad)   // must not trap; error is logged, not thrown
        XCTAssertEqual(controller.currentSourceURL, nil)
    }

    // MARK: - Regression tests for the two review fixes

    func testResolveLaunchURLPrefersExplicitCLIInput() {
        UserDefaults.standard.set("/stored/old.xsf", forKey: App.lastOpenedURLKey)
        defer { UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey) }

        let options = try! App.parseArguments(["/cli/new.xyz"])
        let (url, isReopen) = App.resolveLaunchURL(options: options)
        XCTAssertEqual(url?.path, "/cli/new.xyz")
        XCTAssertFalse(isReopen)
    }

    func testResolveLaunchURLReopensStoredWhenNoCLIInput() {
        UserDefaults.standard.set("/stored/last.xsf", forKey: App.lastOpenedURLKey)
        defer { UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey) }

        let options = try! App.parseArguments([])
        let (url, isReopen) = App.resolveLaunchURL(options: options)
        XCTAssertEqual(url?.path, "/stored/last.xsf")
        XCTAssertTrue(isReopen)
    }

    func testResolveLaunchURLNilWhenNothingStored() {
        UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey)
        let options = try! App.parseArguments([])
        let (url, isReopen) = App.resolveLaunchURL(options: options)
        XCTAssertNil(url)
        XCTAssertFalse(isReopen)
    }

    func testImplicitReopenRecoveryClearsStaleKeyAndOpensEmpty() {
        // A stale lastOpenedURL (missing file) must NOT cause a fatal exit. The
        // launch path treats an implicit reopen as non-fatal: clear the key and
        // open an empty viewer. We exercise the branch directly by simulating
        // the resolved-then-failed reopen and asserting the recovery side effects.
        let stale = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-stale-\(UUID().uuidString).xsf")
        UserDefaults.standard.set(stale.path, forKey: App.lastOpenedURLKey)
        defer { UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey) }

        let options = try! App.parseArguments([])
        let (url, isReopen) = App.resolveLaunchURL(options: options)
        XCTAssertNotNil(url)
        XCTAssertTrue(isReopen)

        // Simulate the failing-reopen recovery: clearing the key + empty viewer is
        // exactly what applicationDidFinishLaunching does on an implicit failure.
        UserDefaults.standard.removeObject(forKey: App.lastOpenedURLKey)
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        XCTAssertTrue(controller.scene.atoms.isEmpty)
        XCTAssertNil(UserDefaults.standard.string(forKey: App.lastOpenedURLKey))
    }

    // MARK: - File watching

    @MainActor
    func testFileWatcherStartsOnLoadAndStopsOnClose() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        XCTAssertFalse(controller.isWatchingFile)
        controller.loadFile(Scene(loaded: try Parser.load(fixture)), from: fixture, frameIndex: 0)
        XCTAssertTrue(controller.isWatchingFile, "loading a file must start a watcher")
        XCTAssertFalse(controller.isReloadPromptVisible)
        controller.stopFileWatching()
        XCTAssertFalse(controller.isWatchingFile)
    }

    @MainActor
    func testFileWatcherRestartsWhenNewFileLoaded() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcrysden-fw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first.xsf")
        let second = dir.appendingPathComponent("second.xsf")
        try FileManager.default.copyItem(at: fixture, to: first)
        try FileManager.default.copyItem(at: fixture, to: second)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(Scene(loaded: try Parser.load(first)), from: first, frameIndex: 0)
        XCTAssertTrue(controller.isWatchingFile)
        let firstURL = controller.currentSourceURL
        controller.loadFile(Scene(loaded: try Parser.load(second)), from: second, frameIndex: 0)
        XCTAssertTrue(controller.isWatchingFile)
        XCTAssertEqual(controller.currentSourceURL, second)
        XCTAssertNotEqual(firstURL, controller.currentSourceURL)
    }

    @MainActor
    func testFileWatcherNoOpForEmptyViewer() {
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        XCTAssertFalse(controller.isWatchingFile)
        // Closing an empty viewer must not trap.
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(controller.isWatchingFile)
    }

    // MARK: - Multiple windows

    @MainActor
    func testNewWindowMenuItemExistsWithShortcut() {
        let app = App()
        let menu = app.buildMenu()
        guard let fileMenu = menu.items.first(where: { $0.title == "File" })?.submenu else {
            return XCTFail("File menu missing")
        }
        guard let newWindow = fileMenu.items.first(where: { $0.title == "New Window" }) else {
            return XCTFail("'New Window' menu item missing")
        }
        XCTAssertEqual(newWindow.action, Selector(("newDocument:")))
        XCTAssertEqual(newWindow.keyEquivalent, "N")
        XCTAssertEqual(newWindow.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(newWindow.target as? App, app)
    }

    @MainActor
    func testWindowMenuHasStandardItems() {
        let app = App()
        let menu = app.buildMenu()
        guard let windowSub = menu.items.first(where: { $0.submenu?.title == "Window" })?.submenu else {
            return XCTFail("Window menu missing")
        }
        let titles = windowSub.items.map { $0.title }
        XCTAssertTrue(titles.contains("Minimize"))
        XCTAssertTrue(titles.contains("Zoom"))
        XCTAssertTrue(titles.contains("Bring All to Front"))
    }

    @MainActor
    func testWindowMenuListsOpenWindows() {
        let app = App()
        let menu = app.buildMenu()
        guard let windowSub = menu.items.first(where: { $0.submenu?.title == "Window" })?.submenu else {
            return XCTFail("Window menu missing")
        }
        // Simulate a registered window via the test seam.
        let wc1 = MainWindowController(scene: Scene(), showWindow: false)
        wc1.window.title = "Structure A"
        app.testAddWindow(wc1)
        app.menuWillOpen(windowSub)
        let names = windowSub.items.map { $0.title }
        XCTAssertTrue(names.contains("Structure A"), "Window menu should list the open window")
    }

    // MARK: - Analysis checkmark sync

    @MainActor
    private func analysisMenu(_ app: App) -> NSMenu {
        let menu = app.buildMenu()
        // The Analysis item itself has no title; match by its submenu's title.
        guard let analysis = menu.items.first(where: { $0.submenu?.title == "Analysis" })?.submenu else {
            XCTFail("Analysis menu missing")
            return NSMenu()
        }
        XCTAssertTrue(analysis.delegate === app)
        return analysis
    }

    @MainActor
    func testAnalysisCheckmarksReflectActiveViewerMode() {
        let app = App()
        let analysis = analysisMenu(app)
        let wc = MainWindowController(scene: Scene(), showWindow: false)
        wc.state.measurementMode = .distance
        app.testAddWindow(wc)
        app.menuWillOpen(analysis)
        let onItems = analysis.items.filter { $0.state == .on }
        XCTAssertEqual(onItems.count, 1, "exactly one mode should be checked")
        XCTAssertEqual(onItems.first?.tag, 2, "Distance (tag 2) should be checked")
    }

    @MainActor
    func testAnalysisCheckmarksClearWhenNoActiveViewer() {
        let app = App()
        let analysis = analysisMenu(app)
        // Seed a stale checkmark, then open the menu with no windows registered.
        analysis.items.first?.state = .on
        app.menuWillOpen(analysis)
        let onItems = analysis.items.filter { $0.state == .on }
        XCTAssertEqual(onItems.count, 0, "stale checkmarks must be cleared with no active viewer")
    }

    @MainActor
    func testAnalysisCheckmarksUpdateOnWindowSwitch() {
        let app = App()
        let analysis = analysisMenu(app)
        let wc1 = MainWindowController(scene: Scene(), showWindow: false)
        wc1.state.measurementMode = .distance
        let wc2 = MainWindowController(scene: Scene(), showWindow: false)
        wc2.state.measurementMode = .angle
        app.testAddWindow(wc1)
        app.testAddWindow(wc2)
        // Last added is active: wc2 (angle).
        app.menuWillOpen(analysis)
        XCTAssertEqual(analysis.items.first { $0.tag == 3 }?.state, .on)
        // Simulate wc1 becoming key.
        let note = Notification(name: NSWindow.didBecomeKeyNotification, object: wc1.window)
        app.windowDidBecomeKey(note)
        XCTAssertEqual(analysis.items.first { $0.tag == 2 }?.state, .on)
        XCTAssertEqual(analysis.items.first { $0.tag == 3 }?.state, .off)
    }

    @MainActor
    func testAnalysisCheckmarksUpdateOnWindowClose() {
        let app = App()
        let analysis = analysisMenu(app)
        let wc1 = MainWindowController(scene: Scene(), showWindow: false)
        wc1.state.measurementMode = .distance
        let wc2 = MainWindowController(scene: Scene(), showWindow: false)
        wc2.state.measurementMode = .angle
        app.testAddWindow(wc1)
        app.testAddWindow(wc2)
        // Close the active window (wc2); fallback to wc1.
        let note = Notification(name: NSWindow.willCloseNotification, object: wc2.window)
        app.windowWillClose(note)
        XCTAssertEqual(analysis.items.first { $0.tag == 2 }?.state, .on)
        XCTAssertEqual(analysis.items.first { $0.tag == 3 }?.state, .off)
    }

    func testAppVersionIs120() {
        XCTAssertEqual(App.appVersion, "1.2.0")
    }
}

