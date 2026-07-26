import Foundation
import Combine

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
    @Published var measurementMode: MeasurementMode = .none { didSet { onChange?() } }
    /// k-path state (crystal only). points carry fractional coords + labels; when
    /// empty the editor offers the default high-symmetry path for the structure.
    @Published var kPathPoints: [KPoint] = [] { didSet { onChange?() } }
    /// UI-only: when true the user is editing the k-path by clicking BZ landmarks.
    /// Forces Brillouin-zone visibility on (handled in syncFromState). Exiting
    /// this mode does not itself change the route.
    @Published var editKPathOnBZ: Bool = false { didSet { onChange?() } }
    /// UI-only undo stack of prior routes (snapshots before each mutation), so the
    /// "Undo" control can step back. Bounded to 1024 entries.
    private var kPathUndo: [[KPoint]] = []
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
    /// `.kpf` => XCrySDen native k-path file.
    var onExportKPath: ((KPath, KPathExportFormat) -> Void)?
    /// Recalculate the default high-symmetry route for the current scene and
    /// install it (the "Default" control). The controller owns the scene, so it
    /// wires this to recompute `makeDefaultKPath`.
    var onResetKPath: (() -> Void)?

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
        // Mirror the scene's route: for a freshly-loaded crystal this is the
        // generated high-symmetry default; once the user edits it, the edited
        // route lives in the scene and must be copied back, never regenerated.
        kPathPoints = scene.kPathPoints
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
        showColorPlane = scene.grid2D != nil   // default to shown when a grid is present
        // Forces: gate the sidebar section on presence, reflect the toggle/scale.
        hasForceSet = (scene.forceSet != nil)
        showForces = scene.showForces
        forceScale = scene.forceScale
        onChange = saved
    }

    // MARK: - k-path editing (UI-only mutations; each fires onChange → sync)

    /// Record the current route on the undo stack before mutating it. Bounded so a
    /// long editing session cannot grow the stack without limit.
    private func pushUndo() {
        if kPathUndo.count >= 1024 { kPathUndo.removeFirst() }
        kPathUndo.append(kPathPoints)
    }

    /// Bound a single node's label to 64 chars. No-op for an out-of-range index or when
    /// the bounded value is unchanged (no undo entry pushed in that case).
    func updateLabel(at index: Int, to label: String) {
        guard kPathPoints.indices.contains(index) else { return }
        let bounded = String(label.prefix(64))
        guard kPathPoints[index].label != bounded else { return }
        pushUndo()
        kPathPoints[index].label = bounded
    }

    /// Swap a node with its predecessor. No-op at the top or out of range.
    func moveUp(at index: Int) {
        guard index > 0, index < kPathPoints.count else { return }
        pushUndo()
        kPathPoints.swapAt(index, index - 1)
    }

    /// Swap a node with its successor. No-op at the bottom or out of range.
    func moveDown(at index: Int) {
        guard index >= 0, index < kPathPoints.count - 1 else { return }
        pushUndo()
        kPathPoints.swapAt(index, index + 1)
    }

    /// Remove a node. No-op for an out-of-range index.
    func remove(at index: Int) {
        guard kPathPoints.indices.contains(index) else { return }
        pushUndo()
        kPathPoints.remove(at: index)
    }

    /// Undo the last mutation, restoring the route snapshot taken beforehand.
    /// No-op when there is nothing to undo.
    func undoLast() {
        guard let prev = kPathUndo.popLast() else { return }
        kPathPoints = prev
    }

    /// Clear the whole route. No-op (no undo entry) when already empty.
    func clear() {
        guard !kPathPoints.isEmpty else { return }
        pushUndo()
        kPathPoints = []
    }

    /// Reset to the generated default for the current scene. The controller owns
    /// the scene, so it recomputes the route via `onResetKPath`. No-op when no reset
    /// callback is wired.
    func resetToDefault() {
        guard onResetKPath != nil else { return }
        pushUndo()
        onResetKPath?()
    }

    /// Append a picked BZ landmark, capping the route at 1024 nodes and suppressing
    /// an exact fractional-coordinate repeat of the current last node (renaming a node
    /// must not defeat the duplicate check). Non-consecutive repeats (Gamma-X-Gamma)
    /// remain allowed.
    func append(_ point: KPoint) {
        if let last = kPathPoints.last, last.frac == point.frac { return }
        guard kPathPoints.count < 1024 else { return }
        pushUndo()
        kPathPoints.append(point)
    }
}
