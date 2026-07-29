import AppKit
import Darwin
import Metal
import MetalKit
import simd
import SwiftUI

final class MainWindowController: NSObject, World, NSWindowDelegate {
    let window: NSWindow
    let split = NSSplitView()
    let sidebar: NSHostingView<SideBar>
    let viewport = NSView()
    let canvas: MetalView
    let labelOverlay: LabelOverlayView
    let bandGrapher: BandGrapherView    // 2D band-structure diagram (shown when bandStructure != nil)
    let dosGrapher: DOSGrapherView      // total/projected DOS graph (shown when densityOfStates != nil)
    let colorPlane: ColorPlaneView      // color-plane / 2D-contour overlay (shown when grid2D != nil and toggled)
    let infoPanel: NSTextView           // measurement/selection readout
    let infoWindow: NSWindow            // pop-out window hosting the readout
    /// Standalone atom table (search field + virtualized table). Owned by the
    /// controller but not installed in any window until `showAtomTable` lazily
    /// creates the auxiliary panel.
    let atomTable = AtomTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    /// Lazily-created, reusable auxiliary window hosting `atomTable`. nil until the
    /// first `showAtomTable`; repeated calls reuse this same window.
    private(set) var atomTableWindow: NSWindow?
    /// Last selection synced INTO the atom table — guards against redundant
    /// `setSelectedAtomIndices` work and selection-callback recursion.
    private var lastSyncedSelection: [Int] = []
    /// The main Metal renderer. `nil` only if Metal is unavailable (no GPU device or the
    /// shader library fails to compile) — exactly the case `try! Renderer(device:)` used
    /// to trap on. All other render touches guard on this, so the GUI still opens with
    /// graphs/labels/sidebar and only the 3D canvas stays blank (never a hard crash).
    let renderer: Renderer?
    private let device: MTLDevice?
    private lazy var renderer2D: Renderer2D? = device.flatMap { try? Renderer2D(device: $0) }
    var scene: Scene { didSet { renderer?.scene = scene; renderer2D?.scene = scene } }
    var camera = Camera()
    /// Test-only seam: when true, renderer creation is forced to fail so the graceful
    /// Metal-unavailable path is exercisable without a real GPU-less machine.
    internal static var forceRendererFailure = false
    let state: SideBarState
    /// The on-disk source + forced format of the currently-loaded file, kept so
    /// the animation controls can re-parse an arbitrary frame (AXSF animation
    /// is re-decoded frame-by-frame; the parsed LoadedScene is otherwise
    /// single-use). Nil for the empty opening viewer.
    private var sourceURL: URL?
    private var forcedFormat: ParseFormat?
    /// Editor BZ cache. `BrillouinZone.build` is expensive (cubic in the G-star for
    /// anisotropic cells), so the editor builds at most once per loaded/frame scene and
    /// reuses the result across clicks — including a negative cache of a failed build.
    /// The BZ is fully determined by `cell` + `baseAtoms`; supercell/slab edits preserve
    /// both, so only a file/frame install (which can change the cell) invalidates via
    /// `bzEpoch`. `epoch == -1` marks an unpopulated cache (freshly-built controllers).
    private struct BZEditCache {
        var epoch: Int = -1
        var bz: BrillouinZone? = nil
        var candidates: [BZCandidate] = []
    }
    private var bzEditCache = BZEditCache()
    private var bzEpoch = 0
    /// Test-only count of actual editor BZ builds (cache misses). Lets tests confirm
    /// at-most-once-per-scene construction and invalidation on file/frame install.
    internal var bzBuildCount = 0
    /// Test-only seam: true while an active file watcher is installed for the
    /// loaded source. Lets tests assert watching starts/loads without a real fs event.
    internal var isWatchingFile: Bool { fileWatchSource != nil }
    /// Test-only seam: true while the reload prompt is visible. Lets tests assert
    /// the prompt is shown after a debounced change without a real fs event.
    internal var isReloadPromptVisible: Bool { reloadPromptWindow != nil }
    /// Monotonic generation counter so out-of-order background drop loads never
    /// overwrite a later-scrubbed or more recent load. Incremented at each
    /// loadFile / loadDroppedFile entry; the capture before async work gates install.
    private var loadGeneration = 0
    /// Repeating timer driving AXSF playback. Held weakly by the runloop; we
    /// recreate it on Play and invalidate on Pause/stop in `syncFromState`.
    private var playTimer: Timer?

    // MARK: - File watching

    /// Dispatch source monitoring the loaded source file for disk changes. nil when
    /// no file is loaded or watching was cancelled (e.g. on close / new load).
    private var fileWatchSource: DispatchSourceFileSystemObject?
    /// POSIX descriptor backing `fileWatchSource`, tracked so the cancel handler
    /// closes it exactly once (double-close is undefined).
    private var fileWatchDescriptor: Int32 = -1
    /// Debounce timer coalescing rapid fs events into a single reload prompt.
    private var fileWatchDebounce: Timer?
    /// Floating reload-prompt panel shown over the viewport; nil when hidden.
    private var reloadPromptWindow: NSPanel?
    /// Tracks whether the prompt is for a delete (vs. modify) so the message differs.
    private var reloadPromptIsDelete = false
    /// Monotonic token so a stale debounce can't prompt after a reload/close.
    private var fileWatchToken = 0
    /// Last-seen inode of the watched file; a change means the file was replaced
    /// (atomic write) and we must re-open the descriptor on the new inode.
    private var fileWatchInode: UInt64 = 0

