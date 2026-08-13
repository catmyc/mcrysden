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
        scene.showBondDistances = true
        scene.msaaSampleCount = 2
        scene.currentFrame = 7
        scene.opacity = 0.42
        scene.lineWidth = 3.5
        scene.depthCueingStrength = 0.75
        scene.aoStrength = 0.6
        scene.shadowStrength = 0.55
        scene.aoQuality = 3
        scene.shadowQuality = 1
        scene.hbondSettings.maxDistance = 3.75
        scene.molecularSurfaceSettings.probeRadius = 2.0
        scene.atomColorScheme = .coordination
        scene.elementOverrides = [1: ElementOverride(colorHex: "#FF0000", covalentRadius: 0.5, vdwRadius: 1.5, labelOverride: "H", fontScale: 1.2)]
        scene.repetitionMode = .asymmetricUnit
        scene.cellRodsEnabled = true
        scene.cellRodFactor = 0.8
        scene.unicolorBonds = true
        scene.unicolorBondHex = "#00FF00"
        scene.tessellationFactor = 3

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
        scene.colorPlaneColormap = .turbo
        scene.colorPlaneContourCount = 9
        scene.volumeSlices = [VolumeSlice(enabled: true, h: 1, k: 0, l: 0, distance: 0.5)]

        let kpts = [KPoint(SIMD3<Float>(0, 0, 0), "Γ"), KPoint(SIMD3<Float>(0.5, 0, 0), "X")]
        scene.kPathPoints = kpts
        scene.kPathBreaks = [0]
        scene.kPathProvenance = .userEdited

        var camera = Camera()
        camera.center = SIMD3<Float>(1, 2, 3)
        camera.distance = 15
        camera.rotation = simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        camera.perspective = true

        var bookmarkCamera0 = Camera()
        bookmarkCamera0.center = SIMD3<Float>(10, 20, 30)
        bookmarkCamera0.distance = 5
        var bookmarkCamera2 = Camera()
        bookmarkCamera2.center = SIMD3<Float>(-1, -2, -3)
        bookmarkCamera2.distance = 50
        var bookmarks: [CameraBookmark?] = [
            CameraBookmark(name: "First", camera: bookmarkCamera0), nil,
            CameraBookmark(name: "Third", camera: bookmarkCamera2),
        ]

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-roundtrip-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try StateStore.save(scene, camera: camera, sourceURL: sourceURL,
                            to: tmp, kPathSampling: 42, cameraBookmarks: bookmarks)

        var loaded = Scene()
        var loadedCamera: Camera? = nil
        var loadedBookmarks: [CameraBookmark?] = []
        let loadedSampling = try StateStore.load(into: &loaded, camera: &loadedCamera,
                                                cameraBookmarks: &loadedBookmarks, from: tmp)
        XCTAssertEqual(loadedSampling, 42)

        XCTAssertEqual(loaded.displayMode, .spaceFill)
        XCTAssertEqual(loaded.atomScale, 0.7, accuracy: 0.0001)
        XCTAssertEqual(loaded.showBrillouinZone, true)
        XCTAssertEqual(loaded.lighting.ambient, 0.123, accuracy: 1e-5)
        XCTAssertEqual(loaded.lighting.diffuse, 0.456, accuracy: 1e-5)
        XCTAssertEqual(loaded.lighting.specular, 0.789, accuracy: 1e-5)
        XCTAssertEqual(loaded.lighting.shininess, 64, accuracy: 1e-5)
        XCTAssertEqual(loaded.lighting.azimuth, 123, accuracy: 1e-5)
        XCTAssertEqual(loaded.lighting.elevation, -23, accuracy: 1e-5)
        XCTAssertEqual(loaded.backgroundType, .gradient_top)
        XCTAssertEqual(loaded.background, "#112233")
        XCTAssertEqual(loaded.backgroundBottom, "#445566")
        XCTAssertEqual(loaded.showScaleIndicator, true)
        XCTAssertEqual(loaded.showBondDistances, true)
        XCTAssertEqual(loaded.msaaSampleCount, 2)
        XCTAssertEqual(loaded.currentFrame, 7)
        XCTAssertEqual(loaded.opacity, 0.42, accuracy: 1e-5)
        XCTAssertEqual(loaded.lineWidth, 3.5, accuracy: 1e-5)
        XCTAssertEqual(loaded.depthCueingStrength, 0.75, accuracy: 1e-5)
        XCTAssertEqual(loaded.aoStrength, 0.6, accuracy: 1e-5)
        XCTAssertEqual(loaded.shadowStrength, 0.55, accuracy: 1e-5)
        XCTAssertEqual(loaded.aoQuality, 3)
        XCTAssertEqual(loaded.shadowQuality, 1)
        XCTAssertEqual(loaded.hbondSettings.maxDistance, 3.75, accuracy: 1e-5)
        XCTAssertEqual(loaded.molecularSurfaceSettings.probeRadius, 2.0, accuracy: 1e-5)
        XCTAssertEqual(loaded.atomColorScheme, .coordination)
        XCTAssertEqual(loaded.elementOverrides[1]?.colorHex, "#FF0000")
        XCTAssertEqual(loaded.repetitionMode, .asymmetricUnit)
        XCTAssertEqual(loaded.cellRodsEnabled, true)
        XCTAssertEqual(loaded.cellRodFactor, 0.8, accuracy: 1e-5)
        XCTAssertEqual(loaded.unicolorBonds, true)
        XCTAssertEqual(loaded.unicolorBondHex, "#00FF00")
        XCTAssertEqual(loaded.tessellationFactor, 3)
        XCTAssertEqual(loaded.currentOrbital, 1)
        XCTAssertEqual(loaded.isoLevel, 5, accuracy: 1e-5)
        XCTAssertEqual(loaded.colorPlaneColormap, .turbo)
        XCTAssertEqual(loaded.colorPlaneContourCount, 9)
        // Grid2D is not persisted in the state file (it comes from re-parsing the source).
        XCTAssertEqual(loaded.volumeSlices.count, 1)
        XCTAssertEqual(loaded.volumeSlices[0].h, 1)
        XCTAssertEqual(loaded.kPathPoints.count, 2)
        XCTAssertEqual(loaded.kPathPoints[0].label, "Γ")
        XCTAssertEqual(loaded.kPathBreaks, [0])
        XCTAssertEqual(loaded.kPathProvenance, .userEdited)

        let restoredCamera = try XCTUnwrap(loadedCamera)
        XCTAssertEqual(restoredCamera.center.x, 1, accuracy: 1e-4)
        XCTAssertEqual(restoredCamera.center.y, 2, accuracy: 1e-4)
        XCTAssertEqual(restoredCamera.center.z, 3, accuracy: 1e-4)
        XCTAssertEqual(restoredCamera.distance, 15, accuracy: 1e-4)
        XCTAssertEqual(restoredCamera.perspective, true)

        XCTAssertEqual(loadedBookmarks.count, 3)
        let first = try XCTUnwrap(loadedBookmarks[0])
        XCTAssertEqual(first.name, "First")
        XCTAssertEqual(first.camera.center.x, 10, accuracy: 1e-4)
        XCTAssertNil(loadedBookmarks[1])
        let third = try XCTUnwrap(loadedBookmarks[2])
        XCTAssertEqual(third.name, "Third")
        XCTAssertEqual(third.camera.distance, 50, accuracy: 1e-4)

        // Camera bookmarks are exercised through the controller.
        let assertCamera: (Camera, SIMD3<Float>, Float, simd_quatf, Bool) -> Void = {
            XCTAssertEqual($0.center.x, $1.x, accuracy: 1e-3)
            XCTAssertEqual($0.center.y, $1.y, accuracy: 1e-3)
            XCTAssertEqual($0.center.z, $1.z, accuracy: 1e-3)
            XCTAssertEqual($0.distance, $2, accuracy: 1e-3)
            XCTAssertEqual($0.rotation.vector.x, $3.vector.x, accuracy: 1e-3)
            XCTAssertEqual($0.rotation.vector.y, $3.vector.y, accuracy: 1e-3)
            XCTAssertEqual($0.rotation.vector.z, $3.vector.z, accuracy: 1e-3)
            XCTAssertEqual($0.rotation.vector.w, $3.vector.w, accuracy: 1e-3)
            XCTAssertEqual($0.perspective, $4)
        }
        assertCamera(restoredCamera, camera.center, camera.distance,
                     camera.rotation, camera.perspective)
        assertCamera(first.camera, bookmarkCamera0.center, bookmarkCamera0.distance,
                     bookmarkCamera0.rotation, bookmarkCamera0.perspective)
        assertCamera(third.camera, bookmarkCamera2.center, bookmarkCamera2.distance,
                     bookmarkCamera2.rotation, bookmarkCamera2.perspective)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.camera = camera
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
        controller.camera = alteredCamera
        XCTAssertTrue(controller.recallCameraBookmark(at: 0))
        assertCamera(controller.camera, camera.center, camera.distance,
                     camera.rotation, camera.perspective)

        controller.clearCameraBookmark(at: 0)
        XCTAssertNil(controller.cameraBookmarks[0])
        let cameraAfterClear = controller.camera
        XCTAssertFalse(controller.recallCameraBookmark(at: 0), "empty recall must be a no-op")
        assertCamera(controller.camera, cameraAfterClear.center, cameraAfterClear.distance,
                     cameraAfterClear.rotation, cameraAfterClear.perspective)
        // --- Backward compatibility and defaults (merged) ---
        do {

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
        XCTAssertEqual(scene.opacity, 1.0, "missing opacity key keeps opaque default")
        XCTAssertEqual(scene.lineWidth, 1.0, "missing lineWidth key keeps 1px default")
        XCTAssertEqual(scene.depthCueingStrength, 0.0, "missing depthCueingStrength key keeps off default")
        XCTAssertEqual(scene.aoStrength, 0.0, "missing aoStrength key keeps off default")
        XCTAssertEqual(scene.shadowStrength, 0.0, "missing shadowStrength key keeps off default")
        XCTAssertEqual(scene.aoQuality, 2, "missing aoQuality key keeps medium default")
        XCTAssertEqual(scene.shadowQuality, 2, "missing shadowQuality key keeps medium default")
        XCTAssertTrue(scene.volumeSlices.isEmpty, "missing volumeSlices key keeps empty default")
        }   // end merged block

    }

    /// The flat state format must persist the band-surface interactive orientation
    /// (WYSIWYG round trip) and reject/clamp malformed values.
    @MainActor
    func testStateRoundTripBandSurfaceOrientation() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let sourceURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        var scene = Scene(loaded: try Parser.load(sourceURL))
        scene.bandSurfaceOrientation = BandSurfaceOrientation(azimuthDegrees: 123.5, elevationDegrees: -31)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-band-orient-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try StateStore.save(scene, camera: nil, sourceURL: sourceURL, to: tmp)

        var loaded = Scene()
        var loadedCamera: Camera? = nil
        _ = try StateStore.load(into: &loaded, camera: &loadedCamera, from: tmp)
        XCTAssertEqual(loaded.bandSurfaceOrientation?.azimuthDegrees ?? -1, 123.5, accuracy: 1e-5)
        XCTAssertEqual(loaded.bandSurfaceOrientation?.elevationDegrees ?? -999, -31, accuracy: 1e-5)

        // Elevation is clamped to the view's ±89° range on load.
        let clamped = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-band-orient-clamp-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: clamped) }
        let payload: [String: Any] = [
            "bandSurfaceOrientation": ["azimuthDegrees": 10, "elevationDegrees": 500],
        ]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: clamped)
        var scene2 = Scene()
        var camera2: Camera? = nil
        _ = try StateStore.load(into: &scene2, camera: &camera2, from: clamped)
        XCTAssertEqual(scene2.bandSurfaceOrientation?.elevationDegrees ?? -999, 89, accuracy: 1e-5)
        XCTAssertEqual(scene2.bandSurfaceOrientation?.azimuthDegrees ?? -999, 10, accuracy: 1e-5)

        // Non-finite angle rejects the whole load transactionally. JSONSerialization
        // refuses to write NaN, so craft the payload as raw JSON text.
        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-band-orient-bad-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: bad) }
        let badJSON = #"{"bandSurfaceOrientation":{"azimuthDegrees":1e999,"elevationDegrees":10}}"#
        try badJSON.data(using: .utf8)!.write(to: bad)
        var scene3 = Scene()
        var camera3: Camera? = nil
        XCTAssertThrowsError(try StateStore.load(into: &scene3, camera: &camera3, from: bad))
        XCTAssertNil(scene3.bandSurfaceOrientation, "failed load must not mutate the scene")
    }

    /// Opening a scene WITHOUT a persisted orientation must reset the live view to
    /// defaults — the previous document's angles must not leak across loads.
    @MainActor
    func testSceneInstallResetsOrientationWhenAbsent() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let sourceURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        let plain = Scene(loaded: try Parser.load(sourceURL))          // no orientation
        let oriented = Scene(loaded: try Parser.load(sourceURL))
        // Scene is a value type; set the orientation on the copy.
        var orientedScene = oriented
        orientedScene.bandSurfaceOrientation = BandSurfaceOrientation(azimuthDegrees: 77, elevationDegrees: -12)

        let wc = MainWindowController(scene: orientedScene, showWindow: false)
        XCTAssertEqual(wc.bandSurfaceView.azimuthDegrees, 77, accuracy: 1e-4)
        XCTAssertEqual(wc.bandSurfaceView.elevationDegrees, -12, accuracy: 1e-4)

        // Reinstall a scene without an orientation: the view must fall back to
        // the built-in defaults instead of keeping 77°/-12°.
        wc.loadFile(plain, from: nil, format: nil, frameIndex: 0)
        XCTAssertEqual(wc.bandSurfaceView.azimuthDegrees, 30, accuracy: 1e-4)
        XCTAssertEqual(wc.bandSurfaceView.elevationDegrees, 24, accuracy: 1e-4)
    }
}
