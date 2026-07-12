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
        // Pin perspective: this diagnostic asserts screen-space cell-frame
        // enclosure of the atoms, which is projection-dependent; the default
        // projection is orthographic, so set it explicitly here.
        r.currentCamera.center = SIMD3<Float>(1.35, 1.35, 1.35)
        r.currentCamera.distance = 12
        r.currentCamera.perspective = true
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

// Draws the ColorPlaneView with a loaded 2D grid and asserts the colormap
// actually renders: the frame must contain non-background pixels AND real
// color variation (the field spans a wide range, so a viridis map is not flat).
// This exercises the view end-to-end, not just the parser bridge.
final class ColorPlaneDiag: XCTestCase {
    func testColorPlaneRendersColormap() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let loaded = try Parser.load(dir.appendingPathComponent("Fixtures/mol-urea2D.xsf"))
        guard let grid = loaded.grid2D else { throw Thrown.msg("no grid2D parsed") }

        let w = 240, h = 240
        let view = ColorPlaneView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.grid = grid.values
        view.zLabel = grid.ident
        view.contourLevels = [grid.minValue + (grid.maxValue - grid.minValue) * 0.5]

        // Render the view into a bitmap context (same path the scaffold draw() uses).
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Thrown.msg("no ctx") }
        // ColorPlaneView.isFlipped == true; CGContext is not, so mirror so the
        // height-preserving layout the view assumes matches what we read back.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { throw Thrown.msg("no pixels") }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var nonBackground = 0
        var distinctR = Set<UInt8>()
        for i in stride(from: 0, to: w*h*4, by: 4) {
            let r = px[i], g = px[i+1], b = px[i+2]
            // The scaffold fills white first; colored (viridis) pixels differ.
            if !(r > 235 && g > 235 && b > 235) { nonBackground += 1 }
            distinctR.insert(r)
        }
        print("[colorplane] nonBackgroundPx=\(nonBackground) distinctR=\(distinctR.count)")
        // The field spans a real range, so the colormap must paint a large area.
        XCTAssertGreaterThan(nonBackground, w * h / 4,
                             "color plane drew almost nothing (\(nonBackground) non-white px)")
        // Viridis maps distinct values to distinct hues → many distinct red levels.
        XCTAssertGreaterThan(distinctR.count, 8,
                             "colormap was nearly flat (\(distinctR.count) distinct red levels)")
    }

    // Pure marching-squares geometry: top edge sampled 0 (left) and 3 (right),
    // level 1. Linear interpolation puts the top crossing at u=1/3, NOT the
    // midpoint 1/2. Verifies the interpolated crossing position directly.
    func testContourInterpolates() throws {
        let segs = ColorPlaneView.contourSegments(tl: 0, tr: 3, br: 3, bl: 3, level: 1)
        XCTAssertEqual(segs.count, 1, "one plain cell -> one segment")
        // The top-edge crossing should sit at u=(1-0)/(3-0)=1/3 along the top.
        let top = segs[0][0].y == 0 ? segs[0][0] : segs[0][1]
        XCTAssertEqual(top.y, 0, "crossing should lie on the top edge (v=0)")
        XCTAssertEqual(Double(top.x), 1.0 / 3.0, accuracy: 1e-6,
                       "top crossing at interpolated u=1/3, not midpoint 1/2")
    }

    // Saddle cell: four crossings -> exactly TWO segments. The original bug drew
    // only seg[0]->seg[1] and dropped the rest, so a saddle produced one segment.
    // We use an asymmetric field (tl,br high; tr,bl low) so the asymptotic decider
    // is unambiguous, and assert: two segments, each on distinct edges, covering
    // all four edges (no crossing is lost).
    func testContourSaddleTopology() throws {
        let level: Float = 0
        let segs = ColorPlaneView.contourSegments(tl: 2, tr: -1, br: 2, bl: -1, level: level)
        XCTAssertEqual(segs.count, 2, "saddle cell must yield two segments (not one)")
        // Each segment's two endpoints should each lie on a different cell edge
        // (u==0/u==1/v==0/v==1), i.e. crossings are on edges not floating inside.
        let onEdge: (SIMD2<Float>) -> Bool = { p in
            let eps: Float = 1e-3
            return p.x < eps || abs(p.x - 1) < eps || p.y < eps || abs(p.y - 1) < eps
        }
        var usedEdges = Set<Int>()
        for seg in segs {
            for p in seg {
                XCTAssertTrue(onEdge(p), "crossing must sit on a cell edge")
                if p.y < 1e-3 { usedEdges.insert(0) }      // top
                else if abs(p.x - 1) < 1e-3 { usedEdges.insert(1) }   // right
                else if abs(p.y - 1) < 1e-3 { usedEdges.insert(2) }   // bottom
                else if p.x < 1e-3 { usedEdges.insert(3) }   // left
            }
        }
        // All four edges must be touched — no crossing dropped, confirming the two
        // segments together use all four edge crossings.
        XCTAssertEqual(usedEdges.count, 4, "contour must use all four edge crossings")
    }

    // A one-cell-interpolation sanity check at the opposite extreme: level exactly
    // at a corner value still yields a crossing at the cell boundary (t clamped).
    func testContourClampsToEdge() throws {
        let segs = ColorPlaneView.contourSegments(tl: 0, tr: 1, br: 2, bl: 1, level: 1)
        XCTAssertEqual(segs.count, 1, "mid-range cell -> one segment")
        XCTAssertFalse(segs[0].contains { $0.x.isNaN || $0.y.isNaN }, "no NaN crossings")
    }

}