    init(scene: Scene, showWindow: Bool = true) {
        self.scene = scene
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        // Build the renderer defensively: if there is no Metal device or the shader
        // library fails to compile, fall back to a nil renderer rather than `try!`-trapping.
        // The window still opens — graphs, labels, and the sidebar work; only the Metal
        // canvas stays blank. This keeps the headless export path (which constructs its
        // OWN Renderer in PngExporter/RasterExporter) untouched.
        if let device, !MainWindowController.forceRendererFailure {
            do { renderer = try Renderer(device: device) }
            catch { print("[mcrysden] Metal renderer unavailable (\(error)); 3D canvas disabled"); renderer = nil }
        } else {
            if device == nil { print("[mcrysden] no Metal device; 3D canvas disabled") }
            renderer = nil
        }
        renderer?.scene = scene
        let state = SideBarState()
        self.state = state
        // A controller can be constructed directly with an already-loaded
        // scene in tests and in future embedding paths. Mirror that scene
        // before installing onChange, because every @Published assignment is
        // synchronous and would otherwise feed default state back into it.
        state.syncFromScene(scene)
        sidebar = NSHostingView(rootView: SideBar(state: state))
        canvas = MetalView(frame: .zero, device: device)
        canvas.autoresizingMask = [.width, .height]
        viewport.addSubview(canvas)
        labelOverlay = LabelOverlayView(frame: .zero)
        canvas.addSubview(labelOverlay)
        labelOverlay.autoresizingMask = [.width, .height]
        bandGrapher = BandGrapherView(frame: .zero)
        bandGrapher.autoresizingMask = [.width, .height]
        bandGrapher.isHidden = true
        viewport.addSubview(bandGrapher)
        dosGrapher = DOSGrapherView(frame: .zero)
        dosGrapher.autoresizingMask = [.width, .height]
        dosGrapher.isHidden = true
        viewport.addSubview(dosGrapher)
        colorPlane = ColorPlaneView(frame: .zero)
        colorPlane.autoresizingMask = [.width, .height]
        colorPlane.isHidden = true
        viewport.addSubview(colorPlane)
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
        state.onExportKPath = { [weak self] path, format in
            guard let self else { return }
            self.exportKPath(self.kPathForExport(path), format)
        }
        state.onResetKPath = { [weak self] in self?.resetKPathDefault() }
        state.onSelectKPathNode = { [weak self] index in self?.selectKPathNode(index) }
        state.onShowAtomTable = { [weak self] in self?.showAtomTable() }
        atomTable.onSelectionChange = { [weak self] indices in
            guard let self else { return }
            // Map filtered rows back to original displayed indices; keep them
            // sorted + unique and drop anything that isn't a valid atom index.
            let valid = indices.filter { $0 >= 0 && $0 < self.scene.atoms.count }
            let sortedUnique = Array(Set(valid)).sorted()
            // Table rows are sorted, so they cannot represent the pick order required
            // by angle/dihedral measurements. Keep the full linked selection instead
            // of applying the viewport pick cap.
            let selection = sortedUnique
            self.scene.selectedAtoms = selection
            self.scene.measurementResult = nil
            // Distance is order-independent and can be computed from exactly two
            // table-selected atoms. Other measurement modes remain viewport-only.
            if self.scene.measurementMode == .distance, selection.count == 2 {
                self.scene.measurementResult = Scene.computeMeasurement(
                    mode: self.scene.measurementMode,
                    atoms: self.scene.atoms,
                    selected: selection,
                    cell: self.scene.cell,
                    periodicDim: self.scene.periodicDim
                )
            }
            self.lastSyncedSelection = selection
            if !selection.isEmpty {
                self.positionInfoWindow()
                self.showInfoWindow()
            }
            self.setNeedsRender()
        }
        // syncFromScene (above) installed the initial route via replaceKPath, bumping
        // routeGeneration; mirror that so the first real syncFromState does not treat
        // the initial route as a wholesale replacement and clear a nil selection.
        lastRouteGeneration = state.routeGeneration
        canvas.delegate = renderer
        canvas.world = self
        renderer?.currentCamera = camera
        refreshDelegate()
        layoutSplit()
        window.center()
        if showWindow {
            window.makeKeyAndOrderFront(nil)
        }
        applyCameraForNewSceneIfNeeded()
        // The docked readout is shown lazily by toggleLabels the first time a
        // structure is loaded; it isn't needed on the empty opening frame.
    }

    /// Apply a freshly-loaded scene: reframe the camera ONCE (spec §6 — the
    /// camera resets on file open) and sync the sidebar so the next sidebar
    /// change does not clobber the loaded state with defaults. Records the
    /// source URL/format so AXSF animation can re-parse individual frames, and
    /// populates the animation controls (frameCount > 1 => show playback).
    func loadFile(_ scene: Scene, from url: URL? = nil, format: ParseFormat? = nil, frameIndex: Int = 0) {
        loadGeneration += 1   // cancel any pending background drop loads
        self.scene = scene
        self.sourceURL = url
        self.forcedFormat = format
        if let url {
            // Record in the standard recent-documents list and persist the path so
            // the file can be reopened on the next launch when no CLI input is given.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            UserDefaults.standard.set(url.path, forKey: App.lastOpenedURLKey)
            startFileWatching(url)
        }
        bzEpoch += 1   // new scene: cell/baseAtoms may differ, rebuild the editor BZ
        state.syncFromScene(scene)
        // syncFromScene exits edit mode (editKPathOnBZ -> false); mirror that into the
        // renderer so a freshly-loaded scene can't leave stale landmark crosses drawn.
        renderer?.showBZLandmarks = state.editKPathOnBZ
        // A freshly-loaded scene has its own route; clear any stale node highlight
        // left over from the previous scene (its index may now be out of range).
        // syncFromScene installed that route via replaceKPath (bumping routeGeneration);
        // resync the token so the next syncFromState does not treat the fresh route as
        // a wholesale replacement and clear a newly-set selection.
        renderer?.selectedKPathNode = nil
        lastRouteGeneration = state.routeGeneration
        applyCameraForNewSceneIfNeeded()
        // Graph data replaces the Metal canvas. DOS takes precedence if a loaded
        // scene ever contains both DOS and band data.
        let hasBands = scene.bandStructure != nil
        bandGrapher.bandStructure = scene.bandStructure
        if hasBands {
            bandGrapher.highSymmetryIndices = []   // parsed labels go here once k-labels are read
        }
        dosGrapher.densityOfStates = scene.densityOfStates
        // A 2D scalar grid: the color-plane overlay is available. On load we push
        // the grid data and show the plane by default (the canvas is hidden so the
        // plane fills the viewport); the sidebar toggle drives showColorPlane.
        if let grid = scene.grid2D {
            colorPlane.grid = grid.values
            colorPlane.zLabel = grid.ident
            colorPlane.contourLevels = defaultContourLevels(for: grid)
            // Project the skew plane with an affine that keeps BOTH span vectors'
            // lengths and the angle between them (Gram-Schmidt basis). Passing only
            // |v0|/|v1| would discard the angle and draw a skew plane rectangular.
            colorPlane.physicalSpan = Array(grid.vec.prefix(2))
        } else {
            colorPlane.grid = nil
        }
        updateContentVisibility()
        // Initialise the animation controls WITHOUT triggering onChange (which
        // would otherwise try to reload frame 0 on top of this fresh load).
        let saved = state.onChange
        state.onChange = nil
        state.frameIndex = frameIndex
        state.frameCount = url.map { Parser.frameCount($0, as: format) } ?? 1
        state.isPlaying = false
        state.onChange = saved
        stopPlayback()
        refreshAtomTable()
        // The readout stays hidden until the user selects an atom.
        setNeedsRender()
    }

    /// File > Revert To Saved: re-read the current source file (with the same
    /// forced format, if any) and reload it, exactly as Open does. No-op when no
    /// file is loaded.
    func revertToSource() {
        guard let url = sourceURL else { return }
        do {
            let scene = Scene(loaded: try Parser.load(url, as: forcedFormat))
            loadFile(scene, from: url, format: forcedFormat, frameIndex: 0)
        } catch {
            print("[mcrysden] revert failed: \(error)")
        }
    }

