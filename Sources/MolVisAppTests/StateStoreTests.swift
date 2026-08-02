import Foundation
import simd
import XCTest
@testable import MolVisApp

final class StateStoreTests: XCTestCase {
    @MainActor
    func testStateRoundTripRestoresViewCameraAndAuxiliaryState() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let sourceURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        var scene = Scene(loaded: try Parser.load(sourceURL))
        scene.displayMode = .spaceFill
        scene.atomScale = 0.7
        scene.showBrillouinZone = true
        scene.lighting.ambient = 0.123
        scene.lighting.diffuse = 0.456
        scene.lighting.specular = 0.789
        scene.lighting.shininess = 64
        scene.lighting.azimuth = 123
        scene.lighting.elevation = -23
        scene.backgroundType = .gradient_top
        scene.background = "#112233"
        scene.backgroundBottom = "#445566"
        scene.showScaleIndicator = true
        scene.msaaSampleCount = 2
        scene.currentFrame = 7

        let fields = [
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                        values: Array(repeating: -1, count: 8), minValue: -1, maxValue: 1),
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                        values: Array(repeating: 5, count: 8), minValue: 4, maxValue: 6),
        ]
        scene.multiOrbitalFields = fields
        scene.scalarField = fields[1]
        scene.currentOrbital = 1
        scene.isoLevel = 5

        let grid = Grid2D(cols: 2, rows: 2, origin: .zero,
                          vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)], values: [[0, 1], [2, 3]],
                          minValue: 0, maxValue: 3, ident: "grid")
        scene.grid2D = grid
        scene.showColorPlane = false
        scene.kPathPoints = [
            KPoint(SIMD3<Float>(0, 0, 0), "G"),
            KPoint(SIMD3<Float>(0.5, 0, 0), "X"),
            KPoint(SIMD3<Float>(0, 0.5, 0), "Y"),
        ]
        scene.kPathBreaks = [1]
        scene.kPathProvenance = .userEdited
        scene.kPathSignature = nil

        var camera = Camera()
        camera.center = SIMD3<Float>(1, 2, 3)
        camera.distance = 42
        camera.rotation = simd_quatf(ix: 1, iy: 2, iz: 3, r: 4)
        camera.perspective = true
        let expectedCameraRotation = simd_normalize(camera.rotation)

        var bookmarkCamera0 = Camera()
        bookmarkCamera0.center = SIMD3<Float>(1.25, -2.5, 3.75)
        bookmarkCamera0.distance = 17.25
        bookmarkCamera0.rotation = simd_quatf(ix: 1, iy: 2, iz: 3, r: 4)
        bookmarkCamera0.perspective = true
        let expectedBookmarkRotation0 = simd_normalize(bookmarkCamera0.rotation)
        var bookmarkCamera2 = Camera()
        bookmarkCamera2.center = SIMD3<Float>(-4, 5, -6)
        bookmarkCamera2.distance = 8.5
        let bookmarks: [CameraBookmark?] = [
            CameraBookmark(name: "  Main view \n", camera: bookmarkCamera0),
            nil,
            CameraBookmark(name: "\tSide view  ", camera: bookmarkCamera2),
        ]

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-state-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try StateStore.save(scene, camera: camera, sourceURL: sourceURL, to: tmp,
                            kPathSampling: 42, cameraBookmarks: bookmarks)

        var restored = Scene(loaded: try Parser.load(sourceURL))
        // Volumetric data is supplied by the source loader; seed it as a reload
        // would, then let the state file select the saved orbital and visibility.
        restored.multiOrbitalFields = fields
        restored.scalarField = fields[0]
        restored.grid2D = grid
        var restoredCamera: Camera?
        var restoredBookmarks: [CameraBookmark?] = []
        let sampling = try StateStore.load(into: &restored, camera: &restoredCamera,
                                           cameraBookmarks: &restoredBookmarks, from: tmp)

        XCTAssertEqual(restored.atoms.count, scene.atoms.count)
        XCTAssertEqual(restored.displayMode, .spaceFill)
        XCTAssertEqual(restored.atomScale, 0.7, accuracy: 0.0001)
        XCTAssertTrue(restored.showBrillouinZone)
        XCTAssertEqual(restored.lighting.ambient, 0.123, accuracy: 1e-4)
        XCTAssertEqual(restored.lighting.diffuse, 0.456, accuracy: 1e-4)
        XCTAssertEqual(restored.lighting.specular, 0.789, accuracy: 1e-4)
        XCTAssertEqual(restored.lighting.shininess, 64, accuracy: 1e-4)
        XCTAssertEqual(restored.lighting.azimuth, 123, accuracy: 1e-4)
        XCTAssertEqual(restored.lighting.elevation, -23, accuracy: 1e-4)
        XCTAssertEqual(restored.backgroundType, .gradient_top)
        XCTAssertEqual(restored.background, "#112233")
        XCTAssertEqual(restored.backgroundBottom, "#445566")
        XCTAssertTrue(restored.showScaleIndicator)
        XCTAssertEqual(restored.msaaSampleCount, 2)
        XCTAssertEqual(restored.currentFrame, 7)
        XCTAssertEqual(restored.currentOrbital, 1)
        XCTAssertEqual(restored.scalarField?.values.first, 5)
        XCTAssertEqual(restored.isoLevel, 5, accuracy: 0.0001)
        XCTAssertFalse(restored.showColorPlane)
        XCTAssertEqual(restored.kPathPoints, scene.kPathPoints)
        XCTAssertEqual(restored.kPathBreaks, scene.kPathBreaks)
        XCTAssertEqual(restored.kPathProvenance, .userEdited)
        XCTAssertEqual(sampling, 42)

        let assertCamera: (Camera, SIMD3<Float>, Float, simd_quatf, Bool) -> Void = {
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
        guard let restoredCamera,
              restoredBookmarks.count == CameraBookmark.slotCount,
              let first = restoredBookmarks[0],
              restoredBookmarks[1] == nil,
              let third = restoredBookmarks[2] else {
            return XCTFail("expected the saved camera and three bookmark slots")
        }
        assertCamera(restoredCamera, camera.center, camera.distance,
                     expectedCameraRotation, camera.perspective)
        XCTAssertEqual(first.name, "Main view")
        XCTAssertEqual(third.name, "Side view")
        assertCamera(first.camera, bookmarkCamera0.center, bookmarkCamera0.distance,
                     expectedBookmarkRotation0, bookmarkCamera0.perspective)
        assertCamera(third.camera, bookmarkCamera2.center, bookmarkCamera2.distance,
                     bookmarkCamera2.rotation, bookmarkCamera2.perspective)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.camera = camera // deliberately retains the non-unit live quaternion
        controller.state.setCameraBookmarkName(at: 0, to: "  Live view  ")
        XCTAssertTrue(controller.saveCameraBookmark(at: 0))
        XCTAssertFalse(controller.saveCameraBookmark(at: -1))
        guard let savedBookmark = controller.cameraBookmarks[0] else {
            return XCTFail("expected the live camera bookmark")
        }
        XCTAssertEqual(savedBookmark.name, "Live view")

        var alteredCamera = controller.camera
        alteredCamera.center = SIMD3<Float>(100, 101, 102)
        alteredCamera.distance = 4
        alteredCamera.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        alteredCamera.perspective = false
        controller.camera = alteredCamera
        XCTAssertTrue(controller.recallCameraBookmark(at: 0))
        assertCamera(controller.camera, camera.center, camera.distance,
                     expectedCameraRotation, camera.perspective)
        XCTAssertFalse(controller.state.orthographic)

        controller.clearCameraBookmark(at: 0)
        XCTAssertNil(controller.cameraBookmarks[0])
        let cameraAfterClear = controller.camera
        XCTAssertFalse(controller.recallCameraBookmark(at: 0), "empty recall must be a no-op")
        assertCamera(controller.camera, cameraAfterClear.center, cameraAfterClear.distance,
                     cameraAfterClear.rotation, cameraAfterClear.perspective)
    }

    func testStateBackwardCompatibilityAndDefaults() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-legacy-state-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "atomScale": 0.35,
            "bondRadius": 0.1,
        ]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        let grid = Grid2D(cols: 2, rows: 2, origin: .zero,
                          vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)], values: [[0, 1], [2, 3]],
                          minValue: 0, maxValue: 3, ident: "grid")
        var scene = Scene()
        scene.grid2D = grid
        var camera: Camera? = Camera()
        var bookmarks: [CameraBookmark?] = [
            CameraBookmark(name: "stale", camera: Camera()), nil, nil,
        ]
        let sampling = try StateStore.load(into: &scene, camera: &camera,
                                           cameraBookmarks: &bookmarks, from: tmp)

        XCTAssertNil(camera)
        XCTAssertEqual(bookmarks.count, CameraBookmark.slotCount)
        XCTAssertTrue(bookmarks.allSatisfy { $0 == nil })
        XCTAssertTrue(scene.showColorPlane, "missing color-plane key keeps the historical default")
        XCTAssertFalse(scene.showScaleIndicator, "missing scale-indicator key keeps its default")
        XCTAssertEqual(scene.msaaSampleCount, 1, "missing msaaSampleCount key keeps the off default")
        XCTAssertEqual(sampling, 20, "missing k-path sampling uses the KPath default")
        XCTAssertEqual(scene.displayMode, .ballStick)
        XCTAssertEqual(scene.atomScale, 0.35, accuracy: 0.0001)
    }

    func testStateFormatIsFlatAndRejectsFutureVersion() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let sourceURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-flat-state-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try StateStore.save(Scene(loaded: try Parser.load(sourceURL)), camera: nil,
                            sourceURL: sourceURL, to: tmp)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any])
        XCTAssertNil(object["scene"], "state must not nest a Scene blob")
        XCTAssertEqual(object["source"] as? String, sourceURL.path)
        XCTAssertNotNil(object["displayMode"])
        XCTAssertNotNil(object["supercell"])
        XCTAssertNotNil(object["atomScale"])

        let futurePayload: [String: Any] = ["version": 99, "scene": [:]]
        try JSONSerialization.data(withJSONObject: futurePayload, options: []).write(to: tmp)
        var scene = Scene()
        var camera: Camera?
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera, from: tmp)) { error in
            guard case ParseError.parse = error else {
                return XCTFail("expected a future-version parse error")
            }
        }
    }

    func testMalformedStateRollsBackSceneCameraAndBookmarks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-malformed-state-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var scene = Scene()
        scene.displayMode = .spaceFill
        scene.atomScale = 0.42
        scene.background = "#123456"
        var originalCamera = Camera()
        originalCamera.center = SIMD3<Float>(-1, 2, -3)
        originalCamera.distance = 23
        originalCamera.rotation = simd_quatf(ix: 1, iy: 0, iz: 0, r: 1)
        originalCamera.perspective = true
        var camera: Camera? = originalCamera
        var keptCamera = Camera()
        keptCamera.center = SIMD3<Float>(4, 5, 6)
        keptCamera.distance = 11
        var bookmarks: [CameraBookmark?] = [
            CameraBookmark(name: "Keep one", camera: keptCamera),
            nil,
            CameraBookmark(name: "Keep three", camera: Camera()),
        ]

        let sceneBefore = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(scene)) as! NSDictionary
        let cameraBefore = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(camera)) as! NSDictionary
        let bookmarksBefore = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(bookmarks)) as! NSArray
        func assertUnchanged() throws {
            XCTAssertTrue((try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(scene)) as! NSDictionary).isEqual(sceneBefore))
            XCTAssertTrue((try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(camera)) as! NSDictionary).isEqual(cameraBefore))
            XCTAssertTrue((try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(bookmarks)) as! NSArray).isEqual(bookmarksBefore))
        }

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
            XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera,
                                                      cameraBookmarks: &bookmarks, from: tmp),
                                 "expected \(malformed.label) to reject") { error in
                guard case ParseError.parse = error else {
                    return XCTFail("expected a malformed-state parse error")
                }
            }
            try assertUnchanged()
        }

        // Unsupported msaaSampleCount (not in {1,2,4,8}) must reject with a
        // useful ParseError and roll back scene/camera/bookmarks.
        let malformedMSAA: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "atomScale": 0.9,
            "msaaSampleCount": 3,
            "camera": replacementCameraJSON,
            "cameraBookmarks": [NSNull(), NSNull(), NSNull()],
        ]
        try JSONSerialization.data(withJSONObject: malformedMSAA, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera,
                                                cameraBookmarks: &bookmarks, from: tmp),
                             "unsupported msaaSampleCount must reject") { error in
            guard case let ParseError.parse(path, _, reason) = error else {
                return XCTFail("expected a malformed-msaa parse error")
            }
            XCTAssertTrue(reason.contains("msaaSampleCount"), "reason should mention msaaSampleCount")
        }
        try assertUnchanged()

        // Non-numeric msaaSampleCount must also reject.
        let nonNumericMSAA: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "msaaSampleCount": "eight",
        ]
        try JSONSerialization.data(withJSONObject: nonNumericMSAA, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera,
                                                cameraBookmarks: &bookmarks, from: tmp),
                             "non-numeric msaaSampleCount must reject") { error in
            guard case ParseError.parse = error else {
                return XCTFail("expected a non-numeric msaa parse error")
            }
        }
        try assertUnchanged()

        // Boolean msaaSampleCount must also reject.
        let booleanMSAA: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "msaaSampleCount": true,
        ]
        try JSONSerialization.data(withJSONObject: booleanMSAA, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera,
                                                cameraBookmarks: &bookmarks, from: tmp),
                             "boolean msaaSampleCount must reject") { error in
            guard case ParseError.parse = error else {
                return XCTFail("expected a boolean msaa parse error")
            }
        }
        try assertUnchanged()

        // Nonintegral msaaSampleCount must also reject.
        let nonintegralMSAA: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "msaaSampleCount": 1.5,
        ]
        try JSONSerialization.data(withJSONObject: nonintegralMSAA, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera,
                                                cameraBookmarks: &bookmarks, from: tmp),
                             "nonintegral msaaSampleCount must reject") { error in
            guard case ParseError.parse = error else {
                return XCTFail("expected a nonintegral msaa parse error")
            }
        }
        try assertUnchanged()
    }
}
