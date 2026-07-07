import Foundation
import Combine

final class SideBarState: ObservableObject {
    @Published var displayMode: DisplayMode = .ballStick { didSet { onChange?() } }
    @Published var atomScale: Float = 0.35 { didSet { onChange?() } }
    @Published var bondRadius: Float = 0.10 { didSet { onChange?() } }
    @Published var showCellFrame: Bool = true { didSet { onChange?() } }
    @Published var showAxes: Bool = true { didSet { onChange?() } }
    @Published var backgroundHex: String = "#101014"
    @Published var n1: Int = 1
    @Published var n2: Int = 1
    @Published var n3: Int = 1
    @Published var slabEnabled: Bool = false
    @Published var slabA_h: Int = 0
    @Published var slabA_k: Int = 1
    @Published var slabA_l: Int = 0
    @Published var slabA_dist: Float = 0
    @Published var slabB_h: Int = 0
    @Published var slabB_k: Int = -1
    @Published var slabB_l: Int = 0
    @Published var slabB_dist: Float = 0
    var onChange: (() -> Void)?
}
