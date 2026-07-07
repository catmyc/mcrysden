import XCTest
import simd
@testable import MolVisApp

// Regression guard for the horizontal-drag inversion bug. The grabbed point
// on the structure must follow the mouse: drag right -> point moves right.
// (Vertical drag direction was confirmed correct by the user and is unchanged.)
final class DragSignTest: XCTestCase {
    private func drag(_ cam: inout Camera, dx: Float, dy: Float) {
        let rotX = simd_quatf(angle: dy * 0.01, axis: SIMD3(1,0,0))
        let rotY = simd_quatf(angle: -dx * 0.01, axis: SIMD3(0,1,0))
        cam.rotation = rotY * rotX * cam.rotation
    }
    private func projectX(_ cam: Camera, _ p: SIMD3<Float>) -> Float {
        let clip = cam.projectionMatrix(aspect: 1) * cam.viewMatrix() * SIMD4(p.x, p.y, p.z, 1)
        return (clip.x / clip.w) * 0.5 + 0.5
    }
    func testRightDragMovesPointRight() {
        let grab = SIMD3<Float>(0.5, 0.2, 0.8)
        var cam = Camera(); cam.center = .zero; cam.distance = 6
        let before = projectX(cam, grab)
        drag(&cam, dx: 12, dy: 0)
        let after = projectX(cam, grab)
        print("[drag-sign] right-drag dx: before=\(before) after=\(after)")
        XCTAssertGreaterThan(after, before, "dragging right must move the grabbed point to the right")
    }
    func testLeftDragMovesPointLeft() {
        let grab = SIMD3<Float>(0.5, 0.2, 0.8)
        var cam = Camera(); cam.center = .zero; cam.distance = 6
        let before = projectX(cam, grab)
        drag(&cam, dx: -12, dy: 0)
        let after = projectX(cam, grab)
        print("[drag-sign] left-drag  dx: before=\(before) after=\(after)")
        XCTAssertLessThan(after, before, "dragging left must move the grabbed point to the left")
    }
}
