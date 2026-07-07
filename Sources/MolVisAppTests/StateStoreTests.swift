import XCTest
@testable import MolVisApp
final class StateStoreTests: XCTestCase {
    func testStateRoundTrip() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        var s = Scene(loaded: try Parser.load(url))
        s.atomScale = 0.7
        s.camera.distance = 42
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t.mvis-state")
        try StateStore.save(s, camera: s.camera, to: tmp)
        var s2 = Scene()
        var c2: Camera? = nil
        try StateStore.load(&s2, camera: &c2, from: tmp)
        XCTAssertEqual(s2.atomScale, 0.7, accuracy: 0.0001)
        XCTAssertEqual(s2.atoms.count, s.atoms.count)
        XCTAssertEqual(c2!.distance, Float(42), accuracy: Float(0.0001))
    }
    func testStateLoadsWithoutCamera() throws {
        // a state file with no "camera" key must load the scene and leave camera nil
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t2.mvis-state")
        let payload: [String: Any] = ["version": 1, "scene": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Scene()))]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = Camera()
        try StateStore.load(&s, camera: &c, from: tmp)
        XCTAssertNil(c)
    }
    func testStateRejectsFutureVersion() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t3.mvis-state")
        let payload: [String: Any] = ["version": 99, "scene": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Scene()))]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = nil
        XCTAssertThrowsError(try StateStore.load(&s, camera: &c, from: tmp)) { err in
            guard case ParseError.parse = err else { return XCTFail("expected parse error") }
        }
    }
}
