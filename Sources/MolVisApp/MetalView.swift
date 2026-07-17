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
        guard let world else { return }
        if e.modifierFlags.contains(.option) {
            // Option-drag = PAN: translate the look-at center in the camera's
            // right/up plane so a grabbed point follows the mouse ("grab and
            // drag" semantics). The decomposed helpers below use the camera's
            // EFFECTIVE projection (2D modes force identity rotation +
            // orthographic), so pan tracks the rendered pixels exactly.
            let is2D = world.scene.displayMode.is2D
            let axes = MetalView.panAxes(camera: world.camera, is2D: is2D)
            let wpp = MetalView.panWorldPerPixel(camera: world.camera, viewHeight: Float(bounds.height), is2D: is2D)
            world.camera.center -= (axes.right * dx + axes.up * dy) * wpp
        } else {
            // Plain drag = ORBIT around the camera's current up/right axes rather
            // than world-fixed axes: a horizontal drag rotates around what is
            // currently the vertical direction on screen, and a vertical drag
            // rotates around the horizontal direction — the intuitive "follow
            // your mouse" behavior.
            let R = float4x4(world.camera.rotation)
            let viewRight = (R * SIMD4<Float>(1, 0, 0, 0)).xyz   // camera right → world
            let viewUp    = (R * SIMD4<Float>(0, 1, 0, 0)).xyz   // camera up → world
            let rotV = simd_quatf(angle: +dy * 0.01, axis: viewRight)
            let rotH = simd_quatf(angle: -dx * 0.01, axis: viewUp)
            world.camera.rotation = rotH * rotV * world.camera.rotation
        }
        world.setNeedsRender()
    }

    /// Pan basis (camera-right, camera-up) as world-space unit vectors. 2D
    /// modes force an identity rotation in the renderer, so pan must match by
    /// using world axes rather than the stored 3D rotation matrix.
    static func panAxes(camera: Camera, is2D: Bool) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        if is2D { return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)) }
        let R = float4x4(camera.rotation)
        return ((R * SIMD4<Float>(1, 0, 0, 0)).xyz, (R * SIMD4<Float>(0, 1, 0, 0)).xyz)
    }

    /// World units per screen pixel for panning. Perspective uses
    /// `2 · distance · tan(fov/2)` over the viewport height (fov = π/4);
    /// orthographic uses the projection's full visible height
    /// `2 · max(1, distance)`. 2D modes render with the orthographic path
    /// irrespective of the stored `camera.perspective`, so the orthographic
    /// scale applies there even if a perspective camera is set.
    static func panWorldPerPixel(camera: Camera, viewHeight: Float, is2D: Bool) -> Float {
        let h = viewHeight > 0 ? viewHeight : 1
        let d = max(1.0, camera.distance)
        if is2D || !camera.perspective {
            return (2.0 * d) / h
        }
        return (2.0 * d * tan(Float.pi / 8)) / h
    }

    override func mouseUp(with e: NSEvent) {
        guard let down = mouseDownPos else { return }
        let up = convert(e.locationInWindow, from: nil)
        let dist = hypot(up.x - down.x, up.y - down.y)
        mouseDownPos = nil
        guard dist < 5 else { return }   // a drag, not a click

        // Project each atom to screen accounting for its on-screen radius AND
        // depth: the click must land inside the rendered disk, and among
        // overlapping atoms the closest to the camera wins. Hidden/empty
        // structures are not pickable (matches the renderer's visibility gate).
        guard let s = world?.scene, MetalView.hitTestEnabled(scene: s) else { return }
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

    /// Distance multiplier for a pinch-gesture delta. Positive magnification
    /// (zoom-in) reduces distance; the 0.5 damper keeps the gesture smooth. The raw
    /// event value is clamped into a sane band and the resulting factor is then pinned
    /// into [0.01, 2] so extreme / NaN / infinite events can never yield a zero,
    /// negative, NaN, or infinite factor — any of which would corrupt the camera
    /// distance. The 0.01 floor keeps an extreme-but-finite pinch from collapsing the
    /// distance to a near-zero step (a de facto no-op that never reaches the target),
    /// while leaving the normal 0.5 damped range untouched. A non-finite event is
    /// treated as a no-op (factor 1.0). The view's `magnify(with:)` multiplies
    /// `camera.distance` by the factor and the renderer clamps the result to a minimum
    /// of 2.
    static func clampedMagnification(_ raw: Float) -> Float {
        guard raw.isFinite else { return 0 }
        return min(2 - Float.ulpOfOne, max(-2, raw))
    }

    static func magnifyFactor(for magnification: Float) -> Float {
        max(0.01, 1.0 - clampedMagnification(magnification) * 0.5)
    }

    /// Whether atom picking is enabled for this scene: requires atoms present
    /// AND the structure not hidden. Hidden structures must not be clickable,
    /// and there is nothing to pick in an empty scene.
    static func hitTestEnabled(scene: Scene) -> Bool {
        scene.atoms.count > 0 && scene.showStructure
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
        // A non-finite scrolling delta (garbage trackpad event) would make the
        // factor NaN/Inf and corrupt camera.distance, so treat it as a no-op.
        // Swift's `max(2, x)` collapses NaN to 2 but NOT Inf, so guard explicitly.
        guard let factor = MetalView.scrollZoomFactor(e.scrollingDeltaY) else { return }
        world?.camera.distance = max(2, (world?.camera.distance ?? 20) * factor)
        world?.setNeedsRender()
    }

    /// Distance scale factor for a scroll delta, or `nil` for a non-finite delta
    /// (a malformed trackpad event that must NOT corrupt the camera distance to
    /// NaN/Inf). Mirrors the `magnifyFactor`/`clampedMagnification` seam.
    static func scrollZoomFactor(_ delta: CGFloat) -> Float? {
        guard delta.isFinite else { return nil }
        return Float(1.0 + delta * 0.001)
    }
    override func magnify(with e: NSEvent) {
        let factor = MetalView.magnifyFactor(for: Float(e.magnification))
        world?.camera.distance = max(2, (world?.camera.distance ?? 20) * factor)
        world?.setNeedsRender()
    }
}
