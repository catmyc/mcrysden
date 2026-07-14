import AppKit
import Foundation
import simd

// Color-plane / 2D-contour rendering for a 2D scalar field (XSF DATAGRID_2D). The grid
// is drawn as a value→color bitmap (a perceptual viridis-like map) in an NSView, like
// XCrySDen's colorplane. Tier A #4 — falls out of the field engine once the 2D grid is
// parsed. Also renders iso-contour lines over the colormap for the same field.
final class ColorPlaneView: NSView {
    /// A 2D scalar grid sampled from a 3D field's slice, or read directly from a DATAGRID_2D.
    var grid: [[Float]]? {
        didSet { needsDisplay = true }
    }
    /// The grid's world-space span vectors (col-axis, row-axis). When BOTH are
    /// present, the view projects the skew plane with an affine map that
    /// preserves the vectors' lengths AND the angle between them — so a skew
    /// DATAGRID plane renders as a parallelogram, not a stretched rectangle.
    /// Empty -> the bitmap fills the view (slice grids without stored geometry).
    var physicalSpan: [SIMD3<Float>] = []
    /// Optional iso-contour levels to trace over the colormap.
    var contourLevels: [Float] = []
    var zLabel: String = ""

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let grid, !grid.isEmpty,
              let firstRow = grid.first, !firstRow.isEmpty
        else { NSColor.white.setFill(); dirtyRect.fill(); drawEmpty(); return }

        let rows = grid.count
        let cols = firstRow.count
        // A jagged (non-rectangular) grid would over-run row buffers; treat it as empty
        // rather than crash (project principle: never crash on malformed input).
        guard grid.allSatisfy({ $0.count == cols }) else {
            NSColor.white.setFill(); dirtyRect.fill(); return
        }
        guard let cg = renderBitmap(grid, rows: rows, cols: cols) else {
            NSColor.white.setFill(); dirtyRect.fill(); return
        }

        // Projection from normalized grid coords (u in [0,1] across cols, v in
        // [0,1] down rows) to view pixels. With both span vectors we build a 2D
        // basis (Gram-Schmidt on vec[0],vec[1]) that keeps their relative length
        // AND angle; without them the unit square fills the view.
        let project = makeProjection(rows: rows, cols: cols)

        // Draw the bitmap into the projected unit square via an affine transform,
        // so a skew plane maps to a parallelogram instead of a rectangle.
        var t = project.affine   // maps (u,v) -> pixel
        ctx.concatenate(t)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.concatenate(t.inverted())

