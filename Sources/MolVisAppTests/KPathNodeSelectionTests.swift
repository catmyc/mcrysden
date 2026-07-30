import XCTest
import Metal
import simd
@testable import MolVisApp

// Selected route-node highlight linkage: the renderer draws one route node
// (the node selected in the sidebar route list) as a larger green cross in the
// BZ viewport, and the controller exposes selectKPathNode(_:) as the hook the
// SidebarState/UI invokes later. These tests lock the render toggle and the
// controller seam without touching SideBar/SideBarState.

final class KPathNodeSelectionTests: XCTestCase {
    struct NoGpu: Error {}

    // Render the scene's BZ + route to raw RGBA bytes at the given size, using
    // the scene's default camera (same framing the GUI/exporters use).
    private func render(_ scene: Scene, r: Renderer, w: Int = 300, h: Int = 300) -> [UInt8] {
        r.scene = scene
        let desc = MTLTextureDescriptor(); desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h; desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let tex = r.device.makeTexture(descriptor: desc)!
        let cb = r.device.makeCommandQueue()!.makeCommandBuffer()!
        let vp = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        _ = r.encode(to: cb, target: tex, viewport: vp, camera: scene.defaultCamera())
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px
    }

    // Count pixels whose RGB differs by more than a small threshold.
    private func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2])) > 24 { n += 1 }
        }
        return n
    }

    // A crystal scene (fcc Si slab) with a cell + base atoms so the BZ builds,
    // plus a 3-node route so there is a node to highlight.
    private func routeScene() throws -> Scene {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        scene.showBrillouinZone = true
        scene.kPathPoints = [
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
            KPoint(SIMD3(0.5, 0.5, 0), "M"),
        ]
        return scene
    }

    // Selecting a node must change the rendered frame: a larger green cross is
    // drawn at that node on top of the cyan node crosses.
    func testSelectedNodeHighlightRenders() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        let scene = try routeScene()
        r.selectedKPathNode = nil
        let base = render(scene, r: r)
        r.selectedKPathNode = 1
        let highlighted = render(scene, r: r)
        let d = diff(base, highlighted)
        print("[kpath-select] highlighted vs base: \(d) changed pixels")
        XCTAssertGreaterThan(d, 0, "selecting a route node must change the rendered frame")
    }

    // An out-of-range index is a safe no-op: the frame is unchanged from the
    // no-selection baseline (and must not trap).
    func testOutOfRangeSelectionIsNoOp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        let scene = try routeScene()
        r.selectedKPathNode = nil
        let base = render(scene, r: r)
        r.selectedKPathNode = 99
        let oob = render(scene, r: r)
        XCTAssertEqual(diff(base, oob), 0, "out-of-range index must not change the render")
    }

    // The controller method is the sidebar hook: it sets the renderer toggle.
    func testControllerSelectKPathNodeSetsRendererToggle() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        let c = MainWindowController(scene: scene, showWindow: false)
        XCTAssertNil(c.renderer?.selectedKPathNode)
        c.selectKPathNode(2)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 2)
        c.selectKPathNode(nil)
        XCTAssertNil(c.renderer?.selectedKPathNode)
    }

    func testSelectionSynchronizes2DRendererAcrossDelegateSwitches() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        guard c.renderer != nil, c.renderer2D != nil else { throw NoGpu() }

        c.selectKPathNode(1)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 1)
        XCTAssertEqual(c.renderer2D?.selectedKPathNode, 1)

        c.state.displayMode = .ballStick2D
        XCTAssertTrue(c.scene.displayMode.is2D)
        XCTAssertTrue(c.canvas.delegate === c.renderer2D)
        XCTAssertEqual(c.renderer2D?.selectedKPathNode, 1)
        XCTAssertEqual(c.labelOverlay.labels.filter { $0.style == .selectedRouteNode }.map(\.symbol), ["X"])

        c.selectKPathNode(nil)
        XCTAssertNil(c.renderer?.selectedKPathNode)
        XCTAssertNil(c.renderer2D?.selectedKPathNode)

        c.state.displayMode = .ballStick
        XCTAssertTrue(c.canvas.delegate === c.renderer)
        c.selectKPathNode(0)
        c.state.displayMode = .ballStick2D
        XCTAssertEqual(c.renderer2D?.selectedKPathNode, 0)
    }

    // Loading a fresh scene clears any stale node highlight from the previous
    // scene so an out-of-range index can't linger.
    func testLoadFileClearsSelectedNode() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let c = MainWindowController(scene: Scene(loaded: try Parser.load(url)), showWindow: false)
        c.selectKPathNode(3)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 3)
        let other = Scene(loaded: try Parser.load(url))
        c.loadFile(other, from: url)
        XCTAssertNil(c.renderer?.selectedKPathNode, "loadFile must clear the stale node highlight")
    }

    // MARK: - Production-path bridge + lifecycle regression (review findings 1, 6, 8)

    // The sidebar selects a node by invoking the state callback (never by calling
    // selectKPathNode directly). That production path must reach the renderer toggle.
    func testSelectionBridgeViaCallbackReachesRenderer() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        XCTAssertNil(c.renderer?.selectedKPathNode)
        c.state.onSelectKPathNode?(1)   // production entry point used by SideBar
        XCTAssertEqual(c.renderer?.selectedKPathNode, 1, "callback must reach the renderer")
        c.state.onSelectKPathNode?(nil) // deselect via the same path
        XCTAssertNil(c.renderer?.selectedKPathNode, "nil callback must clear the highlight")
    }

    // A whole-route replacement clears the selection through the production path.
    // `clear()` is what the sidebar "Clear" button calls; it funnels through
    // replaceKPath -> onChange -> syncFromState, which must drop the highlight.
    func testWholeRouteReplacementClearsSelection() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        c.state.onSelectKPathNode?(1)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 1)
        c.state.clear()   // production "Clear" path: replaceKPath -> syncFromState
        XCTAssertNil(c.renderer?.selectedKPathNode, "whole-route Clear must clear the highlight")
    }

    // Undo is another whole-route replacement (replaceKPath); it too must clear.
    func testUndoClearsSelection() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        c.state.onSelectKPathNode?(0)
        c.state.append(KPoint(SIMD3(0.25, 0.25, 0), "K")) // a real edit to undo
        XCTAssertEqual(c.renderer?.selectedKPathNode, 0)
        c.state.undoLast()   // replaceKPath -> syncFromState
        XCTAssertNil(c.renderer?.selectedKPathNode, "Undo (whole-route) must clear the highlight")
    }

    // The "Default" control regenerates the route (onResetKPath -> replaceKPath);
    // that wholesale replacement must also clear the selection.
    func testResetToDefaultClearsSelection() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        c.state.onSelectKPathNode?(0)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 0)
        c.state.resetToDefault()   // onResetKPath -> controller -> state.replaceKPath
        XCTAssertNil(c.renderer?.selectedKPathNode, "Default (whole-route) must clear the highlight")
    }

    // A single-node edit is NOT a wholesale replacement, so the selection must
    // survive it. This guards against over-clearing: editing a selected node's
    // label must keep it highlighted.
    func testSingleNodeEditPreservesSelection() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        c.state.onSelectKPathNode?(1)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 1)
        c.state.updateLabel(at: 1, to: "Z")   // granular edit, no replaceKPath
        XCTAssertEqual(c.renderer?.selectedKPathNode, 1, "single-node edit must keep the highlight")
    }

    // resetView is a natural clearing point for the transient highlight.
    func testResetViewClearsSelection() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        c.state.onSelectKPathNode?(2)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 2)
        c.resetView()
        XCTAssertNil(c.renderer?.selectedKPathNode, "resetView must clear the highlight")
    }

    // resetView must bump viewResetGeneration (the SideBar observes this to clear
    // its local selected node/editor) WITHOUT bumping routeGeneration (the route is
    // unchanged — only the camera resets).
    func testResetViewBumpsViewResetGenerationOnly() throws {
        let c = MainWindowController(scene: try routeScene(), showWindow: false)
        let routeGenBefore = c.state.routeGeneration
        c.state.onSelectKPathNode?(1)
        c.resetView()
        XCTAssertEqual(c.state.viewResetGeneration, 1, "resetView must bump viewResetGeneration")
        XCTAssertEqual(c.state.routeGeneration, routeGenBefore, "resetView must NOT bump routeGeneration")
    }

    // MARK: - routeGeneration bump semantics (the SideBar's .onChange(of: routeGeneration) invariant)

    // Whole-route replacement bumps routeGeneration so the SideBar clears its local
    // selection/draft even when the selected index is still valid.
    func testReplaceKPathBumpsRouteGeneration() {
        let state = SideBarState()
        XCTAssertEqual(state.routeGeneration, 0)
        state.replaceKPath(points: [KPoint(SIMD3(0, 0, 0), "Γ")], breaks: [],
                           provenance: .generated, signature: "sig")
        XCTAssertEqual(state.routeGeneration, 1, "replaceKPath must bump routeGeneration")
    }

    // Single-node edits must NOT bump routeGeneration — otherwise the SideBar would
    // clear the selection every time a selected node's coordinate/label changes.
    func testSingleNodeEditsDoNotBumpRouteGeneration() {
        let state = SideBarState()
        state.replaceKPath(points: [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")],
                           breaks: [], provenance: .generated, signature: "sig")
        let baseline = state.routeGeneration
        state.updateLabel(at: 0, to: "G")
        XCTAssertEqual(state.routeGeneration, baseline, "updateLabel must not bump routeGeneration")
        state.updateKPathPoint(at: 0, fractionalCoordinate: SIMD3(0.1, 0, 0), label: "G")
        XCTAssertEqual(state.routeGeneration, baseline, "updateKPathPoint must not bump routeGeneration")
        state.moveUp(at: 1)
        XCTAssertEqual(state.routeGeneration, baseline, "moveUp must not bump routeGeneration")
        state.remove(at: 1)
        XCTAssertEqual(state.routeGeneration, baseline, "remove must not bump routeGeneration")
        state.append(KPoint(SIMD3(0.5, 0.5, 0), "M"))
        XCTAssertEqual(state.routeGeneration, baseline, "append must not bump routeGeneration")
    }

    // clear() and undoLast() funnel through replaceKPath, so they bump routeGeneration.
    func testClearAndUndoBumpRouteGeneration() {
        let state = SideBarState()
        state.replaceKPath(points: [KPoint(SIMD3(0, 0, 0), "Γ")], breaks: [],
                           provenance: .generated, signature: "sig")
        let afterReplace = state.routeGeneration
        state.clear()
        XCTAssertEqual(state.routeGeneration, afterReplace + 1, "clear must bump routeGeneration")
        state.append(KPoint(SIMD3(0.5, 0, 0), "X"))
        let afterAppend = state.routeGeneration
        state.undoLast()
        XCTAssertEqual(state.routeGeneration, afterAppend + 1, "undo (whole-route) must bump routeGeneration")
    }

    // A frame change replaces the route wholesale (reloadFrame -> replaceKPath);
    // the selection must clear. Driven through the production path: setting
    // state.frameIndex triggers syncFromState -> reloadFrame.
    func testFrameReloadClearsSelection() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si.anim_3to1.axsf")
        let c = MainWindowController(scene: Scene(), showWindow: false)
        c.loadFile(Scene(loaded: try Parser.load(url)), from: url, frameIndex: 0)
        XCTAssertEqual(c.state.frameCount, 2)
        // A generated route exists on this crystal; select its first node via the bridge.
        c.state.onSelectKPathNode?(0)
        XCTAssertEqual(c.renderer?.selectedKPathNode, 0)
        c.state.frameIndex = 1   // production path -> syncFromState -> reloadFrame
        XCTAssertNil(c.renderer?.selectedKPathNode, "frame reload must clear the highlight")
    }
}
