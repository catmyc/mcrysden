import XCTest
@testable import MolVisApp
final class StateStoreTests: XCTestCase {
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
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t.mvis-state")
        // ...then save view-state + source path + camera (the flat spec format).
        try StateStore.save(s, camera: cam, sourceURL: url, to: tmp)
        // Reload: re-parse the source for atoms, then apply saved view-state.
        var s2 = Scene(loaded: try Parser.load(url))
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        // Atoms come from the re-parsed source...
        XCTAssertEqual(s2.atoms.count, s.atoms.count)
        // ...view-state and camera round-trip from the state file.
        XCTAssertEqual(s2.atomScale, 0.7, accuracy: 0.0001)
        XCTAssertEqual(s2.displayMode, .spaceFill)
        XCTAssertTrue(s2.showBrillouinZone)
        XCTAssertEqual(c2!.distance, Float(42), accuracy: Float(0.0001))
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
        // a state file with no "camera" key must load the scene and leave camera nil
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t2.mvis-state")
        let payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1,1,1],
                                      "atomScale": 0.35, "bondRadius": 0.1]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = Camera()
        try StateStore.load(into: &s, camera: &c, from: tmp)
        XCTAssertNil(c)
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
        XCTAssertEqual(s2.currentFrame, 7)
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
