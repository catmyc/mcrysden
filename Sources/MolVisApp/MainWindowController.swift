import AppKit
import Metal
import MetalKit
import simd
import SwiftUI

final class MainWindowController: NSObject, World, NSWindowDelegate {
    let window: NSWindow
    let split = NSSplitView()
    let sidebar: NSHostingView<SideBar>
    let canvas: MetalView
    let labelOverlay: LabelOverlayView
    let infoPanel: NSTextView           // measurement/selection readout
    let infoWindow: NSWindow            // pop-out window hosting the readout
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
        labelOverlay = LabelOverlayView(frame: .zero)
        canvas.addSubview(labelOverlay)
        labelOverlay.autoresizingMask = [.width, .height]
        let info = NSTextView(frame: .zero)
        info.isEditable = false
        info.isSelectable = true
        info.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        info.backgroundColor = NSColor.windowBackgroundColor
        self.infoPanel = info
        // Pop-out window: a child of the main window so it floats alongside;
        // titled so the user can also move it.  Does not take focus away from
        // the main window.
        // Use a non-activating panel so the readout never steals key-window /
        // focus status from the main viewer — this prevents click event loops
        // Bottom-docked readout panel: sits just under the main window with
        // the standard macOS title-bar buttons (close / miniaturize / zoom)
        // so the user can make it float, hide it, or dismiss it.  The title
        // text and titlebar are hidden so only the buttons show, for a clean
        // docked aesthetic.
        let iw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 180),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        iw.title = "Selection / Measurement"
        iw.titleVisibility = .visible
        iw.titlebarAppearsTransparent = false
        iw.isReleasedWhenClosed = false
        iw.isOpaque = false
        iw.backgroundColor = NSColor.clear
        iw.hasShadow = true
        // ReadoutView is the visible panel; the transparent scroll view sits
        // inside it so the text scrolls over the rounded backdrop.
        let backdrop = ReadoutView(frame: NSRect(x: 0, y: 0, width: 1100, height: 180))
        let sc = NSScrollView(frame: backdrop.bounds)
        sc.autoresizingMask = [.width, .height]
        sc.hasVerticalScroller = true
        sc.drawsBackground = false
        sc.borderType = .noBorder
        sc.documentView = info
        backdrop.addSubview(sc)
        iw.contentView = backdrop
        self.infoWindow = iw
        let f = CGRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(contentRect: f, styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        state.onChange = { [weak self] in self?.syncFromState() }
        state.onResetView = { [weak self] in self?.resetView() }
        canvas.delegate = renderer
        canvas.world = self
        renderer.currentCamera = camera
        refreshDelegate()
        layoutSplit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        applyCameraForNewSceneIfNeeded()
        // The docked readout is shown lazily by toggleLabels the first time a
        // structure is loaded; it isn't needed on the empty opening frame.
    }

    /// Apply a freshly-loaded scene: reframe the camera ONCE (spec §6 — the
    /// camera resets on file open) and sync the sidebar so the next sidebar
    /// change does not clobber the loaded state with defaults.
    func loadFile(_ scene: Scene) {
        self.scene = scene
        state.syncFromScene(scene)
        applyCameraForNewSceneIfNeeded()
        // The readout stays hidden until the user selects an atom.
    }

    private func layoutSplit() {
        // Horizontal split: sidebar | canvas.
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(canvas)
        window.contentView = split
        // Set the 1:4 sidebar‑to‑canvas ratio after the split is in the window
        // so the position isn't ignored by an unplaced view.
        split.setPosition(window.frame.width / 5, ofDividerAt: 0)
    }

    /// Pin the readout window below the main window, spaced far enough down
    // that the title-bar buttons (close/miniaturize/zoom) stay fully accessible.
    /// Called on move/resize so the readout tracks the GUI.
    private func positionInfoWindow() {
        let f = window.frame
        // Docked just below the main window: the readout's top edge (accounting
        // for the rounded-corner inset) sits 8 px under the main window's
        // bottom edge.
        infoWindow.setFrame(NSRect(x: f.origin.x, y: f.minY - 180 - 8,
                                   width: f.width, height: 180), display: false)
    }

    /// Show the docked readout (first selection / measurement).
    private func showInfoWindow() {
        infoWindow.orderFront(nil)
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
        updateLabels()
        let text = buildInfoText()
        if infoPanel.string != text { infoPanel.string = text }
        canvas.draw()
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        if infoWindow.isVisible { positionInfoWindow() }   // keep docked to the bottom edge
    }

    func windowDidResize(_ notification: Notification) {
        split.setPosition(window.frame.width / 5, ofDividerAt: 0)
        if infoWindow.isVisible { positionInfoWindow() }
    }

    /// Closing the main window must end the program: hide the docked readout
    // first so the app terminates cleanly instead of leaving it orphaned.
    func windowWillClose(_ notification: Notification) {
        infoWindow.orderOut(nil)
    }

    // MARK: - World protocol

    func renderCamera() -> Camera {
        // Mirror Renderer.encode: 2D display modes force identity rotation and
        // orthographic projection so the hit-test projects to the same pixels.
        if scene.displayMode.is2D {
            var cam = camera
            cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            cam.perspective = false
            return cam
        }
        return camera
    }

    /// Toggle selection of `index`.  While a measurement result is locked the
    /// selection is frozen.  Otherwise clicking an atom toggles it; when the
    /// selection reaches the active mode's atom cap the measurement is computed
    /// automatically and the result is locked (no further picks).
    func toggleSelection(_ index: Int) {
        guard scene.measurementResult == nil else { return }   // locked
        guard index >= 0, index < scene.atoms.count else { return }
        if let pos = scene.selectedAtoms.firstIndex(of: index) {
            scene.selectedAtoms.remove(at: pos)          // deselect
            setNeedsRender()
            return
        }
        if scene.selectedAtoms.count >= scene.measurementMode.selectionCap {
            scene.selectedAtoms = []                 // restart at cap
        }
        scene.selectedAtoms.append(index)
        // Auto-measure once the required number of atoms is reached.
        if scene.measurementMode != .none
            && scene.selectedAtoms.count >= scene.measurementMode.selectionCap {
            scene.measurementResult = Scene.computeMeasurement(mode: scene.measurementMode,
                                                                atoms: scene.atoms,
                                                                selected: scene.selectedAtoms)
        }
        // Reveal + dock the readout the first time an atom is selected.
        if !infoWindow.isVisible { positionInfoWindow(); showInfoWindow() }
        setNeedsRender()
    }

    /// Explicitly compute the measurement for the active mode from the current
    /// selection. Populates `scene.measurementResult` (locking further picks)
    /// when enough atoms are selected; clears the lock otherwise.
    func performMeasurement() {
        guard scene.measurementMode != .none else { return }
        let cap = scene.measurementMode.selectionCap
        let sel = scene.selectedAtoms
        guard sel.count == cap, sel.allSatisfy({ $0 < scene.atoms.count }) else {
            // Not enough atoms — clear any stale lock so the user keeps picking.
            scene.measurementResult = nil
            return
        }
        scene.measurementResult = Scene.computeMeasurement(mode: scene.measurementMode,
                                                            atoms: scene.atoms, selected: sel)
        setNeedsRender()
    }

    /// Clear the active measurement result so the user can pick fresh atoms.
    func clearMeasurement() {
        scene.measurementResult = nil
        scene.selectedAtoms = []
        setNeedsRender()
    }

    /// Project each atom to screen coordinates and overlay its element symbol.
    func updateLabels() {
        guard scene.showLabels, !scene.atoms.isEmpty else {
            labelOverlay.labels = []; return
        }
        let cw = Float(canvas.bounds.width), ch = Float(canvas.bounds.height)
        guard cw > 0, ch > 0 else { labelOverlay.labels = []; return }
        let aspect = cw / ch
        let view = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        // Atom element labels
        let labels: [LabelOverlayView.Label] = scene.atoms.compactMap { atom in
            let clip = proj * view * SIMD4<Float>(atom.coord.x, atom.coord.y, atom.coord.z, 1)
            guard abs(clip.w) > 1e-10 else { return nil }
            let ndc = clip / clip.w
            guard ndc.z >= 0, ndc.z <= 1 else { return nil }
            let sx = CGFloat((ndc.x * 0.5 + 0.5) * cw)
            let sy = CGFloat((1 - (ndc.y * 0.5 + 0.5)) * ch)   // flip for AppKit y-down
            return LabelOverlayView.Label(symbol: ElementTable.symbol(atom.atomicNumber),
                                          x: sx - 10, y: sy - 12)  // offset so text centres near atom
        }

        labelOverlay.labels = labels
    }

    /// Build the text shown in the info/selection readout — selected-atom
    /// details (Cartesian + crystal coordinates) plus any measurement result.
    /// Optional `width`-aware column alignment is handled by fixed-width
    /// integer/float format specifiers so columns line up.
    func buildInfoText() -> String {
        let sel = scene.selectedAtoms
        if sel.isEmpty { return "No atoms selected." }

        var lines: [String] = []
        let atoms = scene.atoms
        let hasCell = scene.cell != nil
        // Fixed-width columns so every row lines up under its header.
        // Idx=3, Name=4, each coordinate block = 22 chars "(xxx.xxx, yyy.yyy, zzz.zzz)".
        if hasCell {
            lines.append("Idx  Name   Cartesian (Å)                 Crystal (frac)")
            lines.append("---  ----   ----------------------------  ----------------------------")
        } else {
            lines.append("Idx  Name   Cartesian (Å)")
            lines.append("---  ----   ----------------------------")
        }
        for idx in sel {
            guard idx < atoms.count else { continue }
            let a = atoms[idx]
            // %@ with a Swift String and String(format:) is UNSAFE on arm64:
            // small strings are stored as tagged pointers, and the formatter
            // dereferences them as Obj-C object refs → crash in strlen
            // (tracked in session as the on-click abort).  Cast each String to
            // NSString explicitly so %@ receives a proper heap object.
            let sym = ElementTable.symbol(a.atomicNumber) as NSString
            let cart = String(format: "(%7.3f, %7.3f, %7.3f)", a.coord.x, a.coord.y, a.coord.z) as NSString
            let body = hasCell ? scene.fractionalCoord(a.coord) : nil
            if let f = body {
                let crys = String(format: "(%7.3f, %7.3f, %7.3f)", f.x, f.y, f.z) as NSString
                lines.append(String(format: "%3d  %-4@  %@  %@", idx + 1, sym, cart, crys))
            } else {
                lines.append(String(format: "%3d  %-4@  %@", idx + 1, sym, cart))
            }
        }
        if let r = scene.measurementResult {
            lines.append("")
            lines.append("Measurement:")
            lines.append("  " + r.summary)
        }
        return lines.joined(separator: "\n")
    }

    /// Menu-item action: toggle element labels on/off and update the overlay.
    @objc func toggleLabels(_ sender: Any?) {
        scene.showLabels.toggle()
        state.showLabels = scene.showLabels
        setNeedsRender()
    }

    func applyCameraForNewSceneIfNeeded() {
        let (c, r) = scene.boundingSphere()
        camera.center = c
        camera.distance = max(8, r * 3)
        setNeedsRender()
    }

    /// Reset the view: reframe the camera on the structure (center on the
    /// centroid, distance fit to the bounding sphere, rotation cleared) — the
    /// same framing a freshly-opened file gets (spec §6).
    func resetView() {
        camera.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        applyCameraForNewSceneIfNeeded()
    }

    func syncFromState() {
        scene.displayMode = state.displayMode
        scene.atomScale = state.atomScale
        scene.bondRadius = state.bondRadius
        scene.showCellFrame = state.showCellFrame
        scene.showAxes = state.showAxes
        scene.showLabels = state.showLabels
        scene.measurementMode = state.measurementMode
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
