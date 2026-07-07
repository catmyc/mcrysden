import AppKit
import MetalKit

protocol World: AnyObject {
    var camera: Camera { get set }
    var scene: Scene { get set }
    func setNeedsRender()
}

final class MetalView: MTKView {
    weak var world: World?
    private var lastMouse: NSPoint?

    override init(frame: NSRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        commonInit()
    }
    required init(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        colorPixelFormat = .rgba8Unorm
        depthStencilPixelFormat = .depth32Float
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        // delegate is the Renderer, set by owner after init
    }

    override func mouseDown(with e: NSEvent)       { lastMouse = convert(e.locationInWindow, from: nil) }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let last = lastMouse else { lastMouse = p; return }
        let dx = Float(p.x - last.x), dy = Float(p.y - last.y)
        lastMouse = p
        let rotX = simd_quatf(angle: dy * 0.01, axis: SIMD3(1,0,0))
        let rotY = simd_quatf(angle: dx * 0.01, axis: SIMD3(0,1,0))
        world?.camera.rotation = rotY * rotX * world!.camera.rotation
        world?.setNeedsRender()
    }
    override func rightMouseDragged(with e: NSEvent) {
        // slab distance adjust if slab active
        guard var slab = world?.scene.slab else { return }
        let p = convert(e.locationInWindow, from: nil)
        let delta = Float(p.y - (lastMouse?.y ?? p.y)) * 0.05
        lastMouse = p
        slab.planeA.distance += delta
        world?.scene.slab = slab
        world?.setNeedsRender()
    }
    override func scrollWheel(with e: NSEvent) {
        let factor = Float(1.0 + e.scrollingDeltaY * 0.001)
        world?.camera.distance = max(2, (world?.camera.distance ?? 20) * factor)
        world?.setNeedsRender()
    }
    override func magnify(with e: NSEvent) {
        let factor = Float(1.0 + e.magnification)
        world?.camera.distance = max(2, (world?.camera.distance ?? 20) * factor)
        world?.setNeedsRender()
    }
}
