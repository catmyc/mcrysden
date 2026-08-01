import Foundation
import Combine

/// A point-in-time snapshot of the full k-path identity captured before a mutation,
/// so the "Undo" control can restore geometry AND provenance/signature exactly.
private struct KPathUndoSnapshot {
    let points: [KPoint]
    let breaks: Set<Int>
    let provenance: KPathProvenance
    let signature: String?
}

final class SideBarState: ObservableObject {
    @Published var displayMode: DisplayMode = .ballStick { didSet { onChange?() } }
    @Published var atomScale: Float = 0.35 { didSet { onChange?() } }
    @Published var bondRadius: Float = 0.10 { didSet { onChange?() } }
    @Published var showCellFrame: Bool = true { didSet { onChange?() } }
    @Published var showAxes: Bool = true { didSet { onChange?() } }
    @Published var showLabels: Bool = false { didSet { onChange?() } }
    /// True when the loaded scene is a crystal (has a cell). Drives which
    /// crystal-only controls (Brillouin zone, k-path) are shown.
    @Published var isCrystal: Bool = false { didSet { onChange?() } }
    /// Runtime-only symmetry result for the current base crystal. It is read by
    /// the sidebar and never participates in view-state persistence.
    @Published var crystalSymmetry: CrystalSymmetryAnalysis?
    /// Point-in-time structural summary of the current scene (atom count,
    /// formula, space group, ...). Nil when the viewer is empty. Never
    /// participates in view-state persistence.
    @Published var structureSummary: StructureSummary? = nil
    /// Overlay the Brillouin-zone wireframe (crystal only). Synced to
    /// scene.showBrillouinZone in syncFromState().
    @Published var showBrillouinZone: Bool = false { didSet { onChange?() } }
    /// Projection mode toggle (bound to camera.perspective): checked =
    /// orthographic, unchecked = perspective. Synced in syncFromState().
    @Published var orthographic: Bool = true { didSet { onChange?() } }
    /// Hide the atomic structure (keep cell frame / axes / BZ). Synced to
    /// scene.showStructure in syncFromState().
    @Published var showStructure: Bool = true { didSet { onChange?() } }
    @Published var backgroundHex: String = "#101014" { didSet { onChange?() } }
    /// Second (bottom) background color; only meaningful when backgroundType is
    /// `.gradient_top`. Synced to scene.backgroundBottom in syncFromState().
    @Published var backgroundBottomHex: String = "#000000" { didSet { onChange?() } }
    /// Solid vs vertical-gradient background. Synced to scene.backgroundType.
    @Published var backgroundType: BackgroundType = .solid { didSet { onChange?() } }
    /// Adjustable Phong lighting — mirrored from Scene.lighting so sliders bind
    /// straight through to the same Codable value the renderer/state file use.
    @Published var lighting: Lighting = Lighting() { didSet { onChange?() } }
    @Published var n1: Int = 1 { didSet { onChange?() } }
    @Published var n2: Int = 1 { didSet { onChange?() } }
    @Published var n3: Int = 1 { didSet { onChange?() } }
    @Published var slabEnabled: Bool = false { didSet { onChange?() } }
    @Published var slabA_h: Int = 0 { didSet { onChange?() } }
    @Published var slabA_k: Int = 1 { didSet { onChange?() } }
    @Published var slabA_l: Int = 0 { didSet { onChange?() } }
    @Published var slabA_dist: Float = 0 { didSet { onChange?() } }
    @Published var slabB_h: Int = 0 { didSet { onChange?() } }
    @Published var slabB_k: Int = -1 { didSet { onChange?() } }
    @Published var slabB_l: Int = 0 { didSet { onChange?() } }
    @Published var slabB_dist: Float = 0 { didSet { onChange?() } }
    /// Coordination analysis is a runtime-only opt-in. It is deliberately not
    /// mirrored into Scene or persisted state: changing files must not serialize
    /// derived neighbor data into a document.
    @Published var coordinationEnabled: Bool = false { didSet { onChange?() } }
    @Published var coordinationRadiusScale: Float = CoordinationAnalyzer.defaultRadiusScale {
        didSet {
            let bounded = min(2.0, max(0.50, coordinationRadiusScale))
            if coordinationRadiusScale != bounded {
                coordinationRadiusScale = bounded
            } else {
                onChange?()
            }
        }
    }
    @Published var showCoordinationColors: Bool = false { didSet { onChange?() } }
    /// Runtime-only readouts populated by MainWindowController. These are not
    /// scene fields and therefore do not participate in state-file persistence.
    @Published var coordinationStatusText: String = "Off"
    @Published var coordinationSummaryText: String = ""
    @Published var coordinationAnalysisAvailable = false
    // --- Electronic-structure graph interaction ---------------------------------
    // View-only state driving the band/DOS grapher views. None of these are scene
    // fields, so they do not participate in state-file persistence. The controller
    // mirrors them into the grapher views from syncFromState() / the onChange hook.
    /// Master enable for the electronic-structure section. Hides the section when false.
    @Published var electronicStructureEnabled: Bool = false { didSet { onChange?() } }
    /// When true, the grapher y-axis is clipped to energyWindowMin...energyWindowMax.
    @Published var energyWindowEnabled: Bool = false { didSet { onChange?() } }
    @Published var energyWindowMin: Float = -10 { didSet { onChange?() } }
    @Published var energyWindowMax: Float = 10 { didSet { onChange?() } }
    /// Fermi-level shift applied to the displayed energies (eV).
    @Published var fermiShift: Float = 0 { didSet { onChange?() } }
    /// Live cursor readout text ("E = ... eV" / "E = ... eV, DOS = ...").
    /// Set by the controller from the grapher's cursor callback; not a scene field.
    @Published var electronicStructureCursorText: String = ""
    /// Computed band-gap summary text (e.g. "Eg = 1.23 eV (direct)").
    /// Set by the controller; not a scene field.
    @Published var bandGapSummary: String = ""
    /// Computed electronic-analysis report (band or DOS). Set by the controller
    /// from the actually-displayed graph (DOS takes viewport precedence); nil
    /// when neither graph is available. Not a scene field.
    @Published var electronicAnalysisReport: ElectronicAnalysisReport?
    @Published var measurementMode: MeasurementMode = .none { didSet { onChange?() } }
    /// k-path state (crystal only). points carry fractional coords + labels; when
    /// empty the editor offers the default high-symmetry path for the structure.
    @Published var kPathPoints: [KPoint] = [] { didSet { kPathDidChange() } }
    /// Indices i such that there is NO segment between kPathPoints[i] and
    /// kPathPoints[i+1]. Represents disconnected high-symmetry segments.
    @Published var kPathBreaks: Set<Int> = [] { didSet { kPathDidChange() } }
    /// Runtime-only physical reciprocal-space readouts aligned with kPathPoints.
    /// These are derived from the loaded scene cell and are not persisted.
    @Published private(set) var kPathDistanceReadouts: [KPathDistanceReadout] = []
    /// The final cumulative connected route distance, when the route is valid.
    /// A nil value means the route or reciprocal basis contains invalid data.
    var kPathTotalDistance: Float? {
        kPathDistanceReadouts.last?.cumulativeDistance
    }
    /// UI-only: when true the user is editing the k-path by clicking BZ landmarks.
    /// Forces Brillouin-zone visibility on (handled in syncFromState). Exiting
    /// this mode does not itself change the route.
    @Published var editKPathOnBZ: Bool = false { didSet { onChange?() } }
    /// Runtime-only reciprocal-editor availability for the current base scene.
    /// A failed BZ build or framing attempt sets the reason; scene/frame installs
    /// clear it so a later scene can be tried independently.
    @Published var reciprocalEditorStatusText: String? = nil
    var reciprocalEditorAvailable: Bool { reciprocalEditorStatusText == nil }
    /// Per-segment k-path sampling density used when building the KPath for export.
    /// UI-only preference (not a scene field); the controller stamps it onto the
    /// route before exporting. Defaults to the KPath default of 20.
    @Published var kPathSampling: Int = 20
    /// Route provenance, mirrored from the scene. This is the source of truth for
    /// the route's identity: user-edit mutations set it to `.userEdited` (and clear
    /// the signature), `resetToDefault` / the controller set it to `.generated`,
    /// and undo restores the value captured beforehand. The controller's
    /// syncFromState copies it through to the scene; it is intentionally not
    /// @Published because it never drives a view directly.
    var kPathProvenance: KPathProvenance = .generated
    /// Structure signature for generated routes; nil when user-edited. Mirrored
    /// from the scene and restored by undo exactly like kPathProvenance.
    var kPathSignature: String? = nil
    /// UI-only undo stack of prior routes (snapshots before each mutation), so the
    /// "Undo" control can step back. Bounded to 1024 entries. Each entry captures
    /// the points, break set, provenance, and signature so undo can restore the
    /// route's full identity, not just its geometry.
    private var kPathUndo: [KPathUndoSnapshot] = []
    /// `kPathPoints` and `kPathBreaks` must reach the controller as one route
    /// snapshot. Their `didSet`s synchronously invoke `onChange`, so compound
    /// editor operations batch the notification until both values agree.
    private var kPathMutationDepth = 0
    private var pendingKPathChange = false
    /// Runtime-only cell used to derive the physical k-path readouts. It is
    /// refreshed by syncFromScene and deliberately has no persistence path.
    private var kPathCell: Cell?
    /// Bumped once per whole-route replacement (replaceKPath) so the controller can
    /// clear a stale node selection and the SideBar can drop its local editor draft.
    /// Single-node edits (updateLabel, updateKPathPoint, move, remove, append, ...)
    /// leave it untouched, so editing a selected node keeps its highlight. @Published
    /// so SwiftUI can observe it.
     @Published private(set) var routeGeneration = 0
     /// Bumped once per view reset so the SideBar clears its local selected node/editor
     /// (a view reset is a natural clearing point for the transient highlight, but it
     /// does NOT replace the route, so routeGeneration must stay untouched).
     @Published private(set) var viewResetGeneration = 0
    /// Whether an undo is available. Drives the "Undo" control's disabled state so it
    /// stays enabled after a Clear (the pre-clear route is restorable) and is cleared
    /// whenever the route is reset/loaded.
    var canUndo: Bool { !kPathUndo.isEmpty }
    /// Isosurface controls (only meaningful when the scene carries a scalarField).
    /// sliderRange is set by the controller from the field's [minValue, maxValue].
    @Published var showIsoSurface: Bool = true { didSet { onChange?() } }
    @Published var isoLevel: Float = 0 { didSet { onChange?() } }
    @Published var isoRange: ClosedRange<Float> = 0...1
    /// True when a volumetric field is present — the sidebar gates the
    /// Isosurface section on this so structure-only files show no empty controls.
    var hasScalarField: Bool = false
    /// Multi-orbital cube selection. The picker is shown only when orbitalCount > 1.
    @Published var currentOrbital: Int = 0 { didSet { onChange?() } }
    @Published var orbitalCount: Int = 0
    /// True when a Fermi surface (BXSF) is present — the sidebar gates the
    /// Fermi Surface section on this so structure-only files show no empty controls.
    var hasFermiSurface: Bool = false
    /// Toggle the Fermi-surface overlay. Synced to scene.showFermiSurface in
    /// syncFromState(); meaningful only when hasFermiSurface is true.
    @Published var showFermiSurface: Bool = true { didSet { onChange?() } }
    /// True when a 2D scalar grid (DATAGRID_2D) is present — the sidebar gates the
    /// Color Plane section on this so structure-only files show no empty controls.
    var hasGrid2D: Bool = false
    /// Toggle the color-plane overlay. Synced in syncFromState(); when on, the
    /// 2D ColorPlaneView replaces the 3D canvas. Meaningful only when hasGrid2D.
    @Published var showColorPlane: Bool = true { didSet { onChange?() } }
    /// True when a forceSet (parsed from a QE output) is present — the sidebar
    /// gates the Forces section on this so force-less files show no empty controls.
    var hasForceSet: Bool = false
    /// Draw force arrows (when a forceSet is present). Synced to scene.showForces
    /// in syncFromState(); meaningless without a forceSet.
    @Published var showForces: Bool = true { didSet { onChange?() } }
    /// Å-per-(eV/Å) arrow-length multiplier. Synced to scene.forceScale.
    @Published var forceScale: Float = 50.0 { didSet { onChange?() } }
    /// Human-readable force/energy/stress readout for the Forces sidebar section,
    /// set by the controller from scene.forceSet on every render. Not @Published:
    /// it changes only when the scene reloads, so a plain assignment suffices.
    var forceSummary: String = ""
    /// AXSF animation playback state. frameCount is 1 for non-animated files
    /// (the playback UI is hidden in that case). isPlaying drives a timer in
    /// MainWindowController; frameIndex advances it and reloads the frame.
    @Published var isPlaying: Bool = false { didSet { onChange?() } }
    @Published var frameIndex: Int = 0 { didSet { onChange?() } }
    @Published var frameCount: Int = 0 { didSet { onChange?() } }
    var onChange: (() -> Void)?
    /// Invoked when the user taps "Reset View" in the sidebar.
    var onResetView: (() -> Void)?
    /// Export the given k-path in the requested format (the controller presents
    /// a save panel and writes the text). `.qe` => QE K_POINTS crystal;
    /// `.qeCrystalB` => QE K_POINTS crystal_b band-path rows, one special point
    /// per line with a per-line subdivision weight; `.wannier90` => Wannier90
    /// kpoint_path block; `.kpf` => XCrySDen native k-path file; `.vasp` =>
    /// VASP line-mode KPOINTS.
    var onExportKPath: ((KPath, KPathExportFormat) -> Void)?
    /// Import a k-path from a file (the controller presents an open panel and
    /// parses the chosen route). Imported routes are marked user-edited exactly
    /// like other user edits, so they are never auto-regenerated when the
    /// structure changes.
    var onImportKPath: (() -> Void)?
    /// Recalculate the default high-symmetry route for the current scene and
    /// install it (the "Default" control). The controller owns the scene, so it
    /// wires this to recompute `makeDefaultKPath`.
    var onResetKPath: (() -> Void)?
    /// Select (or deselect, nil) the route node at `index` in the BZ viewport. The
    /// sidebar route list invokes this on tap; the controller wires it to highlight
    /// the node. Whole-route replacements clear the selection on their own, so this
    /// callback only needs to forward the index.
    var onSelectKPathNode: ((Int?) -> Void)?
    /// Present the atom table panel for the current scene. The controller owns the
    /// AtomTableView and lazily creates the auxiliary window on first use.
    var onShowAtomTable: (() -> Void)?
    /// Export the electronic-analysis report as text. The controller presents a
    /// save panel and writes `summaryText`. Not a scene field.
    var onExportElectronicAnalysisText: ((ElectronicAnalysisReport) -> Void)?
    /// Export the electronic-analysis report as CSV. The controller presents a
    /// save panel and writes `csv`. Not a scene field.
    var onExportElectronicAnalysisCSV: ((ElectronicAnalysisReport) -> Void)?

