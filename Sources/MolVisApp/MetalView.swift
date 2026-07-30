import AppKit
import MetalKit
import simd

protocol World: AnyObject {
    var camera: Camera { get set }
    var scene: Scene { get set }
    var isReciprocalPathEditing: Bool { get }
    func setNeedsRender()
    /// The camera actually used to render the scene (2D modes override with
    /// identity rotation + ortho). Hit-testing must use this to match pixels.
    func renderCamera() -> Camera
    /// Toggle selection of one atom index (measurement-cap aware).
    func toggleSelection(_ index: Int)
    /// Adjust slab plane A distance by `delta` (right-drag): applies the new
    /// slab so atoms are actually filtered, instead of mutating a bare field.
    func adjustSlabPlaneA(by delta: Float)
    /// Handle a click in reciprocal k-path edit mode. `click` is the pointer in
    /// top-origin pixel coordinates; `viewport` is the drawable size in pixels.
    /// Returns true if the click was consumed — when it was, the caller must skip
    /// atom hit-testing so selection never fires while editing the route.
    func handleReciprocalPathClick(at click: SIMD2<Float>, viewport: SIMD2<Float>) -> Bool
    /// Handle pointer movement in reciprocal k-path edit mode. `point` is nil when
    /// the pointer leaves the view or a gesture begins; otherwise it is a top-origin
    /// coordinate in the view's logical drawable space, matching the click hook.
    /// `viewport` is the corresponding finite, positive logical drawable size.
    func handleReciprocalPathHover(at point: SIMD2<Float>?, viewport: SIMD2<Float>)
    /// Called once for each actual valid logical viewport-size change. The default
    /// implementation below preserves ordinary redraw behavior for other worlds.
    func reciprocalViewportSizeDidChange(_ viewport: SIMD2<Float>)
    func reciprocalAccessibilityDescriptors(viewport: SIMD2<Float>) -> [ReciprocalAccessibilityDescriptor]
    func focusReciprocalAccessibilityCandidate(_ descriptor: ReciprocalAccessibilityDescriptor)
    func activateReciprocalAccessibilityCandidate(_ descriptor: ReciprocalAccessibilityDescriptor) -> Bool
    func clearReciprocalAccessibilityFocus()
}

extension World {
    var isReciprocalPathEditing: Bool { false }
    func reciprocalViewportSizeDidChange(_ viewport: SIMD2<Float>) { setNeedsRender() }
    func reciprocalAccessibilityDescriptors(viewport: SIMD2<Float>)
        -> [ReciprocalAccessibilityDescriptor] { [] }
    func focusReciprocalAccessibilityCandidate(_ descriptor: ReciprocalAccessibilityDescriptor) {}
    func activateReciprocalAccessibilityCandidate(_ descriptor: ReciprocalAccessibilityDescriptor) -> Bool { false }
    func clearReciprocalAccessibilityFocus() {}
}

enum ReciprocalKeyboardAction {
    case previous
    case next
    case activate
    case clear
}

struct ReciprocalAccessibilityDescriptor: Equatable {
    let candidate: BZCandidate
    let screenPoint: SIMD2<Float>
    let screenRadius: Float
    let label: String
    let value: String
    let help: String

    init(candidate: BZCandidate, screenPoint: SIMD2<Float>, screenRadius: Float = 8,
         label: String, value: String, help: String) {
        self.candidate = candidate
        self.screenPoint = screenPoint
        self.screenRadius = screenRadius
        self.label = label
        self.value = value
        self.help = help
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.candidate.point == rhs.candidate.point
            && lhs.candidate.cartesian == rhs.candidate.cartesian
            && lhs.candidate.type.rawValue == rhs.candidate.type.rawValue
            && lhs.screenPoint == rhs.screenPoint
            && lhs.screenRadius == rhs.screenRadius
            && lhs.label == rhs.label
            && lhs.value == rhs.value
            && lhs.help == rhs.help
    }
}

