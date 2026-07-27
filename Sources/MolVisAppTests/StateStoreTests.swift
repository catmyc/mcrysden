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