        // Contour lines on top, traced in the same projected space.
        if !contourLevels.isEmpty {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            for level in contourLevels {
                traceContour(grid, rows: rows, cols: cols, level: level, project: project.point)
            }
        }
        drawTitle()
    }

    /// Projection of normalized grid coords (u∈[0,1]×v∈[0,1]) to view pixels.
    /// `point(u,v)` gives a pixel; `affine` is the matching CGAffineTransform.
    private struct GridProjection {
        let point: (CGFloat, CGFloat) -> NSPoint
        let affine: CGAffineTransform
    }

    private func makeProjection(rows: Int, cols: Int) -> GridProjection {
        let viewW = bounds.width, viewH = bounds.height
        guard viewW > 0, viewH > 0, cols > 1, rows > 1 else {
            return GridProjection(point: { _,_ in .zero }, affine: .identity)
        }

        // 2D basis from the two span vectors (Gram-Schmidt). Because the basis is
        // orthonormal, the grid keeps its true shape: length ratio AND angle.
        let v0 = physicalSpan.count > 0 ? physicalSpan[0] : SIMD3<Float>(1, 0, 0)
        let v1 = physicalSpan.count > 1 ? physicalSpan[1] : SIMD3<Float>(0, 1, 0)
        let len0 = simd_length(v0)
        let e1 = len0 > 1e-6 ? (v0 / len0) : SIMD3<Float>(1, 0, 0)
        let v1perp = v1 - e1 * simd_dot(v1, e1)
        let len1p = simd_length(v1perp)
        let e2 = len1p > 1e-6 ? (v1perp / len1p) :perp(e1)
        // 2D coordinates of a sample (u,v): dot(u*v0 + v*v1, e1/e2).
        // Corner (u,v) in 2D: U=u*|v0|, and V along e2 from v1's perpendicular.
        let bu = CGFloat(len0)                 // e1 extent per unit u
        let bvx = CGFloat(simd_dot(v1, e1))    // e1 extent per unit v
        let bvy = CGFloat(len1p)               // e2 extent per unit v

        // Bounding box of the parallelogram (u,v)∈[0,1]² in 2D.
        let corners: [(CGFloat, CGFloat)] = [(0,0),(1,0),(0,1),(1,1)].map { (su, sv) in
            let e1c = su * bu + sv * bvx
            let e2c = sv * bvy
            return (e1c, e2c)
        }
        let xs = corners.map { $0.0 }, ys = corners.map { $0.1 }
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let spanW = maxX - minX, spanH = maxY - minY

        // Uniform scale so the whole parallelogram fits, then center it. A
        // uniform scale preserves the angle; independent x/y scaling would not.
        // A degenerate span (vectors parallel or a zero-length span) would divide by
        // zero -> infinite scale and an un-drawable parallelogram; fall back to a
        // uniform scaled unit square CENTERED in the view so the bitmap occupies a
        // sensible area instead of a single top-left pixel. The affine MUST match the
        // point() mapping below exactly, or the bitmap (drawn via affine) and the
        // contours (drawn via point) would land in different places.
        let eps: CGFloat = 1e-6
        guard spanW > eps && spanH > eps else {
            let s = min(viewW, viewH) * 0.5
            let centerView = CGPoint(x: viewW / 2, y: viewH / 2)
            func projectUnit(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
                return NSPoint(x: centerView.x + (u - 0.5) * s, y: centerView.y - (v - 0.5) * s)
            }
            // Columns: +1 in u -> (+s, 0) px; +1 in v -> (0, -s) px (isFlipped).
            // Origin (u=v=0) maps to centerView - (s*0.5, -s*0.5).
            let affine = CGAffineTransform(a: s, b: 0, c: 0, d: -s,
                                           tx: centerView.x - s * 0.5,
                                           ty: centerView.y + s * 0.5)
            return GridProjection(point: projectUnit, affine: affine)
        }
        let s = min(viewW / spanW, viewH / spanH)
        // 2D origin (u=0,v=0) maps here; center the bbox in the view.
        let centerView = CGPoint(x: viewW / 2, y: viewH / 2)
        let center2D = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        func project(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
            let e1c = u * bu + v * bvx
            let e2c = v * bvy
            // isFlipped == true: v grows downward in AppKit; flip e2.
            let px = centerView.x + s * (e1c - center2D.x)
            let py = centerView.y - s * (e2c - center2D.y)
            return NSPoint(x: px, y: py)
        }

        // Matching affine: columns are the pixel steps for +1 in u and +1 in v.
        // du changes only the 2D x (e1) component -> a=bu*s, b=0.
        let a: CGFloat = bu * s
        let b: CGFloat = 0
        let c: CGFloat = bvx * s
        let d: CGFloat = -bvy * s   // minus for isFlipped (v downward)
        // tx,ty from u=v=0 corner.
        let p00 = project(0, 0)
        let affine = CGAffineTransform(a: a, b: b, c: c, d: d, tx: p00.x, ty: p00.y)
        return GridProjection(point: project, affine: affine)
    }

    /// A unit vector perpendicular to e1 (for the degenerate parallel-span case).
    private func perp(_ e1: SIMD3<Float>) -> SIMD3<Float> {
        let cand = abs(e1.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return normalize(cand - e1 * simd_dot(cand, e1))
    }

    /// Render the grid as a colormap bitmap via a viridis-style transfer.
    private func renderBitmap(_ g: [[Float]], rows: Int, cols: Int) -> CGImage? {
        let flat = g.flatMap { $0 }
        guard let vMin = flat.min(), let vMax = flat.max(), vMax > vMin else { return nil }
        let range = vMax - vMin
        let bytesPerRow = cols * 4
        var px = [UInt8](repeating: 0, count: rows * bytesPerRow)
        for y in 0..<rows {
            for x in 0..<cols {
                let t = (g[y][x] - vMin) / range
                let (r, gr, b) = viridis(t)
                let o = (y * cols + x) * 4
                px[o] = r; px[o+1] = gr; px[o+2] = b; px[o+3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bmp = CFDataCreate(nil, px, px.count),
              let provider = CGDataProvider(data: bmp),
              let cg = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: bytesPerRow, space: cs,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return cg
    }

    /// Trilinear viridis-style colormap, t in [0,1].
    private func viridis(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let tt = max(0, min(1, t))
        // polynomial approximation of viridis
        let r = max(0, min(1, 0.267004 + tt*(0.003295 + tt*(-0.227411 + tt*(2.787674 + tt*(-2.719152 + tt*0.815994))))))
        let gr = max(0, min(1, 0.004874 + tt*(0.104041 + tt*(0.546790 + tt*(-1.248878 + tt*(0.745538 + tt*0.207481))))))
        let b = max(0, min(1, 0.329415 + tt*(1.015680 + tt*(-2.129948 + tt*(2.600750 + tt*(-1.737255 + tt*0.472965))))))
        return (UInt8(r*255.5), UInt8(gr*255.5), UInt8(b*255.5))
    }

    /// Marching-squares contour trace for a single iso level, drawn in view coords.
    ///
    /// Crossing positions are LINEARLY INTERPOLATED between the two corner values
    /// on each edge (not placed at fixed midpoints). Cell size uses (cols-1) and
    /// (rows-1) since `cols` samples span `cols-1` intervals. Four-crossing saddle
    /// cells produce TWO segments; pairing them by the center value resolves the
    /// saddle ambiguity instead of dropping one. Geometry is computed by the pure
    /// `contourSegments` helper (unit-tested directly) and mapped into view space.
    private func traceContour(_ g: [[Float]], rows: Int, cols: Int, level: Float,
                              project: (CGFloat, CGFloat) -> NSPoint) {
        guard cols > 1, rows > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = 0.8
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let tl = g[y][x], tr = g[y][x + 1], br = g[y + 1][ x + 1], bl = g[y + 1][x]
                for seg in ColorPlaneView.contourSegments(tl: tl, tr: tr, br: br, bl: bl, level: level) {
                    // seg points are in cell-local (u,v)∈[0,1]²; add cell offset and
                    // project through the (skew-aware) grid map.
                    let fu0 = CGFloat(x) + CGFloat(seg[0].x), fv0 = CGFloat(y) + CGFloat(seg[0].y)
                    let fu1 = CGFloat(x) + CGFloat(seg[1].x), fv1 = CGFloat(y) + CGFloat(seg[1].y)
                    path.move(to: project(fu0 / CGFloat(cols - 1), fv0 / CGFloat(rows - 1)))
                    path.line(to: project(fu1 / CGFloat(cols - 1), fv1 / CGFloat(rows - 1)))
                }
            }
        }
        path.stroke()
    }

    /// Pure marching-squares geometry for one cell: given the four corner values
    /// (tl, tr, br, bl) and an iso level, returns the contour segment(s) as pairs of
    /// points in normalized cell coordinates (u,v in 0..1, origin top-left).
    ///
    /// Edge crossings are interpolated linearly between corner values. The four
    /// edges are sampled clockwise (top, right, bottom, left); a 2-crossing cell
    /// yields one segment, a 4-crossing (saddle) cell yields two, paired by the
    /// center value to resolve the topological ambiguity.
    static func contourSegments(tl: Float, tr: Float, br: Float, bl: Float, level: Float)
        -> [[SIMD2<Float>]] {
        // Crossing parameter t in 0..1 along the edge from value a to value b.
        func crossT(_ a: Float, _ b: Float) -> Float {
            let d = b - a
            return abs(d) < 1e-9 ? 0.5 : (level - a) / d
        }
        // Corners in normalized cell coords (u rightward, v downward): tl(0,0)
        // tr(1,0) / bl(0,1) br(1,1). Each crossing is interpolated from the corner
        // with the same name as the edge start. The bottom and left edges were the
        // bug: wrapping them as `1 - crossT(...)` reflected the crossing to the wrong
        // side of the edge. They read clockwise from bl and tl respectively:
        //   bottom bl->br: u along the edge = crossT(bl,br), v = 1
        //   left    tl->bl: v along the edge = crossT(tl,bl), u = 0
        let top = SIMD2<Float>(crossT(tl, tr), 0)          // tl->tr
        let right = SIMD2<Float>(1, crossT(tr, br))        // tr->br
        let bottom = SIMD2<Float>(crossT(bl, br), 1)       // bl->br
        let left = SIMD2<Float>(0, crossT(tl, bl))          // tl->bl
        var pts: [SIMD2<Float>] = []
        if (tl < level) != (tr < level) { pts.append(top) }
        if (tr < level) != (br < level) { pts.append(right) }
        if (br < level) != (bl < level) { pts.append(bottom) }
        if (bl < level) != (tl < level) { pts.append(left) }
        if pts.count == 2 {
            return [pts]
        } else if pts.count == 4 {
            // Saddle cell: two segments. Resolve the ambiguity with the bilinear
            // ASYMPTOTIC DECIDER — the value of the bilinear interpolant at its saddle
            // point (where the gradient vanishes), NOT the cell-centre average. The
            // centre value coincides with the saddle value only for symmetric saddles;
            // for asymmetric fields (e.g. tl=10,tr=-2,br=0.1,bl=-2 at level 0) they
            // disagree and the centre value gives the WRONG connectivity. The bilinear
            // f(u,v) = a + bu + cv + duv has saddle at u*=-c/d, v*=-b/d with value
            // f* = a - bc/d; comparing f* to the level picks the correct pairing.
            let a = tl
            let b = tr - tl
            let c = bl - tl
            let d = br - tr - bl + tl
            let useSaddle = abs(d) > 1e-6
            // Degenerate case (d ≈ 0): the bilinear collapses toward a plane and the
            // saddle value is undefined; fall back to the true cell-centre value of the
            // bilinear, f(0.5,0.5) = a + b/2 + c/2 + d/4 = (tl+tr+bl+br)/4. (The naive
            // (a+b+c+d)/4 would give br/4, which is wrong.)
            let fSaddle = useSaddle ? (a - b * c / d) : (tl + tr + bl + br) / 4
            if fSaddle >= level {
                return [[pts[0], pts[1]], [pts[2], pts[3]]]   // (top,right),(bottom,left)
            } else {
                return [[pts[0], pts[3]], [pts[1], pts[2]]]   // (top,left),(right,bottom)
            }
        }
        return []
    }

    private func drawEmpty() {
        NSColor.gray.set()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.gray]
        let s = NSAttributedString(string: "No 2D field", attributes: attrs)
        var pt = NSPoint(x: bounds.midX - s.size().width/2, y: bounds.midY)
        s.draw(at: pt)
    }

    private func drawTitle() {
        guard !zLabel.isEmpty else { return }
        NSColor.white.set()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: zLabel, attributes: attrs)
        s.draw(at: NSPoint(x: 6, y: 6))
    }
}