final class ReciprocalAccessibilityElement: NSAccessibilityElement {
    let descriptor: ReciprocalAccessibilityDescriptor
    weak var owner: MetalView?

    init(descriptor: ReciprocalAccessibilityDescriptor, owner: MetalView) {
        self.descriptor = descriptor
        self.owner = owner
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(descriptor.label)
        setAccessibilityValue(descriptor.value)
        setAccessibilityHelp(descriptor.help)
        setAccessibilityEnabled(true)
    }

    override func accessibilityParent() -> Any? { owner }

    override func accessibilityFrame() -> NSRect {
        guard let owner else { return .zero }
        return owner.accessibilityFrame(for: descriptor.screenPoint,
                                        radius: descriptor.screenRadius,
                                        viewport: owner.bounds.size)
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.activateReciprocalAccessibilityElement(self) ?? false
    }
}

final class MetalView: MTKView {
    weak var world: World?
    private var lastMouse: NSPoint?
    private var mouseDownPos: NSPoint?
    private var reciprocalHoverTrackingArea: NSTrackingArea?
    private var lastReciprocalHoverViewport: SIMD2<Float>?
    private var lastLogicalBoundsSize: CGSize?
    private var reciprocalAccessibilityElements: [ReciprocalAccessibilityElement] = []
    private var reciprocalAccessibilityDescriptors: [ReciprocalAccessibilityDescriptor] = []
    private var reciprocalKeyboardFocusIndex: Int?
    private var reciprocalAccessibilityWasQueried = false

    /// Tests replace this with a recorder; production keeps AppKit's global
    /// notification mechanism as the default.
    var accessibilityNotificationPoster: (NSAccessibility.Notification, Any) -> Void = {
        notification, element in
        NSAccessibility.post(element: element, notification: notification)
    }

