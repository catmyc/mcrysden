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
    var scene: Scene { didSet { renderer.scene = scene; applyCameraForNewSceneIfNeeded() } }
    var camera = Camera()

    init(scene: Scene) {
        self.scene = scene
        let device = MTLCreateSystemDefaultDevice()!
        renderer = try! Renderer(device: device)
        renderer.scene = scene
        sidebar = NSHostingView(rootView: SideBar())
        canvas = MetalView(frame: .zero, device: device)
        let f = CGRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(contentRect: f, styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init()
        canvas.delegate = renderer
        canvas.world = self
        renderer.currentCamera = camera
        layoutSplit()
        window.center()
        window.makeKeyAndOrderFront(nil)
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

    func setNeedsRender() {
        renderer.currentCamera = camera
        canvas.draw()
    }

    func applyCameraForNewSceneIfNeeded() {
        let (c, r) = scene.boundingSphere()
        camera.center = c
        camera.distance = max(8, r * 3)
        setNeedsRender()
    }
}
