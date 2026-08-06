import Foundation
import Combine
import AppKit

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
    /// Runtime-only availability for the standard crystallographic orientation
    /// buttons. This is deliberately not a Scene field or a persisted setting.
    @Published private(set) var standardCrystalViewAvailable = false
    /// Help text for the standard crystallographic orientation buttons. When the
    /// buttons are disabled this explains the current prerequisite that failed.
    @Published private(set) var standardCrystalViewHelp =
        "Standard crystallographic views require a valid unit cell."
    /// Runtime-only names and occupancy for the document-scoped camera bookmark
    /// controls. These values are deliberately not scene fields, UserDefaults
    /// settings, or Codable state; MainWindowController owns the bookmark cameras.
    @Published var cameraBookmarkNames: [String] =
        (0..<CameraBookmark.slotCount).map { "View \($0 + 1)" }
    @Published private(set) var cameraBookmarkAvailability: [Bool] =
        Array(repeating: false, count: CameraBookmark.slotCount)
    @Published var atomScale: Float = 0.35 { didSet { onChange?() } }
    @Published var bondRadius: Float = 0.10 { didSet { onChange?() } }
    @Published var showCellFrame: Bool = true { didSet { onChange?() } }
    @Published var showAxes: Bool = true { didSet { onChange?() } }
    @Published var showLabels: Bool = false { didSet { onChange?() } }
    /// Show live distance text above each displayed bond. Synced to
    /// scene.showBondDistances in syncFromScene/syncFromState.
    @Published var showBondDistances: Bool = false { didSet { onChange?() } }
    /// Show the scale indicator overlay. Synced to scene.showScaleIndicator in
    /// syncFromScene(); the controller mirrors changes back into the Scene.
    @Published var showScaleIndicator: Bool = false { didSet { onChange?() } }
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
    /// Optional path to a background image file. Synced to
    /// scene.backgroundImagePath in syncFromState(). nil/empty = no image.
    @Published var backgroundImagePath: String? = nil { didSet { onChange?() } }
    /// Anaglyph stereo rendering mode. Synced to scene.anaglyphMode.
    @Published var anaglyphMode: AnaglyphMode = .off { didSet { onChange?() } }
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
    /// Runtime-only first-shell polyhedron metrics derived from the current
    /// coordination analysis (volume, bond-length distortion, angle deviation).
    /// The controller computes these on a background queue; not persisted.
    @Published var polyhedronSummaryText: String = ""
    /// Runtime-only two-structure comparison status (reference name + RMSD).
    /// Empty when no comparison is active. Not persisted.
    @Published var comparisonStatusText: String = ""
    /// Draw the comparison displacement arrows in the viewport. Runtime-only
    /// (the comparison reference itself is never persisted).
    @Published var showComparisonArrows: Bool = false { didSet { onChange?() } }
    /// True while a two-structure comparison is being computed off the main
    /// thread. The sidebar disables the arrow toggle and export button during
    /// this window so the user cannot act on a result that does not yet exist.
    /// Not a scene field and not persisted.
    @Published var comparisonCalculating: Bool = false
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
    /// Runtime-only distribution analysis derived from the coordination result.
    /// Nil when coordination is disabled or analysis is unavailable. Not a
    /// scene field and not persisted.
    @Published var distributionAnalysis: DistributionAnalysis?
    /// Whether the distribution analysis (bond/angle/RDF) is available.
    @Published var distributionAnalysisAvailable = false
    /// Present the neighbor table panel for the current coordination analysis.
    /// The controller owns the NeighborTableView and lazily creates the window.
    var onShowNeighborTable: (() -> Void)?
    /// Present the first-shell polyhedron metrics panel. The controller owns
    /// the PolyhedronTableView and lazily creates the window.
    var onShowPolyhedronTable: (() -> Void)?
    /// Export the distribution analysis as CSV. The controller presents a save
    /// panel and writes the CSV text. Not a scene field.
    var onExportDistributionCSV: ((DistributionAnalysis) -> Void)?
    /// Present the two-structure comparison panel. The controller owns the
    /// reference structure and the panel, and lazily creates the window.
    var onShowComparison: (() -> Void)?
    /// Clear the active two-structure comparison (reference, arrows, readouts).
    var onClearComparison: (() -> Void)?
    /// Export the active comparison summary as CSV. The controller presents a
    /// save panel and writes the per-match data. Not a scene field.
    var onExportComparisonCSV: (() -> Void)?
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
    /// Multiple independent isosurface specs. Empty = legacy ±pair behavior.
    /// Non-empty = render exactly the enabled specs. Capped at 8.
    @Published var isoSurfaces: [IsoSurfaceSpec] = [] { didSet { onChange?() } }
    /// Small palette used to seed colors for newly-added iso specs.
    private static let isoPalette: [String] = ["#1f6f99", "#f1773f", "#3fae5a",
        "#a051b8", "#d62728", "#17becf", "#bcbd22", "#e694c4"]
    /// Index into isoPalette for the next added spec.
    private var nextIsoPaletteIndex = 0
    /// Display-only clipping plane (crystal only). nil = no clipping.
    @Published var clipPlane: ClipPlane? { didSet { onChange?() } }
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
    /// Colormap for the 2D color plane. Defaults to .viridis.
    @Published var colorPlaneColormap: Colormap = .viridis { didSet { onChange?() } }
    /// Whether contour lines are drawn over the color plane.
    @Published var colorPlaneContourEnabled: Bool = true { didSet { onChange?() } }
    /// Number of contour levels (2...20).
    @Published var colorPlaneContourCount: Int = 6 { didSet { onChange?() } }
    /// 3D volume slices: sample the scalar field on arbitrary fractional planes.
    /// Empty = none; cap 3. Synced from scene.volumeSlices.
    @Published var volumeSlices: [VolumeSlice] = [] { didSet { onChange?() } }
    // --- Region integration (view-state only, NOT persisted) ---------------------
    /// Gated on hasScalarField. The controller recomputes the integral when these
    /// inputs change and writes the summary back into `regionResultSummary`.
    @Published var regionShape: RegionShape = .box { didSet { onRegionChange?() } }
    @Published var regionCenter: SIMD3<Float> = .zero { didSet { onRegionChange?() } }
    @Published var regionHalfExtents: SIMD3<Float> = SIMD3<Float>(2, 2, 2) { didSet { onRegionChange?() } }
    @Published var regionRadius: Float = 2 { didSet { onRegionChange?() } }
    /// Live single-line readout set by the controller. Not @Published (set on load
    /// and on region recompute, not via didSet).
    var regionResultSummary: String = ""
    /// Error text when the region contains no samples. nil = no error.
    var regionComputeError: String? = nil
    /// Whole-field integral readout ("Whole field" button). Empty until computed.
    var regionWholeFieldSummary: String = ""
    /// Invoked when the user taps the background-image "Choose…" button. The
    /// controller presents an NSOpenPanel and sets backgroundImagePath.
    var onPickBackgroundImage: (() -> Void)?
    /// Invoked when any region input changes. MainWindowController wires this to
    /// recompute the integral (guarded against unrelated sidebar changes).
    var onRegionChange: (() -> Void)?
    /// Invoked when the user taps "Whole field". The controller computes
    /// RegionIntegration.integrateAll(field:) and writes the summary.
    var onComputeWholeField: (() -> Void)?
    // --- Structure tools (runtime-only, not persisted) ---
    @Published private(set) var cellRepresentation: CellRepresentation = .input
    @Published private(set) var basisTransformHelp: String = ""
    @Published private(set) var primitiveTransformAvailable = false
    @Published private(set) var conventionalTransformAvailable = false
    @Published var deformationMatrix: [Float] = [1,0,0, 0,1,0, 0,0,1] { didSet { onChange?() } }
    @Published var clusterCenter: SIMD3<Float> = .zero { didSet { onChange?() } }
    @Published var clusterRadius: Float = 5 { didSet { onChange?() } }
    @Published var surfaceH: Int = 1 { didSet { onChange?() } }
    @Published var surfaceK: Int = 0 { didSet { onChange?() } }
    @Published var surfaceL: Int = 0 { didSet { onChange?() } }
    @Published var surfaceLayers: Int = 4 { didSet { onChange?() } }
    @Published var surfaceVacuum: Float = 10 { didSet { onChange?() } }
    @Published var surfaceTermination: Int = 0 { didSet { onChange?() } }
    @Published var surfaceStackCount: Int = 1 { didSet { onChange?() } }
    @Published private(set) var surfaceTerminationOptions = 0
    @Published private(set) var structureToolsStatusText = ""
    @Published private(set) var surfaceStatusText = ""
    @Published private(set) var surfaceBuilderAvailable = false
    // --- Structure editing (runtime-only, not persisted) ---
    @Published private(set) var structureEditingAvailable = false
    @Published private(set) var structureEditStatusText = ""
    @Published var latticeA: Float = 0
    @Published var latticeB: Float = 0
    @Published var latticeC: Float = 0
    @Published var latticeAlpha: Float = 0
    @Published var latticeBeta: Float = 0
    @Published var latticeGamma: Float = 0
    @Published var defectElementSymbol: String = "Si"
    @Published var interstitialFracX: Float = 0.5
    @Published var interstitialFracY: Float = 0.5
    @Published var interstitialFracZ: Float = 0.5
    @Published var displaceDeltaX: Float = 0
    @Published var displaceDeltaY: Float = 0
    @Published var displaceDeltaZ: Float = 0
    @Published var displaceAllAtoms = true
    var onInsertInterstitial: (() -> Void)?
    var onRemoveSelectedAtoms: (() -> Void)?
    var onSubstituteSelected: (() -> Void)?
    var onDisplaceAtoms: (() -> Void)?
    var onApplyLattice: (() -> Void)?
    var onResetLattice: (() -> Void)?
    var onExportStructure: ((StructureExportFormat) -> Void)?
    /// True when the current scene is a z-parallel 2D slab whose vacuum the
    /// surface-vacuum slider can adjust live (not just at build time).
    @Published private(set) var surfaceVacuumAdjustable = false
    var onApplyBasisTransform: ((CellRepresentation) -> Void)?
    var onApplyDeformation: (() -> Void)?
    var onCutCluster: (() -> Void)?
    var onBuildSurface: (() -> Void)?
    var onSurfaceVacuumChange: (() -> Void)?
    /// True when a forceSet (parsed from a QE output) is present — the sidebar
    /// gates the Forces section on this so force-less files show no empty controls.
    var hasForceSet: Bool = false
    /// Draw force arrows (when a forceSet is present). Synced to scene.showForces
    /// in syncFromState(); meaningless without a forceSet.
    @Published var showForces: Bool = true { didSet { onChange?() } }
    /// Å-per-(eV/Å) arrow-length multiplier. Synced to scene.forceScale.
    @Published var forceScale: Float = 50.0 { didSet { onChange?() } }
    /// MSAA sample count for the Metal render target. Bound to the Appearance
    /// sidebar picker (Off/2x/4x/8x); the raw value IS the sample count.
    @Published var msaaSampleCount: Int = 1 { didSet { onChange?() } }
    /// Scene-object opacity (0 = transparent, 1 = opaque). At 1.0 the output is
    /// identical to the original opaque path.
    @Published var opacity: Float = 1.0 { didSet { onChange?() } }
    /// Line width in pixels for scene lines. 1 = original 1px.
    @Published var lineWidth: Float = 1.0 { didSet { onChange?() } }
    /// Depth-cueing (fog) strength: 0 = off; >0 fades distant fragments.
    @Published var depthCueingStrength: Float = 0.0 { didSet { onChange?() } }
    /// Ambient-occlusion strength: 0 = off; >0 darkens atoms/bonds.
    @Published var aoStrength: Float = 0.0 { didSet { onChange?() } }
    /// Soft-shadow strength: 0 = off; >0 darkens sides of atoms/bonds.
    @Published var shadowStrength: Float = 0.0 { didSet { onChange?() } }
    /// AO quality level (0 = off, 1 = low, 2 = medium, 3 = high).
    @Published var aoQuality: Int = 2 { didSet { onChange?() } }
    /// Soft-shadow quality level (0 = off, 1 = low, 2 = medium, 3 = high).
    @Published var shadowQuality: Int = 2 { didSet { onChange?() } }
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
    /// Per-frame playback multiplier. View-only (not persisted). The playback
    /// timer's interval is `0.1 / max(0.1, playbackSpeed)` (clamped 0.1...20
    /// defensively in the controller).
    @Published var playbackSpeed: Float = 1.0 { didSet { onChange?() } }
    /// When true the playback timer wraps from the last frame back to 0 instead
    /// of stopping. View-only (not persisted).
    @Published var loopPlayback: Bool = false { didSet { onChange?() } }
    /// Whether to draw the trajectory-trail line strip through each atom's
    /// per-frame positions. View-only; the controller computes the vertex strip
    /// from the loaded frames and pushes it to the renderer.
    @Published var showTrajectoryTrails: Bool = false { didSet { onChange?() } }
    /// Evenly-sampled thumbnail images for the timeline strip (at most
    /// TimelineThumbnails.maxCount, always including frame 0). Runtime-only;
    /// populated by the controller on a background queue, never persisted.
    @Published private(set) var timelineThumbnails: [CGImage] = []
    /// Per-frame derived metrics (volume, energy, force, RMSD). Runtime-only;
    /// populated by the controller, never persisted.
    @Published var frameMetrics: [FrameMetric] = []
    var onChange: (() -> Void)?
    /// Invoked when the user taps a timeline thumbnail; the controller sets
    /// state.frameIndex to the thumbnail's source frame index.
    var onSeekToThumbnail: ((Int) -> Void)?
    /// Invoked to present a save panel and write the per-frame metrics CSV.
    var onExportFrameMetricsCSV: ((String) -> Void)?
    /// Invoked (with the chosen save URL) to export the animation as GIF/APNG/MP4.
    var onExportAnimation: ((URL) -> Void)?
    /// Invoked (with the chosen save URL) to save the current project.
    var onSaveProject: ((URL) -> Void)?
    /// Whether the trajectory-trail overlay has been computed for the current
    /// animation (so the controller can avoid redundant frame loads).
    var trajectoryTrailsAvailable = false

    /// Pure frame-stepping logic shared by the playback timer. Returns the next
    /// frame index, or nil when playback should stop (no loop and past the end).
    /// `count` <= 0 is treated as "no animation" (returns nil).
    static func nextFrame(after current: Int, count: Int, loop: Bool) -> Int? {
        guard count > 0 else { return nil }
        if current + 1 < count { return current + 1 }
        return loop ? 0 : nil
    }

    /// Replace the cached timeline thumbnails. The property is `private(set)`
    /// so the controller sets it through this method rather than directly.
    func setTimelineThumbnails(_ images: [CGImage]) {
        timelineThumbnails = images
    }
    /// Invoked when the user taps "Reset View" in the sidebar.
    var onResetView: (() -> Void)?
    /// Invoked when the user chooses one of the standard crystallographic
    /// orientations in the Display section.
    var onStandardCrystalView: ((StandardCrystalView) -> Void)?
    /// Camera bookmark actions are wired by MainWindowController. Slot indices
    /// are validated again by the controller because SwiftUI callbacks can outlive
    /// the row that created them.
    var onSaveCameraBookmark: ((Int) -> Void)?
    var onRecallCameraBookmark: ((Int) -> Void)?
    var onClearCameraBookmark: ((Int) -> Void)?
    /// Export the given k-path in the requested format (the controller presents
    /// a save panel and writes the text). `.qe` => QE K_POINTS crystal;
    /// `.qeCrystalB` => QE K_POINTS crystal_b band-path rows, one special point
    /// per line with a per-line subdivision weight; `.qeTpibaB` => QE
    /// K_POINTS tpiba_b rows converted through the active cell; `.wannier90` =>
    /// Wannier90 kpoint_path block; `.kpf` => XCrySDen native k-path file;
    /// `.vasp` => VASP line-mode KPOINTS.
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
    // --- Powder XRD (view-state only, NOT persisted) -------------------------------
    /// Index into PowderXRD.wavelengthOptions for the selected incident radiation.
    @Published var xrdWavelengthIndex: Int = 0 { didSet { onChange?() } }
    /// Maximum 2θ (degrees) computed and displayed.
    @Published var xrdMaxTwoTheta: Float = 120 { didSet { onChange?() } }
    /// Peak broadening FWHM (degrees 2θ) for the synthesized curve.
    @Published var xrdFWHM: Float = 0.5 { didSet { onChange?() } }
    /// Toggle Miller-index labels above peak sticks.
    @Published var xrdShowLabels: Bool = true { didSet { onChange?() } }
    /// When true and a volumetric field is present, project electron density
    /// instead of using nuclear scattering factors.
    @Published var xrdUseElectronDensity: Bool = false { didSet { onChange?() } }
    /// Computed XRD pattern for the current scene/settings. Set by the controller;
    /// nil when unavailable. Not a scene field.
    @Published var xrdPattern: XRDPattern? = nil
    /// Human-readable status text ("N peaks · source: ..."). Not a scene field.
    @Published var xrdStatusText: String = ""
    /// Present the standalone Powder XRD graph window.
    var onShowXRDWindow: (() -> Void)?
    /// Export the current XRD pattern as CSV.
    var onExportXRDCSV: (() -> Void)?

    /// Apply a publication preset's quality settings to this state. The preset
    /// is an action (not document state): it sets multiple quality fields at
    /// once without being persisted or synced back from the scene.
    func applyPreset(_ preset: PublicationPreset) {
        var tmp = Scene()
        preset.apply(to: &tmp)
        opacity = tmp.opacity
        lineWidth = tmp.lineWidth
        depthCueingStrength = tmp.depthCueingStrength
        aoStrength = tmp.aoStrength
        shadowStrength = tmp.shadowStrength
        aoQuality = tmp.aoQuality
        shadowQuality = tmp.shadowQuality
    }

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
        showBondDistances = scene.showBondDistances
        showScaleIndicator = scene.showScaleIndicator
        showBrillouinZone = scene.showBrillouinZone
        isCrystal = scene.isCrystal
        crystalSymmetry = scene.crystalSymmetry
        refreshStandardCrystalViewAvailability(cell: scene.cell,
                                               reciprocalEditing: false)
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
        backgroundImagePath = scene.backgroundImagePath
        anaglyphMode = scene.anaglyphMode
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
        // Cap the spec list at 8 on load; the renderer enforces the same cap.
        isoSurfaces = Array(scene.isoSurfaces.prefix(8))
        nextIsoPaletteIndex = isoSurfaces.count % SideBarState.isoPalette.count
        // Clipping plane: nil when absent or when there is no cell to filter against.
        clipPlane = scene.cell != nil ? scene.clipPlane : nil
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
        // Color-plane colormap + contour configuration.
        colorPlaneColormap = scene.colorPlaneColormap
        colorPlaneContourEnabled = scene.colorPlaneContourEnabled
        colorPlaneContourCount = scene.colorPlaneContourCount
        // Volume slices: cap at 3 on load; the renderer enforces the same cap.
        volumeSlices = Array(scene.volumeSlices.prefix(3))
        msaaSampleCount = scene.msaaSampleCount
        opacity = scene.opacity
        lineWidth = scene.lineWidth
        depthCueingStrength = scene.depthCueingStrength
        aoStrength = scene.aoStrength
        shadowStrength = scene.shadowStrength
        aoQuality = scene.aoQuality
        shadowQuality = scene.shadowQuality
        // --- Structure tools (runtime-only, not persisted) ---
        // Availability + help text follow the scene's symmetry analysis; the
        // user-preference fields (deformation matrix, cluster, surface h/k/l, ...)
        // deliberately keep their values across loads. cellRepresentation is owned
        // by the controller (currentCellRepresentation) and mirrored separately.
        let structureSym = scene.crystalSymmetry?.symmetry
        let structure3D = scene.isCrystal && scene.periodicDim == 3
            && scene.cell != nil && !scene.atoms.isEmpty
        let structurePrimAvail = structure3D
            && (structureSym?.primitiveStructure.atomCount ?? 0) < scene.atoms.count
        let structureConvAvail = structure3D && structureSym != nil
        primitiveTransformAvailable = structurePrimAvail
        conventionalTransformAvailable = structureConvAvail
        basisTransformHelp = structure3D && structureSym == nil
            ? (scene.crystalSymmetry?.reasonDescription ?? "symmetry analysis unavailable")
            : ""
        surfaceBuilderAvailable = structure3D
        surfaceTerminationOptions = 0
        // Structure editing availability mirrors the engine's editability gate
        // (pristine geometry within the atom cap).
        structureEditingAvailable = scene.isStructureEditable
        if let params = scene.cellParameters {
            latticeA = params.a
            latticeB = params.b
            latticeC = params.c
            latticeAlpha = params.alpha
            latticeBeta = params.beta
            latticeGamma = params.gamma
        }
        // Transient status lines describe the previous scene's actions.
        structureToolsStatusText = ""
        surfaceStatusText = ""
        structureEditStatusText = ""
        // The vacuum slider shows the derived vacuum (c length minus slab extent)
        // for a z-parallel 2D slab, so the live-vacuum comparisons are consistent.
        if scene.periodicDim == 2, let cell = scene.cell, cell.isCZParallel,
           let extent = scene.surfaceSlabExtent {
            surfaceVacuum = max(0, cell.cLength - extent)
        }
        surfaceVacuumAdjustable = scene.periodicDim == 2
            && scene.cell?.isCZParallel == true && scene.surfaceSlabExtent != nil
        onChange = saved
    }

    /// Mirror the controller's basis-transform availability computation into state.
    /// The controller owns the `currentCellRepresentation`; the scene owns the
    /// symmetry result. Neither is settable from here, so the controller passes the
    /// fully-resolved values in.
    func applyBasisTransformAvailability(primitive: Bool, conventional: Bool,
                                         help: String, representation: CellRepresentation) {
        primitiveTransformAvailable = primitive
        conventionalTransformAvailable = conventional
        basisTransformHelp = help
        cellRepresentation = representation
    }

    /// Set the runtime-only structure-tools status line (basis/deformation/cluster).
    func setStructureToolsStatus(_ text: String) {
        structureToolsStatusText = text
    }

    /// Set the runtime-only structure-editing status line (defects/lattice/export).
    func setStructureEditStatus(_ text: String) {
        structureEditStatusText = text
    }

    /// Set the runtime-only surface-builder status line + termination availability.
    func setSurfaceStatus(_ text: String, terminationOptions: Int, termination: Int) {
        surfaceStatusText = text
        surfaceTerminationOptions = terminationOptions
        surfaceTermination = termination
    }

    /// Replace the runtime-only camera-bookmark occupancy and names when a
    /// document is installed. A short/malformed input is padded or truncated to
    /// exactly CameraBookmark.slotCount slots. Empty slots receive their stable
    /// default name; occupied slots use the persisted bookmark name.
    func syncCameraBookmarkSlots(_ bookmarks: [CameraBookmark?]) {
        var names = cameraBookmarkNames
        if names.count != CameraBookmark.slotCount {
            names = (0..<CameraBookmark.slotCount).map { "View \($0 + 1)" }
        }
        var availability = Array(repeating: false, count: CameraBookmark.slotCount)
        for index in 0..<CameraBookmark.slotCount {
            let bookmark = bookmarks.indices.contains(index) ? bookmarks[index] : nil
            availability[index] = bookmark != nil
            names[index] = bookmark.map { String($0.name.prefix(32)) } ?? "View \(index + 1)"
        }
        cameraBookmarkNames = names
        cameraBookmarkAvailability = availability
    }

    /// Bounds-safe accessors used by the sidebar's dynamic rows. Bookmark names
    /// are UI-only, so editing one never invokes the scene synchronization hook.
    func cameraBookmarkName(at index: Int) -> String {
        guard cameraBookmarkNames.indices.contains(index) else { return "" }
        return cameraBookmarkNames[index]
    }

    func setCameraBookmarkName(at index: Int, to name: String) {
        guard cameraBookmarkNames.indices.contains(index) else { return }
        let bounded = String(name.prefix(32))
        guard cameraBookmarkNames[index] != bounded else { return }
        var names = cameraBookmarkNames
        names[index] = bounded
        cameraBookmarkNames = names
    }

    /// Return the name used when saving a slot. Blank names fall back to the
    /// stable default without changing the text field until a save succeeds.
    func cameraBookmarkSaveName(at index: Int) -> String? {
        guard cameraBookmarkNames.indices.contains(index) else { return nil }
        let trimmed = cameraBookmarkNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "View \(index + 1)" : String(trimmed.prefix(32))
    }

    /// Bounds-safe occupancy read used by the sidebar to disable empty slots.
    func cameraBookmarkIsAvailable(at index: Int) -> Bool {
        guard cameraBookmarkAvailability.indices.contains(index) else { return false }
        return cameraBookmarkAvailability[index]
    }

    /// Update one slot's runtime occupancy without touching its displayed name.
    /// Clear therefore retains a user's name for the next save.
    func setCameraBookmarkOccupied(at index: Int, _ occupied: Bool) {
        guard cameraBookmarkAvailability.indices.contains(index) else { return }
        var availability = cameraBookmarkAvailability
        availability[index] = occupied
        cameraBookmarkAvailability = availability
    }

    /// Refresh the runtime-only availability and help text for the standard
    /// crystallographic orientation buttons. `reciprocalEditing` is supplied by
    /// the controller because that mode is transient and is not a Scene field.
    /// The assignments are intentionally free of `onChange` notifications: these
    /// values describe UI availability and must never feed back into scene sync.
    func refreshStandardCrystalViewAvailability(cell: Cell?, reciprocalEditing: Bool) {
        let help: String
        let available: Bool

        if reciprocalEditing {
            available = false
            help = "Standard crystallographic views are unavailable while editing the reciprocal-space k-path."
        } else if displayMode.is2D {
            available = false
            help = "Standard crystallographic views are unavailable in 2D display mode."
        } else if let cell {
            if let reason = Camera.standardCrystalViewUnavailableReason(cell: cell) {
                available = false
                help = reason
            } else {
                available = true
                help = "Align the camera to a standard crystallographic direction."
            }
        } else {
            available = false
            help = "Standard crystallographic views require a valid unit cell."
        }

        if standardCrystalViewAvailable != available {
            standardCrystalViewAvailable = available
        }
        if standardCrystalViewHelp != help {
            standardCrystalViewHelp = help
        }
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

    // MARK: - Isosurface spec list helpers

    /// Add a new iso spec seeded at the current isoLevel, sign +1, with the next
    /// palette color. No-op when already at the 8-spec cap.
    func addIsoSurfaceSpec() {
        guard isoSurfaces.count < 8 else { return }
        let color = SideBarState.isoPalette[nextIsoPaletteIndex % SideBarState.isoPalette.count]
        nextIsoPaletteIndex += 1
        isoSurfaces.append(IsoSurfaceSpec(level: isoLevel, colorHex: color, sign: 1, enabled: true))
    }

    /// Remove the spec at `index`. No-op for an out-of-range index.
    func removeIsoSurfaceSpec(at index: Int) {
        guard isoSurfaces.indices.contains(index) else { return }
        isoSurfaces.remove(at: index)
    }

    /// Toggle a spec's enabled flag. No-op for an out-of-range index.
    func toggleIsoSurface(at index: Int) {
        guard isoSurfaces.indices.contains(index) else { return }
        isoSurfaces[index].enabled.toggle()
    }

    /// Clear the spec list back to the legacy ±pair behavior.
    func resetIsoSurfaces() {
        isoSurfaces = []
    }

    // MARK: - Volume slice list helpers

    /// Add a new volume slice (default h/k/l/distance, enabled). No-op when already
    /// at the 3-slice cap.
    func addVolumeSlice() {
        guard volumeSlices.count < 3 else { return }
        volumeSlices.append(VolumeSlice())
    }

    /// Remove the slice at `index`. No-op for an out-of-range index.
    func removeVolumeSlice(at index: Int) {
        guard volumeSlices.indices.contains(index) else { return }
        volumeSlices.remove(at: index)
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
    case structureTools = "SideBarCollapsed.structureTools"
    case animation = "SideBarCollapsed.animation"
    case coordination = "SideBarCollapsed.coordination"
    case electronicStructure = "SideBarCollapsed.electronicStructure"
    case clipping = "SideBarCollapsed.clipping"
    case region = "SideBarCollapsed.region"
    case volumeSlices = "SideBarCollapsed.volumeSlices"
    case stereo = "SideBarCollapsed.stereo"
    case xrd = "SideBarCollapsed.xrd"

    var defaultsKey: String { rawValue }
}

extension Cell {
    /// Length of the c lattice vector.
    var cLength: Float { sqrt(c.x * c.x + c.y * c.y + c.z * c.z) }
    /// True when the c lattice vector is parallel to the z-axis (its x and y
    /// components are negligible) — the conventional embedding for a 2D slab.
    var isCZParallel: Bool { abs(c.x) < 1e-5 && abs(c.y) < 1e-5 }
}
