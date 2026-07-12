import AppKit

// Band-structure diagram. Drawn in `draw(_:)` with Core Graphics (NSBezierPath), the
// same 2D-overlay approach as LabelOverlayView — no Metal needed for a static plot.
// x-axis = k-path distance (cumulative fractional-reciprocal length), y-axis = energy
// in eV; a dashed Fermi-level line and high-symmetry k-point gridlines are overlaid.
final class BandGrapherView: NSView {
    var bandStructure: BandStructure? {
        didSet { needsDisplay = true }
    }
    /// Indices (into kDistances) of high-symmetry points to mark with vertical gridlines.
    var highSymmetryIndices: [Int] = []

    private let axisFont = NSFont.systemFont(ofSize: 11)
    private let titleFont = NSFont.boldSystemFont(ofSize: 13)
    private let margin = NSPoint(x: 64, y: 44)   // left/bottom margin for axes
    private let topMargin: CGFloat = 28

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let bs = bandStructure, bs.nKPoints > 1, bs.nBands > 0
        else { drawEmpty(dirtyRect); return }

        NSColor.white.setFill()
        dirtyRect.fill()

        let plot = NSPoint(x: bounds.width - 20, y: bounds.height - topMargin)
        let origin = NSPoint(x: margin.x, y: bounds.height - margin.y)
        let plotW = plot.x - origin.x
        let plotH = origin.y - plot.y

        let distances = bs.kDistances
        let xMin = distances.first!, xMax = distances.last!
        let allE = bs.kPoints.flatMap { $0.energies }
        var yMin = allE.min()!, yMax = allE.max()!
        // pad range and include the Fermi level in the visible window
        let yPad = max(0.5, (yMax - yMin) * 0.08)
        yMin -= yPad; yMax += yPad
        if bs.fermiEnergy < yMin { yMin = bs.fermiEnergy - 0.5 }
        if bs.fermiEnergy > yMax { yMax = bs.fermiEnergy + 0.5 }

        func proj(_ ix: Int, _ energy: Float) -> NSPoint {
            let fx = xMin == xMax ? 0 : CGFloat((distances[ix] - xMin) / (xMax - xMin))
            let fy = yMin == yMax ? 0.5 : CGFloat((energy - yMin) / (yMax - yMin))
            return NSPoint(x: origin.x + fx * plotW, y: origin.y - fy * plotH)
        }

        // --- box + axes ---
        let axis = NSColor.black
        axis.setStroke()
        let box = NSBezierPath()
        box.move(to: origin)
        box.line(to: NSPoint(x: origin.x + plotW, y: origin.y))
        box.line(to: NSPoint(x: origin.x + plotW, y: origin.y - plotH))
        box.line(to: NSPoint(x: origin.x, y: origin.y - plotH))
        box.close()
        box.lineWidth = 1
        box.stroke()

        // --- energy (y) axis ticks + label ---
        let yTicks = 5
        axis.setStroke()
        for i in 0...yTicks {
            let frac = CGFloat(i) / CGFloat(yTicks)
            let e = yMin + (yMax - yMin) * Float(frac)
            let p = NSPoint(x: origin.x, y: origin.y - plotH * frac)
            let tick = NSBezierPath()
            tick.move(to: p); tick.line(to: NSPoint(x: p.x - 4, y: p.y)); tick.stroke()
            drawLabel(String(format: "%.1f", e), at: NSPoint(x: p.x - 8, y: p.y), font: axisFont,
                      color: axis, rightAligned: true)
        }
        // "E (eV)" axis label
        drawLabel("E (eV)", at: NSPoint(x: 6, y: origin.y - plotH - 14), font: titleFont, color: axis, rightAligned: false)

        // --- Fermi level ---
        NSColor.red.withAlphaComponent(0.8).setStroke()
        let fermiPath = NSBezierPath()
        fermiStyle(fermiPath)
        let f0 = proj(0, bs.fermiEnergy), f1 = proj(bs.nKPoints - 1, bs.fermiEnergy)
        fermiPath.move(to: f0); fermiPath.line(to: f1)
        fermiPath.stroke()
        drawLabel("Ef", at: NSPoint(x: f1.x + 3, y: f1.y), font: axisFont, color: .red, rightAligned: false)

        // --- high-symmetry k-point gridlines + labels ---
        NSColor.lightGray.withAlphaComponent(0.5).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for ix in highSymmetryIndices where ix >= 0 && ix < bs.nKPoints {
            let gx = origin.x + plotW * CGFloat(ix) / CGFloat(bs.nKPoints - 1)
            grid.move(to: NSPoint(x: gx, y: origin.y))
            grid.line(to: NSPoint(x: gx, y: origin.y - plotH))
        }
        grid.stroke()

        // --- band lines ---
        NSColor.systemBlue.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1.0
        for ib in 0..<bs.nBands {
            line.removeAllPoints()
            var first = true
            for ik in 0..<bs.nKPoints {
                let p = proj(ik, bs.kPoints[ik].energies[ib])
                if first { line.move(to: p); first = false } else { line.line(to: p) }
            }
            line.stroke()
        }

        // --- k-path label ---
        drawLabel("k-path", at: NSPoint(x: origin.x + plotW / 2, y: origin.y + 16), font: titleFont, color: axis, rightAligned: false)

        // title
        drawLabel(bs.fermiEnergy != 0 ? "Band Structure (E\u{2081} = \(String(format: "%.3f", bs.fermiEnergy)) eV)" : "Band Structure",
                  at: NSPoint(x: origin.x + plotW / 2, y: 6), font: titleFont, color: axis, rightAligned: false)
    }

    private func drawEmpty(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); dirtyRect.fill()
        drawLabel("No band structure", at: NSPoint(x: bounds.midX, y: bounds.midY),
                  font: titleFont, color: .gray, rightAligned: false)
    }

    private func fermiStyle(_ p: NSBezierPath) {
        p.lineWidth = 1.0
        p.setLineDash([4, 3], count: 2, phase: 0)
    }

    private func drawLabel(_ s: String, at p: NSPoint, font: NSFont, color: NSColor, rightAligned: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attr = NSAttributedString(string: s, attributes: attrs)
        var pt = p
        if rightAligned { pt.x -= attr.size().width } else { pt.x -= attr.size().width / 2; pt.y -= attr.size().height / 2 }
        attr.draw(at: pt)
    }
}
