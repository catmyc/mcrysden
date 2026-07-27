import XCTest
@testable import MolVisApp

final class StateSaveBridgeTests: XCTestCase {
    /// The bridge must capture the LIVE scene, camera, and source URL at call
    /// time and round-trip them through StateStore.save/load.
    @MainActor
    func testSaveStateCaptivesLiveSceneCameraAndSource() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(Scene(loaded: try Parser.load(url)), from: url, format: nil, frameIndex: 0)

        // Mutate the live camera + a scene field so we can confirm the bridge
        // captures them (not a default/empty snapshot).
        controller.camera.distance = 31.5
        controller.state.atomScale = 0.7

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try controller.saveState(to: tmp)

        var restored = Scene(loaded: try Parser.load(url))
        var restoredCamera: Camera? = nil
        try StateStore.load(into: &restored, camera: &restoredCamera, from: tmp)

        XCTAssertEqual(restored.atomScale, 0.7, accuracy: 1e-4)
        XCTAssertEqual(restoredCamera?.distance, 31.5)
    }

    /// The saved state must record the source path so a later load can re-parse it.
    @MainActor
    func testSaveStatePersistsSourceURL() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(Scene(loaded: try Parser.load(url)), from: url, format: nil, frameIndex: 0)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-src-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try controller.saveState(to: tmp)

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        XCTAssertEqual(obj?["source"] as? String, url.path)
    }

    /// An empty viewer (no source) must save without trapping and record no source.
    @MainActor
    func testSaveStateEmptyViewer() throws {
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-empty-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNoThrow(try controller.saveState(to: tmp))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: tmp)) as? [String: Any]
        XCTAssertNil(obj?["source"])
    }
}