    /// VoiceOver and keyboard focus are meaningful only while the reciprocal
    /// editor is active. Returning false outside that mode leaves normal view
    /// focus and key handling to AppKit.
    override var acceptsFirstResponder: Bool {
        world?.isReciprocalPathEditing == true
    }

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
        if bounds.size.width.isFinite, bounds.size.height.isFinite,
           bounds.size.width > 0, bounds.size.height > 0 {
            lastLogicalBoundsSize = bounds.size
        }
        // delegate is the Renderer, set by owner after init
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        notifyWorldOfLogicalSizeChange()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        notifyWorldOfLogicalSizeChange()
    }

    /// Resize the persistent overlay through the normal World render path, but
    /// only once for each valid logical drawable size. This also catches split
    /// divider changes, which do not require an NSWindow resize notification.
    private func notifyWorldOfLogicalSizeChange() {
        let size = bounds.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            guard lastLogicalBoundsSize != nil else { return }
            lastLogicalBoundsSize = nil
            clearReciprocalFocusForResize()
            return
        }
        guard lastLogicalBoundsSize != size else { return }
        lastLogicalBoundsSize = size
        clearReciprocalFocusForResize()
        world?.reciprocalViewportSizeDidChange(SIMD2<Float>(Float(size.width), Float(size.height)))
    }

    private func clearReciprocalFocusForResize() {
        invalidateReciprocalAccessibilityFocus()
        world?.clearReciprocalAccessibilityFocus()
    }

    /// Converts AppKit's bottom-origin view point to the top-origin coordinates
    /// consumed by reciprocal-space picking. The returned viewport intentionally
    /// uses the same logical bounds as `mouseUp`, rather than a backing-scale
    /// conversion, so hover and click projections remain identical.
    static func reciprocalHoverPayload(for point: NSPoint, bounds: NSRect)
        -> (point: SIMD2<Float>, viewport: SIMD2<Float>)? {
        guard let viewport = reciprocalHoverViewport(for: bounds),
              point.x.isFinite, point.y.isFinite else { return nil }
        let x = Float(point.x)
        let y = Float(bounds.height) - Float(point.y)
        guard x.isFinite, y.isFinite,
              x >= 0, x <= viewport.x, y >= 0, y <= viewport.y else { return nil }
        return (SIMD2<Float>(x, y), viewport)
    }

    /// Returns a finite, positive viewport or nil for a zero/invalid view.
    static func reciprocalHoverViewport(for bounds: NSRect) -> SIMD2<Float>? {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let viewport = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        guard viewport.x.isFinite, viewport.y.isFinite else { return nil }
        return viewport
    }

    override func updateTrackingAreas() {
        if let area = reciprocalHoverTrackingArea {
            removeTrackingArea(area)
            reciprocalHoverTrackingArea = nil
        }
        super.updateTrackingAreas()

        // `.inVisibleRect` makes AppKit keep this area aligned with clipping and
        // resizing; no continuous MTKView rendering loop is needed for tracking.
        // Do not clear hover or accessibility state here: AppKit can rebuild
        // tracking areas without changing geometry, and the hover callback also
        // owns the keyboard tooltip state. Mouse exit, gestures, and explicit
        // geometry invalidation handle genuine pointer/presentation changes.
        guard Self.reciprocalHoverViewport(for: bounds) != nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        reciprocalHoverTrackingArea = area
    }

    private func sendReciprocalPathHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let payload = Self.reciprocalHoverPayload(for: point, bounds: bounds) else { return }
        clearReciprocalAccessibilityFocusForPointer()
        lastReciprocalHoverViewport = payload.viewport
        world?.handleReciprocalPathHover(at: payload.point, viewport: payload.viewport)
    }

    private var hasReciprocalAccessibilityFocus: Bool {
        reciprocalKeyboardFocusIndex != nil
            || reciprocalAccessibilityElements.contains(where: { $0.isAccessibilityFocused() })
    }

    /// Pointer hover owns the shared reciprocal tooltip. Clear every local AX
    /// representation before the world receives the pointer candidate, so the
    /// controller cannot leave a keyboard-focused child behind the pointer UI.
    private func clearReciprocalAccessibilityFocusForPointer() {
        guard hasReciprocalAccessibilityFocus else { return }
        reciprocalKeyboardFocusIndex = nil
        clearAccessibilityElementFocus()
        world?.clearReciprocalAccessibilityFocus()
        postReciprocalAccessibilityNotification(.focusedUIElementChanged)
    }

    private func clearReciprocalPathHover() {
        // If the view was resized to zero before the exit event arrived, retain
        // the last valid viewport so the clear notification still has valid data.
        guard let viewport = Self.reciprocalHoverViewport(for: bounds) ?? lastReciprocalHoverViewport else {
            return
        }
        lastReciprocalHoverViewport = nil
        world?.handleReciprocalPathHover(at: nil, viewport: viewport)
    }

    override func mouseEntered(with e: NSEvent) {
        super.mouseEntered(with: e)
        sendReciprocalPathHover(for: e)
    }

    override func mouseMoved(with e: NSEvent) {
        super.mouseMoved(with: e)
        sendReciprocalPathHover(for: e)
    }

    override func mouseExited(with e: NSEvent) {
        clearReciprocalPathHover()
        super.mouseExited(with: e)
    }

    override func mouseDown(with e: NSEvent) {
        clearReciprocalPathHover()
        // Defensive: ignore clicks delivered while a modal tracking loop is
        // active (e.g. the Open panel) so we never hit-test against a stale
        // scene or a zero-sized canvas.
        guard let w = window, w.isVisible else { return }
        if world?.isReciprocalPathEditing == true {
            w.makeFirstResponder(self)
        }
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

        let cw = bounds.width, ch = bounds.height
        guard cw > 1, ch > 1 else { return }   // needs a drawable pixel area
        // up.y is bottom-origin (AppKit); px/sy below are top-origin, so flip.
        let px = Float(up.x), py = Float(ch) - Float(up.y)

        // Reciprocal k-path edit mode (phase 2): offer the click to the BZ path
        // handler BEFORE atom picking and BEFORE the atom-pick eligibility guard. The
        // BZ editor must work even with the structure hidden or atoms empty (a user
        // may focus on the BZ then), and in edit mode every click is consumed (so atom
        // selection never occurs), whether or not it hits a landmark.
        let click = SIMD2<Float>(px, py)
        let viewport = SIMD2<Float>(Float(cw), Float(ch))
        if world?.handleReciprocalPathClick(at: click, viewport: viewport) == true {
            return
        }

        // Project each atom to screen accounting for its on-screen radius AND
        // depth: the click must land inside the rendered disk, and among
        // overlapping atoms the closest to the camera wins. Hidden/empty
        // structures are not pickable (matches the renderer's visibility gate).
        guard let s = world?.scene, MetalView.hitTestEnabled(scene: s) else { return }
        // Use the renderer's effective camera so the hit test matches the
        // rendered image exactly (2D modes force identity rotation + ortho).
        let cam = world!.renderCamera()
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: Float(cw / ch))

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
        clearReciprocalPathHover()
        lastMouse = convert(e.locationInWindow, from: nil)
    }
    override func rightMouseUp(with e: NSEvent) {
        lastMouse = nil
    }

    /// Apply a zoom factor accepted by one of the gesture handlers. A neutral
    /// factor remains a render-only no-op, while an actual zoom invalidates
    /// reciprocal-space hover before changing the camera.
    func applyZoom(factor: Float) {
        if factor != 1 {
            clearReciprocalPathHover()
        }
        world?.camera.distance = max(2, (world?.camera.distance ?? 20) * factor)
        world?.setNeedsRender()
    }

    /// Apply a scroll delta after validating the value that will affect the
    /// camera. Keeping the guard here makes malformed scroll input a complete
    /// no-op before hover or camera state is touched.
    func applyScrollZoom(delta: CGFloat) {
        guard let factor = MetalView.scrollZoomFactor(delta) else { return }
        applyZoom(factor: factor)
    }

    override func scrollWheel(with e: NSEvent) {
        // A non-finite scrolling delta (garbage trackpad event) would make the
        // factor NaN/Inf and corrupt camera.distance, so treat it as a no-op.
        // Swift's `max(2, x)` collapses NaN to 2 but NOT Inf, so guard explicitly.
        applyScrollZoom(delta: e.scrollingDeltaY)
    }

    /// Distance scale factor for a scroll delta, or `nil` for a non-finite delta
    /// (a malformed trackpad event that must NOT corrupt the camera distance to
    /// NaN/Inf). Mirrors the `magnifyFactor`/`clampedMagnification` seam.
    static func scrollZoomFactor(_ delta: CGFloat) -> Float? {
        guard delta.isFinite else { return nil }
        // A finite CGFloat (e.g. CGFloat.greatestFiniteMagnitude) can overflow the
        // Float conversion and yield ±infinity, which scrollWheel would multiply
        // into the camera distance. Guard on the factor that is actually used.
        let factor = Float(1.0 + delta * 0.001)
        guard factor.isFinite else { return nil }
        return factor
    }
    override func magnify(with e: NSEvent) {
        let factor = MetalView.magnifyFactor(for: Float(e.magnification))
        applyZoom(factor: factor)
    }

    override func keyDown(with event: NSEvent) {
        guard let action = Self.reciprocalKeyboardAction(for: event),
              handleReciprocalKeyboard(action) else {
            super.keyDown(with: event)
            return
        }
    }

    /// Translate only unmodified editor keys. Ordinary command/control/option
    /// shortcuts continue through AppKit, as do all keys outside edit mode.
    static func reciprocalKeyboardAction(for event: NSEvent) -> ReciprocalKeyboardAction? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 123, 126: return .previous
        case 124, 125: return .next
        case 36, 76, 49: return .activate
        case 53: return .clear
        default: return nil
        }
    }

    /// Direct seam for tests and the event handler. Arrow order follows the
    /// deterministic BZ candidate order; left/up move backward and right/down
    /// move forward through that same order.
    @discardableResult
    func handleReciprocalKeyboard(_ action: ReciprocalKeyboardAction) -> Bool {
        guard let world, world.isReciprocalPathEditing else { return false }
        guard let viewport = Self.reciprocalHoverViewport(for: bounds) else {
            invalidateReciprocalAccessibilityFocus()
            world.clearReciprocalAccessibilityFocus()
            return false
        }

        switch action {
        case .clear:
            let hadFocus = hasReciprocalAccessibilityFocus
            reciprocalKeyboardFocusIndex = nil
            clearAccessibilityElementFocus()
            world.clearReciprocalAccessibilityFocus()
            if hadFocus {
                postReciprocalAccessibilityNotification(.focusedUIElementChanged)
            }
            return true
        case .activate:
            let descriptors = currentReciprocalAccessibilityDescriptors(viewport: viewport)
            guard let index = reciprocalKeyboardFocusIndex,
                  descriptors.indices.contains(index) else { return false }
            return world.activateReciprocalAccessibilityCandidate(descriptors[index])
        case .previous, .next:
            let descriptors = currentReciprocalAccessibilityDescriptors(viewport: viewport)
            guard !descriptors.isEmpty else { return false }
            let previousFocus = reciprocalKeyboardFocusIndex
            let delta = action == .previous ? -1 : 1
            let nextIndex: Int
            if let current = reciprocalKeyboardFocusIndex, descriptors.indices.contains(current) {
                nextIndex = (current + delta + descriptors.count) % descriptors.count
            } else {
                nextIndex = delta < 0 ? descriptors.count - 1 : 0
            }
            reciprocalKeyboardFocusIndex = nextIndex
            clearAccessibilityElementFocus()
            world.focusReciprocalAccessibilityCandidate(descriptors[nextIndex])
            _ = accessibilityElementsForReciprocalLandmarks()
            if let element = reciprocalAccessibilityElements[safe: nextIndex] {
                element.setAccessibilityFocused(true)
            }
            if previousFocus != nextIndex {
                if let element = reciprocalAccessibilityElements[safe: nextIndex] {
                    postReciprocalAccessibilityNotification(.focusedUIElementChanged,
                                                             element: element)
                }
            }
            return true
        }
    }

    /// Return the current AX children directly for tests and embedding paths
    /// where VoiceOver is unavailable. The normal AppKit path uses the same
    /// collection through `accessibilityChildren()`.
    func reciprocalAccessibilityElementsForTesting() -> [NSAccessibilityElement] {
        accessibilityElementsForReciprocalLandmarks()
    }

    /// Current keyboard focus is intentionally exposed only as an index into
    /// the current visible descriptor list; it is never persisted in Scene.
    var reciprocalKeyboardFocusIndexForTesting: Int? { reciprocalKeyboardFocusIndex }

    override func accessibilityChildren() -> [Any]? {
        let base = super.accessibilityChildren() ?? []
        let reciprocal = accessibilityElementsForReciprocalLandmarks()
        return base + reciprocal
    }

    private func currentReciprocalAccessibilityDescriptors(viewport: SIMD2<Float>)
        -> [ReciprocalAccessibilityDescriptor] {
        guard world?.isReciprocalPathEditing == true else {
            invalidateReciprocalAccessibilityFocus()
            return []
        }
        return world?.reciprocalAccessibilityDescriptors(viewport: viewport) ?? []
    }

    private func accessibilityElementsForReciprocalLandmarks() -> [ReciprocalAccessibilityElement] {
        guard let viewport = Self.reciprocalHoverViewport(for: bounds),
              world?.isReciprocalPathEditing == true else {
            invalidateReciprocalAccessibilityFocus()
            return []
        }
        let wasQueried = reciprocalAccessibilityWasQueried
        reciprocalAccessibilityWasQueried = true
        let descriptors = currentReciprocalAccessibilityDescriptors(viewport: viewport)
        guard descriptors != reciprocalAccessibilityDescriptors else {
            return reciprocalAccessibilityElements
        }
        let hadExistingAccessibilityState = !reciprocalAccessibilityDescriptors.isEmpty
            || !reciprocalAccessibilityElements.isEmpty
        clearAccessibilityElementFocus()
        reciprocalAccessibilityDescriptors = descriptors
        reciprocalAccessibilityElements = descriptors.map {
            ReciprocalAccessibilityElement(descriptor: $0, owner: self)
        }
        if let index = reciprocalKeyboardFocusIndex,
           reciprocalAccessibilityElements.indices.contains(index) {
            reciprocalAccessibilityElements[index].setAccessibilityFocused(true)
        } else if !reciprocalAccessibilityElements.indices.contains(reciprocalKeyboardFocusIndex ?? -1) {
            reciprocalKeyboardFocusIndex = nil
        }
        if hadExistingAccessibilityState || wasQueried {
            postReciprocalAccessibilityNotification(.layoutChanged)
        }
        return reciprocalAccessibilityElements
    }

    func invalidateReciprocalAccessibilityFocus() {
        let hadAccessibilityState = reciprocalAccessibilityWasQueried
            || !reciprocalAccessibilityDescriptors.isEmpty
            || !reciprocalAccessibilityElements.isEmpty
        let hadFocus = hasReciprocalAccessibilityFocus
        reciprocalKeyboardFocusIndex = nil
        clearAccessibilityElementFocus()
        reciprocalAccessibilityDescriptors = []
        reciprocalAccessibilityElements = []
        reciprocalAccessibilityWasQueried = false
        if hadAccessibilityState {
            postReciprocalAccessibilityNotification(.layoutChanged)
        }
        if hadFocus {
            postReciprocalAccessibilityNotification(.focusedUIElementChanged)
        }
    }

    private func clearAccessibilityElementFocus() {
        for element in reciprocalAccessibilityElements {
            element.setAccessibilityFocused(false)
        }
    }

    fileprivate func activateReciprocalAccessibilityElement(_ element: ReciprocalAccessibilityElement) -> Bool {
        guard let viewport = Self.reciprocalHoverViewport(for: bounds),
              let current = currentReciprocalAccessibilityDescriptors(viewport: viewport)
                .first(where: { $0 == element.descriptor }) else { return false }
        return world?.activateReciprocalAccessibilityCandidate(current) ?? false
    }

    private func postReciprocalAccessibilityNotification(
        _ notification: NSAccessibility.Notification,
        element: Any? = nil
    ) {
        accessibilityNotificationPoster(notification, element ?? self)
    }

    func accessibilityFrame(for point: SIMD2<Float>, radius: Float, viewport: CGSize) -> NSRect {
        guard point.x.isFinite, point.y.isFinite,
              radius.isFinite, radius > 0,
              let window else { return .zero }
        guard let logicalViewport = Self.reciprocalHoverViewport(
            for: NSRect(origin: .zero, size: viewport)) else { return .zero }
        let localY = CGFloat(logicalViewport.y) - CGFloat(point.y)
        let diameter = CGFloat(radius) * 2
        let local = NSRect(x: CGFloat(point.x) - CGFloat(radius), y: localY - CGFloat(radius),
                           width: diameter, height: diameter)
        let inWindow = convert(local, to: nil)
        return window.convertToScreen(inWindow)
    }

    /// Compatibility seam for callers that do not have a projected landmark
    /// descriptor. Real reciprocal elements always use the dynamic overload.
    func accessibilityFrame(for point: SIMD2<Float>, viewport: CGSize) -> NSRect {
        accessibilityFrame(for: point, radius: 8, viewport: viewport)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
