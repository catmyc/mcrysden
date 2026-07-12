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
        // Draw the bitmap to fill the view.
        ctx.draw(cg, in: bounds)

        // Contour lines on top.
        if !contourLevels.isEmpty {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            for level in contourLevels {
                traceContour(grid, rows: rows, cols: cols, level: level)
            }
        }
        drawTitle()
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

    /// Marching-squares contour trace for a single iso level, drawn in view coordinates.
    private func traceContour(_ g: [[Float]], rows: Int, cols: Int, level: Float) {
        let W = bounds.width, H = bounds.height
        let cellW = W / CGFloat(cols), cellH = H / CGFloat(rows)
        let path = NSBezierPath()
        path.lineWidth = 0.8
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let tl = g[y][x], tr = g[y][x + 1], br = g[y + 1][x + 1], bl = g[y + 1][x]
                func pt(_ gx: Int, _ gy: Int) -> NSPoint {
                    NSPoint(x: (CGFloat(gx) + 0.5) * cellW, y: (CGFloat(gy) + 0.5) * cellH)
                }
                var seg: [NSPoint] = []
                if (tl < level) != (tr < level) { seg.append(NSPoint(x: pt(x + 1, y).x, y: pt(x, y).y)) }
                if (tr < level) != (br < level) { seg.append(pt(x + 1, y + 1)) }
                if (br < level) != (bl < level) { seg.append(NSPoint(x: pt(x, y + 1).x, y: pt(x + 1, y + 1).y)) }
                if (bl < level) != (tl < level) { seg.append(pt(x, y)) }
                if seg.count >= 2 {
                    path.move(to: seg[0]); path.line(to: seg[1])
                }
            }
        }
        path.stroke()
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
