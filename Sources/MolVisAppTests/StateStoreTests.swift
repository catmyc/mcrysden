import Foundation
import simd
import XCTest
@testable import MolVisApp
final class StateStoreTests: XCTestCase {
    @MainActor
    func testStateRoundTrip() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        // Load atoms from source (what happens on app start)...
        var s = Scene(loaded: try Parser.load(url))
        s.atomScale = 0.7
        s.displayMode = .spaceFill
        s.showBrillouinZone = true
        var cam = Camera()
        cam.distance = 42
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-state-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let assertCameraFields: (Camera, SIMD3<Float>, Float, simd_quatf, Bool) -> Void = {
            actual, center, distance, rotation, perspective in
            XCTAssertEqual(actual.center.x, center.x)
            XCTAssertEqual(actual.center.y, center.y)
            XCTAssertEqual(actual.center.z, center.z)
            XCTAssertEqual(actual.distance, distance)
            XCTAssertEqual(actual.perspective, perspective)
            XCTAssertEqual(simd_length(actual.rotation.vector), 1, accuracy: 1e-5)
            XCTAssertEqual(actual.rotation.vector.x, rotation.vector.x, accuracy: 1e-5)
            XCTAssertEqual(actual.rotation.vector.y, rotation.vector.y, accuracy: 1e-5)
            XCTAssertEqual(actual.rotation.vector.z, rotation.vector.z, accuracy: 1e-5)
            XCTAssertEqual(actual.rotation.vector.w, rotation.vector.w, accuracy: 1e-5)
        }

        var bookmarkCamera0 = Camera()
        bookmarkCamera0.center = SIMD3<Float>(1.25, -2.5, 3.75)
        bookmarkCamera0.distance = 17.25
        bookmarkCamera0.rotation = simd_quatf(ix: 1, iy: 2, iz: 3, r: 4)
        bookmarkCamera0.perspective = true
        let bookmarkRotation0 = simd_normalize(bookmarkCamera0.rotation)
        var bookmarkCamera2 = Camera()
        bookmarkCamera2.center = SIMD3<Float>(-4, 5, -6)
        bookmarkCamera2.distance = 8.5
        bookmarkCamera2.perspective = false
        let bookmarks: [CameraBookmark?] = [
            CameraBookmark(name: "  Main view \n", camera: bookmarkCamera0),
            nil,
            CameraBookmark(name: "\tSide view  ", camera: bookmarkCamera2),
        ]
        // ...then save view-state + source path + camera (the flat spec format).
        try StateStore.save(s, camera: cam, sourceURL: url, to: tmp,
                            cameraBookmarks: bookmarks)
        // Reload: re-parse the source for atoms, then apply saved view-state.
        var s2 = Scene(loaded: try Parser.load(url))
        var c2: Camera? = nil
        var restoredBookmarks: [CameraBookmark?] = []
        try StateStore.load(into: &s2, camera: &c2,
                            cameraBookmarks: &restoredBookmarks, from: tmp)
        // Atoms come from the re-parsed source...
        XCTAssertEqual(s2.atoms.count, s.atoms.count)
        // ...view-state and camera round-trip from the state file.
        XCTAssertEqual(s2.atomScale, 0.7, accuracy: 0.0001)
        XCTAssertEqual(s2.displayMode, .spaceFill)
        XCTAssertTrue(s2.showBrillouinZone)
        guard let restoredCamera = c2 else {
            return XCTFail("expected the saved camera")
        }
        assertCameraFields(restoredCamera, cam.center, cam.distance, cam.rotation, cam.perspective)

        guard restoredBookmarks.count == CameraBookmark.slotCount,
              let first = restoredBookmarks[0],
              restoredBookmarks[1] == nil,
              let third = restoredBookmarks[2] else {
            return XCTFail("expected three bookmark slots with the middle slot empty")
        }
        XCTAssertEqual(first.name, "Main view")
        XCTAssertEqual(third.name, "Side view")
        assertCameraFields(first.camera, bookmarkCamera0.center, bookmarkCamera0.distance,
                           bookmarkRotation0, bookmarkCamera0.perspective)
        assertCameraFields(third.camera, bookmarkCamera2.center, bookmarkCamera2.distance,
                           bookmarkCamera2.rotation, bookmarkCamera2.perspective)

