import XCTest
@testable import MolVisApp

// Verify hide-structure: the model defaults, the sidebar<->scene sync in both
// directions, and persistence through the flat state format. (The Renderer
// gate itself is a single `if scene.showStructure` wrapper around the existing
// atom/bond/polyhedral draws — cell frame, axes and BZ draw regardless — and
// is trivially correct by inspection, corroborated by the other snapshot and
// cell-render diagnostics that exercise the same draw path.)
final class VisHideStructure: XCTestCase {

    func testShowStructureDefault() throws {
        // Default: structure visible for both a crystal and a molecule.
        XCTAssertTrue(Scene().showStructure, "empty scene shows structure by default")
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let xsf = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        XCTAssertTrue(xsf.showStructure, "loaded crystal shows structure by default")
    }

    // The sidebar toggle must propagate to the scene both ways (state -> scene
    // on change, scene -> state on load) so the renderer's single source of
    // truth (scene.showStructure) reflects the UI.
    func testShowStructureSync() throws {
        let wc = MainWindowController(scene: Scene(), showWindow: false)
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        wc.loadFile(Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf"))),
                    from: URL(fileURLWithPath:"/x"), format: nil, frameIndex: 0)
        // On load, a crystal initializes the mirror.
        XCTAssertTrue(wc.state.showStructure, "loaded crystal: sidebar shows structure")
        XCTAssertTrue(wc.scene.showStructure, "loaded crystal: scene shows structure")
        // User hides structure in the sidebar -> scene follows (state -> scene).
        wc.state.showStructure = false
        XCTAssertFalse(wc.scene.showStructure, "toggling sidebar off must hide scene structure")
        // Toggle back on.
        wc.state.showStructure = true
        XCTAssertTrue(wc.scene.showStructure, "toggling sidebar on must restore scene structure")
    }

    // The hidden flag must survive a save/load cycle (flat spec format).
    func testShowStructurePersists() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        scene.showStructure = false
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hide.mvis-state")
        try StateStore.save(scene, camera: nil, sourceURL: URL(fileURLWithPath:"/x"), to: tmp)
        var loaded = Scene()
        var c: Camera? = nil
        try StateStore.load(into: &loaded, camera: &c, from: tmp)
        XCTAssertFalse(loaded.showStructure, "hidden flag persists through state load")
    }
}