    /// Reflect a loaded scene's controls into the sidebar WITHOUT triggering
    /// onChange (so we don't immediately re-mutate the scene we just loaded).
    func syncFromScene(_ scene: Scene) {
        let saved = onChange
        onChange = nil
        displayMode = scene.displayMode
        atomScale = scene.atomScale
        bondRadius = scene.bondRadius
        showCellFrame = scene.showCellFrame
        showAxes = scene.showAxes
        showLabels = scene.showLabels
        showBrillouinZone = scene.showBrillouinZone
        isCrystal = scene.isCrystal
        crystalSymmetry = scene.crystalSymmetry
        // Structural summary (nil for an empty viewer). Computed here so both
        // init and loadFile populate it through syncFromScene — a controller
        // constructed directly with a non-empty scene must show its summary too.
        structureSummary = StructureSummary(scene, symmetry: crystalSymmetry)
        // Mirror the scene's route: for a freshly-loaded crystal this is the
        // generated high-symmetry default; once the user edits it, the edited
        // route lives in the scene and must be copied back, never regenerated.
        // Provenance and signature travel with the geometry so the sidebar's idea
        // of the route's identity matches the scene's exactly.
        refreshKPathMetrics(for: scene.cell)
        replaceKPath(points: scene.kPathPoints, breaks: scene.kPathBreaks,
                     provenance: scene.kPathProvenance, signature: scene.kPathSignature)
        clearReciprocalEditorStatus()
        editKPathOnBZ = false   // loading a new scene exits edit mode
        kPathUndo = []          // drop stale undo history from the previous scene
        measurementMode = scene.measurementMode
        backgroundHex = scene.background
        backgroundBottomHex = scene.backgroundBottom
        backgroundType = scene.backgroundType
        lighting = scene.lighting
        n1 = scene.superCell.n1
        n2 = scene.superCell.n2
        n3 = scene.superCell.n3
        if let slab = scene.slab {
            slabEnabled = true
            slabA_h = slab.planeA.h; slabA_k = slab.planeA.k; slabA_l = slab.planeA.l; slabA_dist = slab.planeA.distance
            slabB_h = slab.planeB.h; slabB_k = slab.planeB.k; slabB_l = slab.planeB.l; slabB_dist = slab.planeB.distance
        } else {
            slabEnabled = false
        }
        // Projection mode: the live render camera's perspective flag is the
        // source of truth, mirrored here so the toggle reflects the loaded view.
        orthographic = !scene.camera.perspective
        showStructure = scene.showStructure
        // Isosurface: the slider range follows the loaded field; default the iso
        // level to the field's midpoint so a surface is visible on first load.
        if let field = scene.scalarField {
            hasScalarField = true
            isoRange = field.minValue...field.maxValue
            isoLevel = scene.isoLevel != 0 ? scene.isoLevel : (field.minValue + field.maxValue) * 0.5
            showIsoSurface = scene.showIsoSurface
        } else {
            hasScalarField = false
        }
        orbitalCount = scene.multiOrbitalFields.count
        currentOrbital = orbitalCount > 0
            ? min(max(0, scene.currentOrbital), orbitalCount - 1)
            : 0
        hasFermiSurface = (scene.fermiSurface != nil)
        showFermiSurface = scene.showFermiSurface
        hasGrid2D = (scene.grid2D != nil)
        // Grid presence gates visibility; retain the user's preference while a
        // trajectory frame temporarily has no plane to display.
        showColorPlane = scene.showColorPlane
        // Forces: gate the sidebar section on presence, reflect the toggle/scale.
        hasForceSet = (scene.forceSet != nil)
        showForces = scene.showForces
        forceScale = scene.forceScale
        onChange = saved
    }