        let controllerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-controller-state-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: controllerURL) }
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        var controllerCamera = Camera()
        controllerCamera.center = SIMD3<Float>(-7, 8, 9)
        controllerCamera.distance = 31.5
        controllerCamera.rotation = simd_quatf(ix: 0, iy: 1, iz: 0, r: 2)
        controllerCamera.perspective = true
        let controllerRotation = simd_normalize(controllerCamera.rotation)
        controller.camera = controllerCamera
        controller.state.setCameraBookmarkName(at: 0, to: "  Controller view  ")
        XCTAssertTrue(controller.saveCameraBookmark(at: 0))
        XCTAssertTrue(controller.state.cameraBookmarkIsAvailable(at: 0))
        guard let savedBookmark = controller.cameraBookmarks[0] else {
            return XCTFail("expected the controller bookmark to be occupied")
        }
        XCTAssertEqual(savedBookmark.name, "Controller view")
        assertCameraFields(savedBookmark.camera, controllerCamera.center, controllerCamera.distance,
                           controllerRotation, controllerCamera.perspective)

        // The controller's document save must carry its runtime bookmark slots.
        try controller.saveState(to: controllerURL)
        var savedScene = Scene()
        var savedControllerCamera: Camera? = nil
        var savedControllerBookmarks: [CameraBookmark?] = []
        try StateStore.load(into: &savedScene, camera: &savedControllerCamera,
                            cameraBookmarks: &savedControllerBookmarks, from: controllerURL)
        guard savedControllerBookmarks.count == CameraBookmark.slotCount,
              let persistedBookmark = savedControllerBookmarks[0],
              let persistedCamera = savedControllerCamera else {
            return XCTFail("expected controller camera state and bookmark persistence")
        }
        XCTAssertNil(savedControllerBookmarks[1])
        XCTAssertNil(savedControllerBookmarks[2])
        XCTAssertEqual(persistedBookmark.name, "Controller view")
        assertCameraFields(persistedBookmark.camera, controllerCamera.center,
                           controllerCamera.distance, controllerRotation,
                           controllerCamera.perspective)
        assertCameraFields(persistedCamera, controllerCamera.center, controllerCamera.distance,
                           controllerRotation, controllerCamera.perspective)

        // Invalid indices must be harmless while the valid slot remains intact.
        XCTAssertFalse(controller.saveCameraBookmark(at: -1))
        XCTAssertFalse(controller.saveCameraBookmark(at: CameraBookmark.slotCount))
        XCTAssertFalse(controller.recallCameraBookmark(at: -1))
        XCTAssertFalse(controller.recallCameraBookmark(at: CameraBookmark.slotCount))
        let savedName = controller.state.cameraBookmarkName(at: 0)
        controller.clearCameraBookmark(at: -1)
        controller.clearCameraBookmark(at: CameraBookmark.slotCount)
        XCTAssertNotNil(controller.cameraBookmarks[0])
        XCTAssertEqual(controller.state.cameraBookmarkName(at: 0), savedName)

        // Recall restores every camera field, normalizes the stored quaternion,
        // and mirrors projection into the sidebar's orthographic toggle.
        var alteredCamera = controllerCamera
        alteredCamera.center = SIMD3<Float>(100, 101, 102)
        alteredCamera.distance = 4
        alteredCamera.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        alteredCamera.perspective = false
        controller.camera = alteredCamera
        XCTAssertTrue(controller.recallCameraBookmark(at: 0))
        assertCameraFields(controller.camera, controllerCamera.center, controllerCamera.distance,
                           controllerRotation, controllerCamera.perspective)
        assertCameraFields(controller.scene.camera, controllerCamera.center,
                           controllerCamera.distance, controllerRotation,
                           controllerCamera.perspective)
        XCTAssertFalse(controller.state.orthographic)

        let recalledCamera = controller.camera
        controller.clearCameraBookmark(at: 0)
        XCTAssertNil(controller.cameraBookmarks[0])
        XCTAssertFalse(controller.state.cameraBookmarkIsAvailable(at: 0))
        XCTAssertFalse(controller.recallCameraBookmark(at: 0), "empty recall must be a no-op")
        assertCameraFields(controller.camera, recalledCamera.center, recalledCamera.distance,
                           recalledCamera.rotation, recalledCamera.perspective)
    }

    /// The saved file must match the documented flat contract: top-level
    /// view-state fields + optional source + optional camera (NOT a nested Scene).
    func testStateFormatIsFlat() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flat.mvis-state")
        try StateStore.save(Scene(loaded: try Parser.load(url)), camera: nil, sourceURL: url, to: tmp)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertNil(obj!["scene"], "state must NOT nest a Scene blob")
        XCTAssertEqual(obj!["source"] as? String, url.path)
        XCTAssertNotNil(obj!["displayMode"])
        XCTAssertNotNil(obj!["supercell"])
        XCTAssertNotNil(obj!["atomScale"])
    }

    func testStateLoadsWithoutCamera() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-legacy-state-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A legacy state file with no camera or cameraBookmarks key must load the
        // scene, leave camera nil, and replace any stale input with three nil slots.
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1,1,1],
                                      "atomScale": 0.35, "bondRadius": 0.1]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = Camera()
        var legacyBookmarks: [CameraBookmark?] = [CameraBookmark(name: "stale", camera: Camera()), nil]
        try StateStore.load(into: &s, camera: &c,
                            cameraBookmarks: &legacyBookmarks, from: tmp)
        XCTAssertNil(c)
        XCTAssertEqual(legacyBookmarks.count, CameraBookmark.slotCount)
        XCTAssertTrue(legacyBookmarks.allSatisfy { $0 == nil })

        // Bookmark validation is transactional even after scene and camera
        // candidates have been changed by the malformed state file.
        s.displayMode = .spaceFill
        s.atomScale = 0.42
        s.background = "#123456"
        var originalCamera = Camera()
        originalCamera.center = SIMD3<Float>(-1, 2, -3)
        originalCamera.distance = 23
        originalCamera.rotation = simd_quatf(ix: 1, iy: 0, iz: 0, r: 1)
        originalCamera.perspective = true
        c = originalCamera
        var keptCamera = Camera()
        keptCamera.center = SIMD3<Float>(4, 5, 6)
        keptCamera.distance = 11
        let originalBookmarks: [CameraBookmark?] = [
            CameraBookmark(name: "Keep one", camera: keptCamera),
            nil,
            CameraBookmark(name: "Keep three", camera: Camera()),
        ]
        var bookmarks = originalBookmarks
        // Compare decoded JSON objects rather than encoder byte order (Scene's
        // set-backed route fields do not promise a stable dictionary order).
        let sceneBefore = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(s)) as! NSDictionary
        let cameraBefore = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(c)) as! NSDictionary
        let bookmarksBefore = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(bookmarks)) as! NSArray

        var replacementCamera = Camera()
        replacementCamera.center = SIMD3<Float>(9, 8, 7)
        replacementCamera.distance = 6
        replacementCamera.perspective = false
        let replacementCameraJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(replacementCamera))
        var invalidBookmarkCamera = replacementCamera
        invalidBookmarkCamera.distance = 0
        let invalidBookmarkCameraJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(invalidBookmarkCamera))

        let malformedBookmarks: [(label: String, name: String, camera: Any)] = [
            ("blank name", " \n\t", replacementCameraJSON),
            ("invalid camera", "Bad camera", invalidBookmarkCameraJSON),
            ("overlong name", String(repeating: "x", count: 33), replacementCameraJSON),
        ]
        for malformed in malformedBookmarks {
            let payload: [String: Any] = [
                "version": 1,
                "displayMode": "ballStick",
                "atomScale": 0.9,
                "camera": replacementCameraJSON,
                "cameraBookmarks": [
                    ["name": malformed.name, "camera": malformed.camera] as [String: Any],
                    NSNull(),
                    NSNull(),
                ] as [Any],
            ]
            try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
            XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c,
                                                      cameraBookmarks: &bookmarks, from: tmp),
                                 "expected \(malformed.label) to reject")
            XCTAssertTrue((try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(s)) as! NSDictionary).isEqual(sceneBefore))
            XCTAssertTrue((try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(c)) as! NSDictionary).isEqual(cameraBefore))
            XCTAssertTrue((try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(bookmarks)) as! NSArray).isEqual(bookmarksBefore))
        }
    }
    // The new appearance fields (lighting, backgroundType/backgroundBottom,
    // currentFrame) must survive a state round-trip with no loss — they are
    // Codable and live on the Scene, so a regression in StateStore or Scene
    // decoding would surface here.
    func testStateRoundTripAppearanceFields() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        var s = Scene(loaded: try Parser.load(url))
        s.lighting.ambient = 0.123
        s.lighting.diffuse = 0.456
        s.lighting.specular = 0.789
        s.lighting.shininess = 64
        s.lighting.azimuth = 123
        s.lighting.elevation = -23
        s.backgroundType = .gradient_top
        s.background = "#112233"
        s.backgroundBottom = "#445566"
        s.showScaleIndicator = true
        s.currentFrame = 7
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t_appear.mvis-state")
        try StateStore.save(s, camera: nil, sourceURL: url, to: tmp)
        var s2 = Scene()
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertEqual(s2.lighting.ambient, 0.123, accuracy: 1e-4)
        XCTAssertEqual(s2.lighting.diffuse, 0.456, accuracy: 1e-4)
        XCTAssertEqual(s2.lighting.specular, 0.789, accuracy: 1e-4)
        XCTAssertEqual(s2.lighting.shininess, 64, accuracy: 1e-4)
        XCTAssertEqual(s2.lighting.azimuth, 123, accuracy: 1e-4)
        XCTAssertEqual(s2.lighting.elevation, -23, accuracy: 1e-4)
        XCTAssertEqual(s2.backgroundType, .gradient_top)
        XCTAssertEqual(s2.background, "#112233")
        XCTAssertEqual(s2.backgroundBottom, "#445566")
        XCTAssertTrue(s2.showScaleIndicator)
        XCTAssertEqual(s2.currentFrame, 7)
    }

    func testCurrentOrbitalRoundTripSelectsSavedField() throws {
        let fields = [
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                        values: Array(repeating: -1, count: 8), minValue: -1, maxValue: 1),
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                        values: Array(repeating: 5, count: 8), minValue: 4, maxValue: 6),
        ]
        var scene = Scene()
        scene.multiOrbitalFields = fields
        scene.scalarField = fields[1]
        scene.currentOrbital = 1
        scene.isoLevel = 5
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbital.mvis-state")
        try StateStore.save(scene, camera: nil, sourceURL: nil, to: tmp)

        var restored = Scene()
        restored.multiOrbitalFields = fields
        restored.scalarField = fields[0]
        var camera: Camera?
        try StateStore.load(into: &restored, camera: &camera, from: tmp)
        XCTAssertEqual(restored.currentOrbital, 1)
        XCTAssertEqual(restored.scalarField?.values.first, 5)
        XCTAssertEqual(restored.isoLevel, 5)
    }

    /// A DATAGRID_2D scene saved with the color plane hidden must restore
    /// hidden BEFORE viewport visibility is chosen — the review finding.
    func testShowColorPlaneRoundTrip() throws {
        let grid = Grid2D(cols: 2, rows: 2, origin: .zero,
                          vec: [SIMD3(1,0,0), SIMD3(0,1,0)], values: [[0,1],[2,3]],
                          minValue: 0, maxValue: 3, ident: "grid")
        var scene = Scene()
        scene.grid2D = grid
        scene.showColorPlane = false
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cp.mvis-state")
        try StateStore.save(scene, camera: nil, sourceURL: nil, to: tmp)

        var restored = Scene()
        restored.grid2D = grid
        var camera: Camera?
        try StateStore.load(into: &restored, camera: &camera, from: tmp)
        XCTAssertFalse(restored.showColorPlane)
        // The key is actually written to the flat file.
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        XCTAssertEqual(obj?["showColorPlane"] as? Bool, false)
    }

    /// Old state files lack the key; the scene default (true) must keep the
    /// historical shown-when-grid-present behavior.
    func testShowColorPlaneBackwardsCompat() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cp_compat.mvis-state")
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1,1,1],
                                      "atomScale": 0.35, "bondRadius": 0.1]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var scene = Scene()
        scene.grid2D = Grid2D(cols: 2, rows: 2, origin: .zero,
                              vec: [SIMD3(1,0,0), SIMD3(0,1,0)], values: [[0,1],[2,3]],
                              minValue: 0, maxValue: 3, ident: "grid")
        var camera: Camera?
        try StateStore.load(into: &scene, camera: &camera, from: tmp)
        XCTAssertTrue(scene.showColorPlane)
        XCTAssertFalse(scene.showScaleIndicator)
    }

    /// The per-segment k-path sampling preference must round-trip through the flat
    /// state file: save with a value, load it back.
    func testKPathSamplingRoundTrip() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let s = Scene(loaded: try Parser.load(url))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpsample.mvis-state")
        try StateStore.save(s, camera: nil, sourceURL: url, to: tmp, kPathSampling: 42)

        var s2 = Scene(loaded: try Parser.load(url))
        var c2: Camera? = nil
        let sampling = try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertEqual(sampling, 42)
        // And it is actually written to the flat file.
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        XCTAssertEqual(obj?["kPathSampling"] as? Int, 42)
    }

    /// Old state files lack the kPathSampling key; the load must fall back to the
    /// KPath default of 20 rather than trapping.
    func testKPathSamplingBackwardsCompat() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpsample_old.mvis-state")
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1,1,1],
                                      "atomScale": 0.35, "bondRadius": 0.1]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = nil
        let sampling = try StateStore.load(into: &s, camera: &c, from: tmp)
        XCTAssertEqual(sampling, 20)
    }

    func testStateRejectsFutureVersion() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t3.mvis-state")
        let payload: [String: Any] = ["version": 99, "scene": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Scene()))]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = nil
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp)) { err in
            guard case ParseError.parse = err else { return XCTFail("expected parse error") }
        }
    }
}
