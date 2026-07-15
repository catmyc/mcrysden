import AppKit
import MetalKit
import simd

protocol World: AnyObject {
    var camera: Camera { get set }
    var scene: Scene { get set }
    func setNeedsRender()
    /// The camera actually used to render the scene (2D modes override with
    /// identity rotation + ortho). Hit-testing must use this to match pixels.
    func renderCamera() -> Camera
    /// Toggle selection of one atom index (measurement-cap aware).
    func toggleSelection(_ index: Int)
    /// Adjust slab plane A distance by `delta` (right-drag): applies the new
    /// slab so atoms are actually filtered, instead of mutating a bare field.
    func adjustSlabPlaneA(by delta: Float)
}

final class MetalView: MTKView {
    weak var world: World?
    private var lastMouse: NSPoint?
    private var mouseDownPos: NSPoint?

    override init(frame: NSRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        commonInit()
    }
    required init(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        colorPixelFormat = .rgba8Unorm
        depthStencilPixelFormat = .depth32Float
        preferredFramesPerSecond = 60
        // On-demand rendering: we call setNeedsDisplay() ourselves after each
        // camera/scene change instead of driving a continuous display loop.
        enableSetNeedsDisplay = true
        isPaused = true
        // delegate is the Renderer, set by owner after init
    }

    override func mouseDown(with e: NSEvent) {
        // Defensive: ignore clicks delivered while a modal tracking loop is
        // active (e.g. the Open panel) so we never hit-test against a stale
        // scene or a zero-sized canvas.
        guard let w = window, w.isVisible else { return }
        let p = convert(e.locationInWindow, from: nil)
        lastMouse = p; mouseDownPos = p
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let last = lastMouse else { lastMouse = p; return }
        let dx = Float(p.x - last.x), dy = Float(p.y - last.y)
        lastMouse = p
        // The camera's right/up axes in world space are the first two columns
        // of its rotation matrix — the same basis the orbit path recomputes,
        // shared here so pan and orbit never disagree about screen directions.
        let R = float4x4(self.world!.camera.rotation)
        let viewRight = (R * SIMD4<Float>(1, 0, 0, 0)).xyz   // camera right → world
        let viewUp    = (R * SIMD4<Float>(0, 1, 0, 0)).xyz   // camera up → world

        if e.modifierFlags.contains(.option) {
            // Option-drag = PAN: translate the look-at center in the camera's
            // right/up plane so a grabbed point follows the mouse ("grab and
            // drag" semantics). World units per pixel come from the projected
            // visible height at the target plane (perspective fov = π/4).
            let distance = max(1.0, world!.camera.distance)
            let worldPerPixel = Float(2.0 * distance * tan(Float.pi / 8)) / Float(bounds.height)
            world?.camera.center -= (viewRight * dx + viewUp * dy) * worldPerPixel
        } else {
            // Plain drag = ORBIT around the camera's current up/right axes rather
            // than world-fixed axes: a horizontal drag rotates around what is
            // currently the vertical direction on screen, and a vertical drag
            // rotates around the horizontal direction — the intuitive "follow
            // your mouse" behavior.
            let rotV = simd_quatf(angle: +dy * 0.01, axis: viewRight)
            let rotH = simd_quatf(angle: -dx * 0.01, axis: viewUp)
            world?.camera.rotation = rotH * rotV * world!.camera.rotation
        }
        world?.setNeedsRender()
    }

    override func mouseUp(with e: NSEvent) {
        guard let down = mouseDownPos else { return }
        let up = convert(e.locationInWindow, from: nil)
        let dist = hypot(up.x - down.x, up.y - down.y)
        mouseDownPos = nil
        guard dist < 5 else { return }   // a drag, not a click

        // Project each atom to screen accounting for its on-screen radius AND
        // depth: the click must land inside the rendered disk, and among
        // overlapping atoms the closest to the camera wins.
        guard let s = world?.scene, s.atoms.count > 0 else { return }
        let cw = bounds.width, ch = bounds.height
        guard cw > 1, ch > 1 else { return }   // needs a drawable pixel area
        // Use the renderer's effective camera so the hit test matches the
        // rendered image exactly (2D modes force identity rotation + ortho).
        let cam = world!.renderCamera()
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: Float(cw / ch))
        // up.y is bottom-origin (AppKit); sy/oy below are top-origin, so flip.
        let px = Float(up.x), py = Float(ch) - Float(up.y)

        var bestIdx = -1
        var bestDepth = Float.infinity      // prefer nearest (smallest view -z)
        // Capture once; clamp() below uses the current scene so cap changes
        // mid-gesture still behave.
        for (i, a) in s.atoms.enumerated() {
            let worldPos = SIMD4<Float>(a.coord.x, a.coord.y, a.coord.z, 1)
            let viewPos = (view * worldPos).xyz
            let depth = -viewPos.z           // positive into screen (Metal: -z forward)
            guard depth > 0.01 else { continue }   // behind camera
            // Project the atom center to screen pixels.
            let vp = view * worldPos
            let clipC = proj * vp
            guard abs(clipC.w) > 1e-10 else { continue }
            let ndcC = clipC / clipC.w
            let sx = (ndcC.x * 0.5 + 0.5) * Float(cw)
            let sy = (1.0 - (ndcC.y * 0.5 + 0.5)) * Float(ch)
            // Estimate projected radius (px): offset in view space along
            // view-right by the atom's world radius, then project the
            // offset point and measure the pixel separation.  Offsetting in
            // view space keeps the direction perpendicular to the view axis.
            let rWorld = atomWorldRadius(atomicNumber: a.atomicNumber, scale: s.atomScale, mode: s.displayMode)
            let offView = vp + SIMD4<Float>(rWorld, 0, 0, 0)
            let clipO = proj * offView
            guard abs(clipO.w) > 1e-10 else { continue }
            let ndcO = clipO / clipO.w
            let ox = (ndcO.x * 0.5 + 0.5) * Float(cw)
            let oy = (1.0 - (ndcO.y * 0.5 + 0.5)) * Float(ch)
            let rScreen = sqrt((ox - sx) * (ox - sx) + (oy - sy) * (oy - sy))
            let hitR = max(rScreen, 6)       // at least 6px so tiny atoms stay pickable
            let d = sqrt((sx - px) * (sx - px) + (sy - py) * (sy - py))
            if d <= hitR && depth < bestDepth { bestDepth = depth; bestIdx = i }
        }
        if bestIdx >= 0 {
            world?.toggleSelection(bestIdx)
            world?.setNeedsRender()
        }
    }

    /// World-radius of an atom matching what the renderer draws, so the hit
    /// test uses the disk the user actually sees.
    private func atomWorldRadius(atomicNumber: Int, scale: Float, mode: DisplayMode) -> Float {
        switch mode {
        case .spaceFill: return ElementTable.vdwRadius(atomicNumber)
        case .wireFrame: return 0.06
        case .polyhedral: return 0.12
        default: return ElementTable.covalentRadius(atomicNumber) * scale
        }
    }

    override func rightMouseDragged(with e: NSEvent) {
        // slab distance adjust if slab active: route through the controller so
        // the slab is actually re-applied (atoms filtered), not just a bare field.
        let p = convert(e.locationInWindow, from: nil)
        let delta = Float(p.y - (lastMouse?.y ?? p.y)) * 0.05
        lastMouse = p
        world?.adjustSlabPlaneA(by: delta)
    }
    override func rightMouseDown(with e: NSEvent) {
        lastMouse = convert(e.locationInWindow, from: nil)
    }
    override func rightMouseUp(with e: NSEvent) {
        lastMouse = nil
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