    /// Clear the transient reciprocal-editor failure for a new scene or frame.
    /// This intentionally does not invoke `onChange`: the status is not scene state.
    func clearReciprocalEditorStatus() {
        reciprocalEditorStatusText = nil
    }

    // MARK: - k-path editing (UI-only mutations; each fires onChange → sync)

    /// Record the current route on the undo stack before mutating it. The snapshot
    /// captures the full identity — points, breaks, provenance, and signature — so
    /// undo restores exactly what the route was, not just its geometry. Bounded so a
    /// long editing session cannot grow the stack without limit.
    private func pushUndo() {
        if kPathUndo.count >= 1024 { kPathUndo.removeFirst() }
        kPathUndo.append(KPathUndoSnapshot(points: kPathPoints, breaks: kPathBreaks,
                                           provenance: kPathProvenance, signature: kPathSignature))
    }

    /// Mark the route as user-edited, clearing any generated signature. Every
    /// user-initiated mutation calls this after pushUndo() so the edit is recorded
    /// as deliberate and never mistaken for the canonical generated path.
    private func markUserEdited() {
        kPathProvenance = .userEdited
        kPathSignature = nil
    }

    /// Run a compound k-path change while deferring its synchronous state
    /// callback. Nested calls are supported so helper methods remain safe.
    private func mutateKPath(_ mutation: () -> Void) {
        kPathMutationDepth += 1
        defer {
            kPathMutationDepth -= 1
            if kPathMutationDepth == 0, pendingKPathChange {
                pendingKPathChange = false
                refreshKPathDistanceReadouts()
                onChange?()
            }
        }
        mutation()
    }

