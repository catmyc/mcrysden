import XCTest
import Metal
import simd
@testable import MolVisApp
private enum Thrown: Error { case msg(String) }

final class CellRenderDiag: XCTestCase {
    private func fixture(_ name: String) throws -> Scene {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        return Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/\(name)")))
    }

    func testCellEnclosesAtoms() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.msg("noGPU") }
        let s = try fixture("si110.xsf")
        let r = try Renderer(device: device)
        r.scene = s
        r.currentCamera.center = SIMD3<Float>(1.35, 1.35, 1.35)
        r.currentCamera.distance = 12
        let w = 200, h = 200
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm; desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw Thrown.msg("noTex") }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        r.encode(to: cb, target: tex,
                 viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                 camera: r.currentCamera)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        var cMinX = w, cMinY = h, cMaxX = -1, cMaxY = -1
        var aMinX = w, aMinY = h, aMaxX = -1, aMaxY = -1
        // The corner orientation gizmo is a fixed screen-space overlay pinned to
        // the bottom-left corner (NDC ≈ -0.82, -0.82, arm length 0.10). Its bright
        // pixels would otherwise be misclassified as atoms and inflate the atom
        // bbox, so skip any pixel whose NDC coordinate falls in that corner box.
        // This is viewport-size independent: pixel -> NDC, then compare.
        func inGizmoCorner(_ x: Int, _ y: Int) -> Bool {
            let ndcX = (Float(x) / Float(w)) * 2.0 - 1.0
            let ndcY = 1.0 - (Float(y) / Float(h)) * 2.0 // row 0 = top = +NDC y
            return ndcX < -0.70 || ndcY < -0.70
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y*w+x)*4
                let red = px[i], g = px[i+1], b = px[i+2]
                if red == g && g == b && red > 60 {
                    cMinX = min(cMinX, x); cMinY = min(cMinY, y); cMaxX = max(cMaxX, x); cMaxY = max(cMaxY, y)
                } else if red > 30 || g > 30 || b > 30 {
                    if inGizmoCorner(x, y) { continue } // skip the corner-gizmo axes
                    aMinX = min(aMinX, x); aMinY = min(aMinY, y); aMaxX = max(aMaxX, x); aMaxY = max(aMaxY, y)
                }
            }
        }
        print("[cell-render] cellBBox=(\(cMinX),\(cMinY))..(\(cMaxX),\(cMaxY))")
        print("[cell-render] atomBBox=(\(aMinX),\(aMinY))..(\(aMaxX),\(aMaxY))")
        let inside = aMinX >= cMinX-2 && aMaxX <= cMaxX+2 && aMinY >= cMinY-2 && aMaxY <= cMaxY+2
        print("[cell-render] atomsInsideCellBBox=\(inside)")
        XCTAssertTrue(cMaxX > 0, "cell frame was not drawn (no grey pixels found)")
        XCTAssertTrue(inside, "atoms should sit inside the cell-frame bounding box")
    }
}
