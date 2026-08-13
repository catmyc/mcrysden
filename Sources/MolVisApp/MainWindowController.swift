import AppKit
import Darwin
import Metal
import MetalKit
import simd
import SwiftUI
import UniformTypeIdentifiers

private struct RouteLabelMeasurementKey: Hashable {
    let text: String
    let style: LabelOverlayView.Label.Style
}

final class MainWindowController: NSObject, World, NSWindowDelegate {
    private final class CoordinationCancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func isCancelled() -> Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
    }

    internal typealias CoordinationAnalyzerOverride =
        ([Atom], Cell?, Int, Float, @escaping () -> Bool) -> CoordinationAnalysis?
    internal typealias CoordinationDebounceScheduler =
        (TimeInterval, @escaping () -> Void) -> (() -> Void)

    let window: NSWindow
    let split = NSSplitView()
    let sidebar: NSHostingView<SideBar>
    let viewport = NSView()
    let canvas: MetalView
    let labelOverlay: LabelOverlayView
    let bandGrapher: BandGrapherView    // 2D band-structure diagram (shown when bandStructure != nil)
    let dosGrapher: DOSGrapherView      // total/projected DOS graph (shown when densityOfStates != nil)
    let linkedGraphs: LinkedGraphsView   // side-by-side band+DOS container (or single child)
    let bandSurfaceView: BandSurfaceView // 3D band-surface plot (shown when scene.bandSurface != nil)
    /// Electronic-structure display flags carried across GUI re-parses so derived
    /// data (DOS, interpolated bands, band surface) survives frame/revert reloads.
    /// Set by App from the CLI options (--bands/--dos/--band-surf).
    var electronicStructureFlags = ElectronicStructureFlags()
    let xrdGrapher: PowderXRDGrapherView // powder XRD diagram (shown in its own auxiliary window)
    let infoPanel: NSTextView           // measurement/selection readout
    let infoWindow: NSWindow            // pop-out window hosting the readout
    /// Standalone atom table (search field + virtualized table). Owned by the
    /// controller but not installed in any window until `showAtomTable` lazily
    /// creates the auxiliary panel.
    let atomTable = AtomTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    /// Standalone neighbor table (virtualized). Owned by the controller but not
    /// installed in any window until `showNeighborTable` lazily creates it.
    let neighborTable = NeighborTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    /// Standalone first-shell polyhedron metrics table. Owned by the controller
    /// but not installed in any window until `showPolyhedronTable` creates it.
    let polyhedronTable = PolyhedronTableView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
    /// Standalone two-structure comparison panel. Owned by the controller but
    /// not installed in any window until a comparison is loaded.
    let comparisonPanel = ComparisonPanelView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
    /// Lazily-created, reusable auxiliary window hosting `neighborTable`.
    private(set) var neighborTableWindow: NSWindow?
    /// Lazily-created, reusable auxiliary window hosting `polyhedronTable`.
    private(set) var polyhedronTableWindow: NSWindow?
    /// Lazily-created, reusable auxiliary window hosting `comparisonPanel`.
    private(set) var comparisonWindow: NSWindow?
    /// Runtime-only distribution analysis derived from the coordination result.
    private(set) var distributionAnalysis: DistributionAnalysis?
    /// Lazily-created, reusable auxiliary window hosting `atomTable`. nil until the
    /// first `showAtomTable`; repeated calls reuse this same window.
    private(set) var atomTableWindow: NSWindow?
    /// Lazily-created, reusable auxiliary window hosting `xrdGrapher`. nil until the
    /// first `showPowderXRD`; repeated calls reuse this same window.
    private(set) var xrdWindow: NSWindow?
    /// Last selection synced INTO the atom table — guards against redundant
    /// `setSelectedAtomIndices` work and selection-callback recursion.
    private var lastSyncedSelection: [Int] = []
    /// The main Metal renderer. `nil` only if Metal is unavailable (no GPU device or the
    /// shader library fails to compile) — exactly the case `try! Renderer(device:)` used
    /// to trap on. All other render touches guard on this, so the GUI still opens with
    /// graphs/labels/sidebar and only the 3D canvas stays blank (never a hard crash).
    let renderer: Renderer?
    private let device: MTLDevice?
    private(set) lazy var renderer2D: Renderer2D? = device.flatMap { try? Renderer2D(device: $0) }
    var scene: Scene {
        didSet {
            renderer?.scene = scene
            renderer2D?.scene = scene
            if Self.reciprocalGeometryChanged(from: oldValue, to: scene) {
                bzEpoch += 1
                bzEditCache = BZEditCache()
            }
            invalidateRouteLabelMeasurementCache()
        }
    }
    var camera = Camera() {
        didSet {
            // Camera mutations can come directly from MetalView orbit/pan/zoom
            // handlers, so invalidate reciprocal hover at the mutation boundary.
            clearReciprocalHover()
            canvas.invalidateReciprocalAccessibilityFocus()
        }
    }
    /// Exactly three optional camera views owned by this document window. These
    /// are runtime state, not Scene fields: they cannot leak through Scene Codable
    /// or UserDefaults and are replaced only when a document is installed.
    internal private(set) var cameraBookmarks: [CameraBookmark?] =
        Array(repeating: nil, count: CameraBookmark.slotCount)
    /// Test-only seam: when true, renderer creation is forced to fail so the graceful
    /// Metal-unavailable path is exercisable without a real GPU-less machine.
    internal static var forceRendererFailure = false
    /// Upper bound on mirrored light sources (XCrySDen parity: 6 lights). The
    /// sidebar cannot exceed it, but the mirror clamps defensively so a restored
    /// or scripted state can never overrun the renderer's fixed light block.
    internal static let maxSceneLights = 6
    let state: SideBarState
    /// Derived coordination data for the currently displayed atom ordering. It
    /// is runtime-only and is discarded whenever the displayed geometry changes.
    private(set) var coordinationAnalysis: CoordinationAnalysis? = nil
    /// Test seam for deterministic async integration tests. Production uses the
    /// synchronous engine entry point below; the closure receives a CoW snapshot
    /// and a cancellation predicate owned by this request.
    internal var coordinationAnalyzerOverride: CoordinationAnalyzerOverride?
    /// Called on the main thread after a current result is installed or deemed
    /// unavailable. Tests use this instead of sleeping for implementation timing.
    internal var coordinationAnalysisDidUpdate: (() -> Void)?
    /// Injectable scheduler for the scale debounce. The default keeps exactly one
    /// cancellable main-queue work item pending at a time.
    internal var coordinationDebounceScheduler: CoordinationDebounceScheduler = { delay, action in
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
    private var coordinationWorkItem: DispatchWorkItem?
    private var coordinationCancellationToken: CoordinationCancellationToken?
    private var coordinationDebounceCancellation: (() -> Void)?
    private var coordinationGeneration = 0
    /// Powder XRD debounce + background compute. PowderXRD.analyze is
    /// O(hklLimit³ · atoms · symmetryOps) and can block the main thread for
    /// seconds on large cells, so it is debounced (~0.2 s) and computed on a
    /// global queue; a generation token discards stale completions.
    private var xrdWorkItem: DispatchWorkItem?
    private var xrdDebounceCancellation: (() -> Void)?
    private var xrdGeneration = 0
    private var xrdCancellationToken: CoordinationCancellationToken?
    /// Derived first-shell polyhedron metrics (aligned to `scene.atoms`), computed
    /// on a background work item after the coordination result is installed.
    private(set) var polyhedronMetrics: [PolyhedronMetrics]? = nil
    private var polyhedronWorkItem: DispatchWorkItem?
    private var polyhedronGeneration = 0
    /// Lock-backed cancellation token for polyhedron analysis, owned
    /// independently from the coordination token so polyhedron restarts
    /// cannot interfere with coordination and vice-versa.
    private var polyhedronCancellationToken: CoordinationCancellationToken?
    /// Test seam mirroring `coordinationAnalysisDidUpdate`.
    internal var polyhedronAnalysisDidUpdate: (() -> Void)?
    /// Runtime-only two-structure comparison: the reference structure loaded by
    /// the user and the last computed result. Never persisted.
    private(set) var comparisonResult: StructureComparisonResult?
    private(set) var comparisonReferenceTitle: String?
    /// Monotonic generation + cancellation token for the async comparison
    /// workflow. Every new request (open-panel, programmatic) bumps the
    /// generation and cancels the prior token so a stale completion after a
    /// clear / new request / window close / geometry change can never install.
    private var comparisonGeneration = 0
    private var comparisonCancellationToken: CoordinationCancellationToken?
    /// The background comparison work item, tracked so it can be cancelled.
    private var comparisonWorkItem: DispatchWorkItem?
    /// Distribution analysis is derived on a background work item so the main
    /// thread is not blocked by the O(27·n²) RDF enumeration or the
    /// O(n·k²) bond-angle sweep.
    private var distributionWorkItem: DispatchWorkItem?
    private var distributionGeneration = 0
    private var distributionCancellationToken: CoordinationCancellationToken?
    private var lastCoordinationEnabled = false
    private var lastCoordinationScale = CoordinationAnalyzer.defaultRadiusScale
    /// Identity of the atom set + criteria the currently installed
    /// `scene.hbondPairs` were detected for. H-bond detection is O(n²)-ish, so
    /// it must not rerun on every unrelated sidebar change; it reruns only when
    /// this fingerprint changes. Wholesale scene replacements (file open, frame
    /// reload) reset it to nil so a fresh scene always recomputes.
    private var lastHbondFingerprint: HbondFingerprint?
    /// Complete CN data installed for the currently displayed atom ordering.
    /// This is the only CN array consumed by renderers and avoids deriving it on
    /// camera-only renders.
    private var installedCoordinationNumbers: [Int] = []
    private var lastCoordinationDelegateIs2D: Bool?
    /// Test counters for lifecycle-only renderer/table updates. They deliberately
    /// do not increment from `setNeedsRender()`.
    internal private(set) var coordinationRendererUpdateCount = 0
    internal private(set) var coordinationTableUpdateCount = 0
    internal private(set) var coordinationFullTableRefreshCount = 0
    /// The on-disk source + forced format of the currently-loaded file, kept so
    /// the animation controls can re-parse an arbitrary frame (AXSF animation
    /// is re-decoded frame-by-frame; the parsed LoadedScene is otherwise
    /// single-use). Nil for the empty opening viewer.
    private var sourceURL: URL?
    private var forcedFormat: ParseFormat?
    /// Monotonic token gating async timeline-thumbnail and frame-metric
    /// generation. A new request bumps the token so a stale background
    /// completion (after a scene/frame reload) can never publish into the
    /// freshly-installed state.
    private var animationDataGeneration = 0
    private var animationDataCancellationToken: CoordinationCancellationToken?
    /// Cache key (sourceURL + frameCount) for the last thumbnail/metric build,
    /// so re-entrant installScene calls for the same document don't re-decode.
    private var lastAnimationDataKey: (url: URL, count: Int)?
    /// Centroid-aligned copy of the loaded frames, cached while
    /// `state.alignTrajectory` is on. nil when alignment is off. Invalidated on
    /// scene/frame reload by `installScene`.
    private var alignedFrames: [Scene]?
    /// Window hosting the per-frame metrics plot; nil until first shown.
    private var framePlotsWindow: NSWindow?
    /// The plot view inside `framePlotsWindow`, retained so the metric picker can
    /// switch its displayed field without rebuilding the window.
    private var framePlotsView: FrameMetricsPlotView?
    /// Runtime-only cell representation for the structure-tools basis transform.
    /// Session-only (not a Scene field); reset to .input on every fresh file open.
    private var currentCellRepresentation: CellRepresentation = .input
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
    /// Reciprocal edit focus is transient: it is never persisted with the scene.
    private var reciprocalStructureCamera: Camera?
    private var reciprocalStructureDisplayMode: DisplayMode?
    private var reciprocalStructureShowBZ: Bool?
    private var reciprocalStructureOrthographic: Bool?
    private var lastEditKPathOnBZ = false
    private var reciprocalHoverCandidate: BZCandidate?
    private var reciprocalHoverCursor: SIMD2<Float>?
    /// Keep this alongside the optional renderer so label styling remains correct
    /// in the Metal-unavailable test path too.
    private var selectedRouteNodeIndex: Int?
    /// Route labels are bounded to 1024 nodes, with a separate style entry for
    /// a selected node. Keep the per-controller cache bounded and unsynchronized.
    private static let routeLabelMeasurementCacheCapacity = 2048
    private var routeLabelMeasurementCache: [RouteLabelMeasurementKey: CGSize] = [:]
    private var routeLabelTextSignature: [String]?
    /// Test-only count of actual route text measurements. Cache hits do not
    /// increment this value.
    internal private(set) var routeLabelMeasurementCount = 0
    internal private(set) var reciprocalEditorFrameCount = 0
    /// Test-only count of render requests, including ordinary scene redraws.
    internal private(set) var renderRequestCount = 0
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
    /// Guards against re-entrant scene mutation during commit/undo so a
    /// lifecycle callback (e.g. coordination update) that touches the scene
    /// cannot silently discard an in-progress edit.
    private var isCommittingEdit = false
    /// When non-nil, undo is disabled for coordinate edits (structure too
    /// large). The string explains why; surfaced via the table's editing-
    /// disabled reason when relevant.
    private var coordinateUndoDisabledReason: String?
    /// The reason the most recent commit was rejected. Surfaces as the
    /// table's accessibility/status text so invalid input is communicated
    /// beyond a beep.
    private(set) var lastEditRejectionReason: String?
    /// Repeating timer driving AXSF playback. Held weakly by the runloop; we
    /// recreate it on Play and invalidate on Pause/stop in `syncFromState`.
    private var playTimer: Timer?

    deinit {
        cancelCoordinationRequest()
        cancelPolyhedronRequest()
        cancelXRDRequest()
        cancelAnimationDataRequest()
        // Cancellation-only teardown: do not mutate published UI state or the
        // installed result from deinit (no alive view/window to render into).
        cancelComparisonRequestOnly()
        // Tear down the repeating playback timer and the file watcher (DispatchSource
        // + its POSIX fd + debounce timer). Both helpers are cancellation-only
        // (invalidate/cancel + nil) and touch no published state, so they are safe
        // here; without this, a controller released without a window close (tests with
        // showWindow:false, rapid window replacement) leaks the timer, the source,
        // the fd and the debounce timer forever.
        stopPlayback()
        stopFileWatching()
    }

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
        // Tier-1 appearance mirror for a directly-constructed controller. Static
        // because `self` is not yet fully initialized here; `syncFromScene`
        // above covers the pre-Tier-1 fields the same way.
        MainWindowController.mirrorTier1Appearance(scene, into: state)
        state.syncCameraBookmarkSlots(cameraBookmarks)
        sidebar = NSHostingView(rootView: SideBar(state: state))
        canvas = MetalView(frame: .zero, device: device)
        canvas.autoresizingMask = [.width, .height]
        viewport.addSubview(canvas)
        labelOverlay = LabelOverlayView(frame: .zero)
        canvas.addSubview(labelOverlay)
        labelOverlay.autoresizingMask = [.width, .height]
        bandGrapher = BandGrapherView(frame: .zero)
        dosGrapher = DOSGrapherView(frame: .zero)
        bandSurfaceView = BandSurfaceView(frame: .zero)
        bandSurfaceView.autoresizingMask = [.width, .height]
        bandSurfaceView.isHidden = true
        viewport.addSubview(bandSurfaceView)
        linkedGraphs = LinkedGraphsView(frame: .zero, bandView: bandGrapher, dosView: dosGrapher,
                                        band: nil, dos: nil, bandPresent: false, dosPresent: false)
        linkedGraphs.autoresizingMask = [.width, .height]
        linkedGraphs.isHidden = true
        viewport.addSubview(linkedGraphs)
        xrdGrapher = PowderXRDGrapherView(frame: .zero)
        xrdGrapher.autoresizingMask = [.width, .height]
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
        // Set up the window's undo manager for coordinate editing. The Edit
        // menu's Undo/Redo items (target nil) resolve to this manager through
        // the first-responder chain.
        window.undoManager?.levelsOfUndo = 64
        window.undoManager?.groupsByEvent = false
        window.delegate = self
        state.onChange = { [weak self] in self?.syncFromState() }
        state.onRegionChange = { [weak self] in self?.recomputeRegionIntegration() }
        state.onPickBackgroundImage = { [weak self] in self?.pickBackgroundImage() }
        state.onComputeWholeField = { [weak self] in self?.computeWholeFieldIntegration() }
        state.onResetView = { [weak self] in self?.resetView() }
        state.onStandardCrystalView = { [weak self] view in
            self?.alignToStandardCrystalView(view)
        }
        state.onSaveCameraBookmark = { [weak self] slot in
            self?.saveCameraBookmark(at: slot)
        }
        state.onRecallCameraBookmark = { [weak self] slot in
            self?.recallCameraBookmark(at: slot)
        }
        state.onClearCameraBookmark = { [weak self] slot in
            self?.clearCameraBookmark(at: slot)
        }
        state.onExportKPath = { [weak self] path, format in
            guard let self else { return }
            self.exportKPath(self.kPathForExport(path), format)
        }
        state.onImportKPath = { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText]
            panel.allowsOtherFileTypes = true
            panel.beginSheetModal(for: self.window) { result in
                guard result == .OK, let url = panel.url else { return }
                do {
                    try self.importKPath(from: url)
                } catch {
                    print("[mcrysden] k-path import failed: \(error)")
                    self.presentImportError(error)
                }
            }
        }
        state.onResetKPath = { [weak self] in self?.resetKPathDefault() }
        state.onSelectKPathNode = { [weak self] index in self?.selectKPathNode(index) }
        state.onShowAtomTable = { [weak self] in self?.showAtomTable() }
        state.onShowNeighborTable = { [weak self] in self?.showNeighborTable() }
        state.onShowPolyhedronTable = { [weak self] in self?.showPolyhedronTable() }
        state.onShowComparison = { [weak self] in self?.chooseComparisonReference() }
        state.onClearComparison = { [weak self] in self?.clearComparison() }
        state.onExportComparisonCSV = { [weak self] in self?.exportComparisonCSV() }
        state.onExportDistributionCSV = { [weak self] dist in
            guard let self else { return }
            self.exportDistributionCSV(dist)
        }
        state.onExportElectronicAnalysisText = { [weak self] report in
            guard let self else { return }
            self.exportElectronicAnalysisText(report.summaryText)
        }
        state.onExportElectronicAnalysisCSV = { [weak self] report in
            guard let self else { return }
            self.exportElectronicAnalysisCSV(report.csv)
        }
        state.onBandSurfaceClosestCount = { [weak self] count in
            guard let self, let mesh = self.scene.bandStructure, mesh.isMesh else { return }
            let keys = BandSurfaceBuilder.closestBands(mesh, count: count,
                                                       bandOffset: self.scene.bandSurface?.bandOffset ?? 0)
            self.state.bandSurfaceBandSelection = Set(keys)
        }
        state.onShowXRDWindow = { [weak self] in self?.showPowderXRD() }
        state.onExportXRDCSV = { [weak self] in self?.exportPowderXRDCSV() }
        state.onSeekToThumbnail = { [weak self] index in
            guard let self else { return }
            self.seekToFrame(index)
        }
        state.onExportFrameMetricsCSV = { [weak self] csv in
            guard let self else { return }
            self.exportFrameMetricsCSV(csv)
        }
        state.onExportAnimation = { [weak self] url in
            guard let self else { return }
            self.exportAnimation(to: url)
        }
        state.onSaveProject = { [weak self] url in
            guard let self else { return }
            self.saveProject(to: url)
        }
        state.onShowFramePlots = { [weak self] in self?.showFramePlots() }
        // Structure-tools callbacks (runtime-only transforms + surface builder).
        state.onApplyBasisTransform = { [weak self] rep in self?.applyBasisTransform(rep) }
        state.onApplyDeformation = { [weak self] in self?.applyDeformation() }
        state.onCutCluster = { [weak self] in self?.cutCluster() }
        state.onBuildSurface = { [weak self] in self?.buildSurfaceCell() }
        state.onSurfaceVacuumChange = { [weak self] in self?.surfaceVacuumDidChange() }
        // Structure-editing callbacks.
        state.onInsertInterstitial = { [weak self] in self?.insertInterstitialFromState() }
        state.onRemoveSelectedAtoms = { [weak self] in self?.removeSelectedAtoms() }
        state.onSubstituteSelected = { [weak self] in self?.substituteSelectedFromState() }
        state.onDisplaceAtoms = { [weak self] in self?.displaceFromState() }
        state.onApplyLattice = { [weak self] in self?.applyLatticeParameters() }
        state.onResetLattice = { [weak self] in self?.resetLatticeParameters() }
        state.onExportStructure = { [weak self] format in self?.exportStructure(format) }
        // Cursor readouts for the electronic-structure graphs. Assigned after
        // super.init so the closures capture a fully-initialized self.
        bandGrapher.onCursor = { [weak self] info in
            guard let self else { return }
            self.linkedGraphs.dosView.linkedCursorEnergy = info?.energy
            self.state.electronicStructureCursorText = info.map {
                String(format: "E = %.3f eV", $0.energy)
            } ?? ""
        }
        dosGrapher.onCursor = { [weak self] info in
            guard let self else { return }
            self.linkedGraphs.bandView.linkedCursorEnergy = info?.energy
            self.state.electronicStructureCursorText = info.map {
                String(format: "E = %.3f eV, DOS = %.3f", $0.energy, $0.dosValue)
            } ?? ""
        }
        // Install electronic-structure data from the initial scene (if constructed
        // directly with band/DOS data, e.g. in tests), so the section shows without
        // an explicit loadFile. Guarded against re-entrancy via isSyncingState.
        let initHasBands = scene.bandStructure != nil
        bandGrapher.bandStructure = scene.bandStructure
        dosGrapher.densityOfStates = scene.densityOfStates
        bandSurfaceView.bandSurface = scene.bandSurface
        if let o = scene.bandSurfaceOrientation {
            bandSurfaceView.azimuthDegrees = o.azimuthDegrees
            bandSurfaceView.elevationDegrees = o.elevationDegrees
        } else {
            // A scene without a persisted orientation must not inherit the previous
            // document's angles: reset to the view defaults.
            bandSurfaceView.azimuthDegrees = 30
            bandSurfaceView.elevationDegrees = 24
        }
        linkedGraphs.bandView.bandStructure = scene.bandStructure
        linkedGraphs.dosView.densityOfStates = scene.densityOfStates
        state.electronicStructureEnabled = initHasBands || scene.densityOfStates != nil || scene.bandSurface != nil
        updateContentVisibility()
        updateElectronicStructureGraphs()
        refreshBandSurfaceBandUI()
        updatePowderXRD()
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
        // Coordinate editing in the atom table. The table routes every cell
        // commit here for transactional validation and application; the table
        // itself never mutates a private copy of the atoms.
        atomTable.onCommitEdit = { [weak self] row, columnIdentifier, value in
            guard let self else { return .rejected(reason: "") }
            return self.commitAtomEdit(row: row, columnIdentifier: columnIdentifier, value: value)
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

    /// Install exactly the supported number of document-scoped bookmark slots.
    /// StateStore normally supplies three entries, but malformed/legacy callers
    /// are padded or truncated here so no later action can index outside bounds.
    private func installCameraBookmarks(_ bookmarks: [CameraBookmark?]) {
        var installed = Array<CameraBookmark?>(repeating: nil, count: CameraBookmark.slotCount)
        for index in installed.indices where bookmarks.indices.contains(index) {
            installed[index] = bookmarks[index]
        }
        cameraBookmarks = installed
        state.syncCameraBookmarkSlots(installed)
    }

    /// Apply a freshly-loaded scene: reframe the camera ONCE (spec §6 — the
    /// camera resets on file open) and sync the sidebar so the next sidebar
    /// change does not clobber the loaded state with defaults. Records the
    /// source URL/format so AXSF animation can re-parse individual frames, and
    /// populates the animation controls (frameCount > 1 => show playback).
    /// A normal structure load passes no bookmarks and therefore starts empty;
    /// App passes restored slots when opening a companion `.mvis-state` file.
    func loadFile(_ scene: Scene, from url: URL? = nil, format: ParseFormat? = nil,
                  frameIndex: Int = 0, cameraBookmarks: [CameraBookmark?] = []) {
        loadGeneration += 1   // cancel any pending background drop loads
        clearReciprocalFocusForSceneReplacement()
        installCameraBookmarks(cameraBookmarks)
        // A new document invalidates any two-structure comparison: the reference
        // was matched against the previous atom ordering. Drop readouts, panel
        // content, and displacement arrows before installing the new scene.
        // loadFile renders later, so suppress the invalidation render.
        invalidateComparisonRequest(render: false)
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
        // Basis transforms are session-only; a fresh file open restores the input
        // representation regardless of any transform applied to the previous scene.
        currentCellRepresentation = .input
        installScene(scene, frameIndex: frameIndex,
                     frameCount: url.map { Parser.frameCount($0, as: format) } ?? 1)
    }

    /// Re-apply the CLI electronic-structure display flags (--bands/--dos/--band-surf)
    /// to a scene that is about to be installed, so derived data survives GUI
    /// re-parses (revert, frame changes). Failures are non-fatal here: the GUI
    /// already reported them at open time; a reload leaves the scene unchanged.
    private func applyElectronicStructureFlags(to scene: inout Scene) {
        let flags = electronicStructureFlags
        guard flags.bandPlot || flags.dosPlot || flags.bandSurf else { return }
        do {
            try App.applyElectronicStructureFlags(scene: &scene, flags: flags,
                                                  kPathSampling: state.kPathSampling)
        } catch {
            print("[mcrysden] warning: electronic-structure flags failed on reload: \(error)")
        }
    }

    /// Everything that follows the source/url bookkeeping in `loadFile`: installs the
    /// scene, rebuilds the editor BZ, syncs the sidebar, reframes the camera, installs
    /// graph data, and initialises the animation controls. Extracted so that in-scene
    /// transforms (basis/deformation/cluster/surface) can reinstall a derived scene
    /// through the exact same path without re-opening the source file. Byte-identical
    /// to the former tail of `loadFile` for the primary open/revert/drop paths.
    private func installScene(_ scene: Scene, frameIndex: Int, frameCount: Int) {
        var scene = scene
        applyElectronicStructureFlags(to: &scene)
        self.scene = scene
        bzEpoch += 1   // new scene: cell/baseAtoms may differ, rebuild the editor BZ
        state.syncFromScene(scene)
        mirrorTier1AppearanceToState(from: scene)
        refreshBasisTransformAvailability()
        // syncFromScene exits edit mode (editKPathOnBZ -> false); mirror that into the
        // renderer so a freshly-loaded scene can't leave stale landmark crosses drawn.
        renderer?.showBZLandmarks = state.editKPathOnBZ
        // A freshly-loaded scene has its own route; clear any stale node highlight
        // left over from the previous scene (its index may now be out of range).
        // syncFromScene installed that route via replaceKPath (bumping routeGeneration);
        // resync the token so the next syncFromState does not treat the fresh route as
        // a wholesale replacement and clear a newly-set selection.
        renderer?.selectedKPathNode = nil
        renderer2D?.selectedKPathNode = nil
        selectedRouteNodeIndex = nil
        lastRouteGeneration = state.routeGeneration
        applyCameraForNewSceneIfNeeded()
        // Graph data replaces the Metal canvas. DOS takes precedence if a loaded
        // scene ever contains both DOS and band data.
        let hasBands = scene.bandStructure != nil
        bandGrapher.bandStructure = scene.bandStructure
        bandGrapher.highSymmetryIndices = scene.bandStructure.map { bs in
            bs.kPoints.indices.filter { !bs.kPoints[$0].label.isEmpty }
        } ?? []
        dosGrapher.densityOfStates = scene.densityOfStates
        bandSurfaceView.bandSurface = scene.bandSurface
        if let o = scene.bandSurfaceOrientation {
            bandSurfaceView.azimuthDegrees = o.azimuthDegrees
            bandSurfaceView.elevationDegrees = o.elevationDegrees
        } else {
            // A scene without a persisted orientation must not inherit the previous
            // document's angles: reset to the view defaults.
            bandSurfaceView.azimuthDegrees = 30
            bandSurfaceView.elevationDegrees = 24
        }
        // Electronic-structure section is available when any graph/surface is populated.
        // (Not a @Published scene field — set directly, not via state, to avoid
        // persisting view-only availability into the scene.)
        state.electronicStructureEnabled = hasBands || scene.densityOfStates != nil || scene.bandSurface != nil
        updateElectronicStructureGraphs()
        refreshBandSurfaceBandUI()
        updatePowderXRD()
        // A 2D scalar grid: the color-plane is now drawn as a textured quad in the
        // Metal scene by the renderer (gated on scene.showColorPlane). No separate
        // canvas swap needed.
        updateContentVisibility()
        // A freshly installed scene owns a new atom set: drop the cached H-bond
        // fingerprint and re-derive the pairs for it (a no-op when disabled).
        hbondGeometryDidChange()
        // Initialise the animation controls WITHOUT triggering onChange (which
        // would otherwise try to reload frame 0 on top of this fresh load).
        let saved = state.onChange
        state.onChange = nil
        state.frameIndex = frameIndex
        state.frameCount = frameCount
        state.isPlaying = false
        state.onChange = saved
        stopPlayback()
        // A fresh scene may have a different source/frame count — invalidate the
        // cached thumbnails/metrics/alignment so the next refresh rebuilds for this document.
        lastAnimationDataKey = nil
        state.trajectoryTrailsAvailable = false
        alignedFrames = nil
        state.alignTrajectory = false
        refreshAnimationData()
        coordinationGeometryDidChange()
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
            currentCellRepresentation = .input
            loadFile(scene, from: url, format: forcedFormat, frameIndex: 0)
        } catch {
            print("[mcrysden] revert failed: \(error)")
        }
    }

    /// Scene -> sidebar mirror for the Tier-1 appearance fields, the exact
    /// inverse of the `syncFromState` block that pushes them the other way.
    /// `SideBarState.syncFromScene` owns the pre-Tier-1 fields; these live here
    /// instead so the sidebar-state file stays untouched by this wiring.
    ///
    /// onChange is suspended for the duration (the same pattern the lattice and
    /// animation prefills use): every assignment below is a @Published didSet
    /// that would otherwise synchronously re-enter `syncFromState` and push the
    /// half-mirrored sidebar back into the scene we are reading from.
    private static func mirrorTier1Appearance(_ scene: Scene, into state: SideBarState) {
        let saved = state.onChange
        state.onChange = nil
        defer { state.onChange = saved }
        state.lights = Array(scene.lights.prefix(maxSceneLights))
        state.hbondSettings = scene.hbondSettings
        state.molecularSurfaceSettings = scene.molecularSurfaceSettings
        state.atomColorScheme = scene.atomColorScheme
        state.elementOverrides = scene.elementOverrides
        state.repetitionMode = scene.repetitionMode
        state.cellRodsEnabled = scene.cellRodsEnabled
        state.cellRodFactor = scene.cellRodFactor
        state.unicolorBonds = scene.unicolorBonds
        state.unicolorBondHex = scene.unicolorBondHex
        state.tessellationFactor = scene.tessellationFactor
    }

    /// Instance form of the Tier-1 scene -> sidebar mirror, used by the scene
    /// installation paths (`installScene`, `reloadFrame`).
    private func mirrorTier1AppearanceToState(from scene: Scene) {
        MainWindowController.mirrorTier1Appearance(scene, into: state)
    }

    /// Refresh the runtime-only basis-transform availability + help text from the
    /// current scene's symmetry analysis and the active cell representation. Called
    /// from `installScene` after `syncFromScene`, so the sidebar's structure-tools
    /// availability mirrors the just-installed scene.
    private func refreshBasisTransformAvailability() {
        let sym = scene.crystalSymmetry?.symmetry
        let is3D = scene.isCrystal && scene.periodicDim == 3 && scene.cell != nil && !scene.atoms.isEmpty
        let primAvail = is3D && (sym?.primitiveStructure.atomCount ?? 0) < scene.atoms.count
        let convAvail = is3D && sym != nil && currentCellRepresentation != .conventional
        state.applyBasisTransformAvailability(
            primitive: primAvail || (is3D && sym != nil && currentCellRepresentation == .conventional),
            conventional: convAvail,
            help: is3D && sym == nil ? (scene.crystalSymmetry?.reasonDescription ?? "symmetry analysis unavailable") : "",
            representation: currentCellRepresentation)
    }

    /// Apply a primitive/conventional basis transform, or restore the input cell.
    func applyBasisTransform(_ representation: CellRepresentation) {
        guard representation != currentCellRepresentation else { return }
        if representation == .input {
            // Session-only transform: restore by re-parsing the source file.
            if sourceURL != nil {
                revertToSource()
            } else {
                state.setStructureToolsStatus("No source file to revert to.")
            }
            return
        }
        guard representation != currentCellRepresentation else { return }
        switch scene.transformed(to: representation) {
        case .success(let next):
            var next = next
            next.transferKPathAcrossGeometryChange(from: scene)
            currentCellRepresentation = representation
            installScene(next, frameIndex: 0, frameCount: 1)
            state.setStructureToolsStatus("Converted to \(representation.label): \(next.atoms.count) atoms")
        case .failure(let error):
            state.setStructureToolsStatus(error.description)
        }
    }

    /// Apply the 3x3 elastic deformation matrix to the cell.
    func applyDeformation() {
        guard state.deformationMatrix.count == 9 else {
            state.setStructureToolsStatus("Deformation matrix must have 9 elements.")
            return
        }
        let rows = [
            SIMD3<Float>(state.deformationMatrix[0], state.deformationMatrix[1], state.deformationMatrix[2]),
            SIMD3<Float>(state.deformationMatrix[3], state.deformationMatrix[4], state.deformationMatrix[5]),
            SIMD3<Float>(state.deformationMatrix[6], state.deformationMatrix[7], state.deformationMatrix[8]),
        ]
        switch scene.deformed(byRows: rows) {
        case .success(let next):
            var next = next
            next.transferKPathAcrossGeometryChange(from: scene)
            installScene(next, frameIndex: 0, frameCount: 1)
            state.setStructureToolsStatus("Cell deformed: \(next.atoms.count) atoms")
        case .failure(let error):
            state.setStructureToolsStatus(error.description)
        }
    }

    /// Cut a finite cluster of atoms within `clusterRadius` of `clusterCenter`.
    func cutCluster() {
        switch scene.cutCluster(center: state.clusterCenter, radius: state.clusterRadius) {
        case .success(let next):
            installScene(next, frameIndex: 0, frameCount: 1)
            state.setStructureToolsStatus("Cluster cut: \(next.atoms.count) atoms")
        case .failure(let error):
            state.setStructureToolsStatus(error.description)
        }
    }

    /// Build a Miller-index surface cell with termination selection + vacuum.
    func buildSurfaceCell() {
        guard state.surfaceBuilderAvailable else {
            state.setSurfaceStatus("Surface builder requires a 3D periodic crystal.",
                                  terminationOptions: 0, termination: 0)
            return
        }
        let request = SurfaceCellRequest(
            h: min(8, max(-8, state.surfaceH)),
            k: min(8, max(-8, state.surfaceK)),
            l: min(8, max(-8, state.surfaceL)),
            layers: min(100, max(1, state.surfaceLayers)),
            vacuum: min(50, max(0, state.surfaceVacuum)),
            termination: max(0, state.surfaceTermination),
            stackCount: min(10, max(1, state.surfaceStackCount))
        )
        switch scene.buildSurfaceCellWithInfo(request: request) {
        case .success(let built):
            let (next, info) = built
            installScene(next, frameIndex: 0, frameCount: 1)
            let options = max(0, info.planeCount - request.layers + 1)
            let termination = options > 0 ? min(state.surfaceTermination, options - 1) : 0
            let vacuum = max(0, (next.cell?.cLength ?? request.vacuum) - info.slabExtent)
            state.setSurfaceStatus("Slab (\(request.h) \(request.k) \(request.l)): \(next.atoms.count) atoms, \(info.planeCount) planes, vacuum \(String(format: "%.2f", vacuum)) Å",
                                 terminationOptions: options, termination: termination)
        case .failure(let error):
            state.setSurfaceStatus(error.description, terminationOptions: 0, termination: 0)
        }
    }

    /// Vacuum thickness (c length minus slab extent) of the current scene when it
    /// is a z-parallel 2D slab; nil otherwise. The sidebar's vacuum slider and the
    /// live-vacuum mirrors compare against this derived value, not the c length.
    private var currentSlabVacuum: Float? {
        guard scene.periodicDim == 2, let cell = scene.cell,
              let extent = scene.surfaceSlabExtent else { return nil }
        return cell.cLength - extent
    }

    /// Live vacuum adjust for the current 2D slab via the build slider. Lightweight
    /// (no full reinstall): just swaps the scene's c length, re-renders, and refresh
    /// the atom table. No-op unless the scene is a z-parallel 2D slab.
    func surfaceVacuumDidChange() {
        guard let currentVacuum = currentSlabVacuum else { return }
        guard state.surfaceVacuum != currentVacuum else { return }
        switch scene.withVacuum(state.surfaceVacuum) {
        case .success(let next):
            scene = next
            setNeedsRender()
            refreshAtomTable()
        case .failure:
            state.surfaceVacuum = currentVacuum
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
        coordinationFullTableRefreshCount += 1
        syncAtomTableEditingState()
        atomTable.update(atoms: scene.atoms, cell: scene.cell, selectedAtoms: scene.selectedAtoms,
                         coordinationNumbers: installedCoordinationNumbers.isEmpty
                            ? nil : installedCoordinationNumbers)
        lastSyncedSelection = scene.selectedAtoms
    }

    // MARK: - Atom-coordinate editing

    /// Record the rejection reason and return `.Rejected`. Centralizes the
    /// bookkeeping so every rejection path surfaces the reason to the UI.
    private func rejectEdit(reason: String) -> EditCommitResult {
        lastEditRejectionReason = reason
        return .rejected(reason: reason)
    }

    /// Validate and apply a coordinate edit committed from the atom table.
    /// Transactional: the scene is left unchanged when the edit is rejected.
    /// `row` is the filtered table row; `columnIdentifier` is x/y/z or a/b/c;
    /// `value` is the raw text from the field editor. Returns `.accepted` when
    /// the edit was applied, `.rejected` otherwise (the table beeps).
    func commitAtomEdit(row: Int, columnIdentifier: NSUserInterfaceItemIdentifier,
                        value: String) -> EditCommitResult {
        // Re-entrancy guard: a lifecycle callback that touches the scene must
        // never discard an in-progress commit.
        guard !isCommittingEdit else {
            return rejectEdit(reason: "")
        }
        isCommittingEdit = true
        defer { isCommittingEdit = false }

        // Resolve the filtered row to the original displayed atom index.
        guard row >= 0, row < atomTable.filteredAtomIndices.count else {
            return rejectEdit(reason: "")
        }
        let atomIndex = atomTable.filteredAtomIndices[row]
        guard atomIndex >= 0, atomIndex < scene.atoms.count else {
            return rejectEdit(reason: "")
        }

        // Editing is only allowed on pristine geometry: no supercell expansion
        // and no slab. Otherwise a coordinate edit would corrupt the base /
        // preslab invariants that widening and slab filtering rebuild from.
        if scene.superCell.total > 1 {
            return rejectEdit(reason: "Editing disabled: supercell active. "
                + "Reset the supercell to 1×1×1 to edit atom coordinates.")
        }
        if scene.slab != nil {
            return rejectEdit(reason: "Editing disabled: slab active. "
                + "Remove the slab to edit atom coordinates.")
        }
        if scene.atoms.count > Self.coordinateUndoMaxAtoms {
            return rejectEdit(reason: "Editing disabled: structure has \(scene.atoms.count) atoms "
                + "(editable cap \(Self.coordinateUndoMaxAtoms)).")
        }

        // Validate the new value: must parse as a finite Float.
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let newValue = Float(trimmed), newValue.isFinite else {
            return rejectEdit(reason: "\"\(trimmed)\" is not a finite number.")
        }

        let currentCoord = scene.atoms[atomIndex].coord
        var newCoord = currentCoord

        switch columnIdentifier {
        case AtomTableView.colX: newCoord.x = newValue
        case AtomTableView.colY: newCoord.y = newValue
        case AtomTableView.colZ: newCoord.z = newValue
        case AtomTableView.colA, AtomTableView.colB, AtomTableView.colC:
            // Fractional edit: requires a finite, nonsingular cell so the
            // fractional<->Cartesian conversion is well-defined.
            guard let cell = scene.cell, cell.isFinite else {
                return rejectEdit(reason: "Fractional edit requires a finite unit cell.")
            }
            guard cell.isNonsingular else {
                return rejectEdit(reason: "Fractional edit requires a nonsingular unit cell.")
            }
            // Convert the displayed fractional value to Cartesian. Preserve the
            // unchanged fractional components, then convert the full triplet.
            let currentFrac = scene.fractionalCoord(currentCoord) ?? SIMD3(0, 0, 0)
            var targetFrac = currentFrac
            switch columnIdentifier {
            case AtomTableView.colA: targetFrac.x = newValue
            case AtomTableView.colB: targetFrac.y = newValue
            case AtomTableView.colC: targetFrac.z = newValue
            default: break
            }
            let cartesian = cell.cartesian(targetFrac)
            guard cartesian.isFinite else {
                return rejectEdit(reason: "Fractional conversion produced a non-finite coordinate.")
            }
            newCoord = cartesian
        default:
            return rejectEdit(reason: "")
        }

        // No-op when the value is unchanged — don't pollute the undo stack.
        if newCoord == currentCoord {
            lastEditRejectionReason = nil
            return .accepted
        }

        // Capture the pre-edit scene for undo BEFORE mutating.
        let preEditScene = scene

        // Apply the edit: copy the atom, preserve identity/label/force, update
        // only the coordinate.
        var editedAtom = scene.atoms[atomIndex]
        editedAtom.coord = newCoord

        // Push the edit onto the scene transactionally.
        var newScene = scene
        newScene.atoms[atomIndex] = editedAtom
        // For pristine geometry (the only editable case), all source snapshots
        // must mirror the edited atoms. Otherwise a later slab, supercell reset,
        // or BZ invalidation could silently restore stale pre-edit geometry.
        if newScene.superCell.total <= 1 && newScene.slab == nil {
            newScene.baseAtoms = newScene.atoms
            newScene.preslabAtoms = newScene.atoms
        }
        // Recompute bonds for the edited atom set (C covalent-radii heuristic).
        // Handles both crystals (periodic, bonds across images) and molecules
        // (non-periodic, distance-only). Never leaves stale or empty molecule
        // bonds after a coordinate edit.
        newScene.bonds = Scene.rebond(newScene.atoms, cell: newScene.cell,
                                       isCrystal: newScene.isCrystal,
                                       periodicDim: newScene.periodicDim)
        if newScene.superCell.total <= 1 && newScene.slab == nil {
            newScene.baseBonds = newScene.bonds
        }
        // A coordinate change invalidates the locked measurement: the picked
        // atoms' positions shifted.
        newScene.measurementResult = nil
        // Invalidate symmetry analysis and the generated k-path that derives
        // from it. Preserve the prior input-completeness so an asymmetric-unit
        // or unknown file is never promoted to `.complete` by an edit. User-
        // edited routes are preserved (cell is unchanged).
        let priorCompleteness = scene.crystalSymmetry?.inputCompleteness ?? .complete
        newScene.crystalSymmetry = CrystalSymmetryAnalyzer.analyze(
            cell: newScene.cell,
            atoms: newScene.atoms,
            isCrystal: newScene.isCrystal,
            periodicDim: newScene.periodicDim,
            inputCompleteness: priorCompleteness
        )
        // Regenerate the canonical path only for valid complete 3D crystals.
        // User-edited routes remain exact; incomplete/unknown/2D inputs skip
        // regeneration (installCanonicalPath clears the path when symmetry is
        // unavailable, which is the correct conservative behavior).
        let isComplete3DCrystal = newScene.isCrystal && newScene.periodicDim == 3
            && priorCompleteness == .complete
        if newScene.kPathProvenance == .generated, let cell = newScene.cell,
           isComplete3DCrystal {
            newScene.installCanonicalPath(cell: cell)
        }

        // Install the new scene. `scene.didSet` invalidates the BZ cache when
        // reciprocal geometry changed (it did: base atoms changed).
        scene = newScene

        // Register bounded undo: capture the pre-edit scene. Coalesced — one
        // entry per cell commit.
        pushEditUndo(preEditScene, actionName: "Edit Atom Coordinate")

        // Run the remaining invalidation lifecycle.
        runCoordinateEditLifecycle()

        // Set up the table for the next edit: editing is enabled on pristine
        // geometry, disabled otherwise (defensive — we already checked above).
        syncAtomTableEditingState()

        return .accepted
    }

    /// Per-snapshot atom cap for undo. Each undo entry captures a full Scene
    /// (atoms + bonds + cell + fields); at ~32 bytes/atom plus bonds, a 500k-
    /// atom structure would burn ~16 MB per snapshot. Cap so the bounded
    /// history (levelsOfUndo) never exceeds a reasonable memory budget.
    static let coordinateUndoMaxAtoms = 10_000

    /// Register an undo action with the window's undo manager. One entry
    /// per commit; the redo stack (in NSUndoManager) is cleared automatically
    /// because a new edit invalidates redo history. Skipped (with a clear
    /// status) when the structure exceeds the undo atom cap.
    private func pushEditUndo(_ preEditScene: Scene, actionName: String) {
        if preEditScene.atoms.count > Self.coordinateUndoMaxAtoms {
            coordinateUndoDisabledReason = "Undo disabled: structure has \(preEditScene.atoms.count) atoms (cap \(Self.coordinateUndoMaxAtoms))."
            return
        }
        coordinateUndoDisabledReason = nil
        // One explicit group per table-cell commit. This avoids accidentally
        // merging programmatic commits in the same run-loop event and mirrors
        // the UI contract exactly.
        guard let undoManager = window.undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            self?.restoreSceneForUndo(preEditScene, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Restore a pre- or post-edit scene as part of an undo/redo. Called by
    /// NSUndoManager. Registers the inverse action so undo and redo are
    /// symmetric, then runs the invalidation lifecycle.
    func restoreSceneForUndo(_ targetScene: Scene, actionName: String) {
        let currentScene = scene
        scene = targetScene
        // Register the inverse so the user can redo (or undo again).
        window.undoManager?.registerUndo(withTarget: self) { [weak self] _ in
            self?.restoreSceneForUndo(currentScene, actionName: actionName)
        }
        window.undoManager?.setActionName(actionName)
        runCoordinateEditLifecycle()
        syncAtomTableEditingState()
    }

    /// Undo the most recent coordinate edit. Delegates to the window's undo
    /// manager, which dispatches to `restoreSceneForUndo`.
    func undoCoordinateEdit() {
        window.undoManager?.undo()
    }

    /// Redo the most recent undone coordinate edit.
    func redoCoordinateEdit() {
        window.undoManager?.redo()
    }

    /// The invalidation lifecycle shared by commit, undo, and redo. Updates
    /// the structure summary, BZ-dependent geometry, coordination analysis,
    /// distribution analysis, the atom table, and the renderer.
    private func runCoordinateEditLifecycle() {
        // A coordinate change invalidates the two-structure comparison: the
        // source atom ordering shifted. The edit path renders later, so
        // suppress the invalidation render to avoid a double draw.
        invalidateComparisonRequest(render: false)
        // Structure summary reflects the new geometry.
        state.structureSummary = StructureSummary(scene, symmetry: scene.crystalSymmetry)
        // The k-path sidebar mirror must agree with the scene's route (which
        // may have been regenerated). Replace atomically without triggering
        // onChange -> syncFromState, which would push stale state back.
        state.replaceKPath(points: scene.kPathPoints, breaks: scene.kPathBreaks,
                           provenance: scene.kPathProvenance, signature: scene.kPathSignature)
        // Cancel in-flight coordination/distribution work and restart for the
        // new atom ordering.
        coordinationGeometryDidChange()
        // Refresh the atom table (unless a cell edit is in progress).
        refreshAtomTable()
        // Render the updated scene.
        setNeedsRender()
    }

    /// Sync the atom table's editing-enabled flag and tooltip with the current
    /// geometry. Editing is only safe on pristine (unexpanded, unslabbed) geometry.
    internal func syncAtomTableEditingState() {
        let pristine = scene.superCell.total <= 1 && scene.slab == nil
        let withinEditCap = scene.atoms.count <= Self.coordinateUndoMaxAtoms
        let enabled = pristine && withinEditCap
        let reason: String?
        if scene.slab != nil {
            reason = "Editing disabled: slab active. Remove the slab to edit coordinates."
        } else if scene.superCell.total > 1 {
            reason = "Editing disabled: supercell active. Reset to 1×1×1 to edit coordinates."
        } else if !withinEditCap {
            reason = "Editing disabled: structure has \(scene.atoms.count) atoms "
                + "(editable cap \(Self.coordinateUndoMaxAtoms))."
        } else {
            reason = nil
        }
        atomTable.isEditingEnabled = enabled
        atomTable.editingDisabledReason = reason
        atomTable.tableView.toolTip = reason
        atomTable.tableView.setAccessibilityHelp(reason)
    }

    /// Apply a structure-edit engine result transactionally: capture the pre-edit
    /// scene, install the new scene, register one undo group, and run the shared
    /// invalidation lifecycle. Returns false (with status text) on failure.
    @discardableResult
    private func applyEditResult(_ result: Result<Scene, StructureEditError>,
                                 actionName: String, status: (String) -> Void) -> Bool {
        switch result {
        case .failure(let error):
            status(error.description)
            return false
        case .success(let newScene):
            if scene.atoms.count > Self.coordinateUndoMaxAtoms {
                status("Editing disabled: structure has \(scene.atoms.count) atoms (editable cap \(Self.coordinateUndoMaxAtoms)).")
                return false
            }
            let preEdit = scene
            scene = newScene
            pushEditUndo(preEdit, actionName: actionName)
            runCoordinateEditLifecycle()
            syncAtomTableEditingState()
            refreshAtomTable()
            return true
        }
    }

    /// Insert an atom at the given position (fractional when the scene is a crystal).
    @discardableResult
    func insertAtom(element: Int, position: SIMD3<Float>, fractional: Bool) -> Bool {
        applyEditResult(scene.insertingAtom(element: element, label: nil, position: position, fractional: fractional),
                        actionName: "Insert Atom") { [weak self] in self?.state.setStructureEditStatus($0) }
    }

    /// Remove the atoms at the current selection.
    @discardableResult
    func removeSelectedAtoms() -> Bool {
        let indices = scene.selectedAtoms
        let count = indices.count
        let ok = applyEditResult(scene.removingAtoms(at: indices),
                                 actionName: "Remove Atoms") { [weak self] in self?.state.setStructureEditStatus($0) }
        if ok { state.setStructureEditStatus("Removed \(count) atoms") }
        return ok
    }

    /// Substitute the species of the selected atoms.
    @discardableResult
    func substituteSelectedAtoms(element: Int) -> Bool {
        let indices = scene.selectedAtoms
        let count = indices.count
        let ok = applyEditResult(scene.substitutingAtoms(at: indices, element: element, label: nil),
                                 actionName: "Substitute Species") { [weak self] in self?.state.setStructureEditStatus($0) }
        if ok { state.setStructureEditStatus("Substituted \(count) atoms to \(ElementTable.symbol(element))") }
        return ok
    }

    /// Bulk-displace atoms by `delta` (Å, Cartesian). nil indices = all atoms.
    @discardableResult
    func displaceAtoms(indices: [Int]?, by delta: SIMD3<Float>) -> Bool {
        applyEditResult(scene.displacingAtoms(at: indices, by: delta),
                        actionName: "Displace Atoms") { [weak self] in self?.state.setStructureEditStatus($0) }
    }

    /// Edit the lattice parameters from the sidebar state. On success mirror the
    /// new cell parameters back into the lattice fields. A cell change alters the
    /// reciprocal basis, so user-edited k-paths are remapped through Cartesian
    /// reciprocal space (generated routes were already regenerated by the engine).
    @discardableResult
    func applyLatticeParameters() -> Bool {
        let preEdit = scene
        let ok = applyEditResult(
            scene.editingLattice(a: state.latticeA, b: state.latticeB, c: state.latticeC,
                                     alpha: state.latticeAlpha, beta: state.latticeBeta, gamma: state.latticeGamma),
            actionName: "Edit Lattice Parameters") { [weak self] in self?.state.setStructureEditStatus($0) }
        if ok {
            scene.transferKPathAcrossGeometryChange(from: preEdit)
            // Re-mirror the (possibly remapped) route into the sidebar.
            state.replaceKPath(points: scene.kPathPoints, breaks: scene.kPathBreaks,
                               provenance: scene.kPathProvenance, signature: scene.kPathSignature)
            if let params = scene.cellParameters {
                let saved = state.onChange
                state.onChange = nil
                state.latticeA = params.a
                state.latticeB = params.b
                state.latticeC = params.c
                state.latticeAlpha = params.alpha
                state.latticeBeta = params.beta
                state.latticeGamma = params.gamma
                state.onChange = saved
                state.refreshKPathMetrics(for: scene.cell)
            }
        }
        return ok
    }

    /// Prefill the lattice fields from the current cell (no-op when non-crystalline).
    func resetLatticeParameters() {
        guard let params = scene.cellParameters else { return }
        let saved = state.onChange
        state.onChange = nil
        state.latticeA = params.a
        state.latticeB = params.b
        state.latticeC = params.c
        state.latticeAlpha = params.alpha
        state.latticeBeta = params.beta
        state.latticeGamma = params.gamma
        state.onChange = saved
    }

    /// Insert an atom at the interstitial fractional/Cartesian position from state.
    @discardableResult
    func insertInterstitialFromState() -> Bool {
        let symbol = state.defectElementSymbol
        let element = ElementTable.atomicNumber(symbol)
        guard element != 0 else {
            state.setStructureEditStatus("Unknown element symbol \"\(symbol)\"")
            return false
        }
        let fractional = scene.isCrystal && scene.cell != nil
        let position = SIMD3(state.interstitialFracX, state.interstitialFracY, state.interstitialFracZ)
        return insertAtom(element: element, position: position, fractional: fractional)
    }

    /// Substitute the selected atoms to the element from state.
    @discardableResult
    func substituteSelectedFromState() -> Bool {
        let symbol = state.defectElementSymbol
        let element = ElementTable.atomicNumber(symbol)
        guard element != 0 else {
            state.setStructureEditStatus("Unknown element symbol \"\(symbol)\"")
            return false
        }
        return substituteSelectedAtoms(element: element)
    }

    /// Displace atoms from the sidebar delta/selection state.
    @discardableResult
    func displaceFromState() -> Bool {
        let delta = SIMD3(state.displaceDeltaX, state.displaceDeltaY, state.displaceDeltaZ)
        let indices = state.displaceAllAtoms ? nil : scene.selectedAtoms
        return displaceAtoms(indices: indices, by: delta)
    }

    /// Serialize the current scene to the given export format (used by tests).
    func structureExportText(_ format: StructureExportFormat) throws -> String {
        try StructureWriter.write(scene, as: format)
    }

    /// Present a save panel and write the structure in the chosen format.
    func exportStructure(_ format: StructureExportFormat) {
        guard !scene.atoms.isEmpty || format == .crystalNew else {
            state.setStructureEditStatus("No atoms to export.")
            return
        }
        let panel = NSSavePanel()
        let base = scene.title.isEmpty ? "structure" : scene.title
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.exportStructure(format, to: url)
        }
    }

    /// Write the structure in `format` directly to `url` (used by the File menu).
    func exportStructure(_ format: StructureExportFormat, to url: URL) {
        do {
            try App.validateGUIWriteDestination(url, source: sourceURL)
            let text = try structureExportText(format)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Structure Export Failed"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - XCrySDen script (.tcl) save / load

    /// Mirror the live scene into the XCrySDen dialect's view-state projection.
    /// The mapping is a documented simplification (see XcryViewState): azimuth
    /// and elevation come from the camera-relative light direction, zoom from
    /// the camera distance (20 Å at zoom 1), background colors from whichever
    /// of the solid/gradient channels are active, cell/bonds from the display
    /// toggles, and atomScale from the atom scale.
    private func currentXcrysdenViewState() -> XcrysdenViewState {
        XcrysdenViewState(
            azimuth: state.lighting.azimuth,
            elevation: state.lighting.elevation,
            zoom: camera.distance > 0 ? 20 / camera.distance : 1,
            backgroundTopHex: state.backgroundHex,
            backgroundBottomHex: state.backgroundBottomHex,
            showCell: state.showCellFrame,
            showBonds: state.showStructure,
            atomScale: state.atomScale)
    }

    /// Apply an XCrySDen-dialect view state to the side bar + camera. Exact
    /// inverse of `currentXcrysdenViewState()`. Assignments go through @Published
    /// state (whose onChange mirrors into the scene), so the camera distance is
    /// the only field set directly.
    private func apply(_ view: XcrysdenViewState) {
        state.lighting.azimuth = view.azimuth
        state.lighting.elevation = view.elevation
        state.backgroundHex = view.backgroundTopHex
        state.backgroundBottomHex = view.backgroundBottomHex
        state.showCellFrame = view.showCell
        state.showStructure = view.showBonds
        state.atomScale = view.atomScale
        camera.distance = view.zoom > 0 ? 20 / view.zoom : 20
        scene.camera = camera
        setNeedsRender()
    }

    /// File > Save XCrySDen Script…: present a save panel and write the current
    /// view state as an XCrySDen-dialect .tcl script.
    @objc func saveXcrysdenScript(_ sender: Any?) {
        let panel = NSSavePanel()
        let base = scene.title.isEmpty ? "view" : scene.title
        panel.nameFieldStringValue = "\(base).tcl"
        panel.allowedContentTypes = [UTType(filenameExtension: "tcl") ?? .plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try XcrysdenScript.save(self.currentXcrysdenViewState())
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Script Save Failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: self.window)
            }
        }
    }

    /// Open an XCrySDK-dialect .tcl view script and apply it. Skipped lines are
    /// reported to the console but never fail the open.
    func loadXcrydenScript(_ url: URL) {
        do {
            let text = try readCappedText(url, cap: 16 * 1024 * 1024)
            guard let (state, skipped) = XcrysdenScript.load(text, base: currentXcrysdenViewState()) else {
                throw ParseError.parse(path: url.path, line: 0, reason: "no mapped XCrySDen script commands")
            }
            apply(state)
            if !skipped.isEmpty {
                let max = 5
                let summary = skipped.prefix(max)
                    .map { "line \($0.line): \($0.text)" }
                    .joined(separator: "; ")
                let tail = skipped.count > max ? "; +\(skipped.count - max) more" : ""
                print("[mcrysden] xcrysden script: skipped \(skipped.count) unmapped line(s): \(summary)\(tail)")
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Script Load Failed"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }

    /// Lazily create (once) and show the auxiliary neighbor-table panel.
    func showNeighborTable() {
        if neighborTableWindow == nil {
            let win = NSWindow(contentRect: neighborTable.frame,
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            win.title = "Neighbor Table"
            win.isReleasedWhenClosed = false
            win.contentView = neighborTable
            neighborTableWindow = win
        }
        neighborTableWindow?.makeKeyAndOrderFront(nil)
        updateNeighborTable()
    }

    /// Push the current coordination analysis into the neighbor table. O(n)
    /// over the flat neighbor list, so only call on coordination changes.
    private func updateNeighborTable() {
        guard let window = neighborTableWindow, window.isVisible,
              let analysis = coordinationAnalysis else { return }
        neighborTable.update(analysis: analysis, atoms: scene.atoms)
    }

    /// Lazily create (once) and show the auxiliary polyhedron-metrics panel.
    func showPolyhedronTable() {
        if polyhedronTableWindow == nil {
            let win = NSWindow(contentRect: polyhedronTable.frame,
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            win.title = "Polyhedron Metrics"
            win.isReleasedWhenClosed = false
            win.contentView = polyhedronTable
            polyhedronTableWindow = win
        }
        polyhedronTableWindow?.makeKeyAndOrderFront(nil)
        updatePolyhedronTable()
    }

    /// Push the current polyhedron metrics into the panel. Safe to call when
    /// the panel is hidden or the analysis is absent (both are no-ops).
    private func updatePolyhedronTable() {
        guard let window = polyhedronTableWindow, window.isVisible else { return }
        polyhedronTable.update(atoms: scene.atoms, metrics: polyhedronMetrics)
    }

    /// Present an open panel to choose a reference structure, then load it and
    /// compare it against the currently displayed atoms off the main thread.
    /// The synchronous `loadComparisonReference(from:)` seam is preserved for
    /// tests and programmatic use sites.
    func chooseComparisonReference() {
        let panel = NSOpenPanel()
        panel.title = "Choose Reference Structure"
        panel.message = "Compare the displayed structure against a reference file."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let contentTypes = App.openPanelExtensions.compactMap { UTType(filenameExtension: $0) }
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            self.startComparison(from: url)
        }
    }

    /// Parse + compare off the main thread with generation/cancellation
    /// guarding. A stale completion after a clear / new request / window close
    /// / geometry change never installs. Uses `LoadedScene.atoms` directly —
    /// no `Scene` or symmetry analysis is constructed for the reference.
    ///
    /// All mutable controller state (generation, token identity) is captured
    /// as local lets BEFORE the background block, and the main-thread
    /// completion checks only against those captures — never reading
    /// mutable state off-main.
    private func startComparison(from url: URL) {
        // Cancel any prior work and clear stale arrows/result before showing
        // the Calculating state. Suppress the geometry-path render (a fresh
        // result will render on install), but request ONE immediate render so
        // the previously drawn arrows/readouts are erased right away instead
        // of persisting on screen for the duration of the parse/compare.
        invalidateComparisonRequest(render: false)
        comparisonGeneration += 1
        let generation = comparisonGeneration
        let token = CoordinationCancellationToken()
        comparisonCancellationToken = token
        state.comparisonCalculating = true
        state.comparisonStatusText = "Calculating…"
        setNeedsRender()

        let sourceAtoms = scene.atoms
        // Use the effective widened coordination cell so a supercell
        // expansion matches against the displayed periodic images rather than
        // the base cell.
        let sourceCell = effectiveCoordinationCell(for: scene)
        let periodicDim = scene.periodicDim
        let title = url.lastPathComponent

        let work = DispatchWorkItem {
            // Background work reads ONLY captured locals — never self or
            // mutable instance state. No strong reference to the controller.
            guard !token.isCancelled() else { return }
            do {
                let loaded = try Parser.load(url)
                let targetAtoms = loaded.atoms
                guard !targetAtoms.isEmpty else {
                    throw ParseError.parse(path: url.path, line: 0,
                                           reason: "reference file contains no atoms")
                }
                guard let result = StructureComparator.compare(
                    source: sourceAtoms, target: targetAtoms,
                    sourceCell: sourceCell, periodicDim: periodicDim,
                    isCancelled: { token.isCancelled() }) else {
                    throw ParseError.parse(path: url.path, line: 0,
                                           reason: "comparison failed: invalid geometry or limits exceeded")
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard !token.isCancelled(),
                          self.comparisonGeneration == generation else { return }
                    self.installComparison(result, referenceTitle: title)
                    self.state.comparisonCalculating = false
                    self.comparisonCancellationToken = nil
                    self.comparisonWorkItem = nil
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard !token.isCancelled(),
                          self.comparisonGeneration == generation else { return }
                    self.state.comparisonCalculating = false
                    self.comparisonCancellationToken = nil
                    self.comparisonWorkItem = nil
                    self.state.comparisonStatusText = ""
                    self.presentComparisonError(error, url: url)
                }
            }
        }
        comparisonWorkItem = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Cancel any in-flight async comparison and bump the generation so its
    /// stale completion cannot install. Cancellation-only: does not touch
    /// published UI state or the installed result. Used only from `deinit`;
    /// the synchronous load seam now uses `invalidateComparisonRequest`.
    private func cancelComparisonRequestOnly() {
        comparisonGeneration += 1
        comparisonCancellationToken?.cancel()
        comparisonCancellationToken = nil
        comparisonWorkItem?.cancel()
        comparisonWorkItem = nil
    }

    /// Synchronous seam: load a reference structure from `url`, compare it
    /// against the currently displayed atoms, and install the result. Uses
    /// `LoadedScene.atoms` directly (no `Scene`/symmetry construction) and
    /// the effective widened coordination cell so supercell expansions match
    /// against the displayed periodic images. Preserved for tests and
    /// programmatic use sites; the open-panel user path goes through
    /// `startComparison` (async).
    ///
    /// Supersedes any in-flight async request: the full render-suppressed
    /// invalidation clears comparisonCalculating, status text, arrows, and
    /// the panel placeholder before parsing, so a superseded async request
    /// cannot leave the UI in a disabled Calculating state or overwrite this
    /// synchronous result.
    func loadComparisonReference(from url: URL) throws {
        invalidateComparisonRequest(render: false)
        let loaded = try Parser.load(url)
        let targetAtoms = loaded.atoms
        guard !targetAtoms.isEmpty else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "reference file contains no atoms")
        }
        let result = StructureComparator.compare(
            source: scene.atoms, target: targetAtoms,
            sourceCell: effectiveCoordinationCell(for: scene),
            periodicDim: scene.periodicDim)
        guard let result else {
            throw ParseError.parse(path: url.path, line: 0,
                                   reason: "comparison failed: invalid geometry or limits exceeded")
        }
        installComparison(result, referenceTitle: url.lastPathComponent)
    }

    /// Install a completed comparison: update the sidebar readout, the panel,
    /// the displacement arrows, and request a render.
    private func installComparison(_ result: StructureComparisonResult,
                                   referenceTitle: String) {
        comparisonResult = result
        comparisonReferenceTitle = referenceTitle
        var lines: [String] = []
        lines.append("Reference: \(referenceTitle)")
        if let rms = result.rmsDisplacement {
            lines.append(String(format: "RMSD: %.4f Å", rms))
        } else {
            lines.append("RMSD: —")
        }
        lines.append("Matched \(result.matchedPairCount) / \(scene.atoms.count) atoms")
        state.comparisonStatusText = lines.joined(separator: "\n")
        if comparisonWindow == nil {
            let win = NSWindow(contentRect: comparisonPanel.frame,
                               styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "Structure Comparison"
            win.isReleasedWhenClosed = false
            win.contentView = comparisonPanel
            comparisonWindow = win
        }
        comparisonPanel.onChooseReference = { [weak self] in self?.chooseComparisonReference() }
        comparisonPanel.update(referenceTitle: referenceTitle, result: result)
        comparisonWindow?.makeKeyAndOrderFront(nil)
        updateDisplacementArrows()
        setNeedsRender()
    }

    /// Test seam: install a comparison result without presenting panels or
    /// open panels. Mirrors the production installation path (readouts,
    /// panel content, arrows, render request).
    internal func installComparisonForTesting(_ result: StructureComparisonResult,
                                              referenceTitle: String) {
        comparisonResult = result
        comparisonReferenceTitle = referenceTitle
        var lines: [String] = []
        lines.append("Reference: \(referenceTitle)")
        if let rms = result.rmsDisplacement {
            lines.append(String(format: "RMSD: %.4f Å", rms))
        } else {
            lines.append("RMSD: —")
        }
        lines.append("Matched \(result.matchedPairCount) / \(scene.atoms.count) atoms")
        state.comparisonStatusText = lines.joined(separator: "\n")
        comparisonPanel.update(referenceTitle: referenceTitle, result: result)
        updateDisplacementArrows()
        setNeedsRender()
    }

    /// User Clear action: cancel any in-flight comparison immediately, drop
    /// the installed result/arrows/readouts, and render once. Always enabled
    /// (including while `comparisonCalculating`) so the user can abort a
    /// long-running compare.
    func clearComparison() {
        invalidateComparisonRequest(render: true)
    }

    /// Rebuild the renderer's displacement arrows from the active comparison
    /// and the current scene atom positions. Indices that no longer exist (e.g.
    /// after a frame reload) are dropped. Called on every render so a changed
    /// atom ordering cannot leave stale arrows.
    private func updateDisplacementArrows() {
        guard let result = comparisonResult else {
            renderer?.displacementArrows = []
            return
        }
        let atoms = scene.atoms
        renderer?.displacementArrows = result.matches.compactMap { match in
            guard match.sourceIndex >= 0, match.sourceIndex < atoms.count else { return nil }
            let start = atoms[match.sourceIndex].coord
            guard start.isFinite, match.displacement.isFinite else { return nil }
            return (start: start, vector: match.displacement)
        }
    }

    /// Pure helper that builds the comparison CSV text. Never interpolates
    /// user-controlled labels/titles into a String(format:) format string —
    /// every user field is escaped via csvEscape and concatenated. `sourceAtoms`
    /// is the snapshot captured BEFORE the save-panel completion so a concurrent
    /// geometry change cannot reorder atoms under us mid-write.
    static func comparisonCSV(for result: StructureComparisonResult,
                              referenceTitle: String?,
                              sourceAtoms: [Atom]) -> String {
        var lines: [String] = []
        // Sanitize the reference title for the comment line: collapse line
        // breaks so a malicious title cannot inject CSV header/row lines.
        let sanitizedTitle = (referenceTitle ?? "").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if !sanitizedTitle.isEmpty {
            lines.append("# Reference: " + sanitizedTitle)
        }
        if let rms = result.rmsDisplacement {
            lines.append(String(format: "# RMSD: %.4f Å", rms))
        }
        lines.append(String(format: "# Cutoff: %.4f Å; matched: %d",
                            result.maxMatchDistance, result.matchedPairCount))
        lines.append("source_index,target_index,element,label,dx,dy,dz,distance_angstrom")
        for match in result.matches {
            guard match.sourceIndex >= 0, match.sourceIndex < sourceAtoms.count else { continue }
            let atom = sourceAtoms[match.sourceIndex]
            let symbol = csvEscape(ElementTable.symbol(atom.atomicNumber))
            let label = csvEscape(atom.label)
            lines.append(String(format: "%d,%d,", match.sourceIndex + 1, match.targetIndex + 1)
                            + symbol + "," + label + ","
                            + String(format: "%.6f,%.6f,%.6f,%.6f",
                                     match.displacement.x, match.displacement.y,
                                     match.displacement.z, match.distance))
        }
        lines.append("# Unmatched source atoms: "
            + result.unmatchedSourceIndices.map { String($0 + 1) }.joined(separator: ","))
        lines.append("# Unmatched reference atoms: "
            + result.unmatchedTargetIndices.map { String($0 + 1) }.joined(separator: ","))
        return lines.joined(separator: "\n")
    }

    /// RFC 4180 field escaping: wrap in double quotes and double any embedded
    /// quotes when the field contains a comma, quote, or newline. Empty
    /// fields are emitted as two consecutive delimiters (bare empty).
    static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Present a save panel and write the comparison as CSV. Snapshots the
    /// source atoms before the panel completes so a concurrent geometry change
    /// cannot reorder atoms under us. Surfaces write errors to the user.
    func exportComparisonCSV() {
        guard let result = comparisonResult else { return }
        // Snapshot before the modal so the completion closure sees a
        // consistent atom ordering even if the scene changes while the panel
        // is open.
        let sourceAtoms = scene.atoms
        let referenceTitle = comparisonReferenceTitle
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "comparison.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let text = Self.comparisonCSV(for: result, referenceTitle: referenceTitle,
                                          sourceAtoms: sourceAtoms)
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                print("[mcrysden] comparison CSV export failed: \(error)")
                self.presentExportWriteError(error, kind: "Comparison")
            }
        }
    }

    /// Present a generic file-write failure as an alert sheet on the main window.
    private func presentExportWriteError(_ error: Error, kind: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(kind) Export Failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Present the comparison load failure as an alert sheet on the main window.
    private func presentComparisonError(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Comparison Failed"
        alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    /// File > Print… — render the currently visible layer (Metal scene or graph)
    /// through PrintSupport and run a print operation sheet on the main window.
    @objc func printDocument(_ sender: Any?) {
        // All AppKit work (panel, image views) must happen on the main thread.
        guard Thread.isMainThread else {
            print("[mcrysden] printDocument called off main thread — ignoring.")
            return
        }
        let printInfo = NSPrintInfo.shared
        let pageRect = PrintSupport.pageRect(for: printInfo)
        // Print renders at scale (px/pt) — compute pixel dimensions first so the
        // label projection viewport matches the render target exactly.
        // renderMetalScene asserts pixelViewport == pixel dimensions in debug.
        let pixelDimensions = try? PrintSupport.pixelDimensions(for: pageRect)
        let pixelViewport = SIMD2<Float>(Float(pixelDimensions?.width ?? Int(pageRect.width)),
                                         Float(pixelDimensions?.height ?? Int(pageRect.height)))
        let nsImage: NSImage
        do {
            // Graph branches guard on the payload so an empty/hidden graph view
            // does not supersede the Metal canvas. When the linked container is
            // visible, print it so both panels (or the single present one) render.
            if !bandSurfaceView.isHidden, let surface = scene.bandSurface {
                let printView = BandSurfaceView(frame: NSRect(origin: .zero, size: pageRect.size))
                printView.bandSurface = surface
                printView.azimuthDegrees = bandSurfaceView.azimuthDegrees
                printView.elevationDegrees = bandSurfaceView.elevationDegrees
                printView.exportBackground = .white
                nsImage = try PrintSupport.renderGraph(printView, pageRect: pageRect)
            } else if !linkedGraphs.isHidden {
                let printView = LinkedGraphsView(
                    frame: NSRect(origin: .zero, size: pageRect.size),
                    bandView: BandGrapherView(frame: .zero),
                    dosView: DOSGrapherView(frame: .zero),
                    band: scene.bandStructure, dos: scene.densityOfStates,
                    bandPresent: linkedGraphs.bandPresent, dosPresent: linkedGraphs.dosPresent)
                printView.exportBackground = .white
                nsImage = try PrintSupport.renderGraph(printView, pageRect: pageRect)
            } else {
                // Project labels for the PIXEL viewport (not points) so they land
                // at the correct position in the print-resolution image.
                let labels = persistentLabels(viewport: pixelViewport, camera: renderCamera())
                nsImage = try PrintSupport.renderMetalScene(scene: scene, camera: renderCamera(),
                                                            labels: labels, pixelViewport: pixelViewport,
                                                            pageRect: pageRect)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Print Failed"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return
        }
        let view = NSImageView(frame: NSRect(origin: .zero, size: pageRect.size))
        view.image = nsImage
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Present a save panel and write the distribution analysis as CSV.
    /// The RDF CSV emits actual g(r) values, not raw counts.
    private func exportDistributionCSV(_ dist: DistributionAnalysis) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "distribution.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            var lines: [String] = []
            lines.append("# Bond-length distribution (\(dist.uniquePairCount) unique pairs)")
            lines.append(dist.bondLengthHistogram.csv())
            lines.append("")
            lines.append("# Bond-angle distribution (\(dist.uniqueAngleCount) unique angles)")
            lines.append(dist.bondAngleHistogram.csv())
            lines.append("")
            lines.append("# Radial distribution function")
            if dist.radialDistribution.isAvailable {
                lines.append("# maxRadius: \(dist.radialDistribution.maxRadius) Å" + (dist.radialDistribution.wasCapped ? " (capped)" : ""))
            }
            lines.append(dist.radialDistribution.csv())
            let text = lines.joined(separator: "\n")
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { print("[mcrysden] distribution CSV export failed: \(error)") }
        }
    }

    private func updateCoordinationTable() {
        guard let window = atomTableWindow, window.isVisible else { return }
        coordinationTableUpdateCount += 1
        atomTable.updateCoordinationNumbers(installedCoordinationNumbers.isEmpty
                                            ? nil : installedCoordinationNumbers)
    }

    /// Push complete CN data only when analysis data is installed or cleared.
    private func installCoordinationNumbers(_ numbers: [Int]) {
        installedCoordinationNumbers = numbers
        renderer?.coordinationNumbers = numbers
        renderer2D?.coordinationNumbers = numbers
        coordinationRendererUpdateCount += 1
        updateCoordinationTable()
        applyCoordinationColors()
    }

    private func clearCoordinationNumbers() {
        installedCoordinationNumbers = []
        renderer?.coordinationNumbers = []
        renderer2D?.coordinationNumbers = []
        coordinationRendererUpdateCount += 1
        updateCoordinationTable()
        applyCoordinationColors()
    }

    /// Color is a renderer toggle, not an analysis input. Changing it must not
    /// copy or derive the CN array again.
    private func applyCoordinationColors() {
        let enabled = !installedCoordinationNumbers.isEmpty && state.showCoordinationColors
        renderer?.showCoordinationColors = enabled
        renderer2D?.showCoordinationColors = enabled
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
            renderer2D?.selectedKPathNode = selectedRouteNodeIndex
            if let color = renderer?.background { renderer2D?.background = color }
        } else {
            canvas.delegate = renderer
            renderer2D?.scene = scene
            renderer?.selectedKPathNode = selectedRouteNodeIndex
        }
        let is2D = scene.displayMode.is2D
        if lastCoordinationDelegateIs2D != is2D {
            if is2D {
                renderer2D?.coordinationNumbers = installedCoordinationNumbers
                renderer2D?.showCoordinationColors = !installedCoordinationNumbers.isEmpty
                    && state.showCoordinationColors
            }
            lastCoordinationDelegateIs2D = is2D
        }
        // Comparison arrows are runtime-only renderer state; keep the delegate's
        // toggle in step with the sidebar on every delegate refresh.
        renderer?.showDisplacementArrows = state.showComparisonArrows
        installEditorBZCache()
    }

    func setNeedsRender() {
        renderRequestCount += 1
        renderer?.currentCamera = camera
        renderer2D?.currentCamera = camera
        refreshDelegate()
        // Displacement arrows follow the displayed atom ordering (a frame
        // reload may change indices); rebuild them on every render request.
        updateDisplacementArrows()
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
        cancelCoordinationRequest()
        cancelPolyhedronRequest()
        invalidateComparisonRequest(render: false)
        coordinationGeneration += 1
        distributionGeneration += 1
        state.isPlaying = false
        infoWindow.orderOut(nil)
    }

    // MARK: - World protocol

    var isReciprocalPathEditing: Bool {
        state.editKPathOnBZ && scene.isCrystal
    }

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

    func reciprocalViewportSizeDidChange(_ viewport: SIMD2<Float>) {
        guard validReciprocalViewport(viewport) else {
            return
        }
        guard isReciprocalPathEditing else {
            setNeedsRender()
            return
        }
        // A resize can briefly produce an aspect ratio that cannot fit inside the
        // fixed depth range. Keep the established editor camera and defer the fit;
        // entry/projection failures still use their rejecting paths below.
        clearReciprocalHover()
        canvas.invalidateReciprocalAccessibilityFocus()
        _ = frameReciprocalEditor(viewport: viewport)
        setNeedsRender()
    }

    /// Project one BZ candidate exactly as the mouse picker does. Accessibility
    /// and keyboard descriptors use this seam so offscreen, clipped, or behind
    /// landmarks cannot become actions that are not actually visible.
    static func projectVisibleBZCandidate(
        _ candidate: BZCandidate,
        presentation: BZPresentation,
        camera: Camera,
        viewport: SIMD2<Float>
    ) -> (point: SIMD2<Float>, depth: Float, screenRadius: Float)? {
        guard viewport.x > 0, viewport.y > 0,
              viewport.x.isFinite, viewport.y.isFinite,
              (try? Camera.validated(camera)) != nil,
              candidate.point.frac.x.isFinite,
              candidate.point.frac.y.isFinite,
              candidate.point.frac.z.isFinite,
              candidate.cartesian.x.isFinite,
              candidate.cartesian.y.isFinite,
              candidate.cartesian.z.isFinite else { return nil }
        let aspect = viewport.x / viewport.y
        guard aspect.isFinite, aspect > 0 else { return nil }
        let view = camera.viewMatrix()
        let projection = camera.projectionMatrix(aspect: aspect)
        func project(_ world: SIMD3<Float>, requireVisible: Bool) -> (point: SIMD2<Float>, depth: Float)? {
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
            let viewPosition = view * SIMD4<Float>(world.x, world.y, world.z, 1)
            let depth = -viewPosition.z
            guard depth > 0.01, depth.isFinite else { return nil }
            let clip = projection * viewPosition
            guard clip.x.isFinite, clip.y.isFinite, clip.z.isFinite, clip.w.isFinite,
                  clip.w > 1e-10 else { return nil }
            let ndc = clip / clip.w
            guard ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite else { return nil }
            if requireVisible {
                guard ndc.x >= -1, ndc.x <= 1,
                      ndc.y >= -1, ndc.y <= 1,
                      ndc.z >= 0, ndc.z <= 1 else { return nil }
            }
            let point = SIMD2<Float>((ndc.x * 0.5 + 0.5) * viewport.x,
                                     (1 - (ndc.y * 0.5 + 0.5)) * viewport.y)
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return (point, depth)
        }

        let world = presentation.world(cartesian: candidate.cartesian)
        guard let projectedCenter = project(world, requireVisible: true) else { return nil }
        let half = presentation.landmarkHalfExtent
        guard half.isFinite, half > 0 else { return nil }

        // Use the exact six endpoints emitted by Renderer.crossLineSegments. A
        // clipped endpoint contributes no unbounded radius; the final cap keeps
        // malformed perspective geometry from turning the whole canvas clickable.
        var maximumRadius: Float = 0
        for endpoint in Renderer.crossLineSegments(world, half: half) {
            guard let projectedEndpoint = project(endpoint, requireVisible: false) else { continue }
            let delta = projectedEndpoint.point - projectedCenter.point
            let radius = sqrt(delta.x * delta.x + delta.y * delta.y)
            guard radius.isFinite else { continue }
            maximumRadius = max(maximumRadius, radius)
        }
        let minimumRadius = BZPresentation.landmarkPickMinimumRadius
        let viewportRadius = max(viewport.x, viewport.y)
        let safeCap = max(minimumRadius,
                          min(BZPresentation.landmarkScreenRadiusCap, viewportRadius))
        let screenRadius = min(safeCap, max(minimumRadius, maximumRadius))
        guard screenRadius.isFinite, screenRadius > 0 else { return nil }
        return (projectedCenter.point, projectedCenter.depth, screenRadius)
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
        radiusPx: Float? = nil
    ) -> BZCandidate? {
        // Validate the query before doing any work: a positive finite radius, a positive
        // finite viewport, and a finite click that actually falls inside the viewport.
        if let radiusPx {
            guard radiusPx > 0, radiusPx.isFinite else { return nil }
        }
        guard viewport.x > 0, viewport.y > 0,
              viewport.x.isFinite, viewport.y.isFinite,
              click.x.isFinite, click.y.isFinite,
              click.x >= 0, click.x <= viewport.x,
              click.y >= 0, click.y <= viewport.y else { return nil }
        var best: BZCandidate?
        var bestDist = Float.infinity        // best screen-space distance squared
        var bestDepth = Float.infinity       // tie-break: nearest (smallest view -z)
        for cand in candidates {
            guard let projected = projectVisibleBZCandidate(cand, presentation: presentation,
                                                             camera: camera, viewport: viewport) else { continue }
            let hitRadius = radiusPx ?? projected.screenRadius
            guard hitRadius.isFinite, hitRadius > 0 else { continue }
            let radiusSq = hitRadius * hitRadius
            guard radiusSq.isFinite else { continue }
            let dx = projected.point.x - click.x, dy = projected.point.y - click.y
            let dist = dx * dx + dy * dy
            guard dist <= radiusSq else { continue }
            // Closer on screen wins; an actual/near screen-distance tie goes to depth.
            if dist < bestDist - 1e-3 || (dist <= bestDist + 1e-3 && projected.depth < bestDepth) {
                bestDist = dist; bestDepth = projected.depth; best = cand
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
        installEditorBZCache()
        guard let bz = bzEditCache.bz else { return (bzEditCache.candidates, nil) }
        return (bzEditCache.candidates, BZPresentation(bz: bz, scene: scene))
    }

    /// Keep both live renderer implementations on the same controller-built
    /// positive or negative BZ cache. Standalone renderers still build lazily.
    private func installEditorBZCache() {
        guard bzEditCache.epoch == bzEpoch else { return }
        renderer?.installBrillouinZoneCache(bz: bzEditCache.bz,
                                            candidates: bzEditCache.candidates)
        renderer2D?.installBrillouinZoneCache(bz: bzEditCache.bz,
                                              candidates: bzEditCache.candidates)
    }

    static let maximumReciprocalAccessibilityChildren = 4096

    static func reciprocalCandidateTypeName(_ type: BZPointType) -> String {
        switch type {
        case .center: return "Gamma point"
        case .edge: return "BZ vertex"
        case .line: return "BZ edge midpoint"
        case .polyface: return "BZ face center"
        }
    }

    private static func reciprocalFractionDescription(_ frac: SIMD3<Float>) -> String {
        String(format: "(%.4f, %.4f, %.4f)", frac.x, frac.y, frac.z)
    }

    /// Return only the landmarks that are actually drawable in the current
    /// editor viewport. The BZ and candidate array come from editorLandmarks(),
    /// so AX queries and keyboard cycling never rebuild the BZ.
    func reciprocalAccessibilityDescriptors(viewport: SIMD2<Float>)
        -> [ReciprocalAccessibilityDescriptor] {
        guard isReciprocalPathEditing,
              !canvas.isHidden,
              validReciprocalViewport(viewport) else { return [] }
        let (candidates, presentation) = editorLandmarks()
        guard let presentation, validBZPresentation(presentation) else { return [] }
        let camera = renderCamera()
        var descriptors: [ReciprocalAccessibilityDescriptor] = []
        descriptors.reserveCapacity(min(candidates.count, Self.maximumReciprocalAccessibilityChildren))
        for candidate in candidates.prefix(Self.maximumReciprocalAccessibilityChildren) {
            guard let projected = Self.projectVisibleBZCandidate(candidate,
                                                                   presentation: presentation,
                                                                   camera: camera,
                                                                   viewport: viewport) else { continue }
            let candidateLabel = candidate.point.label.isEmpty ? "Unnamed landmark" : candidate.point.label
            let type = Self.reciprocalCandidateTypeName(candidate.type)
            let coordinates = Self.reciprocalFractionDescription(candidate.point.frac)
            let summary = "\(candidateLabel), \(type), fractional coordinates \(coordinates)"
            descriptors.append(ReciprocalAccessibilityDescriptor(
                candidate: candidate,
                screenPoint: projected.point,
                screenRadius: projected.screenRadius,
                label: "Reciprocal landmark: \(summary)",
                value: summary,
                help: "Activate to append \(summary) to the k-path."))
        }
        return descriptors
    }

    func focusReciprocalAccessibilityCandidate(_ descriptor: ReciprocalAccessibilityDescriptor) {
        guard let current = reciprocalAccessibilityDescriptors(viewport: descriptorViewport())
            .first(where: { $0 == descriptor }) else {
            clearReciprocalHover()
            return
        }
        reciprocalHoverCandidate = current.candidate
        reciprocalHoverCursor = current.screenPoint
        updateTransientTooltip()
    }

    func activateReciprocalAccessibilityCandidate(_ descriptor: ReciprocalAccessibilityDescriptor) -> Bool {
        let current = reciprocalAccessibilityDescriptors(viewport: descriptorViewport())
            .first(where: { $0 == descriptor })
        guard let current else { return false }
        return appendReciprocalCandidate(current.candidate)
    }

    func clearReciprocalAccessibilityFocus() {
        clearReciprocalHover()
    }

    private func descriptorViewport() -> SIMD2<Float> {
        SIMD2<Float>(Float(canvas.bounds.width), Float(canvas.bounds.height))
    }

    @discardableResult
    private func appendReciprocalCandidate(_ candidate: BZCandidate) -> Bool {
        guard isReciprocalPathEditing,
              finite(candidate.point.frac) else { return false }
        state.append(candidate.point)
        // SideBarState.append owns duplicate suppression, cap enforcement,
        // undo, and provenance. Keep this scene mirror identical to mouse picks.
        scene.kPathPoints = state.kPathPoints
        setNeedsRender()
        return true
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
            _ = appendReciprocalCandidate(cand)
        } else {
            // Push the (possibly edited) route into the scene and re-render.
            scene.kPathPoints = state.kPathPoints
            setNeedsRender()
        }
        return true
    }

    /// Update only the overlay for reciprocal-space hover. Pointer movement must
    /// not enter the route editor or trigger a Metal redraw.
    func handleReciprocalPathHover(at point: SIMD2<Float>?, viewport: SIMD2<Float>) {
        guard state.editKPathOnBZ, scene.isCrystal else {
            clearReciprocalHover()
            return
        }
        guard let point,
              validReciprocalViewport(viewport),
              point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= viewport.x,
              point.y >= 0, point.y <= viewport.y else {
            clearReciprocalHover()
            return
        }
        let (candidates, presentation) = editorLandmarks()
        guard let presentation, validBZPresentation(presentation) else {
            clearReciprocalHover()
            return
        }
        let candidate = Self.pickBZCandidate(candidates: candidates,
                                             presentation: presentation,
                                             camera: renderCamera(),
                                             viewport: viewport,
                                             click: point)
        guard let candidate, finite(candidate.point.frac) else {
            clearReciprocalHover()
            return
        }
        reciprocalHoverCandidate = candidate
        reciprocalHoverCursor = point
        updateTransientTooltip()
    }

    /// Highlight the route node at `index` in the BZ viewport, linking the
    /// sidebar route list's selection to the rendered k-path overlay. Pass nil
    /// to clear. The renderer draws the selected node as a larger green cross;
    /// out-of-range indices are a safe no-op there. This is the hook the
    /// SidebarState/UI invokes on selection (it sets this from a callback).
    func selectKPathNode(_ index: Int?) {
        selectedRouteNodeIndex = index
        renderer?.selectedKPathNode = index
        renderer2D?.selectedKPathNode = index
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
        let reciprocalPresentationBefore = reciprocalPresentationSignature(for: scene)
        let oldSlab = scene.slab
        isSyncingState = true
        state.slabA_dist += delta
        isSyncingState = false
        let slab = Slab(planeA: Plane(h: state.slabA_h, k: state.slabA_k, l: state.slabA_l, distance: state.slabA_dist),
                        planeB: Plane(h: state.slabB_h, k: state.slabB_k, l: state.slabB_l, distance: state.slabB_dist))
        scene = scene.applySlab(slab)
        let slabChanged = scene.slab != oldSlab
        let reciprocalPresentationAfter = reciprocalPresentationSignature(for: scene)
        if slabChanged, reciprocalPresentationChanged(from: reciprocalPresentationBefore,
                                                       to: reciprocalPresentationAfter) {
            clearReciprocalHover()
            canvas.invalidateReciprocalAccessibilityFocus()
        }
        // A direct slab drag changes the displayed atom set, invalidating
        // any installed two-structure comparison. This path renders later, so
        // suppress the invalidation render.
        invalidateComparisonRequest(render: false)
        coordinationGeometryDidChange()
        refreshAtomTable()
        setNeedsRender()
    }

    /// Project atom and persistent reciprocal-route labels. Route labels are a
    /// separate layer: hiding atom labels must not hide a visible BZ route.
    func updateLabels() {
        if !state.editKPathOnBZ {
            reciprocalHoverCandidate = nil
            reciprocalHoverCursor = nil
        }

        guard let viewport = labelViewport(for: canvas.bounds.size) else {
            reciprocalHoverCandidate = nil
            reciprocalHoverCursor = nil
            canvas.invalidateReciprocalAccessibilityFocus()
            labelOverlay.labels = []
            return
        }
        let cam = renderCamera()
        guard (try? Camera.validated(cam)) != nil else {
            reciprocalHoverCandidate = nil
            reciprocalHoverCursor = nil
            canvas.invalidateReciprocalAccessibilityFocus()
            labelOverlay.labels = []
            return
        }

        var labels = persistentLabels(viewport: viewport, camera: cam)
        if let tooltip = reciprocalTooltipLabel() {
            labels.append(tooltip)
        }
        labelOverlay.labels = labels
    }

    /// Generate only persistent labels for an explicit render viewport. This is
    /// also used by export, where the live canvas may have a different aspect.
    private func persistentLabels(viewport: SIMD2<Float>, camera: Camera) -> [LabelOverlayView.Label] {
        guard validReciprocalViewport(viewport),
              (try? Camera.validated(camera)) != nil else { return [] }

        var labels: [LabelOverlayView.Label] = []
        if scene.showLabels {
            labels += scene.atoms.compactMap { atom in
                guard let projected = projectLabelPoint(atom.coord, camera: camera, viewport: viewport) else {
                    return nil
                }
                return LabelOverlayView.Label(symbol: ElementTable.symbol(atom.atomicNumber),
                                              x: projected.x - 10, y: projected.y - 12)
            }
        }

        // Live bond-distance labels: distance text above each projected bond
        // midpoint. Bounded and deterministic (bond order); follows the atom
        // label layer so hiding atom labels must not hide bond distances.
        if scene.showBondDistances {
            labels += Self.bondDistanceLabels(scene: scene, camera: camera, viewport: viewport)
        }

        // Scale indicators are viewport labels rather than scene geometry. Build
        // them from the same validated camera/viewport used for atom/route labels
        // so the live overlay and export projection stay identical. The canvas
        // visibility check deliberately suppresses this layer for graph views.
        if scene.showScaleIndicator, !canvas.isHidden,
           let indicator = ScaleIndicator.make(camera: camera, viewport: viewport) {
            let pixelWidth = CGFloat(indicator.pixelWidth)
            let text = indicator.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if indicator.lengthAngstrom.isFinite, indicator.lengthAngstrom > 0,
               pixelWidth.isFinite, pixelWidth > 0,
               !text.isEmpty {
                let raw = LabelOverlayView.Label(
                    symbol: text,
                    x: 0,
                    y: 0,
                    style: .scaleIndicator,
                    barWidth: pixelWidth,
                    usesLightForeground: scaleIndicatorUsesLightForeground())
                if let placed = positionedScaleIndicatorLabel(raw,
                                                               in: NSRect(x: 0, y: 0,
                                                                          width: CGFloat(viewport.x),
                                                                          height: CGFloat(viewport.y)),
                                                               avoidOrientationGizmo: scene.showAxes) {
                    labels.append(placed)
                }
            }
        }

        let routeVisible = !canvas.isHidden && scene.isCrystal && scene.showBrillouinZone
        if routeVisible, !scene.kPathPoints.isEmpty {
            synchronizeRouteLabelMeasurementCache()
            let (candidates, presentation) = editorLandmarks()
            guard let presentation, validBZPresentation(presentation) else { return labels }
            _ = candidates // The cache is intentionally shared with picking/framing.
            let selected = selectedRouteNodeIndex ?? renderer?.selectedKPathNode
            let labelBounds = NSRect(x: 0, y: 0, width: CGFloat(viewport.x), height: CGFloat(viewport.y))
            var projected: [(index: Int, label: LabelOverlayView.Label, rect: NSRect, selected: Bool, depth: Float)] = []
            for (index, point) in scene.kPathPoints.prefix(1024).enumerated() {
                guard finite(point.frac),
                      let proj = Self.projectRouteLabelPoint(presentation.world(frac: point.frac),
                                                             camera: camera, viewport: viewport) else {
                    continue
                }
                let isSelected = selected == index
                let style: LabelOverlayView.Label.Style = isSelected ? .selectedRouteNode : .routeNode
                let symbol = point.label.isEmpty ? "K\(index + 1)" : String(point.label.prefix(64))
                let rawLabel = LabelOverlayView.Label(symbol: symbol,
                                                      x: proj.point.x + 6, y: proj.point.y - 6,
                                                      style: style)
                let measuredSize = measuredRouteLabelSize(text: symbol, style: style)
                let label = Self.clampedRouteLabel(rawLabel, in: labelBounds, measuredSize: measuredSize)
                projected.append((index, label,
                                  LabelOverlayView.drawingRect(for: label, measuredSize: measuredSize),
                                  isSelected, proj.depth))
            }

            // Draw EVERY route label. No label is dropped for overlapping a
            // neighbour (that made labels vanish during rotation). Instead the
            // labels are layered by view depth so points nearer the camera draw
            // on top of farther ones, and the sidebar-selected node always draws
            // on top. This keeps the depth ordering consistent with the 3D view
            // while never hiding a label automatically.
            let ordered = projected.sorted { lhs, rhs in
                if lhs.selected != rhs.selected { return rhs.selected }
                return lhs.depth > rhs.depth
            }
            for item in ordered {
                labels.append(item.label)
            }
        }
        return labels
    }

    /// Generate bond-distance labels for the given scene/camera/viewport.
    /// Each displayed bond contributes one label at its projected midpoint,
    /// formatted with an explicit Å unit. Labels are translated to fit inside
    /// the viewport edges (skipped if they cannot fit). Bond labels are hidden
    /// when the structure itself is hidden so they do not float over an empty
    /// cell frame / axes. The total is bounded by `maxLabels`.
    static func bondDistanceLabels(scene: Scene, camera: Camera,
                                   viewport: SIMD2<Float>,
                                   maxLabels: Int = 200,
                                   maxInspectedBonds: Int = 10_000) -> [LabelOverlayView.Label] {
        guard maxLabels > 0 else { return [] }
        guard maxInspectedBonds > 0 else { return [] }
        guard scene.showStructure else { return [] }
        let atoms = scene.atoms
        guard !atoms.isEmpty, !scene.bonds.isEmpty else { return [] }
        guard viewport.x.isFinite, viewport.y.isFinite, viewport.x > 0, viewport.y > 0 else { return [] }

        var labels: [LabelOverlayView.Label] = []
        labels.reserveCapacity(min(scene.bonds.count, maxLabels))
        let bounds = NSRect(x: 0, y: 0, width: CGFloat(viewport.x), height: CGFloat(viewport.y))
        // scene.bonds.prefix is itself overflow-safe: it stops at the cap even
        // when every inspected bond is invalid or offscreen, so an ordinary
        // supercell (thousands of bonds) cannot spin in the inner loop.
        let inspectLimit = min(scene.bonds.count, maxInspectedBonds)
        for bond in scene.bonds.prefix(inspectLimit) {
            guard labels.count < maxLabels else { break }
            guard bond.i >= 0, bond.i < atoms.count,
                  bond.j >= 0, bond.j < atoms.count else { continue }
            guard let displacement = scene.directBondDisplacement(for: bond) else { continue }
            let a = atoms[bond.i].coord
            // Bond records with a zero image connect two explicitly displayed
            // atoms, so labels use their direct endpoint displacement. Periodic-
            // only records are omitted rather than floating over a hidden image.
            let distance = simd_length(displacement)
            guard distance.isFinite, distance > 1e-6 else { continue }
            let midpoint = a + displacement * 0.5
            guard let screen = projectPoint(midpoint, camera: camera, viewport: viewport) else {
                continue
            }
            let text = String(format: "%.2f Å", distance)
            let label = LabelOverlayView.Label(symbol: text,
                                               x: screen.x - 12, y: screen.y - 12,
                                               style: .bondDistance)
            let rect = LabelOverlayView.drawingRect(for: label)
            // Skip the label entirely if it cannot fit on screen.
            guard rect.width <= bounds.width, rect.height <= bounds.height else { continue }
            // Translate the complete drawing rect inside every viewport edge.
            // Clamp the rect's origin within bounds, then derive the label
            // origin from the clamped rect (label.x/y is the text origin,
            // which sits at rect.origin + padding).
            let clampedX = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
            let clampedY = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
            let dx = clampedX - rect.minX
            let dy = clampedY - rect.minY
            labels.append(LabelOverlayView.Label(symbol: text,
                                                 x: label.x + dx, y: label.y + dy,
                                                 style: .bondDistance))
        }
        return labels
    }

    /// Select a light or dark scale foreground from the color visible at the
    /// bottom of the active viewport. A gradient uses its bottom stop; a solid
    /// background uses the ordinary scene background.
    private func scaleIndicatorUsesLightForeground() -> Bool {
        let hex = scene.backgroundType == .gradient_top
            ? scene.backgroundBottom
            : scene.background
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            // The renderer's invalid-hex fallback is black, so prefer white.
            return true
        }
        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.5
    }

    /// Position a scale label at the bottom-left while keeping its complete
    /// text/bar/tick rectangle inside the viewport. The orientation gizmo's
    /// bottom-right footprint gets a small exclusion gap when axes are shown.
    private func positionedScaleIndicatorLabel(
        _ label: LabelOverlayView.Label,
        in bounds: NSRect,
        avoidOrientationGizmo: Bool
    ) -> LabelOverlayView.Label? {
        guard label.style == .scaleIndicator,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let margin: CGFloat = 12
        let rect = LabelOverlayView.drawingRect(for: label)
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              rect.width <= bounds.width - 2 * margin,
              rect.height <= bounds.height - 2 * margin else { return nil }

        var target = NSRect(x: bounds.minX + margin,
                            y: bounds.maxY - margin - rect.height,
                            width: rect.width,
                            height: rect.height)

        if avoidOrientationGizmo {
            let gizmoSize = max(72, min(bounds.width, bounds.height) * 0.16)
            let gizmoMargin: CGFloat = 14
            let gizmo = NSRect(x: bounds.maxX - gizmoSize - gizmoMargin,
                               y: bounds.maxY - gizmoSize - gizmoMargin,
                               width: gizmoSize,
                               height: gizmoSize)
            let gap: CGFloat = 8
            if target.insetBy(dx: -gap, dy: -gap).intersects(gizmo) {
                let liftedMinY = gizmo.minY - gap - rect.height
                guard liftedMinY >= bounds.minY + margin else { return nil }
                target.origin.y = liftedMinY
            }
        }

        guard target.minX >= bounds.minX,
              target.maxX <= bounds.maxX,
              target.minY >= bounds.minY,
              target.maxY <= bounds.maxY else { return nil }
        return LabelOverlayView.Label(
            symbol: label.symbol,
            x: label.x + target.minX - rect.minX,
            y: label.y + target.minY - rect.minY,
            style: label.style,
            barWidth: label.barWidth,
            usesLightForeground: label.usesLightForeground)
    }

    /// Shift a persistent route label's complete drawing rectangle into the
    /// viewport when it fits. The label origin remains node-relative unless a
    /// viewport edge requires a correction; oversized labels are anchored at
    /// the corresponding viewport edge rather than producing invalid geometry.
    static func clampedRouteLabel(_ label: LabelOverlayView.Label, in bounds: NSRect) -> LabelOverlayView.Label {
        clampedRouteLabel(label, in: bounds, measuredSize: LabelOverlayView.measuredSize(for: label))
    }

    private static func clampedRouteLabel(_ label: LabelOverlayView.Label, in bounds: NSRect,
                                          measuredSize: CGSize) -> LabelOverlayView.Label {
        guard label.style == .routeNode || label.style == .selectedRouteNode,
               !bounds.isEmpty else { return label }
        let rect = LabelOverlayView.drawingRect(for: label, measuredSize: measuredSize)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return label }

        let targetX: CGFloat
        if rect.width <= bounds.width {
            targetX = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        } else {
            targetX = bounds.minX
        }
        let targetY: CGFloat
        if rect.height <= bounds.height {
            targetY = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        } else {
            targetY = bounds.minY
        }
        return LabelOverlayView.Label(symbol: label.symbol,
                                      x: label.x + targetX - rect.minX,
                                      y: label.y + targetY - rect.minY,
                                      style: label.style,
                                      barWidth: label.barWidth,
                                      usesLightForeground: label.usesLightForeground)
    }

    private func measuredRouteLabelSize(text: String,
                                        style: LabelOverlayView.Label.Style) -> CGSize {
        let key = RouteLabelMeasurementKey(text: text, style: style)
        if let cached = routeLabelMeasurementCache[key] { return cached }
        let measured = LabelOverlayView.measuredSize(
            for: LabelOverlayView.Label(symbol: text, x: 0, y: 0, style: style))
        routeLabelMeasurementCount += 1
        if routeLabelMeasurementCache.count < Self.routeLabelMeasurementCacheCapacity {
            routeLabelMeasurementCache[key] = measured
        }
        return measured
    }

    private func synchronizeRouteLabelMeasurementCache() {
        let signature = scene.kPathPoints.prefix(1024).enumerated().map { index, point in
            point.label.isEmpty ? "K\(index + 1)" : String(point.label.prefix(64))
        }
        guard routeLabelTextSignature != signature else { return }
        routeLabelMeasurementCache.removeAll(keepingCapacity: true)
        routeLabelTextSignature = signature
    }

    private func invalidateRouteLabelMeasurementCache() {
        routeLabelMeasurementCache.removeAll(keepingCapacity: true)
        routeLabelTextSignature = nil
    }

    private func labelViewport(for size: CGSize) -> SIMD2<Float>? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= CGFloat(Float.greatestFiniteMagnitude),
              size.height <= CGFloat(Float.greatestFiniteMagnitude) else { return nil }
        let width = Float(size.width)
        let height = Float(size.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return SIMD2<Float>(width, height)
    }

    private func projectLabelPoint(_ world: SIMD3<Float>, camera: Camera,
                                   viewport: SIMD2<Float>) -> CGPoint? {
        Self.projectPoint(world, camera: camera, viewport: viewport)
    }

    /// Project a route-node label point, returning both the screen point and a
    /// depth sort key. Points behind the near plane are clamped to just in front
    /// of it so the label stays visible as the BZ rotates (the parallel
    /// projection keeps the screen position stable), and report a large depth so
    /// they layer beneath labels for points actually in front of the camera.
    static func projectRouteLabelPoint(_ world: SIMD3<Float>, camera: Camera,
                                        viewport: SIMD2<Float>) -> (point: CGPoint, depth: Float)? {
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite,
              validViewport(viewport) else { return nil }
        var viewPosition = camera.viewMatrix() * SIMD4<Float>(world.x, world.y, world.z, 1)
        let depth = -viewPosition.z
        let behindCamera: Bool
        let sortDepth: Float
        if depth.isFinite, depth > 0.01 {
            behindCamera = false
            sortDepth = depth
        } else {
            // Clamp just in front of the near plane so the projection keeps the
            // label's screen position stable as it passes behind the camera;
            // report it as farthest so it layers beneath in-front labels.
            viewPosition.z = -0.01
            behindCamera = true
            sortDepth = 1000
        }
        let aspect = viewport.x / viewport.y
        guard aspect.isFinite, aspect > 0 else { return nil }
        let clip = camera.projectionMatrix(aspect: aspect) * viewPosition
        guard clip.x.isFinite, clip.y.isFinite, clip.z.isFinite, clip.w.isFinite,
              clip.w > 1e-10 else { return nil }
        let ndc = clip / clip.w
        guard ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite else { return nil }
        // Behind-camera points project with the near-plane z so they pass the
        // range check; in-front points keep the strict viewport check.
        guard ndc.x >= -1, ndc.x <= 1, ndc.y >= -1, ndc.y <= 1 else { return nil }
        if !behindCamera {
            guard ndc.z >= 0, ndc.z <= 1 else { return nil }
        }
        let x = (ndc.x * 0.5 + 0.5) * viewport.x
        let y = (1 - (ndc.y * 0.5 + 0.5)) * viewport.y
        guard x.isFinite, y.isFinite else { return nil }
        return (CGPoint(x: CGFloat(x), y: CGFloat(y)), sortDepth)
    }

    /// Project a world point into top-origin viewport pixels with the given
    /// camera, rejecting points behind the near plane or outside the viewport.
    /// Shared by atom/route/bond-distance label projection so live and export
    /// compositing use exactly the same geometry.
    static func projectPoint(_ world: SIMD3<Float>, camera: Camera,
                             viewport: SIMD2<Float>) -> CGPoint? {
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite,
              validViewport(viewport) else { return nil }
        let viewPosition = camera.viewMatrix() * SIMD4<Float>(world.x, world.y, world.z, 1)
        let depth = -viewPosition.z
        guard depth > 0.01, depth.isFinite else { return nil }
        let aspect = viewport.x / viewport.y
        guard aspect.isFinite, aspect > 0 else { return nil }
        let clip = camera.projectionMatrix(aspect: aspect) * viewPosition
        guard clip.x.isFinite, clip.y.isFinite, clip.z.isFinite, clip.w.isFinite,
              clip.w > 1e-10 else { return nil }
        let ndc = clip / clip.w
        guard ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite,
              ndc.x >= -1, ndc.x <= 1, ndc.y >= -1, ndc.y <= 1,
              ndc.z >= 0, ndc.z <= 1 else { return nil }
        let x = (ndc.x * 0.5 + 0.5) * viewport.x
        let y = (1 - (ndc.y * 0.5 + 0.5)) * viewport.y
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    private static func validViewport(_ viewport: SIMD2<Float>) -> Bool {
        guard viewport.x.isFinite, viewport.y.isFinite,
              viewport.x > 0, viewport.y > 0 else { return false }
        return true
    }

    private func validBZPresentation(_ presentation: BZPresentation) -> Bool {
        finite(presentation.center) && presentation.inv.isFinite && presentation.inv > 0
            && finite(presentation.reciprocal.a)
            && finite(presentation.reciprocal.b)
            && finite(presentation.reciprocal.c)
             && BrillouinZone.isFiniteInvertible(simd_float3x3(
                columns: (presentation.reciprocal.a,
                          presentation.reciprocal.b,
                          presentation.reciprocal.c)))
    }

    private static func reciprocalGeometryChanged(from old: Scene, to new: Scene) -> Bool {
        guard old.cell?.a != new.cell?.a || old.cell?.b != new.cell?.b
                || old.cell?.c != new.cell?.c else {
            guard old.baseAtoms.count == new.baseAtoms.count else { return true }
            return zip(old.baseAtoms, new.baseAtoms).contains {
                $0.coord != $1.coord || $0.atomicNumber != $1.atomicNumber
            }
        }
        return true
    }

    private func validReciprocalViewport(_ viewport: SIMD2<Float>) -> Bool {
        viewport.x.isFinite && viewport.y.isFinite && viewport.x > 0 && viewport.y > 0
    }

    private func reciprocalPresentationSignature(for scene: Scene)
        -> (center: SIMD3<Float>, inv: Float)? {
        guard bzEditCache.epoch == bzEpoch, let bz = bzEditCache.bz else { return nil }
        let presentation = BZPresentation(bz: bz, scene: scene)
        guard validBZPresentation(presentation) else { return nil }
        return (presentation.center, presentation.inv)
    }

    private func reciprocalPresentationChanged(
        from before: (center: SIMD3<Float>, inv: Float)?,
        to after: (center: SIMD3<Float>, inv: Float)?) -> Bool {
        switch (before, after) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (before?, after?):
            return before.center != after.center || before.inv != after.inv
        }
    }

    private func finite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    private func finite(_ vector: SIMD2<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite
    }

    private func reciprocalTooltipLabel() -> LabelOverlayView.Label? {
        guard state.editKPathOnBZ,
              let candidate = reciprocalHoverCandidate,
              let cursor = reciprocalHoverCursor,
              finite(cursor), finite(candidate.point.frac) else { return nil }
        let label = candidate.point.label.isEmpty ? "K" : String(candidate.point.label.prefix(64))
        let type: String
        switch candidate.type {
        case .center: type = "Gamma"
        case .edge: type = "vertex"
        case .line: type = "edge midpoint"
        case .polyface: type = "face center"
        }
        let f = candidate.point.frac
        let coordinates = String(format: "(%.4f, %.4f, %.4f)", f.x, f.y, f.z)
        return LabelOverlayView.Label(symbol: "\(label)\n\(type)\n\(coordinates)",
                                      x: CGFloat(cursor.x + 14), y: CGFloat(cursor.y + 14),
                                      style: .tooltip)
    }

    private func clearReciprocalHover() {
        let hadHover = reciprocalHoverCandidate != nil || reciprocalHoverCursor != nil
        reciprocalHoverCandidate = nil
        reciprocalHoverCursor = nil
        if hadHover || labelOverlay.labels.contains(where: { $0.style == .tooltip }) {
            updateTransientTooltip()
        }
    }

    /// Replace only the transient tooltip entry. Persistent atom and route labels
    /// remain untouched during pointer movement.
    private func updateTransientTooltip() {
        var labels = labelOverlay.labels.filter { $0.style != .tooltip }
        if let tooltip = reciprocalTooltipLabel() {
            labels.append(tooltip)
        }
        if labels != labelOverlay.labels {
            labelOverlay.labels = labels
        }
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
        appendCoordinationDetails(to: &lines, selection: sel, atoms: atoms)
        if let r = scene.measurementResult {
            lines.append("")
            lines.append("Measurement:")
            lines.append("  " + r.summary)
        }
        return lines.joined(separator: "\n")
    }

    /// Add bounded coordination detail to the selection readout. The engine's
    /// neighbor records are runtime-derived, so every index is validated against
    /// the live displayed atom array before it is formatted.
    private func appendCoordinationDetails(to lines: inout [String], selection: [Int], atoms: [Atom]) {
        guard state.coordinationEnabled,
              let analysis = coordinationAnalysis,
              installedCoordinationNumbers.count == atoms.count else { return }
        let validSelection = selection.filter { $0 >= 0 && $0 < atoms.count }
        guard !validSelection.isEmpty else { return }

        lines.append("")
        lines.append("Coordination:")
        let selectedLimit = min(8, validSelection.count)
        for index in validSelection.prefix(selectedLimit) {
            guard index < installedCoordinationNumbers.count else { continue }
            lines.append("  Atom \(index + 1) CN \(installedCoordinationNumbers[index])")
            let neighbors = analysis.neighbors(of: index)
                .filter { $0.atomIndex >= 0 && $0.atomIndex < atoms.count && $0.distance.isFinite }
                .sorted {
                    // Show nearest neighbors first; symbol, index, and image offset
                    // are only deterministic tie-breakers so the readout is stable.
                    if $0.distance != $1.distance { return $0.distance < $1.distance }
                    let lhs = ElementTable.symbol(atoms[$0.atomIndex].atomicNumber)
                    let rhs = ElementTable.symbol(atoms[$1.atomIndex].atomicNumber)
                    if lhs != rhs { return lhs < rhs }
                    if $0.atomIndex != $1.atomIndex { return $0.atomIndex < $1.atomIndex }
                    if $0.imageOffset.x != $1.imageOffset.x { return $0.imageOffset.x < $1.imageOffset.x }
                    if $0.imageOffset.y != $1.imageOffset.y { return $0.imageOffset.y < $1.imageOffset.y }
                    return $0.imageOffset.z < $1.imageOffset.z
                }
            let neighborLimit = min(16, neighbors.count)
            for neighbor in neighbors.prefix(neighborLimit) {
                let symbol = ElementTable.symbol(atoms[neighbor.atomIndex].atomicNumber)
                let offset = neighbor.imageOffset
                let image = offset == .zero
                    ? ""
                    : " image=(\(offset.x),\(offset.y),\(offset.z))"
                lines.append(String(format: "    %@ #%d %.3f Å%@", symbol as NSString,
                                    neighbor.atomIndex + 1, neighbor.distance, image as NSString))
            }
            if neighbors.count > neighborLimit {
                lines.append("    … and \(neighbors.count - neighborLimit) more neighbors")
            }
        }
        if validSelection.count > selectedLimit {
            lines.append("  … and \(validSelection.count - selectedLimit) more selected atoms")
        }
    }

    /// Menu-item action: toggle element labels on/off and update the overlay.
    @objc func toggleLabels(_ sender: Any?) {
        scene.showLabels.toggle()
        state.showLabels = scene.showLabels
        setNeedsRender()
    }

    private func cameraBookmarkSlotIsValid(_ slot: Int) -> Bool {
        cameraBookmarks.indices.contains(slot) && slot < CameraBookmark.slotCount
    }

    /// Save the current live camera into one document slot. Validate before
    /// replacing anything so a malformed camera cannot destroy a good bookmark.
    @discardableResult
    internal func saveCameraBookmark(at slot: Int) -> Bool {
        guard cameraBookmarkSlotIsValid(slot),
              let name = state.cameraBookmarkSaveName(at: slot) else { return false }
        guard let validated = try? Camera.validated(camera) else { return false }
        cameraBookmarks[slot] = CameraBookmark(name: name, camera: validated)
        state.setCameraBookmarkName(at: slot, to: name)
        state.setCameraBookmarkOccupied(at: slot, true)
        return true
    }

    /// Recall a bookmark transactionally. Validation is performed on a local
    /// copy; failure returns before touching the live camera or sidebar state.
    /// The validated stored presentation is installed only after validation so
    /// recall does not accidentally reframe, align, or alter saved fields.
    @discardableResult
    internal func recallCameraBookmark(at slot: Int) -> Bool {
        guard cameraBookmarkSlotIsValid(slot), let bookmark = cameraBookmarks[slot] else {
            return false
        }
        let candidate = bookmark.camera
        guard let validated = try? Camera.validated(candidate) else { return false }

        clearTransientViewHighlights()
        camera = validated
        // orthographic is a UI mirror, not a second source of camera truth. Fence
        // its synchronous didSet callback so recalling a slot cannot recurse back
        // through syncFromState or overwrite the just-restored camera.
        let wasSyncingState = isSyncingState
        isSyncingState = true
        state.orthographic = !validated.perspective
        isSyncingState = wasSyncingState
        scene.camera = validated
        setNeedsRender()
        return true
    }

    /// Empty a document bookmark slot while retaining the displayed name for a
    /// predictable next save. Invalid indices are harmless no-ops.
    internal func clearCameraBookmark(at slot: Int) {
        guard cameraBookmarkSlotIsValid(slot) else { return }
        cameraBookmarks[slot] = nil
        // Keep a meaningful edited name for the next save; a blank/whitespace
        // draft falls back to the stable slot default instead.
        if let name = state.cameraBookmarkSaveName(at: slot) {
            state.setCameraBookmarkName(at: slot, to: name)
        }
        state.setCameraBookmarkOccupied(at: slot, false)
    }

    func applyCameraForNewSceneIfNeeded() {
        // The scene owns the canonical default-framing rule (atoms AND grid); use it
        // so the window, PNG export and vector export all agree on framing.
        camera = scene.defaultCamera()
        setNeedsRender()
    }

    /// Recompute the runtime-only standard-view availability. The reciprocal
    /// editing flag includes the short transition in which the sidebar has already
    /// changed but the controller has not yet committed `lastEditKPathOnBZ`.
    private func refreshStandardCrystalViewAvailability() {
        state.refreshStandardCrystalViewAvailability(
            cell: scene.cell,
            reciprocalEditing: state.editKPathOnBZ || lastEditKPathOnBZ)
    }

    /// Align the camera to a standard crystallographic direction. Validation is
    /// performed before touching the live camera, and alignment happens on a copy,
    /// so every rejected action leaves the camera byte-for-byte unchanged.
    @discardableResult
    func alignToStandardCrystalView(_ view: StandardCrystalView) -> Bool {
        guard !state.editKPathOnBZ, !lastEditKPathOnBZ,
              !state.displayMode.is2D, !scene.displayMode.is2D,
              let cell = scene.cell,
              Camera.standardCrystalViewUnavailableReason(cell: cell) == nil else {
            refreshStandardCrystalViewAvailability()
            return false
        }

        let original = camera
        var aligned = original
        do {
            try aligned.align(to: view, cell: cell)
        } catch {
            // Alignment is transactional: the live camera has not been touched,
            // and the failed copy is discarded.
            refreshStandardCrystalViewAvailability()
            return false
        }
        // `align` is an orientation operation. Keep these presentation fields
        // explicit here as a defensive contract at the controller boundary.
        aligned.center = original.center
        aligned.distance = original.distance
        aligned.perspective = original.perspective

        clearTransientViewHighlights()
        camera = aligned
        scene.camera = camera
        refreshStandardCrystalViewAvailability()
        setNeedsRender()
        return true
    }

    /// Clear camera/editor overlays that represent a transient viewport focus.
    /// A standard-view change is a view reset for this purpose: route-node
    /// selection must not remain highlighted after the camera moves.
    private func clearTransientViewHighlights() {
        clearReciprocalHover()
        canvas.invalidateReciprocalAccessibilityFocus()
        state.notifyViewReset()
        selectedRouteNodeIndex = nil
        renderer?.selectedKPathNode = nil
        renderer2D?.selectedKPathNode = nil
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
        clearTransientViewHighlights()
        camera.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
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
        clearReciprocalHover()
        applyCameraForNewSceneIfNeeded()
        camera.perspective = !state.orthographic
    }

    private func frameReciprocalEditor(viewport requestedViewport: SIMD2<Float>? = nil) -> Bool {
        let viewport = requestedViewport
            ?? SIMD2<Float>(Float(canvas.bounds.width), Float(canvas.bounds.height))
        // A view can be transiently zero-sized while its window is being laid out.
        // Use the established entry fallback in that case; a valid resize callback
        // always supplies its actual logical viewport.
        let fitViewport = validReciprocalViewport(viewport) ? viewport : SIMD2<Float>(800, 600)
        let (candidates, presentation) = editorLandmarks()
        guard let bz = bzEditCache.bz,
              !candidates.isEmpty,
              let presentation,
              validBZPresentation(presentation),
              let framed = presentation.framedCamera(bz: bz, current: camera,
                                                     viewport: fitViewport) else { return false }
        reciprocalEditorFrameCount += 1
        camera = framed
        return true
    }

    /// Scene/frame installation must never restore a camera captured for the old
    /// structure. It also drops the one transient hover candidate.
    private func clearReciprocalFocusForSceneReplacement() {
        reciprocalStructureCamera = nil
        reciprocalStructureDisplayMode = nil
        reciprocalStructureShowBZ = nil
        reciprocalStructureOrthographic = nil
        lastEditKPathOnBZ = false
        reciprocalHoverCandidate = nil
        reciprocalHoverCursor = nil
        selectedRouteNodeIndex = nil
        renderer?.showBZLandmarks = false
        canvas.invalidateReciprocalAccessibilityFocus()
    }

    private func rejectReciprocalEditor(reason: String = "Brillouin zone unavailable for this cell.") {
        let wasSyncingState = isSyncingState
        isSyncingState = true
        defer { isSyncingState = wasSyncingState }
        state.reciprocalEditorStatusText = reason
        state.editKPathOnBZ = false
        lastEditKPathOnBZ = false

        if let mode = reciprocalStructureDisplayMode {
            state.displayMode = mode
            scene.displayMode = mode
        }
        if let showBZ = reciprocalStructureShowBZ {
            state.showBrillouinZone = showBZ
            scene.showBrillouinZone = showBZ
        }
        if let savedCamera = reciprocalStructureCamera {
            camera = savedCamera
            state.orthographic = reciprocalStructureOrthographic ?? !savedCamera.perspective
        }
        scene.camera = camera
        refreshStandardCrystalViewAvailability()
        reciprocalStructureCamera = nil
        reciprocalStructureDisplayMode = nil
        reciprocalStructureShowBZ = nil
        reciprocalStructureOrthographic = nil
        renderer?.showBZLandmarks = false
        clearReciprocalHover()
        canvas.invalidateReciprocalAccessibilityFocus()
        if window.firstResponder === canvas {
            window.makeFirstResponder(nil)
        }
        updateContentVisibility()
        refreshDelegate()
        setNeedsRender()
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

        let enteringReciprocalEdit = state.editKPathOnBZ && !lastEditKPathOnBZ
        let exitingReciprocalEdit = !state.editKPathOnBZ && lastEditKPathOnBZ
        let standardCrystalViewAvailabilityNeedsRefresh =
            enteringReciprocalEdit || exitingReciprocalEdit
            || state.displayMode != scene.displayMode
        if enteringReciprocalEdit {
            // Capture the complete pre-editor presentation before any validation
            // or 2D->3D transition, so every failure uses the same rejection path.
            reciprocalStructureCamera = camera
            reciprocalStructureDisplayMode = state.displayMode
            reciprocalStructureShowBZ = state.showBrillouinZone
            reciprocalStructureOrthographic = state.orthographic
            guard renderer != nil else {
                rejectReciprocalEditor(reason: "Metal renderer unavailable.")
                return
            }
            guard scene.isCrystal, state.reciprocalEditorAvailable else {
                rejectReciprocalEditor()
                return
            }
            let (candidates, presentation) = editorLandmarks()
            guard !candidates.isEmpty,
                  let presentation,
                  validBZPresentation(presentation) else {
                rejectReciprocalEditor()
                return
            }
            lastEditKPathOnBZ = true
            reciprocalHoverCandidate = nil
            reciprocalHoverCursor = nil
            canvas.invalidateReciprocalAccessibilityFocus()
        } else if exitingReciprocalEdit {
            reciprocalHoverCandidate = nil
            reciprocalHoverCursor = nil
            canvas.invalidateReciprocalAccessibilityFocus()
            if window.firstResponder === canvas {
                window.makeFirstResponder(nil)
            }
            if let mode = reciprocalStructureDisplayMode {
                state.displayMode = mode
            }
            if let showBZ = reciprocalStructureShowBZ {
                state.showBrillouinZone = showBZ
            }
        }

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
        let requestedPerspective = exitingReciprocalEdit
            ? (reciprocalStructureCamera?.perspective ?? !state.orthographic)
            : !state.orthographic
        let projectionChanged = camera.perspective != requestedPerspective
        if previousMode != state.displayMode || projectionChanged {
            clearReciprocalHover()
            canvas.invalidateReciprocalAccessibilityFocus()
        }
        scene.displayMode = state.displayMode
        scene.atomScale = state.atomScale
        scene.bondRadius = state.bondRadius
        scene.showCellFrame = state.showCellFrame
        scene.showAxes = state.showAxes
        scene.showLabels = state.showLabels
        scene.showBondDistances = state.showBondDistances
        scene.showScaleIndicator = state.showScaleIndicator
        // User controls push state -> scene so the renderer reads the new value.
        // (showBrillouinZone is the renderer's source of truth via scene.* .)
        scene.showBrillouinZone = state.showBrillouinZone
        // Projection toggle: orthographic checked => perspective off. Bound to
        // the live render camera (the renderer reads camera.perspective).
        if camera.perspective != requestedPerspective {
            camera.perspective = requestedPerspective
        }
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
        // Comparison displacement arrows are runtime-only renderer state (the
        // reference structure is never persisted); push the toggle through.
        renderer?.showDisplacementArrows = state.showComparisonArrows
        // MSAA sample count. Validated values only (1,2,4,8); the sidebar picker
        // can produce nothing else. Written unconditionally; the renderer gates
        // use on the value being > 1.
        scene.msaaSampleCount = state.msaaSampleCount
        // Color-plane overlay: written unconditionally; the renderer/visibility
        // gates the draw on `scene.grid2D != nil`.
        scene.showColorPlane = state.showColorPlane
        // Color-plane colormap + contour configuration: mirrored into the scene
        // here so they persist via StateStore; the renderer applies them to the
        // in-scene color-plane quad and 3D contour lines.
        scene.colorPlaneColormap = state.colorPlaneColormap
        scene.colorPlaneContourEnabled = state.colorPlaneContourEnabled
        scene.colorPlaneContourCount = min(20, max(2, state.colorPlaneContourCount))
        // Volume slices: mirror into the scene (capped at 3 in SideBarState).
        scene.volumeSlices = Array(state.volumeSlices.prefix(3))
        // Multiple iso specs: mirror into the scene (capped at 8 in SideBarState).
        scene.isoSurfaces = Array(state.isoSurfaces.prefix(8))
        // Display-only clip plane: only meaningful when a cell is present.
        scene.clipPlane = scene.cell != nil ? state.clipPlane : nil
        // Color-plane overlay: a 2D grid may coexist with the 3D structure. The
        // plane is now drawn as a textured quad in the Metal scene by the renderer
        // (gated on scene.showColorPlane), so it composites with the structure instead
        // of swapping the canvas.
        updateContentVisibility()
        if enteringReciprocalEdit, window.isVisible {
            window.makeFirstResponder(canvas)
        }
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
            selectedRouteNodeIndex = nil
            renderer?.selectedKPathNode = nil
            renderer2D?.selectedKPathNode = nil
        }
        // lighting + background — the renderer currently uses a fixed shader and
        // solid clear color (the richer shader is owned by another agent); we
        // mirror state into the scene here so the values persist via StateStore
        // and are ready the moment the renderer starts consuming them.
        scene.lighting = state.lighting
        scene.backgroundType = state.backgroundType
        scene.background = state.backgroundHex
        scene.backgroundBottom = state.backgroundBottomHex
        scene.backgroundImagePath = state.backgroundImagePath
        scene.anaglyphMode = state.anaglyphMode
        // ---- Tier-1 appearance mirrors (state -> scene) ----
        // All of these are plain value mirrors: the renderer reads them straight
        // off the scene, and StateStore persists them through Scene's Codable
        // conformance (whose custom decoder supplies the legacy defaults). They
        // are written unconditionally — each field's default reproduces the
        // pre-Tier-1 output exactly, so an untouched sidebar changes nothing.
        // Multi-light rig: empty = legacy single light. Capped at 6 sources to
        // match the renderer's fixed-size uniform block.
        scene.lights = Array(state.lights.prefix(MainWindowController.maxSceneLights))
        // H-bond criteria mirror here; the detected pair list is derived below
        // (after supercell/slab settle) so it always matches the displayed atoms.
        scene.hbondSettings = state.hbondSettings
        // Molecular surface: settings only. There is no scene-side mesh field —
        // the renderer builds and caches the mesh from these settings itself, so
        // the controller must not compute geometry here.
        scene.molecularSurfaceSettings = state.molecularSurfaceSettings
        // Color scheme + per-element overrides: the renderer resolves per-atom
        // colors/radii from these via ColorSchemes.
        scene.atomColorScheme = state.atomColorScheme
        scene.elementOverrides = state.elementOverrides
        // Unit-of-repetition: `.asymmetricUnit` is a display-time filter applied
        // by the renderer (no atom-set mutation here), so this is a pure mirror
        // even when the supercell is (1,1,1).
        scene.repetitionMode = state.repetitionMode
        scene.cellRodsEnabled = state.cellRodsEnabled
        scene.cellRodFactor = state.cellRodFactor
        scene.unicolorBonds = state.unicolorBonds
        scene.unicolorBondHex = state.unicolorBondHex
        scene.tessellationFactor = state.tessellationFactor
        let reciprocalPresentationBefore = reciprocalPresentationSignature(for: scene)
        // supercell — compare the (n1,n2,n3) tuple, not just total, so changing
        // replication DIRECTION (e.g. 2×1×1 → 1×2×1, same total) re-widen happens.
        let sc = SuperCell(n1: state.n1, n2: state.n2, n3: state.n3)
        // Snapshot the pre-change framing BEFORE any geometry mutation so the
        // center/ratio fixup below tracks the geometry the user actually sees.
        // Snapshotting outside the superCell branch (and applying the fixup
        // AFTER applySlab) lets a combined supercell+slab change frame the final
        // post-slab geometry, and a slab-only change — which also alters the
        // displayed set — trigger a reframe too. The isReloadingFrame guard at
        // the top of syncFromState already keeps playback/frame-slide from here.
        let oldRadius = scene.boundingSphereRadius()
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
        let slabChanged = scene.slab != oldSlab
        if superCellChanged || slabChanged {
            // The displayed geometry changed: recenter on the new framing-sphere
            // centroid and scale the distance by the radius ratio. Preserve the
            // user's orbit quaternion exactly — only zoom/center drift is
            // corrected, no rotation/perspective jump. (applyCameraForNewScene-
            // IfNeeded() is intentionally NOT used: it rebuilds the camera from
            // scratch and would reset orientation.) Guard an empty pre-change
            // scene (oldRadius 0) with the new radius as a safe reference so the
            // ratio is 1 and we never divide by zero.
            let newCenter = scene.framingSphere().center
            let newRadius = scene.boundingSphereRadius()
            camera.center = newCenter
            let referenceRadius = oldRadius > 0 ? oldRadius : newRadius
            if referenceRadius > 0 {
                camera.distance *= newRadius / referenceRadius
            }
        }
        let reciprocalPresentationAfter = reciprocalPresentationSignature(for: scene)
        if (superCellChanged || slabChanged), reciprocalPresentationChanged(
            from: reciprocalPresentationBefore, to: reciprocalPresentationAfter) {
            clearReciprocalHover()
            canvas.invalidateReciprocalAccessibilityFocus()
        }
        syncCoordinationState(geometryChanged: superCellChanged || slabChanged)
        if superCellChanged || slabChanged {
            // Supercell/slab changes alter the displayed atom ordering and
            // invalidate any installed two-structure comparison. This path
            // renders later, so suppress the invalidation render.
            invalidateComparisonRequest(render: false)
            refreshAtomTable()
        }
        // Live-vacuum adjust for 2D slabs: the same slider doubles as the build
        // parameter and a live vacuum control. When the scene is a z-parallel 2D
        // slab and the slider value differs from the derived vacuum, apply it via
        // withVacuum. Defensive (the slider's onChange also routes through
        // onSurfaceVacuumChange); guards failures by mirroring the value back.
        if let currentVacuum = currentSlabVacuum, state.surfaceVacuum != currentVacuum {
            switch scene.withVacuum(state.surfaceVacuum) {
            case .success(let next):
                scene = next
                setNeedsRender()
                refreshAtomTable()
            case .failure:
                state.surfaceVacuum = currentVacuum
            }
        }
        // H-bond pair list: derived from the FINAL displayed atom set, so it runs
        // after supercell/slab/vacuum have settled and after scene.hbondSettings
        // was mirrored above.
        syncHbondPairs()
        // Reframe when crossing the 2D↔3D boundary — after supercell/slab
        // mutations so the camera fits the final geometry.
        if !exitingReciprocalEdit {
            reframeForDisplayMode(previous: previousMode)
        }
        if enteringReciprocalEdit {
            // Entry framing is deliberately one-shot. It runs after a possible
            // 2D->3D structure reframe and therefore preserves the final mode.
            guard frameReciprocalEditor() else {
                rejectReciprocalEditor()
                return
            }
            state.clearReciprocalEditorStatus()
        } else if projectionChanged && state.editKPathOnBZ {
            // Projection changes alter the distance needed to fit the BZ. Refit
            // once after applying the new projection, without changing rotation.
            guard frameReciprocalEditor() else {
                rejectReciprocalEditor()
                return
            }
        }
        if exitingReciprocalEdit {
            if let reciprocalStructureCamera {
                camera = reciprocalStructureCamera
                // Keep the sidebar projection mirror aligned with the restored
                // camera while the existing sync guard is active.
                state.orthographic = !reciprocalStructureCamera.perspective
            }
            scene.camera = camera
            reciprocalStructureCamera = nil
            reciprocalStructureDisplayMode = nil
            reciprocalStructureShowBZ = nil
            reciprocalStructureOrthographic = nil
            lastEditKPathOnBZ = false
        } else if !state.editKPathOnBZ {
            lastEditKPathOnBZ = false
            reciprocalStructureCamera = nil
            reciprocalStructureDisplayMode = nil
            reciprocalStructureShowBZ = nil
            reciprocalStructureOrthographic = nil
        }
        if standardCrystalViewAvailabilityNeedsRefresh {
            refreshStandardCrystalViewAvailability()
        }
        // background clear color (solid top color today; gradient rendering is
        // pending on the shader work).
        if let c = colorFromHex(state.backgroundHex) {
            renderer?.background = MTLClearColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        // Playback timer follows the Play/Pause toggle: started on play,
        // torn down on pause or when not animating at all.
        if state.isPlaying && playTimer == nil { startPlayback() }
        if !state.isPlaying && playTimer != nil { stopPlayback() }
        // Trajectory-trail overlay follows its toggle. refreshTrajectoryTrails()
        // handles both the on (load frames, publish strip) and off (disable
        // renderer flag) cases, so just drive it whenever state and renderer
        // disagree.
        if state.showTrajectoryTrails != renderer?.showTrajectoryTrails {
            refreshTrajectoryTrails()
        }
        // Trajectory-centroid alignment follows its toggle. When turned on, load
        // and cache the aligned frames and immediately reload the current frame so
        // the displayed trajectory is aligned; when turned off, clear the cache
        // and reload to restore the original coordinates.
        if state.alignTrajectory {
            if alignedFrames == nil { refreshAlignedFrames() }
        } else if alignedFrames != nil {
            alignedFrames = nil
            reloadFrame(state.frameIndex)
        }
        // Electronic-structure graph interaction (energy window, Fermi shift) is
        // view-only state -> push it to the grapher views and recompute readouts.
        if state.electronicStructureEnabled {
            updateElectronicStructureGraphs()
            rebuildBandSurface()
        }
        // Powder XRD is cheap (a few ms) and gated on isCrystal internally, so it
        // recomputes on every sidebar/scene change without a debounce.
        updatePowderXRD()
        setNeedsRender()
    }

    // MARK: - H-bond lifecycle

    /// Identity of the inputs an `HbondAnalysis.detect` result depends on: the
    /// detection criteria plus the displayed atom set. Positions are folded into
    /// an FNV-1a hash rather than compared element-wise so the check stays O(n)
    /// with no per-sync allocation of a second atom array.
    private struct HbondFingerprint: Equatable {
        var settings: HbondSettings
        var atomCount: Int
        var atomHash: UInt64
        var cellHash: UInt64
    }

    /// Fold the displayed geometry into a cheap 64-bit digest. Distinct atom
    /// sets can theoretically collide, but only a collision *plus* an identical
    /// count and criteria would skip a recomputation, and every wholesale scene
    /// replacement clears the fingerprint outright.
    private static func hbondFingerprint(for scene: Scene) -> HbondFingerprint {
        var atomHash: UInt64 = 0xcbf29ce484222325
        func mix(_ bits: UInt32) {
            atomHash = (atomHash ^ UInt64(bits)) &* 0x100000001b3
        }
        for atom in scene.atoms {
            mix(atom.coord.x.bitPattern)
            mix(atom.coord.y.bitPattern)
            mix(atom.coord.z.bitPattern)
            mix(UInt32(truncatingIfNeeded: atom.atomicNumber))
        }
        var cellHash: UInt64 = 0xcbf29ce484222325
        if let cell = scene.cell {
            for v in [cell.a, cell.b, cell.c] {
                for c in [v.x, v.y, v.z] {
                    cellHash = (cellHash ^ UInt64(c.bitPattern)) &* 0x100000001b3
                }
            }
        }
        cellHash = (cellHash ^ UInt64(truncatingIfNeeded: scene.periodicDim)) &* 0x100000001b3
        return HbondFingerprint(settings: scene.hbondSettings,
                                atomCount: scene.atoms.count,
                                atomHash: atomHash,
                                cellHash: cellHash)
    }

    /// Keep `scene.hbondPairs` consistent with `scene.hbondSettings` and the
    /// displayed atoms. Disabled ⇒ the list is emptied (so the renderer draws
    /// nothing and no stale pairs persist into a saved state). Enabled ⇒ the
    /// list is recomputed only when the criteria or the atom set actually
    /// changed. `HbondAnalysis.detect` is non-trapping and enforces its own atom
    /// cap, returning [] rather than failing, so no additional guard is needed.
    ///
    /// Call sites: the end of the `syncFromState` mirror (after supercell, slab,
    /// and vacuum have produced the final atom set) and every path that installs
    /// a replacement scene (file open, frame reload, in-scene transforms), which
    /// clear the fingerprint via `hbondGeometryDidChange()` first.
    private func syncHbondPairs() {
        guard scene.hbondSettings.enabled else {
            lastHbondFingerprint = nil
            if !scene.hbondPairs.isEmpty { scene.hbondPairs = [] }
            return
        }
        let fingerprint = MainWindowController.hbondFingerprint(for: scene)
        guard fingerprint != lastHbondFingerprint else { return }
        lastHbondFingerprint = fingerprint
        scene.hbondPairs = HbondAnalysis.detect(scene: scene)
    }

    /// Invalidate the cached H-bond fingerprint after a wholesale scene
    /// replacement, then recompute for the newly installed atoms. Mirrors
    /// `coordinationGeometryDidChange()`'s role for the coordination lifecycle.
    private func hbondGeometryDidChange() {
        lastHbondFingerprint = nil
        syncHbondPairs()
    }

    // MARK: - Coordination lifecycle

    /// Keep analysis work behind an explicit opt-in. Geometry changes are routed
    /// here only after the final displayed atom array (including supercell and
    /// slab filtering) has been installed.
    private func syncCoordinationState(geometryChanged: Bool) {
        let enabledChanged = state.coordinationEnabled != lastCoordinationEnabled
        let scaleChanged = state.coordinationRadiusScale != lastCoordinationScale
        lastCoordinationEnabled = state.coordinationEnabled
        lastCoordinationScale = state.coordinationRadiusScale

        guard state.coordinationEnabled else {
            if coordinationCancellationToken != nil || coordinationAnalysis != nil
                || !installedCoordinationNumbers.isEmpty
                || state.coordinationAnalysisAvailable
                || state.coordinationStatusText != "Off" || !state.coordinationSummaryText.isEmpty {
                clearCoordinationAnalysis(status: "Off", summary: "")
            }
            if state.showCoordinationColors { state.showCoordinationColors = false }
            return
        }

        if geometryChanged || enabledChanged {
            startCoordinationAnalysis(debounced: false)
        } else if scaleChanged {
            startCoordinationAnalysis(debounced: true)
        } else {
            applyCoordinationColors()
        }
    }

    /// Called by file/frame/slab paths that replace `scene` outside the normal
    /// sidebar mirror transaction. The generation bump invalidates every result
    /// from the old atom ordering before launching work for the new one.
    private func coordinationGeometryDidChange() {
        if state.coordinationEnabled {
            lastCoordinationEnabled = true
            lastCoordinationScale = state.coordinationRadiusScale
            startCoordinationAnalysis(debounced: false)
        } else {
            if coordinationCancellationToken != nil || coordinationAnalysis != nil
                || !installedCoordinationNumbers.isEmpty {
                clearCoordinationAnalysis(status: "Off", summary: "")
            }
        }
    }

    /// The analyzer receives the displayed atoms, not `baseAtoms`. For an explicit
    /// supercell, widen only the periodic cell vectors so replicas do not collapse
    /// onto one another through the minimum-image search. Non-periodic axes retain
    /// their original vector and the slab-filtered atom set remains unchanged.
    internal func effectiveCoordinationCell(for scene: Scene) -> Cell? {
        guard let cell = scene.cell else { return nil }
        let n1 = scene.periodicDim >= 1 ? max(1, scene.superCell.n1) : 1
        let n2 = scene.periodicDim >= 2 ? max(1, scene.superCell.n2) : 1
        let n3 = scene.periodicDim >= 3 ? max(1, scene.superCell.n3) : 1
        return Cell(a: cell.a * Float(n1), b: cell.b * Float(n2), c: cell.c * Float(n3))
    }

    private func cancelCoordinationRequest() {
        coordinationCancellationToken?.cancel()
        coordinationCancellationToken = nil
        coordinationWorkItem?.cancel()
        coordinationWorkItem = nil
        coordinationDebounceCancellation?()
        coordinationDebounceCancellation = nil
        cancelDistributionRequest()
    }

    private func cancelDistributionRequest() {
        distributionCancellationToken?.cancel()
        distributionCancellationToken = nil
        distributionWorkItem?.cancel()
        distributionWorkItem = nil
    }

    private func cancelAnimationDataRequest() {
        animationDataCancellationToken?.cancel()
        animationDataCancellationToken = nil
        animationDataGeneration += 1
    }

    /// Cancel any in-flight comparison, clear the installed result + arrows,
    /// and reset the calculating flag. Coordination enable/scale changes go
    /// through `cancelCoordinationRequest` and must NOT touch this — the two
    /// lifecycles are independent. `render` controls whether a single
    /// setNeedsRender is issued (user Clear) or suppressed (geometry paths
    /// that render later anyway). The generation is bumped on every call so a
    /// stale background completion can never install.
    ///
    /// Always resets the auxiliary comparisonPanel placeholder (even for
    /// render-suppressed geometry invalidations) so the panel never shows
    /// stale metrics after a coordinate/supercell/slab/frame change. The
    /// `showComparisonArrows` reset is wrapped in the `isSyncingState` guard
    /// so its `didSet` → `onChange` → `syncFromState` fires into the early
    /// return instead of triggering a nested sync/render.
    private func invalidateComparisonRequest(render: Bool) {
        comparisonGeneration += 1
        comparisonCancellationToken?.cancel()
        comparisonCancellationToken = nil
        comparisonWorkItem?.cancel()
        comparisonWorkItem = nil
        comparisonResult = nil
        comparisonReferenceTitle = nil
        state.comparisonStatusText = ""
        state.comparisonCalculating = false
        renderer?.displacementArrows = []
        renderer?.showDisplacementArrows = false
        // Always reset the arrow-toggle default. Wrap in isSyncingState so the
        // published didSet callback returns early in syncFromState instead of
        // triggering a nested sync/render.
        let wasSyncingState = isSyncingState
        isSyncingState = true
        state.showComparisonArrows = false
        isSyncingState = wasSyncingState
        // Always refresh the auxiliary panel placeholder so it never shows
        // stale metrics, regardless of whether this invalidation renders.
        if let window = comparisonWindow, window.isVisible {
            comparisonPanel.update(referenceTitle: "—",
                                   result: StructureComparisonResult(
                                       matches: [], unmatchedSourceIndices: [],
                                       unmatchedTargetIndices: [],
                                       rmsDisplacement: nil, meanDisplacement: nil,
                                       maxDisplacement: nil, perElement: [],
                                       maxMatchDistance: StructureComparator.defaultMaxMatchDistance,
                                       isComplete: true))
        }
        if render {
            setNeedsRender()
        }
    }

    /// Cancel any in-flight polyhedron analysis, bump its generation so the
    /// stale completion is discarded, and clear the token. Independent of the
    /// coordination token so polyhedron cancellation cannot disturb coordination.
    private func cancelPolyhedronRequest() {
        polyhedronGeneration += 1
        polyhedronCancellationToken?.cancel()
        polyhedronCancellationToken = nil
        polyhedronWorkItem?.cancel()
        polyhedronWorkItem = nil
    }

    private func startCoordinationAnalysis(debounced: Bool) {
        cancelCoordinationRequest()
        coordinationGeneration += 1
        let generation = coordinationGeneration
        let token = CoordinationCancellationToken()
        coordinationCancellationToken = token
        coordinationAnalysis = nil
        clearCoordinationNumbers()
        // A restart supersedes any previous polyhedron metrics derived from the
        // old coordination result; clear them so the readouts never show stale
        // values while the new analysis is in flight.
        cancelPolyhedronRequest()
        clearPolyhedronMetrics()
        state.coordinationAnalysisAvailable = false
        state.coordinationStatusText = scene.atoms.isEmpty ? "Unavailable" : "Calculating…"
        state.coordinationSummaryText = scene.atoms.isEmpty ? "No atoms" : ""
        guard !scene.atoms.isEmpty else {
            token.cancel()
            coordinationCancellationToken = nil
            coordinationAnalysisDidUpdate?()
            return
        }

        let atoms = scene.atoms
        let cell = effectiveCoordinationCell(for: scene)
        let periodicDim = scene.periodicDim
        let scale = state.coordinationRadiusScale
        let slab = scene.slab
        let override = coordinationAnalyzerOverride

        let launch = { [weak self, weak token] in
            guard let self, let token,
                  self.coordinationGeneration == generation,
                  self.coordinationCancellationToken === token,
                  !token.isCancelled() else { return }
            self.launchCoordinationAnalysis(generation: generation, token: token,
                                            atoms: atoms, cell: cell, periodicDim: periodicDim,
                                            scale: scale, slab: slab, override: override)
        }

        if debounced {
            coordinationDebounceCancellation = coordinationDebounceScheduler(0.20, launch)
        } else {
            launch()
        }
    }

    private func launchCoordinationAnalysis(
        generation: Int,
        token: CoordinationCancellationToken,
        atoms: [Atom],
        cell: Cell?,
        periodicDim: Int,
        scale: Float,
        slab: Slab?,
        override: CoordinationAnalyzerOverride?
    ) {
        guard !token.isCancelled() else { return }
        coordinationDebounceCancellation = nil
        let work = DispatchWorkItem { [weak self] in
            guard !token.isCancelled() else { return }
            let result: CoordinationAnalysis?
            if let override {
                result = override(atoms, cell, periodicDim, scale, token.isCancelled)
            } else {
                result = CoordinationAnalyzer.analyze(atoms: atoms, cell: cell,
                                                       periodicDim: periodicDim,
                                                       radiusScale: scale,
                                                       isCancelled: token.isCancelled)
            }
            guard !token.isCancelled() else { return }
            DispatchQueue.main.async { [weak self] in
                guard !token.isCancelled() else { return }
                self?.installCoordinationAnalysis(result, generation: generation,
                                                  token: token, atoms: atoms, cell: cell,
                                                  periodicDim: periodicDim, scale: scale,
                                                  slab: slab)
            }
        }
        coordinationWorkItem = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func installCoordinationAnalysis(_ result: CoordinationAnalysis?,
                                             generation: Int,
                                             token: CoordinationCancellationToken,
                                             atoms: [Atom], cell: Cell?,
                                             periodicDim: Int, scale: Float,
                                             slab: Slab?) {
        guard generation == coordinationGeneration,
              coordinationCancellationToken === token,
              !token.isCancelled(),
              state.coordinationEnabled,
              state.coordinationRadiusScale == scale,
              scene.atoms == atoms,
              scene.periodicDim == periodicDim,
              scene.slab == slab,
              cellsEqual(effectiveCoordinationCell(for: scene), cell) else { return }

        guard let result else {
            finishCoordinationUnavailable(summary: "No complete coordination result")
            return
        }
        let numbers = result.coordinationNumbers
        guard numbers.count == atoms.count, !atoms.isEmpty,
              numbers.allSatisfy({ $0 >= 0 }) else {
            finishCoordinationUnavailable(summary: "No complete coordination result")
            return
        }

        coordinationAnalysis = result
        state.coordinationAnalysisAvailable = true
        state.coordinationStatusText = "Ready"
        let lo = numbers.min() ?? 0
        let hi = numbers.max() ?? 0
        state.coordinationSummaryText = "Atoms: \(numbers.count); coordination range: \(lo)…\(hi)"
        installCoordinationNumbers(numbers)
        coordinationWorkItem = nil
        coordinationCancellationToken = nil
        setNeedsRender()

        // Derive distribution analysis on a background work item so the main
        // thread is not blocked by the O(27·n²) RDF enumeration or the
        // O(n·k²) bond-angle sweep. Each request gets a generation token so
        // stale results from a superseded request are discarded.
        cancelDistributionRequest()
        distributionGeneration += 1
        let distGeneration = distributionGeneration
        let distToken = CoordinationCancellationToken()
        distributionCancellationToken = distToken
        let distAtoms = scene.atoms
        // Use the effective (widened) coordination cell so that volume,
        // density, and minimum-image periodicity are consistent with the
        // coordination analysis that produced the neighbor records.
        let distCell = effectiveCoordinationCell(for: scene)
        let distPeriodicDim = scene.periodicDim
        let distResult = result
        let work = DispatchWorkItem {
            guard !distToken.isCancelled() else { return }
            let dist = DistributionAnalyzer.analyze(distResult, atoms: distAtoms,
                                                     cell: distCell,
                                                     periodicDim: distPeriodicDim,
                                                     isCancelled: distToken.isCancelled)
            guard !distToken.isCancelled() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard !distToken.isCancelled(),
                      self.distributionGeneration == distGeneration,
                      self.distributionCancellationToken === distToken else { return }
                if let dist {
                    self.distributionAnalysis = dist
                    self.state.distributionAnalysis = dist
                    self.state.distributionAnalysisAvailable = true
                } else {
                    self.distributionAnalysis = nil
                    self.state.distributionAnalysis = nil
                    self.state.distributionAnalysisAvailable = false
                }
                self.distributionWorkItem = nil
                self.distributionCancellationToken = nil
                self.setNeedsRender()
            }
        }
        distributionWorkItem = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)

        // Derive first-shell polyhedron metrics on a background work item too.
        // The hull volume enumeration is O(n⁴) per atom, bounded to the first
        // shell (≤ 24 neighbors) and 4,096 atoms, so it must never run on the
        // main thread. Stale results from superseded requests are discarded via
        // the generation token, exactly like the distribution analysis.
        cancelPolyhedronRequest()
        let polyGeneration = polyhedronGeneration
        let polyToken = CoordinationCancellationToken()
        polyhedronCancellationToken = polyToken
        let polyAtoms = scene.atoms
        let polyResult = result
        // Capture the token locally; the background work reads only this
        // capture (never polyhedronGeneration) and never retains self.
        let polyTokenLocal = polyToken
        let polyWork = DispatchWorkItem {
            let metrics = PolyhedronAnalyzer.analyze(
                analysis: polyResult, atoms: polyAtoms,
                isCancelled: { polyTokenLocal.isCancelled() })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.polyhedronGeneration == polyGeneration else { return }
                self.polyhedronWorkItem = nil
                self.polyhedronCancellationToken = nil
                guard let metrics, metrics.count == self.scene.atoms.count else {
                    // Analysis returned nil (over-cap or current nil): show an
                    // explicit unavailable reason so the metrics-table button
                    // stays reachable.
                    self.polyhedronMetrics = nil
                    let reason: String
                    if polyAtoms.count > PolyhedronAnalyzer.maxAtoms {
                        reason = "structure exceeds the \(PolyhedronAnalyzer.maxAtoms)-atom cap"
                    } else {
                        reason = "coordination analysis produced no result"
                    }
                    self.state.polyhedronSummaryText = "Polyhedron metrics unavailable: " + reason + "."
                    self.updatePolyhedronTable()
                    self.polyhedronAnalysisDidUpdate?()
                    return
                }
                self.polyhedronMetrics = metrics
                self.state.polyhedronSummaryText = Self.polyhedronSummary(metrics: metrics)
                self.updatePolyhedronTable()
                self.polyhedronAnalysisDidUpdate?()
            }
        }
        polyhedronWorkItem = polyWork
        DispatchQueue.global(qos: .userInitiated).async(execute: polyWork)

        coordinationAnalysisDidUpdate?()
    }

    private func finishCoordinationUnavailable(summary: String) {
        coordinationCancellationToken?.cancel()
        coordinationCancellationToken = nil
        coordinationWorkItem = nil
        cancelDistributionRequest()
        distributionGeneration += 1
        cancelPolyhedronRequest()
        coordinationAnalysis = nil
        distributionAnalysis = nil
        state.distributionAnalysis = nil
        state.distributionAnalysisAvailable = false
        clearPolyhedronMetrics()
        clearCoordinationNumbers()
        state.coordinationAnalysisAvailable = false
        state.coordinationStatusText = "Unavailable"
        state.coordinationSummaryText = summary
        coordinationAnalysisDidUpdate?()
    }

    private func clearCoordinationAnalysis(status: String, summary: String) {
        cancelCoordinationRequest()
        coordinationGeneration += 1
        distributionGeneration += 1
        cancelPolyhedronRequest()
        coordinationAnalysis = nil
        distributionAnalysis = nil
        state.distributionAnalysis = nil
        state.distributionAnalysisAvailable = false
        clearPolyhedronMetrics()
        clearCoordinationNumbers()
        state.coordinationAnalysisAvailable = false
        state.coordinationStatusText = status
        state.coordinationSummaryText = summary
        coordinationAnalysisDidUpdate?()
    }

    /// Drop the derived polyhedron metrics and their sidebar/table readouts.
    private func clearPolyhedronMetrics() {
        polyhedronMetrics = nil
        state.polyhedronSummaryText = ""
        if let window = polyhedronTableWindow, window.isVisible {
            polyhedronTable.update(atoms: scene.atoms, metrics: nil)
        }
    }

    /// Human-readable summary of the per-atom polyhedron metrics. Means are
    /// computed in Double with finite guards. When a completed analysis yields
    /// a non-empty metrics array but no atom has an available first-shell
    /// polyhedra, an explicit message is returned so the metrics-table button
    /// remains reachable rather than showing a blank section.
    private static func polyhedronSummary(metrics: [PolyhedronMetrics]) -> String {
        let volumes = metrics.compactMap { $0.volume }
        let distortions = metrics.compactMap { $0.bondLengthDistortion }
        let angles = metrics.compactMap { $0.angleDeviation }
        var parts: [String] = []
        if !volumes.isEmpty {
            let mean = volumes.reduce(0.0) { Double($0) + Double($1) } / Double(volumes.count)
            if mean.isFinite {
                parts.append(String(format: "Mean polyhedron volume: %.3f Å³", mean))
            }
        }
        if !distortions.isEmpty {
            let mean = distortions.reduce(0.0) { Double($0) + Double($1) } / Double(distortions.count)
            if mean.isFinite {
                parts.append(String(format: "Mean bond-length distortion: %.4f", mean))
            }
        }
        if !angles.isEmpty {
            let mean = angles.reduce(0.0) { Double($0) + Double($1) } / Double(angles.count)
            if mean.isFinite {
                parts.append(String(format: "Mean angle deviation: %.2f°", mean))
            }
        }
        if parts.isEmpty {
            // Completed analysis but no available first-shell polyhedra.
            return "No first-shell polyhedra available for these atoms."
        }
        return parts.joined(separator: "\n")
    }

    private func cellsEqual(_ lhs: Cell?, _ rhs: Cell?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l.a == r.a && l.b == r.b && l.c == r.c
        default: return false
        }
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

    /// Import a k-path from `url` and install it as the current route. Requires a
    /// crystal structure (a cell) so the route's reciprocal basis is meaningful.
    /// The imported route is marked user-edited (signature cleared) so it is never
    /// auto-regenerated when the structure changes.
    func importKPath(from url: URL) throws {
        guard scene.cell != nil else {
            throw KPathImportError.notAPath(path: url.path, reason: "k-path import requires a crystal structure")
        }
        let imported = try KPathImport.importKPath(from: url)
        let path = imported.path
        // Update the scene first, then publish the sidebar route as one snapshot.
        // Otherwise kPathPoints.didSet synchronously re-enters syncFromState with
        // the previous break set and can briefly pair new points with old breaks.
        scene.kPathPoints = path.points
        scene.kPathBreaks = path.breaks
        scene.kPathProvenance = .userEdited
        scene.kPathSignature = nil
        state.importKPath(points: path.points, breaks: path.breaks)
        // Propagate the imported sampling density only for VASP, which carries an
        // explicit per-segment count; QE/Wannier90/KPF synthesize 20 and must not
        // clobber the existing preference. Clamp to the UI range 2...200; kPathSampling
        // has no didSet onChange, so this does not re-enter syncFromState.
        if imported.format == .vasp {
            state.kPathSampling = min(200, max(2, path.pointsPerSegment))
        }
    }

    /// Present an open panel for choosing a background image. On OK, sets
    /// state.backgroundImagePath and state.backgroundType = .image so the
    /// normal onChange propagation applies it to the scene.
    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            self.state.backgroundImagePath = url.path
            self.state.backgroundType = .image
        }
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
        // Capture the active cell when the save action starts. tpiba_b is a
        // Cartesian reciprocal export, so it must not accidentally use a cell
        // from a later-loaded scene if the save sheet remains open.
        let activeCell = scene.cell
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.defaultFilename
        panel.allowedContentTypes = format == .vasp ? [] : [.plainText]
        if format == .vasp { panel.allowsOtherFileTypes = true }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let text = try KPathExport.export(path, as: format, cell: activeCell)
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

    /// Present an import-failure alert as a sheet on the main window.
    private func presentImportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "k-path import failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Capture the live scene, camera, and current source URL and persist the
    /// view-state to `url` via StateStore. Wired to AppDelegate save actions.
    /// The band-surface plot's live rotation is snapshotted into the scene first
    /// so the saved state restores the exact interactive view (WYSIWYG).
    @MainActor
    internal func saveState(to url: URL) throws {
        var snapshot = scene
        snapshot.bandSurfaceOrientation = BandSurfaceOrientation(
            azimuthDegrees: bandSurfaceView.azimuthDegrees,
            elevationDegrees: bandSurfaceView.elevationDegrees)
        try StateStore.save(snapshot, camera: camera, sourceURL: sourceURL, to: url,
                            kPathSampling: state.kPathSampling,
                            cameraBookmarks: cameraBookmarks)
    }

    /// The loaded source is needed by file actions to protect it from overwrite.
    @MainActor
    internal var currentSourceURL: URL? { sourceURL }

    /// Build the renderer options for the layer currently visible in the viewport.
    /// Coordination data is only exportable while a complete, current analysis is
    /// installed for the displayed atom ordering.
    internal var currentRenderExportOptions: RenderExportOptions {
        let metalCanvasVisible = !canvas.isHidden
        let labels = metalCanvasVisible ? labelOverlay.labels.filter(\.isExportable) : []
        return makeRenderExportOptions(labels: labels, metalCanvasVisible: metalCanvasVisible)
    }

    private func makeRenderExportOptions(labels: [LabelOverlayView.Label],
                                         metalCanvasVisible: Bool) -> RenderExportOptions {
        let exportCoordinationNumbers = metalCanvasVisible
            && state.coordinationAnalysisAvailable
            && coordinationAnalysis != nil
            && installedCoordinationNumbers.count == scene.atoms.count
            ? installedCoordinationNumbers : []
        let selectedRouteNode = metalCanvasVisible && scene.isCrystal && scene.showBrillouinZone
            ? (selectedRouteNodeIndex ?? renderer?.selectedKPathNode).flatMap { index in
                let renderedCount = min(scene.kPathPoints.count, 1024)
                return index >= 0 && index < renderedCount ? index : nil
            }
            : nil
        // Displacement arrows export only when the Metal canvas is visible,
        // a comparison result is installed, and the user has toggled arrows
        // on — and only when the computed arrow list is actually nonempty.
        let arrows: [(start: SIMD3<Float>, vector: SIMD3<Float>)]
        let showArrows: Bool
        if metalCanvasVisible && state.showComparisonArrows && comparisonResult != nil {
            let computed = currentDisplacementArrows()
            arrows = computed
            showArrows = !computed.isEmpty
        } else {
            arrows = []
            showArrows = false
        }
        return RenderExportOptions(labels: labels,
                                   showBZLandmarks: metalCanvasVisible && state.editKPathOnBZ && scene.isCrystal,
                                   coordinationNumbers: exportCoordinationNumbers,
                                   showCoordinationColors: metalCanvasVisible
                                       && !exportCoordinationNumbers.isEmpty
                                       && state.showCoordinationColors,
                                   selectedKPathNode: selectedRouteNode,
                                   displacementArrows: arrows,
                                   showDisplacementArrows: showArrows)
    }

    /// Build the renderer's displacement arrows from the active comparison and
    /// the current scene atom positions, independent of any live renderer.
    /// Mirrors `updateDisplacementArrows()` so export can compute arrows even
    /// when the live renderer is unavailable.
    private func currentDisplacementArrows() -> [(start: SIMD3<Float>, vector: SIMD3<Float>)] {
        guard let result = comparisonResult else { return [] }
        let atoms = scene.atoms
        return result.matches.compactMap { match in
            guard match.sourceIndex >= 0, match.sourceIndex < atoms.count else { return nil }
            let start = atoms[match.sourceIndex].coord
            guard start.isFinite, match.displacement.isFinite else { return nil }
            return (start: start, vector: match.displacement)
        }
    }

    /// Build export options with labels projected for the requested output size,
    /// rather than reusing positions from the live canvas.
    internal func exportRenderOptions(for size: CGSize) throws -> RenderExportOptions {
        let validated = try App.validatedExportSize(size)
        let metalCanvasVisible = !canvas.isHidden
        guard metalCanvasVisible else {
            return makeRenderExportOptions(labels: [], metalCanvasVisible: false)
        }
        // App.validatedExportSize bounds the dimensions before these conversions;
        // the resulting Int values are finite and safely representable as Float.
        let viewport = SIMD2<Float>(Float(validated.width), Float(validated.height))
        let labels = persistentLabels(viewport: viewport, camera: renderCamera())
        return makeRenderExportOptions(labels: labels, metalCanvasVisible: true)
    }

    /// Export the layer currently displayed in the viewport. Graph and color-plane
    /// payloads hidden by the view state must not supersede the Metal canvas.
    @MainActor
    @discardableResult
    internal func exportCurrentView(to url: URL, size: CGSize, options: ExportOptions? = nil) throws -> CGImage {
        let renderOptions = try exportRenderOptions(for: size)
        var visibleScene = scene
        if linkedGraphs.isHidden || !linkedGraphs.dosPresent { visibleScene.densityOfStates = nil }
        if linkedGraphs.isHidden || !linkedGraphs.bandPresent { visibleScene.bandStructure = nil }
        if bandSurfaceView.isHidden || !scene.showBandSurface { visibleScene.bandSurface = nil }
        if !bandSurfaceView.isHidden, scene.showBandSurface {
            visibleScene.bandSurfaceOrientation = BandSurfaceOrientation(
                azimuthDegrees: bandSurfaceView.azimuthDegrees,
                elevationDegrees: bandSurfaceView.elevationDegrees)
        }
        // The color plane is now drawn by the renderer in the Metal scene, so the
        // exported scene keeps grid2D intact (the renderer gates on showColorPlane).
        // Apply export options: if the caller passes explicit options, use them;
        // otherwise render with the scene's own background (preserving gradients).
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

    /// Compute the region integral for the current sidebar region inputs and
    /// write the summary (or an error) back into the sidebar state. Guards
    /// against recomputing when the inputs are unchanged from the last call.
    func recomputeRegionIntegration() {
        let stateRef = state
        // Guard: skip when no field is present.
        guard let field = scene.scalarField else {
            state.regionResultSummary = ""
            state.regionComputeError = nil
            return
        }
        let shape = state.regionShape
        let center = state.regionCenter
        let halfExtents = state.regionHalfExtents
        let radius = state.regionRadius
        // Guard: only recompute when the region inputs actually changed. The
        // first call always computes so the sidebar shows an initial readout.
        if hasComputedRegion && shape == lastRegionShape && center == lastRegionCenter
            && halfExtents == lastRegionHalfExtents && radius == lastRegionRadius {
            return
        }
        hasComputedRegion = true
        lastRegionShape = shape
        lastRegionCenter = center
        lastRegionHalfExtents = halfExtents
        lastRegionRadius = radius
        let region = IntegrationRegion(shape: shape, center: center,
                                        halfExtents: halfExtents, radius: radius)
        if let result = RegionIntegration.integrate(field: field, region: region) {
            state.regionResultSummary = result.summary
            state.regionComputeError = nil
        } else {
            state.regionResultSummary = ""
            state.regionComputeError = "No samples in region"
        }
    }

    /// Compute the whole-field integral (RegionIntegration.integrateAll) and
    /// write the summary into the sidebar state. No-op when no field is present.
    func computeWholeFieldIntegration() {
        guard let field = scene.scalarField else {
            state.regionWholeFieldSummary = ""
            return
        }
        if let result = RegionIntegration.integrateAll(field: field) {
            state.regionWholeFieldSummary = "Whole field: " + result.summary
        } else {
            state.regionWholeFieldSummary = "Whole field: no samples"
        }
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
    /// Last-computed region integration inputs, used to guard against redundant
    /// recomputation when the sidebar fires onChange for unrelated reasons.
    private var lastRegionShape: RegionShape = .box
    private var lastRegionCenter: SIMD3<Float> = .zero
    private var lastRegionHalfExtents: SIMD3<Float> = SIMD3<Float>(2, 2, 2)
    private var lastRegionRadius: Float = 2
    private var hasComputedRegion = false

    /// Decode AXSF frame `index` and swap it into the current scene, preserving
    /// the camera and all UI-controllable state (display mode, scales, lighting,
    /// background, supercell, slab, show flags). Each frame is parsed fresh
    /// from sourceURL via Parser.load(frameIndex:).
    private func reloadFrame(_ index: Int) {
        guard let url = sourceURL else { return }
        let wasReciprocalEditing = state.editKPathOnBZ || lastEditKPathOnBZ
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
        // When trajectory alignment is on, substitute the centroid-aligned atom
        // coordinates for this frame (applied before supercell/slab so the
        // expanded structure stays aligned). Other Scene fields come from the
        // freshly parsed frame below.
        if state.alignTrajectory, let aligned = alignedFrames, aligned.indices.contains(index) {
            next.atoms = aligned[index].atoms
        }
        let restoredDisplayMode = wasReciprocalEditing
            ? (reciprocalStructureDisplayMode ?? scene.displayMode)
            : scene.displayMode
        let restoredShowBZ = wasReciprocalEditing
            ? (reciprocalStructureShowBZ ?? scene.showBrillouinZone)
            : scene.showBrillouinZone
        let restoredOrthographic = wasReciprocalEditing
            ? (reciprocalStructureOrthographic ?? state.orthographic)
            : state.orthographic
        // Carry every appearance/display/quality setting from the previous
        // frame so scrubbing never silently resets the view. This replaces a
        // hand-maintained field list that silently drifted out of sync with
        // Scene. hbondPairs are NOT carried — they index the previous frame's
        // atoms — they are re-derived after install via hbondGeometryDidChange.
        next.adoptAppearance(from: scene)
        // adoptAppearance copies displayMode/showBrillouinZone from the old
        // frame; restore the reciprocal-editing overrides on top when active.
        next.displayMode = restoredDisplayMode
        next.showBrillouinZone = restoredShowBZ
        // Lighting + background are read from the live sidebar (the source of
        // truth), not the old frame the adopt call just copied.
        next.lighting = state.lighting
        next.backgroundType = state.backgroundType
        next.background = state.backgroundHex
        next.backgroundBottom = state.backgroundBottomHex
        // The freshly parsed scene already owns the right generated route for
        // its current structure/input reciprocal basis.  Transfer only a user
        // route, remapping fractional coordinates through Cartesian reciprocal
        // space when this frame changed that basis.  (Supercell/slab are applied
        // later and intentionally do not affect this base-cell decision.)
        next.transferKPathAcrossGeometryChange(from: scene)
        // Re-apply the CLI electronic-structure display flags (--bands/--dos/--band-surf)
        // to the freshly parsed frame so derived data survives frame changes.
        applyElectronicStructureFlags(to: &next)
        // The freshly parsed frame may carry a scalar field whose value range differs
        // from the frame we carried the level over (e.g. animated XSF). Clamp the
        // carried level into the new field's range so it stays meaningful; when the
        // level already fits, its value and iso-surface visibility both pass through
        // unchanged. With a no-field frame the level is inert (the renderer gates on
        // scalarField), so leave it untouched.
        if let field = next.scalarField {
            next.isoLevel = min(field.maxValue, max(field.minValue, next.isoLevel))
        }
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
        if wasReciprocalEditing {
            // A reciprocal editor camera is tied to the old frame's BZ. Leave the
            // replacement in its normal structure framing instead of carrying it.
            next.camera = next.defaultCamera()
            next.camera.perspective = !restoredOrthographic
        } else {
            next.camera = camera
        }
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
        if wasReciprocalEditing {
            state.editKPathOnBZ = false
            state.displayMode = restoredDisplayMode
            state.showBrillouinZone = restoredShowBZ
            state.orthographic = restoredOrthographic
        }
        state.clearReciprocalEditorStatus()
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
        state.refreshKPathMetrics(for: next.cell)
        // The frame's route replaced the previous one wholesale; clear any stale
        // node highlight (the held isSyncingState guard fences syncFromState from
        // detecting the generation bump here, so clear directly and resync the token).
        renderer?.selectedKPathNode = nil
        renderer2D?.selectedKPathNode = nil
        selectedRouteNodeIndex = nil
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
        reciprocalStructureCamera = nil
        reciprocalStructureDisplayMode = nil
        reciprocalStructureShowBZ = nil
        reciprocalStructureOrthographic = nil
        reciprocalHoverCandidate = nil
        reciprocalHoverCursor = nil
        selectedRouteNodeIndex = nil
        lastEditKPathOnBZ = false
        renderer?.showBZLandmarks = false
        canvas.invalidateReciprocalAccessibilityFocus()
        loadGeneration += 1   // cancel any pending background drop loads
        self.scene = next
        // Refresh the graph views so the reloaded frame reflects the electronic-structure
        // flags (bands/DOS/band-surface) carried over from the previous frame.
        bandGrapher.bandStructure = next.bandStructure
        bandGrapher.highSymmetryIndices = next.bandStructure.map { bs in
            bs.kPoints.indices.filter { !bs.kPoints[$0].label.isEmpty }
        } ?? []
        dosGrapher.densityOfStates = next.densityOfStates
        linkedGraphs.bandView.bandStructure = next.bandStructure
        linkedGraphs.dosView.densityOfStates = next.densityOfStates
        bandSurfaceView.bandSurface = next.bandSurface
        state.electronicStructureEnabled = next.bandStructure != nil || next.densityOfStates != nil || next.bandSurface != nil
        if let mesh = next.bandStructure, mesh.isMesh, next.bandSurface != nil {
            state.bandSurfaceCandidates = BandSurfaceBuilder.bandInfos(mesh,
                                                                       bandOffset: next.bandSurface?.bandOffset ?? 0)
        }
        lastBandSurfaceBuildKey = nil
        rebuildBandSurface()
        bzEpoch += 1   // freshly parsed frame: cell/baseAtoms may differ, rebuild the editor BZ
        if wasReciprocalEditing {
            camera = scene.defaultCamera()
            camera.perspective = !restoredOrthographic
            scene.camera = camera
        }
        refreshStandardCrystalViewAvailability()
        // The color-plane is now drawn by the renderer in the Metal scene; frame
        // reloads update scene.grid2D which the renderer reads directly.
        updateContentVisibility()
        // A frame reload replaces the displayed atom ordering, invalidating any
        // installed two-structure comparison. This path renders later, so
        // suppress the invalidation render.
        invalidateComparisonRequest(render: false)
        coordinationGeometryDidChange()
        // The frame's atom set replaced the previous one: the carried settings are
        // already in `scene`, so mirror them back to the sidebar (a no-op in the
        // steady state) and re-derive the H-bond pairs for the new coordinates.
        mirrorTier1AppearanceToState(from: scene)
        hbondGeometryDidChange()
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
    func startPlayback() {
        stopPlayback()
        let clamped = min(20.0, max(0.1, state.playbackSpeed))
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.1 / Double(clamped), repeats: true) { [weak self] _ in
            guard let self else { return }
            if let next = SideBarState.nextFrame(after: self.state.frameIndex,
                                                count: self.state.frameCount,
                                                loop: self.state.loopPlayback) {
                self.state.frameIndex = next
            } else {
                self.state.isPlaying = false
            }
        }
    }

    func stopPlayback() {
        playTimer?.invalidate()
        playTimer = nil
    }

    /// True while a playback timer is installed and not yet invalidated. Test
    /// seam for playback-lifecycle assertions.
    var hasActivePlayTimer: Bool { playTimer != nil }

    /// Clamp `index` into the valid frame range and jump to it. Mirrors the
    /// sidebar Prev/Next buttons, which simply assign `state.frameIndex`; the
    /// resulting `onChange` → `syncFromState` → `reloadFrame` advances the scene.
    func seekToFrame(_ index: Int) {
        guard state.frameCount > 0 else { return }
        let clamped = min(max(0, index), state.frameCount - 1)
        state.frameIndex = clamped
    }

    /// Pure interval math for the playback timer, exposed for testing. 10 Hz
    /// scaled by `speed`, clamped to the 0.1...20 defensive range.
    static func playbackInterval(speed: Float) -> TimeInterval {
        let clamped = min(20.0, max(0.1, Double(speed)))
        return 0.1 / clamped
    }

    // MARK: - Animation timeline + per-frame metrics

    /// Decode every frame of the current animation from sourceURL via Parser.
    /// Returns nil when there is no multi-frame source or any frame fails to load.
    private func loadAllFrames() -> [Scene]? {
        guard let url = sourceURL, state.frameCount > 1 else { return nil }
        let count = state.frameCount
        guard count <= AnimationExporter.maxFrameCount else { return nil }
        var frames: [Scene] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            guard let loaded = try? Parser.load(url, frameIndex: i, as: forcedFormat) else {
                return nil
            }
            frames.append(Scene(loaded: loaded))
        }
        return frames
    }

    /// Pure snapshot-based frame decode for background use. Takes the source
    /// URL, frame count, and format as explicit parameters so the caller can
    /// snapshot them on the main thread before dispatching — never reads
    /// instance state (sourceURL / state.frameCount / forcedFormat) directly.
    private static func loadAllFrames(from url: URL, count: Int, format: ParseFormat?) -> [Scene]? {
        guard count > 1, count <= AnimationExporter.maxFrameCount else { return nil }
        var frames: [Scene] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            guard let loaded = try? Parser.load(url, frameIndex: i, as: format) else {
                return nil
            }
            frames.append(Scene(loaded: loaded))
        }
        return frames
    }

    /// Flatten each atom's per-frame coordinates into a line-strip vertex array:
    /// for atom k the strip is [frame0.coord, frame1.coord, ...], concatenated
    /// for every atom index. Empty when frames have differing atom counts.
    /// Pure function of `frames` — safe to call from any thread.
    private static func trajectoryTrailVertices(frames: [Scene]) -> [SIMD3<Float>] {
        guard let atomCount = frames.first?.atoms.count, atomCount > 0,
              frames.allSatisfy({ $0.atoms.count == atomCount }) else { return [] }
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(atomCount * frames.count)
        for k in 0..<atomCount {
            for frame in frames {
                verts.append(frame.atoms[k].coord)
            }
        }
        return verts
    }

    /// Build timeline thumbnails and per-frame metrics for the current
    /// multi-frame source on a background queue, then publish on main. Cached by
    /// sourceURL + frameCount; stale generations are discarded by token.
    private func refreshAnimationData() {
        guard let url = sourceURL, state.frameCount > 1 else {
            cancelAnimationDataRequest()
            let generation = animationDataGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.animationDataGeneration == generation,
                      (!self.state.timelineThumbnails.isEmpty || !self.state.frameMetrics.isEmpty) else { return }
                self.state.setTimelineThumbnails([])
                self.state.frameMetrics = []
                self.state.trajectoryTrailsAvailable = false
            }
            return
        }
        let key = (url: url, count: state.frameCount)
        if let existing = lastAnimationDataKey, existing == key { return }
        lastAnimationDataKey = key

        cancelAnimationDataRequest()
        let token = animationDataGeneration
        let cancellationToken = CoordinationCancellationToken()
        animationDataCancellationToken = cancellationToken
        let thumbSize = CGSize(width: 128, height: 96)
        // Snapshot ALL main-thread inputs before dispatch so the background
        // closure never touches self.state / self.camera off the main thread.
        let cam = camera
        let showTrails = state.showTrajectoryTrails
        let count = state.frameCount
        let format = forcedFormat
        DispatchQueue.global(qos: .userInitiated).async {
            guard !cancellationToken.isCancelled() else { return }
            guard let frames = Self.loadAllFrames(from: url, count: count, format: format) else {
                return
            }
            var images: [CGImage] = []
            var metrics: [FrameMetric] = []
            var trails: [SIMD3<Float>] = []
            var ok = true
            do {
                images = try TimelineThumbnails.render(frames: frames, camera: cam, size: thumbSize)
            } catch {
                ok = false
            }
            if ok {
                metrics = FrameMetrics.compute(frames: frames)
                if showTrails && !cancellationToken.isCancelled() {
                    trails = Self.trajectoryTrailVertices(frames: frames)
                }
            }
            guard !cancellationToken.isCancelled() else { return }
            DispatchQueue.main.async { [weak self] in
                // Re-check the token ON THE MAIN THREAD: a generation bump between
                // the background read and this block must discard stale data.
                guard let self, !cancellationToken.isCancelled(),
                      self.animationDataGeneration == token,
                      self.animationDataCancellationToken === cancellationToken else { return }
                self.state.setTimelineThumbnails(images)
                self.state.frameMetrics = metrics
                if self.state.showTrajectoryTrails {
                    self.state.trajectoryTrailsAvailable = true
                    self.renderer?.trajectoryTrails = trails
                }
                self.animationDataCancellationToken = nil
            }
        }
    }

    /// Load all frames, centroid-align them to frame 0, and cache the result in
    /// `alignedFrames`. Then reload the currently-displayed frame so the aligned
    /// coordinates take effect immediately. No-op (leaving the cache nil) when
    /// there is no multi-frame source.
    private func refreshAlignedFrames() {
        guard let url = sourceURL, state.frameCount > 1 else {
            alignedFrames = nil
            return
        }
        guard let frames = loadAllFrames() else {
            alignedFrames = nil
            return
        }
        alignedFrames = FrameMetrics.alignCentroid(frames: frames, to: 0)
        // Take effect on the currently displayed frame without disturbing playback.
        reloadFrame(state.frameIndex)
    }

    /// Recompute the trajectory-trail strip and push it to the renderer. Called
    /// when the user toggles the trail overlay on. Uses the centroid-aligned
    /// frames when alignment is on, so trails and alignment compose.
    private func refreshTrajectoryTrails() {
        guard state.showTrajectoryTrails else {
            renderer?.showTrajectoryTrails = false
            return
        }
        guard let url = sourceURL, state.frameCount > 1 else { return }
        if state.trajectoryTrailsAvailable {
            renderer?.showTrajectoryTrails = true
            return
        }
        cancelAnimationDataRequest()
        let token = animationDataGeneration
        let cancellationToken = CoordinationCancellationToken()
        animationDataCancellationToken = cancellationToken
        // Snapshot ALL main-thread inputs before dispatch. alignedFrames is
        // main-thread-owned; reading it off-main is a race, so capture it (or
        // nil) here. When nil, the background path decodes from the snapshots.
        let prealigned = state.alignTrajectory ? alignedFrames : nil
        let count = state.frameCount
        let format = forcedFormat
        DispatchQueue.global(qos: .userInitiated).async {
            guard !cancellationToken.isCancelled() else { return }
            guard let frames = prealigned ?? Self.loadAllFrames(from: url, count: count, format: format) else {
                return
            }
            let trails = Self.trajectoryTrailVertices(frames: frames)
            guard !cancellationToken.isCancelled() else { return }
            DispatchQueue.main.async { [weak self] in
                // Re-check the token ON THE MAIN THREAD: a generation bump between
                // the background read and this block must discard stale data.
                guard let self, !cancellationToken.isCancelled(),
                      self.animationDataGeneration == token,
                      self.animationDataCancellationToken === cancellationToken else { return }
                guard self.state.showTrajectoryTrails else {
                    self.animationDataCancellationToken = nil
                    return
                }
                self.state.trajectoryTrailsAvailable = true
                self.renderer?.trajectoryTrails = trails
                self.renderer?.showTrajectoryTrails = true
                self.animationDataCancellationToken = nil
            }
        }
    }

    private func exportFrameMetricsCSV(_ csv: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "frame_metrics.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { print("[mcrysden] frame metrics CSV export failed: \(error)") }
        }
    }

    private func exportAnimation(to url: URL) {
        let ext = url.pathExtension.lowercased()
        let format: AnimationExportFormat
        switch ext {
        case "apng": format = .apng
        case "mp4": format = .mp4
        default: format = .gif
        }
        // Guard against overwriting the loaded source BEFORE dispatching: a
        // successful background export would otherwise destroy the scene source.
        do {
            try App.validateGUIWriteDestination(url, source: sourceURL)
        } catch {
            presentExportError(error, title: "Animation export failed")
            return
        }
        cancelAnimationDataRequest()
        let token = animationDataGeneration
        let cancellationToken = CoordinationCancellationToken()
        animationDataCancellationToken = cancellationToken
        // Snapshot main-thread inputs for the background closure.
        let cam = camera
        let count = state.frameCount
        let forced = forcedFormat
        DispatchQueue.global(qos: .userInitiated).async {
            guard !cancellationToken.isCancelled() else { return }
            do {
                guard let frames = Self.loadAllFrames(from: url, count: count, format: forced) else {
                    throw ParseError.io(path: url.path, reason: "failed to load animation frames")
                }
                guard !cancellationToken.isCancelled() else { return }
                try AnimationExporter.export(frames: frames, camera: cam,
                                             size: CGSize(width: 640, height: 480),
                                             fps: 10, format: format, to: url)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !cancellationToken.isCancelled(),
                          self.animationDataGeneration == token,
                          self.animationDataCancellationToken === cancellationToken else { return }
                    self.animationDataCancellationToken = nil
                    self.presentExportError(error, title: "Animation export failed")
                }
            }
        }
    }

    private func saveProject(to url: URL) {
        do {
            try App.validateGUIWriteDestination(url, source: sourceURL)
            try ProjectStore.save(scene, to: url)
        } catch {
            presentExportError(error, title: "Save project failed")
        }
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
        // every graph sibling so the editor is usable even on a crystal that also
        // carries band/DOS/grid data. Exiting edit mode falls through to the normal
        // precedence below.
        // The color plane now lives in the Metal scene (drawn as a textured quad by
        // the renderer), so it no longer swaps the canvas — the canvas stays visible
        // and the plane composites with the structure via depth testing.
        let editingReciprocal = state.editKPathOnBZ && scene.isCrystal
        let hasDOS = scene.densityOfStates != nil
        let hasBands = scene.bandStructure != nil
        let showSurface = !editingReciprocal && scene.showBandSurface && scene.bandSurface != nil
        bandSurfaceView.isHidden = !showSurface
        let showGraphs = !editingReciprocal && !showSurface && (hasDOS || hasBands)
        linkedGraphs.isHidden = !showGraphs
        if showGraphs {
            linkedGraphs.bandPresent = hasBands
            linkedGraphs.dosPresent = hasDOS
            linkedGraphs.needsDisplay = true
        }
        // Canvas yields to graphs and the band surface (band surface wins).
        canvas.isHidden = editingReciprocal ? false : (showGraphs || showSurface)
    }

    /// Push the sidebar's electronic-structure interaction state into the grapher
    /// views and recompute the cursor/gap readouts. Called from syncFromState so any
    /// sidebar change (energy window, Fermi shift) redraws the graphs immediately.
    private func updateElectronicStructureGraphs() {
        let window: ClosedRange<Float>?
        if state.energyWindowEnabled {
            window = min(state.energyWindowMin, state.energyWindowMax)...max(state.energyWindowMin, state.energyWindowMax)
        } else {
            window = nil
        }
        bandGrapher.energyWindow = window
        bandGrapher.fermiShift = state.fermiShift
        dosGrapher.energyWindow = window
        dosGrapher.fermiShift = state.fermiShift

        // Band gap summary (only meaningful when band data is shown).
        if let bs = scene.bandStructure, !bs.isMesh,
           let gap = BandAnalysis.bandGap(bs) {
            let kind = gap.isMetallic ? "metallic" : (gap.isDirect ? "direct" : "indirect")
            state.bandGapSummary = String(format: "Eg = %.3f eV (%@)", gap.gap, kind as NSString)
        } else if scene.bandStructure != nil {
            state.bandGapSummary = "Eg: no gap data"
        } else {
            state.bandGapSummary = ""
        }

        // Electronic-analysis report: when BOTH datasets are present use the combined
        // linked report; otherwise prefer the actually-displayed DOS (viewport
        // precedence — see updateContentVisibility), otherwise bands. No expected
        // electron count is inferred because Scene/DOS metadata lacks it.
        if let dos = scene.densityOfStates, let bs = scene.bandStructure {
            state.electronicAnalysisReport = ElectronicAnalysisPresentation.linkedReport(band: bs, dos: dos)
        } else if let dos = scene.densityOfStates {
            state.electronicAnalysisReport = ElectronicAnalysisPresentation.dosReport(dos)
        } else if let bs = scene.bandStructure {
            state.electronicAnalysisReport = ElectronicAnalysisPresentation.bandReport(bs)
        } else {
            state.electronicAnalysisReport = nil
        }
    }

    /// Recompute the band-picker candidates for the displayed mesh and install
    /// the effective selection from the current surface sheets. Called at
    /// install and after frame reloads.
    private func refreshBandSurfaceBandUI() {
        guard let surface = scene.bandSurface, let mesh = scene.bandStructure, mesh.isMesh else {
            state.bandSurfaceCandidates = []
            state.setBandSurfaceEffectiveSelection([])
            return
        }
        state.bandSurfaceCandidates = BandSurfaceBuilder.bandInfos(mesh,
                                                                   bandOffset: surface.bandOffset)
        let displayed = Set(surface.sheets.map { $0.spin * 10_000 + $0.band })
        state.bandSurfaceBandSelection = displayed
        state.setBandSurfaceEffectiveSelection(displayed)
    }

    /// Rebuild the band surface from the mesh + the sidebar's explicit band
    /// selection (an empty selection builds a sheets-less surface). Skips the
    /// work when the selection and mesh content are unchanged. Called from
    /// syncFromState and after frame reloads.
    private var lastBandSurfaceBuildKey: (selection: Set<Int>, content: UInt64)? = nil
    private func rebuildBandSurface() {
        guard scene.bandSurface != nil, let mesh = scene.bandStructure, mesh.isMesh,
              let surface = scene.bandSurface, surface.region.count == 4 else { return }
        let selection = state.bandSurfaceBandSelection
        let content = meshContentHash(mesh)
        let key = (selection, content)
        if let last = lastBandSurfaceBuildKey, last == key { return }
        lastBandSurfaceBuildKey = key
        do {
            var opts = BandSurfaceOptions()
            opts.selectedBands = selection
            opts.bandOffset = surface.bandOffset
            let rebuilt = try BandSurfaceBuilder.build(
                bands: mesh, region: Array(surface.region.prefix(3)),
                regionLabels: Array(surface.regionLabels.prefix(3)), options: opts)
            scene.bandSurface = rebuilt
            bandSurfaceView.bandSurface = rebuilt
            state.setBandSurfaceEffectiveSelection(Set(rebuilt.sheets.map { $0.spin * 10_000 + $0.band }))
            updateContentVisibility()
        } catch {
            print("[mcrysden] warning: band-surface rebuild failed: \(error)")
        }
    }

    /// FNV-1a hash over the mesh identity + a few eigenvalues so frame changes
    /// with equal k-point counts still invalidate the rebuild cache.
    private func meshContentHash(_ mesh: BandStructure) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) {
            hash = (hash ^ value) &* 0x100000001b3
        }
        func mixFloat(_ v: Float) { mix(UInt64(v.bitPattern)) }
        mix(UInt64(mesh.kPoints.count))
        mix(UInt64(mesh.nSpin)); mix(UInt64(mesh.nBands)); mix(UInt64(mesh.kPointsPerSpin))
        mixFloat(mesh.fermiEnergy ?? .nan)
        if let first = mesh.kPoints.first, let last = mesh.kPoints.last {
            mixFloat(first.k.x); mixFloat(first.k.y); mixFloat(first.k.z)
            mixFloat(last.k.x); mixFloat(last.k.y); mixFloat(last.k.z)
            for e in first.energies.prefix(4) { mixFloat(e) }
            for e in last.energies.prefix(4) { mixFloat(e) }
        }
        return hash
    }

    // MARK: - Electronic-analysis export

    private func exportElectronicAnalysisText(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "electronic-analysis.txt"
        panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[mcrysden] electronic-analysis text export failed: \(error)")
                self.presentExportError(error, title: "Electronic analysis export failed")
            }
        }
    }

    private func exportElectronicAnalysisCSV(_ csv: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "electronic-analysis.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[mcrysden] electronic-analysis CSV export failed: \(error)")
                self.presentExportError(error, title: "Electronic analysis export failed")
            }
        }
    }

    private func presentExportError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Powder XRD

    /// Lazily create (once) and show the auxiliary Powder XRD window.
    func showPowderXRD() {
        if xrdWindow == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            win.title = "Powder XRD"
            win.isReleasedWhenClosed = false
            win.contentView = xrdGrapher
            xrdWindow = win
        }
        xrdWindow?.makeKeyAndOrderFront(nil)
        xrdGrapher.pattern = state.xrdPattern
        xrdGrapher.showLabels = state.xrdShowLabels
    }

    /// Lazily create and show the per-frame metrics plot window. Hosts a
    /// `FrameMetricsPlotView` with a metric picker (NSSegmentedControl) and a CSV
    /// export button. The plot is repopulated from `state.frameMetrics` each time
    /// the window is shown.
    func showFramePlots() {
        if framePlotsWindow == nil {
            let plot = FrameMetricsPlotView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            plot.autoresizingMask = [.width, .height]
            plot.metrics = state.frameMetrics
            plot.metric = .volume
            framePlotsView = plot

            // Metric picker (one segment per FrameMetricField).
            let seg = NSSegmentedControl(frame: NSRect(x: 8, y: 4, width: 320, height: 24))
            seg.segmentCount = FrameMetricField.allCases.count
            for (i, field) in FrameMetricField.allCases.enumerated() {
                seg.setLabel(field.label, forSegment: i)
                seg.setWidth(80, forSegment: i)
            }
            seg.selectedSegment = FrameMetricField.volume.rawValue
            seg.autoresizingMask = .maxXMargin
            seg.target = self
            seg.action = #selector(framePlotMetricChanged(_:))

            // CSV export button.
            let exportButton = NSButton(frame: NSRect(x: 340, y: 4, width: 96, height: 24))
            exportButton.title = "Export CSV"
            exportButton.bezelStyle = .rounded
            exportButton.autoresizingMask = .maxXMargin
            exportButton.target = self
            exportButton.action = #selector(framePlotExportCSV(_:))

            // Container: picker + export on top, plot filling below.
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            container.addSubview(plot)
            container.addSubview(seg)
            container.addSubview(exportButton)
            plot.frame = NSRect(x: 0, y: 32, width: 640, height: 328)

            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "Frame Metrics"
            win.isReleasedWhenClosed = false
            win.contentView = container
            framePlotsWindow = win
        }
        framePlotsView?.metrics = state.frameMetrics
        framePlotsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Switch the displayed metric of the live plot window.
    @objc private func framePlotMetricChanged(_ sender: NSSegmentedControl) {
        let field = FrameMetricField(rawValue: sender.selectedSegment) ?? .volume
        framePlotsView?.metric = field
        framePlotsView?.setNeedsDisplay(framePlotsView?.bounds ?? .zero)
    }

    /// Export the displayed metrics CSV via a save panel.
    @objc private func framePlotExportCSV(_ sender: Any) {
        guard let csv = framePlotsView?.csv(), !csv.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "frame_metrics.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.presentExportError(error, title: "Frame metrics export failed") }
        }
    }

    /// Recompute the powder XRD pattern for the current scene and settings.
    /// PowderXRD.analyze is O(hklLimit³ · atoms · symmetryOps) and can block
    /// the main thread for seconds on large cells, so it is debounced (~0.2 s)
    /// and computed on a global queue; a generation token discards stale
    /// completions. The non-crystal clear path stays synchronous.
    private func updatePowderXRD() {
        guard scene.isCrystal else {
            state.xrdPattern = nil
            state.xrdStatusText = ""
            cancelXRDRequest()
            return
        }
        // When the XRD panel is not visible, skip the expensive compute
        // entirely — the grapher only reads when visible and the CSV export
        // is triggered from the panel. The previous pattern is left in place.
        guard xrdWindow?.isVisible == true else { return }

        // Cancel any pending debounce + work from a prior call.
        cancelXRDRequest()
        xrdGeneration += 1
        let generation = xrdGeneration

        // Snapshot ALL inputs on the main thread before the debounce fires so
        // the background closure never touches mutable controller state.
        let cell = scene.cell
        let atoms = scene.baseAtoms.isEmpty ? scene.atoms : scene.baseAtoms
        let periodicDim = scene.periodicDim
        let wavelengthIndex = max(0, min(state.xrdWavelengthIndex, PowderXRD.wavelengthOptions.count - 1))
        let wavelength = PowderXRD.wavelengthOptions[wavelengthIndex].wavelength
        let maxTwoTheta = state.xrdMaxTwoTheta
        let fwhm = state.xrdFWHM
        let symmetryOps = state.crystalSymmetry?.symmetry?.symmetryOperations
        let electronDensity = state.xrdUseElectronDensity ? scene.scalarField : nil
        let showLabels = state.xrdShowLabels
        let token = CoordinationCancellationToken()
        xrdCancellationToken = token

        let work = DispatchWorkItem {
            guard !token.isCancelled() else { return }
            let result = PowderXRD.analyze(
                cell: cell,
                atoms: atoms,
                periodicDim: periodicDim,
                wavelength: wavelength,
                maxTwoTheta: maxTwoTheta,
                hklLimit: 8,
                fwhm: fwhm,
                curveStep: 0.05,
                symmetryOps: symmetryOps,
                electronDensity: electronDensity
            )
            guard !token.isCancelled() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled(), self.xrdGeneration == generation,
                      self.xrdCancellationToken === token else { return }
                self.installPowderXRD(result: result, showLabels: showLabels)
                self.xrdWorkItem = nil
                self.xrdCancellationToken = nil
            }
        }
        xrdWorkItem = work
        xrdDebounceCancellation = coordinationDebounceScheduler(0.20) {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    /// Cancel any pending XRD debounce + background work.
    private func cancelXRDRequest() {
        xrdCancellationToken?.cancel()
        xrdCancellationToken = nil
        xrdWorkItem?.cancel()
        xrdWorkItem = nil
        xrdDebounceCancellation?()
        xrdDebounceCancellation = nil
    }

    /// Publish a computed XRD pattern to state + the live grapher. Always
    /// called on the main thread after the generation token confirms currency.
    private func installPowderXRD(result: XRDPattern, showLabels: Bool) {
        state.xrdPattern = result
        if result.isAvailable {
            var text = "\(result.peaks.count) peaks · source: \(result.sourceDescription)"
            if let strongest = result.peaks.max(by: { $0.relativeIntensity < $1.relativeIntensity }),
               let label = strongest.hklLabels.first {
                text += " · strongest \(label) at 2θ = \(String(format: "%.2f", strongest.twoTheta))°"
            }
            state.xrdStatusText = text
        } else {
            state.xrdStatusText = result.unavailableReason ?? "unavailable"
        }
        if let window = xrdWindow, window.isVisible {
            xrdGrapher.pattern = result
            xrdGrapher.showLabels = showLabels
        }
    }

    private func exportPowderXRDCSV() {
        guard let pattern = state.xrdPattern else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "xrd-pattern.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try pattern.peaksCSV().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[mcrysden] XRD CSV export failed: \(error)")
                self.presentExportError(error, title: "XRD CSV export failed")
            }
        }
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