    private func kPathDidChange() {
        if kPathMutationDepth > 0 {
            pendingKPathChange = true
        } else {
            refreshKPathDistanceReadouts()
            onChange?()
        }
    }

    private func refreshKPathDistanceReadouts() {
        guard let cell = kPathCell else {
            kPathDistanceReadouts = []
            return
        }
        let route = KPath(points: kPathPoints, breaks: kPathBreaks)
        kPathDistanceReadouts = route.reciprocalDistanceReadouts(cell: cell)
    }

    /// Refresh the runtime reciprocal metric after a frame or scene geometry
    /// replacement. This deliberately does not invoke onChange: the route is
    /// unchanged and callers may use it while holding the controller's sync guard.
    func refreshKPathMetrics(for cell: Cell?) {
        kPathCell = cell
        refreshKPathDistanceReadouts()
    }

    /// Replace the whole route atomically from the controller (for example when
    /// restoring or regenerating the canonical path). Restores the full route
    /// identity — points, breaks, provenance, and signature — so a wholesale
    /// replacement never desyncs geometry from its provenance. Its one notification
    /// never exposes a new point list paired with old break indices.
    func replaceKPath(points: [KPoint], breaks: Set<Int>, provenance: KPathProvenance, signature: String?) {
        mutateKPath {
            kPathProvenance = provenance
            kPathSignature = signature
            kPathPoints = points
            kPathBreaks = breaks
            // Bump inside the mutation so the generation is advanced before
            // mutateKPath's deferred onChange -> syncFromState runs; otherwise the
            // controller would observe the pre-bump value and not clear the selection.
            routeGeneration += 1
        }
    }

