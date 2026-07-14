import XCTest

@testable import MolVisApp

final class AnimationControllerTests: XCTestCase {
    @MainActor
    func testQERelaxFrameChangeDoesNotReenterReload() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let initial = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(initial, from: url, format: nil, frameIndex: 0)

        XCTAssertEqual(controller.state.frameCount, 2)
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertEqual(controller.state.frameIndex, 1)

        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.currentFrame, 0)
        XCTAssertEqual(controller.state.frameIndex, 0)
    }
}
