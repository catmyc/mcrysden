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
        kPathPoints = MainWindowController.makeDefaultKPath(for: scene)
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
        onChange = saved
    }
}
