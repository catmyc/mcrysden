import AppKit
import Foundation

// Color-plane / 2D-contour rendering for a 2D scalar field (XSF DATAGRID_2D). The grid
// is drawn as a value→color bitmap (a perceptual viridis-like map) in an NSView, like
// XCrySDen's colorplane. Tier A #4 — falls out of the field engine once the 2D grid is
// parsed. Also renders iso-contour lines over the colormap for the same field.
final class ColorPlaneView: NSView {
    /// A 2D scalar grid sampled from a 3D field's slice, or read directly from a DATAGRID_2D.
    var grid: [[Float]]? {
        didSet { needsDisplay = true }
    }
    /// The grid's physical aspect ratio (width/height in world units), from its
    /// span vectors. Drives aspect-preserving layout; if nil the bitmap fills the
    /// view (legacy behaviour for slice grids without stored geometry).
    var physicalAspect: CGFloat = 1
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
        guard let cg = renderBitmap(grid, rows: rows, cols: cols) else {
            NSColor.white.setFill(); dirtyRect.fill(); return
        }
        // Draw the bitmap preserving the grid's physical aspect ratio, centered
        // with letterbox bars — stretching to an arbitrary window size would skew
        // an anisotropic or skew plane.
        ctx.draw(cg, in: aspectFitRect(nativeW: cols, nativeH: rows, aspect: physicalAspect))

        // Contour lines on top, mapped into the same aspect-fit rect.
        if !contourLevels.isEmpty {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            for level in contourLevels {
                traceContour(grid, rows: rows, cols: cols, level: level)
            }
        }
        drawTitle()
    }

    /// Rectangle (in view coordinates) that fits a native-aspect rectangle of the
    /// given aspect ratio into the view bounds, centered.
    private func aspectFitRect(nativeW: Int, nativeH: Int, aspect: CGFloat) -> CGRect {
        let viewW = bounds.width, viewH = bounds.height
        guard viewW > 0, viewH > 0, nativeW > 0, nativeH > 0, aspect > 0
        else { return bounds }
        // Pixel spacing is uniform; the data has (cols) samples across and (rows)
        // down, so the sample grid's physical aspect is `aspect` (world units).
        let targetAspect = aspect
        var w = viewW
        var h = w / targetAspect
        if h > viewH { h = viewH; w = h * targetAspect }
        let x = (viewW - w) / 2
        let y = (viewH - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
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
    private func traceContour(_ g: [[Float]], rows: Int, cols: Int, level: Float) {
        // Map grid samples into the same aspect-fit rect the colormap is drawn in.
        let rect = aspectFitRect(nativeW: cols, nativeH: rows, aspect: physicalAspect)
        guard rect.width > 0, rect.height > 0, cols > 1, rows > 1 else { return }
        let cellW = rect.width / CGFloat(cols - 1)
        let cellH = rect.height / CGFloat(rows - 1)
        // Normalized cell coordinate (u,v in 0..1 across the cell) to view point.
        func P(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
            NSPoint(x: rect.origin.x + u * cellW, y: rect.origin.y + v * cellH)
        }
        let path = NSBezierPath()
        path.lineWidth = 0.8
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let tl = g[y][x], tr = g[y][x + 1], br = g[y + 1][ x + 1], bl = g[y + 1][x]
                for seg in ColorPlaneView.contourSegments(tl: tl, tr: tr, br: br, bl: bl, level: level) {
                    path.move(to: P(CGFloat(seg[0].x), CGFloat(seg[0].y)))
                    path.line(to: P(CGFloat(seg[1].x), CGFloat(seg[1].y)))
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
        let top = SIMD2<Float>(crossT(tl, tr), 0)          // u in 0..1 along top (v=0)
        let right = SIMD2<Float>(1, crossT(tr, br))        // v in 0..1 along right (u=1)
        let bottom = SIMD2<Float>(1 - crossT(bl, br), 1)    // u in 1..0 along bottom (v=1)
        let left = SIMD2<Float>(0, 1 - crossT(tl, bl))      // v in 1..0 along left (u=0)
        var pts: [SIMD2<Float>] = []
        if (tl < level) != (tr < level) { pts.append(top) }
        if (tr < level) != (br < level) { pts.append(right) }
        if (br < level) != (bl < level) { pts.append(bottom) }
        if (bl < level) != (tl < level) { pts.append(left) }
        if pts.count == 2 {
            return [pts]
        } else if pts.count == 4 {
            let center = (tl + tr + br + bl) / 4
            // Pair by center value: high-center joins top-right & bottom-left, etc.
            if center >= level {
                return [[pts[0], pts[1]], [pts[2], pts[3]]]
            } else {
                return [[pts[0], pts[3]], [pts[1], pts[2]]]
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