    /// Bound a single node's label to 64 chars. No-op for an out-of-range index or when
    /// the bounded value is unchanged (no undo entry pushed in that case).
    func updateLabel(at index: Int, to label: String) {
        guard kPathPoints.indices.contains(index) else { return }
        let bounded = String(label.prefix(64))
        guard kPathPoints[index].label != bounded else { return }
        pushUndo()
        markUserEdited()
        kPathPoints[index].label = bounded
    }

    /// Update a single node's fractional coordinate and label. No-op for an
    /// out-of-range index, a non-finite coordinate, or when both values are
    /// unchanged (no undo entry pushed in that case). Records exactly one undo
    /// snapshot and emits one state change transactionally.
    func updateKPathPoint(at index: Int, fractionalCoordinate: SIMD3<Float>, label: String) {
        guard kPathPoints.indices.contains(index) else { return }
        guard fractionalCoordinate.x.isFinite && fractionalCoordinate.y.isFinite && fractionalCoordinate.z.isFinite else { return }
        let bounded = String(label.prefix(64))
        guard kPathPoints[index].frac != fractionalCoordinate || kPathPoints[index].label != bounded else { return }
        pushUndo()
        markUserEdited()
        // Assign a whole new KPoint in one shot so @Published fires objectWillChange
        // exactly once: an in-place frac-then-label update would otherwise publish an
        // intermediate (new-coordinate, old-label) value to Combine subscribers.
        mutateKPath {
            kPathPoints[index] = KPoint(fractionalCoordinate, bounded)
        }
    }

