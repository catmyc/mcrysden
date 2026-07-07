import AppKit
import Metal
import MetalKit
import SwiftUI

final class MainWindowController: NSObject, World {
    let window: NSWindow
    let split = NSSplitView()
    let sidebar: NSHostingView<SideBar>
    let canvas: MetalView
    let renderer: Renderer
    private lazy var renderer2D = try? Renderer2D(device: MTLCreateSystemDefaultDevice()!)
    var scene: Scene { didSet { renderer.scene = scene; renderer2D?.scene = scene } }
    var camera = Camera()
    let state: SideBarState

    init(scene: Scene) {
        self.scene = scene
        let device = MTLCreateSystemDefaultDevice()!
        renderer = try! Renderer(device: device)
        renderer.scene = scene
        let state = SideBarState()
        self.state = state
        sidebar = NSHostingView(rootView: SideBar(state: state))
        canvas = MetalView(frame: .zero, device: device)
        let f = CGRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(contentRect: f, styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init()
        state.onChange = { [weak self] in self?.syncFromState() }
        canvas.delegate = renderer
        canvas.world = self
        renderer.currentCamera = camera
        refreshDelegate()
        layoutSplit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        applyCameraForNewSceneIfNeeded()
    }

    /// Apply a freshly-loaded scene: reframe the camera ONCE (spec §6 — the
    /// camera resets on file open) and sync the sidebar so the next sidebar
    /// change does not clobber the loaded state with defaults.
    func loadFile(_ scene: Scene) {
        self.scene = scene
        state.syncFromScene(scene)
        applyCameraForNewSceneIfNeeded()
    }

    private func layoutSplit() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(canvas)
        split.setPosition(260, ofDividerAt: 0)
        window.contentView = split
    }

    private func refreshDelegate() {
        if scene.displayMode.is2D {
            canvas.delegate = renderer2D
            renderer2D?.scene = scene
            renderer2D?.background = renderer.background
        } else {
            canvas.delegate = renderer
        }
    }

    func setNeedsRender() {
        renderer.currentCamera = camera
        renderer2D?.currentCamera = camera
        refreshDelegate()
        canvas.draw()
    }

    func applyCameraForNewSceneIfNeeded() {
        let (c, r) = scene.boundingSphere()
        camera.center = c
        camera.distance = max(8, r * 3)
        setNeedsRender()
    }

    func syncFromState() {
        scene.displayMode = state.displayMode
        scene.atomScale = state.atomScale
        scene.bondRadius = state.bondRadius
        scene.showCellFrame = state.showCellFrame
        scene.showAxes = state.showAxes
        // supercell
        let sc = SuperCell(n1: state.n1, n2: state.n2, n3: state.n3)
        if sc.total != scene.superCell.total {
            scene = scene.widenSuperCell(sc)
        }
        // slab — build the Slab then run the scene through applySlab so the
        // atom set is actually filtered (Important #2 of the final review:
        // assigning scene.slab alone left slab/vacuum inert at runtime).
        let slab = state.slabEnabled
            ? Slab(planeA: Plane(h: state.slabA_h, k: state.slabA_k, l: state.slabA_l, distance: state.slabA_dist),
                   planeB: Plane(h: state.slabB_h, k: state.slabB_k, l: state.slabB_l, distance: state.slabB_dist))
            : nil
        scene = scene.applySlab(slab)
        // background
        if let c = colorFromHex(state.backgroundHex) {
            renderer.background = MTLClearColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        setNeedsRender()
    }

    private func colorFromHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255.0, Double((v >> 8) & 0xFF) / 255.0, Double(v & 0xFF) / 255.0)
    }
}
