import Foundation
import Combine

final class SideBarState: ObservableObject {
    @Published var displayMode: DisplayMode = .ballStick { didSet { onChange?() } }
    @Published var atomScale: Float = 0.35 { didSet { onChange?() } }
    @Published var bondRadius: Float = 0.10 { didSet { onChange?() } }
    @Published var showCellFrame: Bool = true { didSet { onChange?() } }
    @Published var showAxes: Bool = true { didSet { onChange?() } }
    @Published var showLabels: Bool = false { didSet { onChange?() } }
    @Published var backgroundHex: String = "#101014" { didSet { onChange?() } }
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
    var onChange: (() -> Void)?
    /// Invoked when the user taps "Reset View" in the sidebar.
    var onResetView: (() -> Void)?

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
        measurementMode = scene.measurementMode
        backgroundHex = scene.background
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