    /// Swap a node with its predecessor. No-op at the top or out of range.
    /// Breaks describe positions between adjacent list entries, so an adjacent
    /// swap deliberately leaves the break-index set unchanged.
    func moveUp(at index: Int) {
        guard index > 0, index < kPathPoints.count else { return }
        pushUndo()
        markUserEdited()
        kPathPoints.swapAt(index, index - 1)
    }

    /// Swap a node with its successor. No-op at the bottom or out of range.
    /// Breaks describe positions between adjacent list entries, so an adjacent
    /// swap deliberately leaves the break-index set unchanged.
    func moveDown(at index: Int) {
        guard index >= 0, index < kPathPoints.count - 1 else { return }
        pushUndo()
        markUserEdited()
        kPathPoints.swapAt(index, index + 1)
    }

    /// Remove a node. No-op for an out-of-range index.
    /// The two gaps bordering an interior deletion collapse into one; that new
    /// gap is broken if either original gap was broken. Boundary deletions drop
    /// the vanished outer gap and never leave an invalid -1/last break behind.
    func remove(at index: Int) {
        guard kPathPoints.indices.contains(index) else { return }
        pushUndo()
        markUserEdited()
        let oldBreaks = kPathBreaks
        mutateKPath {
            kPathPoints.remove(at: index)
            remapBreaksForRemoval(at: index, oldBreaks: oldBreaks)
        }
    }