    /// Parse and load a structure file dropped onto the viewer (drag-and-drop).
    /// Mirrors the Open workflow: parse, load, non-fatal console error on failure.
    /// Parsing runs off the main thread so a large structure never blocks the drag
    /// session; a generation counter guards against out-of-order async completion.
    func loadDroppedFile(_ url: URL) {
        loadGeneration += 1
        let gen = loadGeneration
        let capturedURL = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let scene = Scene(loaded: try Parser.load(capturedURL))
                Task { @MainActor in
                    guard let self, self.loadGeneration == gen else { return }
                    self.loadFile(scene, from: capturedURL, format: nil, frameIndex: 0)
                }
            } catch {
                print("[mcrysden] drop open failed: \(error)")
            }
        }
    }

    private func layoutSplit() {
        // Horizontal split: sidebar | viewport. The viewport owns sibling canvas,
        // band, DOS, and color-plane layers so hiding Metal never hides a graph.
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(viewport)
        window.contentView = split
        // Register the content view for file drags so a structure file dropped
        // onto the viewer is parsed and loaded (NSDraggingDestination below).
        split.registerForDraggedTypes([.fileURL, .string])
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

    /// Lazily create (once) and show the auxiliary atom-table panel. Repeated
    /// calls reuse the same window identity. The panel is non-modal and released
    /// only on app termination (`isReleasedWhenClosed = false`).
    func showAtomTable() {
        if atomTableWindow == nil {
            let win = NSWindow(contentRect: atomTable.frame,
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            win.title = "Atom Table"
            win.isReleasedWhenClosed = false
            win.contentView = atomTable
            atomTableWindow = win
        }
        // A hidden table intentionally stays stale. Catch it up immediately before
        // presenting it again, while preserving the existing window and search text.
        updateAtomTable()
        atomTableWindow?.makeKeyAndOrderFront(nil)
    }

    /// Push the current scene's atoms/cell/selection into the table. O(atom-count)
    /// due to fractional-coordinate computation, so only call on structure changes
    /// (load/frame/supercell/slab), never on every render. Preserves search text.
    func refreshAtomTable() {
        guard let window = atomTableWindow, window.isVisible else { return }
        updateAtomTable()
    }

    private func updateAtomTable() {
        atomTable.update(atoms: scene.atoms, cell: scene.cell, selectedAtoms: scene.selectedAtoms)
        lastSyncedSelection = scene.selectedAtoms
    }

    /// Synchronize the table's row selection to match `scene.selectedAtoms`, but
    /// only when it actually changed — avoids redundant work and callback recursion.
    /// Stale indices (not in the current filter) are ignored by the table view.
    private func syncAtomTableSelection() {
        guard let window = atomTableWindow, window.isVisible else { return }
        if scene.selectedAtoms != lastSyncedSelection {
            atomTable.setSelectedAtomIndices(scene.selectedAtoms)
            lastSyncedSelection = scene.selectedAtoms
        }
    }

    private func refreshDelegate() {
        if scene.displayMode.is2D {
            canvas.delegate = renderer2D
            renderer2D?.scene = scene
            if let color = renderer?.background { renderer2D?.background = color }
        } else {
            canvas.delegate = renderer
        }
    }

    func setNeedsRender() {
        renderer?.currentCamera = camera
        renderer2D?.currentCamera = camera
        refreshDelegate()
        updateLabels()
        let text = buildInfoText()
        if infoPanel.string != text { infoPanel.string = text }
        // Keep the sidebar Forces readout in sync with the scene's forceSet.
        if state.forceSummary != buildForceSummary() { state.forceSummary = buildForceSummary() }
        // Reflect viewport selection into the atom table (only when changed).
        syncAtomTableSelection()
        canvas.draw()
    }

    /// Build the Forces sidebar readout from scene.forceSet (total force, total
    /// energy, number of iterations, optional stress). Returns a placeholder when
    /// no forceSet is present (the sidebar section is hidden then, so unused).
    private func buildForceSummary() -> String {
        guard let fs = scene.forceSet else { return "" }
        var lines: [String] = []
        // totalForce/totalEnergy are optional: a parsed value (even ~0) shows the number; nil shows
        // "—" so the readout never presents an absent measurement as a physical zero (P2 fix).
        if let tf = fs.totalForce {
            lines.append(String(format: "Total force: %.5f eV/Å", tf))
        } else {
            lines.append("Total force: —")
        }
        if let te = fs.totalEnergy {
            lines.append(String(format: "Total energy: %.5f eV", te))
        } else {
            lines.append("Total energy: —")
        }
        lines.append("Iterations: \(fs.nIterations)")
        if let s = fs.stress {
            lines.append(String(format: "Stress (Ry/Bohr³): %.4f %.4f %.4f", s[0].x, s[0].y, s[0].z))
            lines.append(String(format: "                  %.4f %.4f %.4f", s[1].x, s[1].y, s[1].z))
            lines.append(String(format: "                  %.4f %.4f %.4f", s[2].x, s[2].y, s[2].z))
        }
        return lines.joined(separator: "\n")
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
    /// Only the MAIN window closing tears down file watching / playback. The
    /// auxiliary panel has no controller delegate and is a no-op here.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) == window else { return }
        stopFileWatching()
        stopPlayback()
        state.isPlaying = false
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

    /// Project BZ-candidate world positions with the effective render camera and
    /// pick the nearest *visible* candidate to `click`. Primary ordering is screen-space
    /// distance (closest to the pointer wins); depth is only a tie-break for markers that
    /// overlap on screen. Returns nil on a miss or any invalid input — never traps.
    /// `click` and `viewport` are in top-origin pixels.
    static func pickBZCandidate(
        candidates: [BZCandidate],
        presentation: BZPresentation,
        camera: Camera,
        viewport: SIMD2<Float>,
        click: SIMD2<Float>,
        radiusPx: Float = 10
    ) -> BZCandidate? {
        // Validate the query before doing any work: a positive finite radius, a positive
        // finite viewport, and a finite click that actually falls inside the viewport.
        guard radiusPx > 0, radiusPx.isFinite,
              viewport.x > 0, viewport.y > 0,
              viewport.x.isFinite, viewport.y.isFinite,
              click.x.isFinite, click.y.isFinite,
              click.x >= 0, click.x <= viewport.x,
              click.y >= 0, click.y <= viewport.y else { return nil }
        let aspect = viewport.x / viewport.y
        guard aspect.isFinite, aspect > 0 else { return nil }
        let view = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        var best: BZCandidate?
        var bestDist = Float.infinity        // best screen-space distance squared
        var bestDepth = Float.infinity       // tie-break: nearest (smallest view -z)
        let radiusSq = radiusPx * radiusPx
        for cand in candidates {
            let world = presentation.world(cartesian: cand.cartesian)
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { continue }
            let worldPos = SIMD4<Float>(world.x, world.y, world.z, 1)
            let viewPos = view * worldPos
            let depth = -viewPos.z           // positive into screen (Metal: -z forward)
            guard depth > 0.01 else { continue }   // behind camera
            let clip = proj * viewPos
            guard clip.x.isFinite, clip.y.isFinite, clip.z.isFinite, clip.w.isFinite,
                  abs(clip.w) > 1e-10 else { continue }
            let ndc = clip / clip.w
            guard ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite else { continue }
            // Reject landmarks outside the visible frustum (Metal NDC xy in [-1,1], z in [0,1]).
            guard ndc.x >= -1, ndc.x <= 1, ndc.y >= -1, ndc.y <= 1,
                  ndc.z >= 0, ndc.z <= 1 else { continue }
            let sx = (ndc.x * 0.5 + 0.5) * viewport.x
            let sy = (1.0 - (ndc.y * 0.5 + 0.5)) * viewport.y   // top-origin
            let dx = sx - click.x, dy = sy - click.y
            let dist = dx * dx + dy * dy
            guard dist <= radiusSq else { continue }
            // Closer on screen wins; an actual/near screen-distance tie goes to depth.
            if dist < bestDist - 1e-3 || (dist <= bestDist + 1e-3 && depth < bestDepth) {
                bestDist = dist; bestDepth = depth; best = cand
            }
        }
        return best
    }

    /// Returns the editor's cached BZ candidates plus a BZPresentation, building the BZ at
    /// most once per `bzEpoch` (and caching a failed build as nil candidates). A fresh or
    /// invalidated cache builds lazily on first use; repeated clicks within the same
    /// loaded/frame scene reuse the result. Returns nil presentation when there is no cell
    /// or the build failed.
    private func editorLandmarks() -> (candidates: [BZCandidate], presentation: BZPresentation?) {
        if bzEditCache.epoch != bzEpoch {
            bzEditCache.epoch = bzEpoch
            if let cell = scene.cell {
                let bz = BrillouinZone.build(cell: cell, atoms: scene.baseAtoms)
                bzEditCache.bz = bz
                bzEditCache.candidates = bz?.candidates() ?? []
            } else {
                bzEditCache.bz = nil
                bzEditCache.candidates = []
            }
            bzBuildCount += 1
        }
        guard let bz = bzEditCache.bz else { return (bzEditCache.candidates, nil) }
        return (bzEditCache.candidates, BZPresentation(bz: bz, scene: scene))
    }

    /// Reciprocal k-path edit click handler. Edit mode OFF → returns false (not
    /// consumed) so atom picking proceeds. Edit mode ON → always consumed (so atom
    /// selection never fires); builds the BZ (cached per loaded/frame scene), maps
    /// candidates with BZPresentation, appends the picked landmark unless it exactly
    /// repeats the current last node, enforces the 1024 cap, and syncs state+scene +
    /// requests a render.
    func handleReciprocalPathClick(at click: SIMD2<Float>, viewport: SIMD2<Float>) -> Bool {
        guard state.editKPathOnBZ else { return false }
        // Consume the click even on a miss so atom selection never occurs.
        let (candidates, presentation) = editorLandmarks()
        guard let presentation else {
            setNeedsRender()
            return true
        }
        let cam = renderCamera()
        if let cand = Self.pickBZCandidate(candidates: candidates, presentation: presentation,
                                           camera: cam, viewport: viewport, click: click) {
            state.append(cand.point)
        }
        // Push the (possibly edited) route into the scene and re-render.
        scene.kPathPoints = state.kPathPoints
        setNeedsRender()
        return true
    }

    /// Highlight the route node at `index` in the BZ viewport, linking the
    /// sidebar route list's selection to the rendered k-path overlay. Pass nil
    /// to clear. The renderer draws the selected node as a larger green cross;
    /// out-of-range indices are a safe no-op there. This is the hook the
    /// SidebarState/UI invokes on selection (it sets this from a callback).
    func selectKPathNode(_ index: Int?) {
        renderer?.selectedKPathNode = index
        setNeedsRender()
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
                                                                selected: scene.selectedAtoms,
                                                                cell: scene.cell,
                                                                periodicDim: scene.periodicDim)
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
        guard sel.count == cap, sel.allSatisfy({ $0 >= 0 && $0 < scene.atoms.count }) else {
            // Not enough atoms — clear any stale lock so the user keeps picking.
            scene.measurementResult = nil
            return
        }
        scene.measurementResult = Scene.computeMeasurement(mode: scene.measurementMode,
                                                            atoms: scene.atoms, selected: sel,
                                                            cell: scene.cell,
                                                            periodicDim: scene.periodicDim)
        setNeedsRender()
    }

    /// Begin a measurement mode (or return to free selection when `mode ==
    /// .none`). Clears any previous selection/result and records the mode in
    /// `state` — the single source of truth — so it survives later sidebar
    /// syncs. The state's onChange propagates the value into the scene.
    func beginMeasurementMode(_ mode: MeasurementMode) {
        scene.measurementResult = nil
        scene.selectedAtoms = []
        state.measurementMode = mode
        setNeedsRender()
    }

    /// Right-drag slab distance adjust on plane A. Mirrors the new distance into
    /// `state` (single source of truth) and re-runs the slab filter on the scene
    /// so atoms are actually culled. Guarded against onChange recursion: we set
    /// the state field under `isSyncingState` so the synchronous onChange ->
    /// syncFromState does not re-enter, then apply the slab directly.
    func adjustSlabPlaneA(by delta: Float) {
        guard scene.slab != nil else { return }
        isSyncingState = true
        state.slabA_dist += delta
        isSyncingState = false
        let slab = Slab(planeA: Plane(h: state.slabA_h, k: state.slabA_k, l: state.slabA_l, distance: state.slabA_dist),
                        planeB: Plane(h: state.slabB_h, k: state.slabB_k, l: state.slabB_l, distance: state.slabB_dist))
        scene = scene.applySlab(slab)
        refreshAtomTable()
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
        // Use the renderer's *effective* camera (which forces identity rotation
        // + orthographic projection in 2D modes) so labels track the atoms
        // exactly — `camera` alone would drift off in 2D.
        let cam = renderCamera()
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: aspect)
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
            // sel holds Int, so a stale -1 passes an upper-bound check and would
            // trap on atoms[idx]; reject negatives as well as out-of-range indices.
            guard idx >= 0, idx < atoms.count else { continue }
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
        // The scene owns the canonical default-framing rule (atoms AND grid); use it
        // so the window, PNG export and vector export all agree on framing.
        camera = scene.defaultCamera()
        setNeedsRender()
    }

    /// Reset the view: reframe the camera on the structure (center on the
    /// centroid, distance fit to the bounding sphere, rotation cleared) — the
    /// same framing a freshly-opened file gets (spec §6).
    ///
    /// NOTE (per user request): this intentionally resets the CAMERA only —
    /// lighting, background and the display mode are preserved. The brief asked
    /// for "reframe only", and other tests depend on resetView() not touching
    /// appearance state. Reset lighting/background separately via the sidebar.
    func resetView() {
        camera.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        // A view reset is a natural clearing point for the transient node highlight;
        // the route is unchanged, so this only drops the render toggle, not appearance.
        // Bumping viewResetGeneration signals the SideBar to clear its local selected
        // node/editor too, keeping the sidebar selection in sync with the renderer.
        state.notifyViewReset()
        renderer?.selectedKPathNode = nil
        applyCameraForNewSceneIfNeeded()
        // applyCameraForNewSceneIfNeeded() replaces the camera with
        // scene.defaultCamera(), whose projection defaults to orthographic — restore
        // the user's choice from state.orthographic, exactly as reframeForDisplayMode
        // does on a real 2D↔3D transition.
        camera.perspective = !state.orthographic
    }

    /// Reframe the camera when the display mode changes so the structure always
    /// fills the viewport.  The 2D path uses a fixed identity rotation + orthographic
    /// projection but keeps the user's distance/orientation, while 3D uses the
    /// orbit camera — both derive their center and scale from the structure's
    /// bounding sphere so a switch never produces a tiny off-centre blob.
    ///
    /// Same-mode changes (e.g. ballStick↔spaceFill, or line2D↔point2D) do NOT
    /// reframe — only a real 2D↔3D transition does. The projection choice
    /// (perspective vs orthographic, driven by `state.orthographic`) is preserved
    /// across the transition: `applyCameraForNewSceneIfNeeded` resets the camera
    /// to the framing default (always orthographic), so we restore the user's
    /// projection afterward.
    private func reframeForDisplayMode(previous: DisplayMode) {
        guard previous.is2D != scene.displayMode.is2D else { return }
        applyCameraForNewSceneIfNeeded()
        camera.perspective = !state.orthographic
    }

    func syncFromState() {
        // reloadFrame mirrors its accepted index back into the published sidebar
        // state. That assignment fires onChange synchronously, so this guard must
        // run before the frame-dispatch branch or the same frame reloads recursively
        // until the main-thread stack overflows.
        guard !isReloadingFrame else { return }
        // AXSF animation: a new frame index means the user scrubbed or stepped —
        // decode that frame in full, re-applying the current view/UI state so the
        // camera, supercell, slab, etc. survive the reload. reloadFrame keeps
        // isReloadingFrame true so the state assignment it performs does not
        // re-enter here.
        if state.frameCount > 1 && state.frameIndex != scene.currentFrame {
            reloadFrame(state.frameIndex)
            return
        }
        // Guard re-entrancy: below we mirror scene-derived values back into
        // `state` (isCrystal, kPathPoints), whose @Published didSet fires
        // onChange -> syncFromState again. Without this guard a sidebar change
        // (which already entered here via onChange) would assign state.* and
        // recurse infinitely. The re-entrant call returns here doing nothing,
        // since the original invocation already performed the mirroring.
        guard !isSyncingState else { return }
        isSyncingState = true
        defer { isSyncingState = false }

        // k-path edit mode needs the BZ visible. Force it on BEFORE the state->scene
        // pushes below, so the scene receives true (we're inside the isSyncingState
        // guard, so the onChange from this assignment returns early at the guard).
        if state.editKPathOnBZ, !state.showBrillouinZone {
            state.showBrillouinZone = true
        }
        // White BZ-landmark crosses draw only while editing the k-path on the BZ;
        // the renderer keeps this non-persisted toggle in sync with the sidebar.
        renderer?.showBZLandmarks = state.editKPathOnBZ
        // k-path editing requires an orbitable 3D camera: in a 2D display mode the
        // renderer forces identity rotation + orthographic, so drag-to-orbit would show
        // no visible effect. On entering edit mode from a 2D mode, switch to ballStick so
        // the existing 2D<->3D reframe logic below restores a sensible 3D view.
        if state.editKPathOnBZ, state.displayMode.is2D {
            state.displayMode = .ballStick
        }

        let previousMode = scene.displayMode
        scene.displayMode = state.displayMode
        scene.atomScale = state.atomScale
        scene.bondRadius = state.bondRadius
        scene.showCellFrame = state.showCellFrame
        scene.showAxes = state.showAxes
        scene.showLabels = state.showLabels
        // User controls push state -> scene so the renderer reads the new value.
        // (showBrillouinZone is the renderer's source of truth via scene.* .)
        scene.showBrillouinZone = state.showBrillouinZone
        // Projection toggle: orthographic checked => perspective off. Bound to
        // the live render camera (the renderer reads camera.perspective).
        camera.perspective = !state.orthographic
        // Hide-structure toggle: suppress atoms/bonds/polyhedra, keep frame/axes/BZ.
        scene.showStructure = state.showStructure
        // Multi-orbital cube: selecting an orbital swaps the renderer's scalarField
        // and updates the slider range. Preserve the current iso value where possible,
        // clamping it when the new orbital has a narrower value range.
        if !scene.multiOrbitalFields.isEmpty {
            let index = min(max(0, state.currentOrbital), scene.multiOrbitalFields.count - 1)
            let field = scene.multiOrbitalFields[index]
            scene.currentOrbital = index
            scene.scalarField = field
            state.currentOrbital = index
            state.orbitalCount = scene.multiOrbitalFields.count
            state.isoRange = field.minValue...field.maxValue
            state.isoLevel = min(field.maxValue, max(field.minValue, state.isoLevel))
        }
        // Isosurface: only the slider + toggle are meaningful when a field is
        // present, but writing the values unconditionally is harmless (the renderer
        // gates the draw on `scene.scalarField != nil`).
        scene.showIsoSurface = state.showIsoSurface
        scene.isoLevel = state.isoLevel
        // Fermi surface: written unconditionally; the renderer gates the draw on
        // `scene.fermiSurface != nil`.
        scene.showFermiSurface = state.showFermiSurface
        // Force arrows: only meaningful when a forceSet is present; the renderer
        // gates the draw on forceSet + showForces, so writing is unconditional.
        scene.showForces = state.showForces
        scene.forceScale = state.forceScale
        // Color-plane overlay: written unconditionally; the renderer/visibility
        // gates the draw on `scene.grid2D != nil`.
        scene.showColorPlane = state.showColorPlane
        // Color-plane overlay: a 2D grid may coexist with the 3D structure. The
        // canvas shows EITHER the 3D scene or the color plane, never both — so the
        // plane wins only while the toggle is on AND a grid is present.
        updateContentVisibility()
        scene.measurementMode = state.measurementMode
        // Scene-derived mirrors flow state <- scene purely to keep the sidebar
        // indicators in sync; guarded above against re-entrant onChange.
        state.isCrystal = scene.isCrystal
        // k-path: the edited route lives in the sidebar state; push it into the
        // scene (never regenerate, or a sidebar sync would clobber user edits).
        // Provenance and signature are owned by the sidebar state (user-edit
        // mutations set them; undo/reset/restore replace them wholesale), so copy
        // them through verbatim instead of recomputing from the geometry diff —
        // recomputing here would wrongly re-flag an undo-restored generated route
        // as user-edited.
        scene.kPathProvenance = state.kPathProvenance
        scene.kPathSignature = state.kPathSignature
        scene.kPathPoints = state.kPathPoints
        scene.kPathBreaks = state.kPathBreaks
        // A whole-route replacement (Default/undo/clear) bumps routeGeneration;
        // clear any stale node selection so an out-of-range index can't linger.
        // Single-node edits leave the generation untouched, so editing a selected
        // node keeps its highlight.
        if state.routeGeneration != lastRouteGeneration {
            lastRouteGeneration = state.routeGeneration
            renderer?.selectedKPathNode = nil
        }
        // lighting + background — the renderer currently uses a fixed shader and
        // solid clear color (the richer shader is owned by another agent); we
        // mirror state into the scene here so the values persist via StateStore
        // and are ready the moment the renderer starts consuming them.
        scene.lighting = state.lighting
        scene.backgroundType = state.backgroundType
        scene.background = state.backgroundHex
        scene.backgroundBottom = state.backgroundBottomHex
        // supercell — compare the (n1,n2,n3) tuple, not just total, so changing
        // replication DIRECTION (e.g. 2×1×1 → 1×2×1, same total) re-widen happens.
        let sc = SuperCell(n1: state.n1, n2: state.n2, n3: state.n3)
        var superCellChanged = false
        if sc != scene.superCell {
            let previous = scene.superCell
            scene = scene.widenSuperCell(sc)
            superCellChanged = scene.superCell != previous
            if scene.superCell != sc {
                state.n1 = scene.superCell.n1
                state.n2 = scene.superCell.n2
                state.n3 = scene.superCell.n3
            }
        }
        // slab — build the Slab then run the scene through applySlab so the
        // atom set is actually filtered (Important #2 of the final review:
        // assigning scene.slab alone left slab/vacuum inert at runtime).
        let slab = state.slabEnabled
            ? Slab(planeA: Plane(h: state.slabA_h, k: state.slabA_k, l: state.slabA_l, distance: state.slabA_dist),
                   planeB: Plane(h: state.slabB_h, k: state.slabB_k, l: state.slabB_l, distance: state.slabB_dist))
            : nil
        let oldSlab = scene.slab
        if superCellChanged || scene.slab != slab {
            scene = scene.applySlab(slab)
        }
        if superCellChanged || scene.slab != oldSlab {
            refreshAtomTable()
        }
        // Reframe when crossing the 2D↔3D boundary — after supercell/slab
        // mutations so the camera fits the final geometry.
        reframeForDisplayMode(previous: previousMode)
        // background clear color (solid top color today; gradient rendering is
        // pending on the shader work).
        if let c = colorFromHex(state.backgroundHex) {
            renderer?.background = MTLClearColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        // Playback timer follows the Play/Pause toggle: started on play,
        // torn down on pause or when not animating at all.
        if state.isPlaying && playTimer == nil { startPlayback() }
        if !state.isPlaying && playTimer != nil { stopPlayback() }
        setNeedsRender()
    }

    /// Default high-symmetry k-path for the active crystal (crystal only).
    /// Uses the canonical path generator with the scene's symmetry analysis.
    /// Maps the path from the standardized reciprocal basis to the input-cell
    /// reciprocal basis. Returns nil for molecules or when symmetry is
    /// unavailable (the caller should then fall back to an empty route).
    static func makeDefaultKPath(for scene: Scene) -> KPath? {
        guard let cell = scene.cell, let symmetry = scene.crystalSymmetry?.symmetry else { return nil }
        let canonical = CanonicalPathGenerator.generate(for: symmetry)
        let mapped = CanonicalPathGenerator.mapToInputReciprocal(canonical, symmetry: symmetry, inputCell: cell)
        return KPath(points: mapped.kPoints, breaks: mapped.breaks)
    }

    /// "Default" control: reinstall the generated high-symmetry route for the
    /// current scene (wired via `state.onResetKPath`). Regenerates the canonical
    /// path from the current symmetry and maps it to the input-cell reciprocal
    /// basis. Sets provenance to `.generated` and records the structure signature.
    private func resetKPathDefault() {
        guard let path = Self.makeDefaultKPath(for: scene) else { return }
        // Update the scene first, then publish the sidebar route as one snapshot.
        // Otherwise kPathPoints.didSet synchronously re-enters syncFromState with
        // the previous break set and can briefly mark this generated reset as a
        // user edit.
        scene.kPathPoints = path.points
        scene.kPathBreaks = path.breaks
        scene.kPathProvenance = .generated
        scene.kPathSignature = CanonicalPathGenerator.structureSignature(for: scene.crystalSymmetry?.symmetry)
        let signature = scene.kPathSignature
        state.replaceKPath(points: path.points, breaks: path.breaks, provenance: .generated, signature: signature)
    }

    /// Install the canonical path from the scene's symmetry analysis into the
    /// scene. Called when the structure changes and the path was auto-generated.
    private func regenerateCanonicalPathIfNeeded() {
        guard scene.kPathProvenance == .generated else { return }
        guard let cell = scene.cell else { return }
        scene.installCanonicalPath(cell: cell)
    }

    /// Present a save panel and write the k-path text for the chosen format.
    /// Surfaces export errors (e.g. KPF cannot represent disconnected paths)
    /// to the user via an alert sheet.
    private func exportKPath(_ path: KPath, _ format: KPathExportFormat) {
        guard !path.points.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format == .vasp ? "KPOINTS" : "kpath.\(format.rawValue)"
        panel.allowedContentTypes = format == .vasp ? [] : [.plainText]
        if format == .vasp { panel.allowsOtherFileTypes = true }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let text = try KPathExport.export(path, as: format)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[mcrysden] k-path export failed: \(error)")
                self.presentExportError(error)
            }
        }
    }

    /// Stamp the sidebar's current per-segment sampling onto a route before export.
    /// The route arrives from the SideBar built with the KPath default; this applies
    /// the user's preference so the exported point density matches the UI choice.
    func kPathForExport(_ path: KPath) -> KPath {
        var path = path
        path.pointsPerSegment = state.kPathSampling
        return path
    }

    /// Present an export-failure alert as a sheet on the main window.
    private func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "k-path export failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Capture the live scene, camera, and current source URL and persist the
    /// view-state to `url` via StateStore. Wired to AppDelegate save actions.
    @MainActor
    internal func saveState(to url: URL) throws {
        try StateStore.save(scene, camera: camera, sourceURL: sourceURL, to: url, kPathSampling: state.kPathSampling)
    }

    /// The loaded source is needed by file actions to protect it from overwrite.
    @MainActor
    internal var currentSourceURL: URL? { sourceURL }

    /// Export the layer currently displayed in the viewport. Graph and color-plane
    /// payloads hidden by the view state must not supersede the Metal canvas.
    @MainActor
    @discardableResult
    internal func exportCurrentView(to url: URL, size: CGSize, options: ExportOptions? = nil) throws -> CGImage {
        // The export size is the current logical viewport size; reproject labels
        // after a resize before copying the live overlay.
        updateLabels()
        var visibleScene = scene
        if dosGrapher.isHidden { visibleScene.densityOfStates = nil }
        if bandGrapher.isHidden { visibleScene.bandStructure = nil }
        if colorPlane.isHidden { visibleScene.grid2D = nil }
        // Apply export options: if the caller passes explicit options, use them;
        // otherwise render with the scene's own background (preserving gradients).
        let renderOptions = RenderExportOptions(labels: canvas.isHidden ? [] : labelOverlay.labels,
                                                showBZLandmarks: !canvas.isHidden && state.editKPathOnBZ && scene.isCrystal)
        if let options {
            // Apply background override to the scene copy for ALL export paths
            // (graph, vector, and Metal) so background/transparency settings are
            // honored uniformly.
            if !options.isTransparent {
                visibleScene.background = options.backgroundHex
                visibleScene.backgroundType = .solid
            }
            return try App.exportScene(visibleScene, camera: camera, to: url, size: size,
                                       options: renderOptions, exportOptions: options)
        }
        return try App.exportScene(visibleScene, camera: camera, to: url, size: size,
                                   options: renderOptions)
    }

    /// Pick a small set of iso-contour levels spanning the grid's value range,
    /// for the color-plane's marching-squares contour trace. Six levels keeps the
    /// plot legible without overcrowding it.
    private func defaultContourLevels(for grid: Grid2D) -> [Float] {
        let lo = grid.minValue, hi = grid.maxValue
        guard hi > lo else { return [] }
        let n = 6
        return (1..<n).map { i in lo + (hi - lo) * Float(i) / Float(n) }
    }

    /// Guards the main syncFromState() path while reloadFrame assigns
    /// state.frameIndex (which would otherwise fire onChange and re-enter).
    private var isReloadingFrame = false
    private var isSyncingState = false
    /// Last-seen value of `state.routeGeneration`. A whole-route replacement bumps
    /// that counter; when it changes we clear any stale node selection. Single-node
    /// edits leave the counter untouched, so editing a selected node keeps its
    /// highlight. Initialized in init/syncFromState from the current state.
    private var lastRouteGeneration = -1

    /// Decode AXSF frame `index` and swap it into the current scene, preserving
    /// the camera and all UI-controllable state (display mode, scales, lighting,
    /// background, supercell, slab, show flags). Each frame is parsed fresh
    /// from sourceURL via Parser.load(frameIndex:).
    private func reloadFrame(_ index: Int) {
        guard let url = sourceURL else { return }
        guard index >= 0, index < state.frameCount else {
            isReloadingFrame = true
            state.isPlaying = false
            state.frameIndex = scene.currentFrame
            isReloadingFrame = false
            stopPlayback()
            return
        }
        guard let loaded = try? Parser.load(url, frameIndex: index, as: forcedFormat) else {
            print("[mcrysden] failed to load frame \(index)")
            // Roll back the requested index and STOP playback so a corrupt tail
            // frame doesn't spin the timer retrying a frame that never loads.
            // Raise isReloadingFrame BEFORE mutating state so the synchronous
            // onChange -> syncFromState early-returns instead of reloading again.
            isReloadingFrame = true
            state.isPlaying = false
            state.frameIndex = scene.currentFrame
            isReloadingFrame = false
            stopPlayback()
            return
        }
        // Start from the freshly parsed frame but carry the LIVE UI state over
        // (not state.*, which lags by one onChange) so scrolling frames never
        // resets the view, supercell, slab, or appearance settings.
        var next = Scene(loaded: loaded)
        next.camera = camera
        next.displayMode = scene.displayMode
        next.atomScale = scene.atomScale
        next.bondRadius = scene.bondRadius
        next.showCellFrame = scene.showCellFrame
        next.showAxes = scene.showAxes
        next.showLabels = scene.showLabels
        next.showStructure = scene.showStructure
        next.showBrillouinZone = scene.showBrillouinZone
        // The freshly parsed scene already owns the right generated route for
        // its current structure/input reciprocal basis.  Transfer only a user
        // route, remapping fractional coordinates through Cartesian reciprocal
        // space when this frame changed that basis.  (Supercell/slab are applied
        // later and intentionally do not affect this base-cell decision.)
        next.transferKPathAcrossGeometryChange(from: scene)
        // Volumetric-surface settings: without these, scrubbing an animated scalar
        // field or Fermi surface resets the iso level / visibility to defaults.
        next.showIsoSurface = scene.showIsoSurface
        next.isoLevel = scene.isoLevel
        next.showFermiSurface = scene.showFermiSurface
        // The freshly parsed frame may carry a scalar field whose value range differs
        // from the frame we carried the level over (e.g. animated XSF). Clamp the
        // carried level into the new field's range so it stays meaningful; when the
        // level already fits, its value and iso-surface visibility both pass through
        // unchanged. With a no-field frame the level is inert (the renderer gates on
        // scalarField), so leave it untouched.
        if let field = next.scalarField {
            next.isoLevel = min(field.maxValue, max(field.minValue, next.isoLevel))
        }
        // Force-arrow settings: carry them across the frame reload so scrubbing an
        // animated .pwo doesn't silently drop the visibility / scale the user set.
        next.showForces = scene.showForces
        next.forceScale = scene.forceScale
        next.lighting = state.lighting
        next.backgroundType = state.backgroundType
        next.background = state.backgroundHex
        next.backgroundBottom = state.backgroundBottomHex
        next.selectedAtoms = []                 // selection is per-frame
        next.measurementResult = nil
        next.measurementMode = state.measurementMode  // mode survives frame changes
        // Re-apply the current supercell and slab so the new frame matches the
        // framing the user had before the reload.
        next = next.widenSuperCell(SuperCell(n1: state.n1, n2: state.n2, n3: state.n3))
        if state.slabEnabled {
            let slab = Slab(planeA: Plane(h: state.slabA_h, k: state.slabA_k, l: state.slabA_l, distance: state.slabA_dist),
                            planeB: Plane(h: state.slabB_h, k: state.slabB_k, l: state.slabB_l, distance: state.slabB_dist))
            next = next.applySlab(slab)
        }
        next.currentFrame = index
        // Apply the live sidebar's preserved orbital selection and clamp the carried
        // isoLevel to the new field's range. Note: the multi-orbital branch below is
        // unreachable for AXSF animations (which yield no multi-orbital frames) but is the
        // source of truth for Gaussian-style multi-orbital cubes; it's covered by a
        // focused unit test (testMultiOrbitalSelectionAppliedDuringReload).
        let nOrbitals = next.multiOrbitalFields.count
        applySelectedOrbitalAndClampIso(scene: &next, currentOrbital: state.currentOrbital)
        // ---- Side-bar per-frame metadata transaction ----
        // Hold BOTH isSyncingState AND isReloadingFrame true for the metadata writes
        // below so (a) the @Published didSet -> onChange -> syncFromState short-circuits
        // at the isSyncingState guard there, and (b) syncFromState's frame-recursion
        // branch (state.frameIndex != scene.currentFrame) does not re-enter reloadFrame
        // with the OLD scene still in place. We have not yet assigned self.scene = next,
        // so that branch WOULD otherwise loop until the stack overflows. Save/restore
        // both flags — isReloadingFrame is initialized true to fence the
        // frameIndex = index assignment below; isSyncingState is what we add on top.
        let outerSyncingState = isSyncingState
        isSyncingState = true
        isReloadingFrame = true
        defer {
            isReloadingFrame = false
            isSyncingState = outerSyncingState
        }
        state.frameIndex = index     // keep the two in sync; guarded from re-entry
        // Presence gates (no @Published, but harmlessly inside the held guard).
        state.hasScalarField = (next.scalarField != nil)
        state.hasFermiSurface = (next.fermiSurface != nil)
        state.hasGrid2D = (next.grid2D != nil)
        // Grid presence controls whether the plane can be shown, not the user's
        // preference. Carry the live scene's preference so it survives frames
        // without a grid, then mirror into state so the two agree.
        let resolvedShowColorPlane = scene.showColorPlane
        next.showColorPlane = resolvedShowColorPlane
        state.showColorPlane = resolvedShowColorPlane
        state.hasForceSet = (next.forceSet != nil)
        state.isCrystal = next.isCrystal
        state.crystalSymmetry = next.crystalSymmetry
        state.structureSummary = StructureSummary(next, symmetry: next.crystalSymmetry)
        // The route can have been regenerated (generated provenance) or
        // reciprocal-basis-remapped (user provenance). Mirror BOTH pieces while
        // the synchronous @Published callbacks are fenced; otherwise a later
        // unrelated sidebar change would push the old fractional coordinates
        // back into the newly installed frame and misclassify its provenance.
        state.replaceKPath(points: next.kPathPoints, breaks: next.kPathBreaks,
                           provenance: next.kPathProvenance, signature: next.kPathSignature)
        // The frame's route replaced the previous one wholesale; clear any stale
        // node highlight (the held isSyncingState guard fences syncFromState from
        // detecting the generation bump here, so clear directly and resync the token).
        renderer?.selectedKPathNode = nil
        lastRouteGeneration = state.routeGeneration
        // Orbital picker: mirror the preserved & validated scene selection exactly
        // (applySelectedOrbitalAndClampIso already clamped + bounded it) so the
        // sidebar always agrees with the rendered frame, even for negative injected
        // state that has not yet been sanitized by syncFromState.
        state.orbitalCount = nOrbitals
        state.currentOrbital = next.currentOrbital
        // iso level: the just-carried next.isoLevel (already field-range-clamped above)
        // is mirrored so the slider matches the rendered frame's level.
        state.isoLevel = next.isoLevel
        // Slider range: use the field's actual bounds when present, otherwise clear
        // stale slider bounds back to the neutral default so they don't leak across.
        if let field = next.scalarField {
            state.isoRange = field.minValue...field.maxValue
        } else {
            state.isoRange = 0...1
        }
        // ---- end of held-guard transaction ----
        loadGeneration += 1   // cancel any pending background drop loads
        self.scene = next
        bzEpoch += 1   // freshly parsed frame: cell/baseAtoms may differ, rebuild the editor BZ
        // Refresh the color-plane overlay when the reloaded frame changes grid2D
        // presence or data, mirroring loadFile so the plane's data/labels/contours
        // stay consistent across frame reloads.
        if let grid = next.grid2D {
            colorPlane.grid = grid.values
            colorPlane.zLabel = grid.ident
            colorPlane.contourLevels = defaultContourLevels(for: grid)
            colorPlane.physicalSpan = Array(grid.vec.prefix(2))
        } else {
            colorPlane.grid = nil
        }
        updateContentVisibility()
        refreshAtomTable()
        setNeedsRender()
    }

    /// Apply a sidebar's preserved orbital selection to a freshly reloaded frame, and
    /// clamp the carried isoLevel into the selected field's range. Mirrors the logic
    /// `syncFromState()` uses for a multi-orbital scene but operates on the new frame
    /// before it is installed, so the renderer and the slider agree on which orbital
    /// is shown. Called from `reloadFrame` just before the metadata transaction.
    internal func applySelectedOrbitalAndClampIso(scene: inout Scene, currentOrbital: Int) {
        let nOrbitals = scene.multiOrbitalFields.count
        if nOrbitals > 0 {
            let idx = min(max(0, currentOrbital), nOrbitals - 1)
            scene.currentOrbital = idx
            scene.scalarField = scene.multiOrbitalFields[idx]
        }
        if let field = scene.scalarField {
            scene.isoLevel = min(field.maxValue, max(field.minValue, scene.isoLevel))
        }
    }

    /// Begin (or restart) the playback timer. Repeating at ~10 Hz; each tick
    /// advances frameIndex by one, wrapping to 0 at the end (or stopping — here
    /// we stop at the end and clear isPlaying for predictability).
    private func startPlayback() {
        stopPlayback()
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.state.frameIndex + 1 >= self.state.frameCount {
                // Reached the last frame — stop rather than wrap.
                self.state.isPlaying = false
            } else {
                self.state.frameIndex += 1
            }
        }
    }

    private func stopPlayback() {
        playTimer?.invalidate()
        playTimer = nil
    }

    // MARK: - File watching

    /// Begin (or restart) watching `url` for disk changes. Idempotent: any prior
    /// watcher is cancelled first. No-op when the file can't be opened (e.g. gone).
    func startFileWatching(_ url: URL) {
        stopFileWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileWatchDescriptor = fd
        fileWatchInode = Self.inodeOf(url) ?? 0
        fileWatchToken += 1
        let token = fileWatchToken
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleWatchEvent(source.data, url: url, token: token)
        }
        source.setCancelHandler {
            // Unconditionally close our captured descriptor exactly once, even if
            // the controller has been released before the async handler runs.
            close(fd)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fileWatchDescriptor == fd else { return }
                self.fileWatchDescriptor = -1
            }
        }
        source.resume()
        fileWatchDescriptor = fd
        fileWatchSource = source
    }

    /// Cancel any active file watcher and dismiss the reload prompt.
    func stopFileWatching() {
        fileWatchDebounce?.invalidate()
        fileWatchDebounce = nil
        fileWatchToken += 1
        dismissReloadPrompt()
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
    }

    private func handleWatchEvent(_ event: DispatchSource.FileSystemEvent, url: URL, token: Int) {
        guard token == fileWatchToken else { return }
        // Delete/rename/revoke: the inode we opened is gone.
        if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
            // A delete/rename is often an atomic replace (write temp + rename, or
            // truncate + rewrite). If a new file now lives at the same path with a
            // different inode, re-open on the new inode and prompt for reload.
            if let inode = Self.inodeOf(url), inode != 0, inode != fileWatchInode {
                fileWatchSource?.cancel()
                fileWatchSource = nil
                fileWatchDebounce?.invalidate()
                startFileWatching(url)
                scheduleReloadPrompt(url: url, isDelete: false, token: fileWatchToken)
                return
            }
            fileWatchSource?.cancel()
            fileWatchSource = nil
            scheduleReloadPrompt(url: url, isDelete: true, token: token)
            return
        }
        // Write/extend: content changed.
        scheduleReloadPrompt(url: url, isDelete: false, token: token)
    }

    private func scheduleReloadPrompt(url: URL, isDelete: Bool, token: Int) {
        fileWatchDebounce?.invalidate()
        fileWatchDebounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, self.fileWatchToken == token else { return }
            self.showReloadPrompt(url: url, isDelete: isDelete)
        }
    }

    private func showReloadPrompt(url: URL, isDelete: Bool) {
        dismissReloadPrompt()
        reloadPromptIsDelete = isDelete
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                            styleMask: [.nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.level = .floating
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        container.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: isDelete
            ? "\(url.lastPathComponent) was deleted or moved."
            : "\(url.lastPathComponent) changed on disk.")
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        let button = NSButton(title: isDelete ? "OK" : "Reload", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = isDelete ? #selector(dismissReloadPromptObjC) : #selector(confirmReloadFromPrompt)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
        ])
        panel.contentView = container
        reloadPromptWindow = panel
        window.addChildWindow(panel, ordered: .above)
        positionReloadPrompt()
    }

    private func positionReloadPrompt() {
        guard let panel = reloadPromptWindow else { return }
        let wf = window.frame
        let size = panel.frame.size
        panel.setFrame(NSRect(x: wf.origin.x + wf.width - size.width - 12,
                              y: wf.origin.y + wf.height - size.height - 36,
                              width: size.width, height: size.height), display: false)
    }

    @objc private func confirmReloadFromPrompt(_ sender: Any?) {
        dismissReloadPrompt()
        revertToSource()
    }

    @objc private func dismissReloadPromptObjC(_ sender: Any?) {
        dismissReloadPrompt()
    }

    private func dismissReloadPrompt() {
        reloadPromptWindow?.parent?.removeChildWindow(reloadPromptWindow!)
        reloadPromptWindow?.orderOut(nil)
        reloadPromptWindow = nil
    }

    private static func inodeOf(_ url: URL) -> UInt64? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return inode.uint64Value
    }

    /// Select exactly one viewport layer. Keeping the graph views as siblings of
    /// Metal avoids overlapping plots and avoids hiding a graph with its parent.
    private func updateContentVisibility() {
        // k-path edit mode needs the Metal canvas (the BZ is rendered there); suppress
        // every graph/color-plane sibling so the editor is usable even on a crystal that
        // also carries band/DOS/grid data. Exiting edit mode falls through to the normal
        // precedence below.
        let editingReciprocal = state.editKPathOnBZ && scene.isCrystal
        let showDOS = !editingReciprocal && scene.densityOfStates != nil
        let showBands = !editingReciprocal && !showDOS && scene.bandStructure != nil
        let showPlane = !editingReciprocal && !showDOS && !showBands && state.showColorPlane && scene.grid2D != nil
        dosGrapher.isHidden = !showDOS
        bandGrapher.isHidden = !showBands
        colorPlane.isHidden = !showPlane
        canvas.isHidden = !editingReciprocal && (showDOS || showBands || showPlane)
        if showDOS { dosGrapher.needsDisplay = true }
        if showBands { bandGrapher.needsDisplay = true }
        if showPlane { colorPlane.needsDisplay = true }
    }

    private func colorFromHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255.0, Double((v >> 8) & 0xFF) / 255.0, Double(v & 0xFF) / 255.0)
    }
}

/// Drag-and-drop onto the viewer. The content view (an NSSplitView) is registered
/// for file drags in `layoutSplit()`; on drop it hands the file to the window's
/// delegate (the MainWindowController) to parse and load. Reads file URLs plus
/// string paths for compatibility with the legacy filenames pboard type.
///
/// NSDraggingDestination is already adopted by NSView; these are overrides of
/// its (optional) methods, not a retroactive conformance.
extension NSSplitView {
    /// Validate that the drag carries a single supported file URL before
    /// advertising a copy operation. Reads only file URLs (`urlReadingFileURLsOnly`)
    /// and applies the same supported-file rules the Open panel uses, so an
    /// unsupported file never advertises a drop and silently no-ops.
    private static func supportedFileURL(from info: NSDraggingInfo) -> URL? {
        let pb = info.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let url = (pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
            ?? (pb.readObjects(forClasses: [NSString.self], options: nil) as? [String]).flatMap { strings in
                strings.first.map { URL(fileURLWithPath: $0) }
            }
        guard let url else { return nil }
        return (App.supportsOpenURL(url) && !url.hasDirectoryPath) ? url : nil
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.supportedFileURL(from: sender) != nil ? .copy : []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.supportedFileURL(from: sender) != nil ? .copy : []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.supportedFileURL(from: sender) else { return false }
        guard let controller = window?.delegate as? MainWindowController else { return false }
        controller.loadDroppedFile(url)
        return true
    }
}