    /// Remap break indices after removing the point at `index`.
    /// For each remaining gap, look up its predecessor gap(s) before removal.
    /// This naturally handles first/last removals and discards malformed old
    /// break indices instead of shifting them into another invalid position.
    private func remapBreaksForRemoval(at index: Int, oldBreaks: Set<Int>) {
        let remainingPointCount = kPathPoints.count
        guard remainingPointCount >= 2 else {
            kPathBreaks = []
            return
        }
        var newBreaks = Set<Int>()
        for newGap in 0..<(remainingPointCount - 1) {
            let isBroken: Bool
            if index > 0, index < remainingPointCount, newGap == index - 1 {
                // The deleted point was interior: old gaps index-1 and index
                // both contributed to the new direct connection.
                isBroken = oldBreaks.contains(index - 1) || oldBreaks.contains(index)
            } else {
                // Gaps before the deletion retain their index; gaps after it
                // shift one slot down in the new point list.
                let oldGap = newGap < index ? newGap : newGap + 1
                isBroken = oldBreaks.contains(oldGap)
            }
            if isBroken { newBreaks.insert(newGap) }
        }
        kPathBreaks = newBreaks
    }

    /// Undo the last mutation, restoring the route snapshot taken beforehand.
    /// No-op when there is nothing to undo.
    func undoLast() {
        guard let snap = kPathUndo.popLast() else { return }
        replaceKPath(points: snap.points, breaks: snap.breaks,
                     provenance: snap.provenance, signature: snap.signature)
    }

    /// Clear the whole route. No-op (no undo entry) when already empty.
    func clear() {
        guard !kPathPoints.isEmpty else { return }
        pushUndo()
        markUserEdited()
        replaceKPath(points: [], breaks: [], provenance: .userEdited, signature: nil)
    }

    /// Import a route from a file. Records the current route on the undo stack
    /// (so Undo restores the pre-import route), then replaces it with the imported
    /// one marked as user-edited — imported routes must NOT be auto-regenerated
    /// when the structure changes, exactly like other user edits.
    func importKPath(points: [KPoint], breaks: Set<Int>) {
        guard !points.isEmpty else { return }
        pushUndo()
        replaceKPath(points: points, breaks: breaks, provenance: .userEdited, signature: nil)
    }

    /// Toggle a break at the given index. A break at i means no segment joins
    /// kPathPoints[i] and kPathPoints[i+1]. No-op for an out-of-range index.
    /// When inserting a break, remaps existing break indices that are >= the
    /// insertion point (none, since the break is between existing points).
    func toggleBreak(at index: Int) {
        guard index >= 0, index < kPathPoints.count - 1 else { return }
        pushUndo()
        markUserEdited()
        if kPathBreaks.contains(index) {
            kPathBreaks.remove(index)
        } else {
            kPathBreaks.insert(index)
        }
    }

    /// Insert a break at the given index. No-op if already present or out of range.
    func insertBreak(at index: Int) {
        guard index >= 0, index < kPathPoints.count - 1 else { return }
        guard !kPathBreaks.contains(index) else { return }
        pushUndo()
        markUserEdited()
        kPathBreaks.insert(index)
    }

    /// Remove a break at the given index. No-op if not present or out of range.
    func removeBreak(at index: Int) {
        guard kPathBreaks.contains(index) else { return }
        pushUndo()
        markUserEdited()
        kPathBreaks.remove(index)
    }

    /// Reset to the generated default for the current scene. The controller owns
    /// the scene, so it recomputes the route via `onResetKPath`. No-op when no reset
    /// callback is wired.
    func resetToDefault() {
        guard onResetKPath != nil else { return }
        pushUndo()
        onResetKPath?()
    }

    /// Bump `viewResetGeneration` so the SideBar clears its local selected
    /// node/editor and the controller clears the renderer highlight. A view reset
    /// does not replace the route, so `routeGeneration` is intentionally untouched.
    func notifyViewReset() {
        viewResetGeneration += 1
    }

    /// Append a picked BZ landmark, capping the route at 1024 nodes and suppressing
    /// an exact fractional-coordinate repeat of the current last node (renaming a node
    /// must not defeat the duplicate check). Non-consecutive repeats (Gamma-X-Gamma)
    /// remain allowed.
    func append(_ point: KPoint) {
        if let last = kPathPoints.last, last.frac == point.frac { return }
        guard kPathPoints.count < 1024 else { return }
        pushUndo()
        markUserEdited()
        kPathPoints.append(point)
    }
}

/// Identifiers for sidebar sections whose collapsed state is persisted in
/// UserDefaults. Each case's rawValue IS the UserDefaults key; a missing key
/// defaults to expanded (false). The rawValue is the single source of truth —
/// `@AppStorage` declarations in `SideBar` reference these, so the key strings
/// live in exactly one place.
enum CollapsibleSidebarSection: String, CaseIterable {
    case isosurface = "SideBarCollapsed.isosurface"
    case fermiSurface = "SideBarCollapsed.fermiSurface"
    case symmetry = "SideBarCollapsed.symmetry"
    case display = "SideBarCollapsed.display"
    case appearance = "SideBarCollapsed.appearance"
    case structureSummary = "SideBarCollapsed.structureSummary"
    case colorPlane = "SideBarCollapsed.colorPlane"
    case forces = "SideBarCollapsed.forces"
    case kPath = "SideBarCollapsed.kPath"
    case supercell = "SideBarCollapsed.supercell"
    case slab = "SideBarCollapsed.slab"
    case animation = "SideBarCollapsed.animation"
    case coordination = "SideBarCollapsed.coordination"
    case electronicStructure = "SideBarCollapsed.electronicStructure"

    var defaultsKey: String { rawValue }
}
