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
        // pad range; include the Fermi level in the window ONLY when present
        // (metallic). Insulating outputs have no Fermi energy and we must not
        // forge a 0 eV line, so nil leaves the window to the eigenvalues.
        let yPad = max(0.5, (yMax - yMin) * 0.08)
        yMin -= yPad; yMax += yPad
        if let ef = bs.fermiEnergy {
            if ef < yMin { yMin = ef - 0.5 }
            if ef > yMax { yMax = ef + 0.5 }
        }

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

        // --- Fermi level (metallic only) ---
        // Insulating QE outputs report highest-occupied/lowest-unoccupied levels
        // instead of a Fermi energy; bs.fermiEnergy is then nil and we skip the
        // red line entirely rather than forging a value.
        if let ef = bs.fermiEnergy {
            NSColor.red.withAlphaComponent(0.8).setStroke()
            let fermiPath = NSBezierPath()
            fermiStyle(fermiPath)
            let f0 = proj(0, ef), f1 = proj(bs.nKPoints - 1, ef)
            fermiPath.move(to: f0); fermiPath.line(to: f1)
            fermiPath.stroke()
            drawLabel("Ef", at: NSPoint(x: f1.x + 3, y: f1.y), font: axisFont, color: .red, rightAligned: false)
        }

        // --- high-symmetry k-point gridlines + labels ---
        // Markers are placed at the k-point's CUMULATIVE path distance, not its
        // uniform index — with nonuniform k-spacing the two differ, and an index-
        // based x would misalign the marker from its band.
        NSColor.lightGray.withAlphaComponent(0.5).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for ix in highSymmetryIndices where ix >= 0 && ix < bs.nKPoints {
            let fx = xMin == xMax ? 0 : CGFloat((distances[ix] - xMin) / (xMax - xMin))
            let gx = origin.x + plotW * fx
            grid.move(to: NSPoint(x: gx, y: origin.y))
            grid.line(to: NSPoint(x: gx, y: origin.y - plotH))
        }
        grid.stroke()

        // --- band lines ---
        // A uniform-weight sampling mesh is NOT a band path, so its points must not
        // be connected; render it as disconnected dots instead. Plot EVERY band: a
        // mesh holds spectra at all bands, not just the first.
        if bs.isMesh {
            NSColor.systemBlue.set()
            for ik in 0..<bs.kPoints.count {
                for ib in 0..<bs.nBands {
                    let p = proj(ik, bs.kPoints[ik].energies[ib])
                    let rect = NSRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)
                    NSBezierPath(ovalIn: rect).fill()
                }
            }
        } else {
            // Each spin channel is an ordered sub-path; draw them separately so the
            // grapher never connects the end of one channel to the start of the next.
            // Distinct colours + a legend identify the channels.
            let palette: [NSColor] = [.systemBlue, .systemRed]
            for s in 0..<bs.nSpin {
                let base = s * bs.kPointsPerSpin
                palette[s % palette.count].setStroke()
                let line = NSBezierPath()
                line.lineWidth = 1.0
                for ib in 0..<bs.nBands {
                    line.removeAllPoints()
                    var first = true
                    for ik in 0..<bs.kPointsPerSpin {
                        let p = proj(base + ik, bs.kPoints[base + ik].energies[ib])
                        if first { line.move(to: p); first = false } else { line.line(to: p) }
                    }
                    line.stroke()
                }
            }
            // Channel legend (bottom-right), one entry per spin channel.
            let labels = ["spin ↑", "spin ↓"]
            for s in 0..<bs.nSpin {
                let color = palette[s % palette.count]
                color.set()
                let attr = NSAttributedString(string: labels[s % labels.count],
                                              attributes: [.font: axisFont, .foregroundColor: color])
                let yPos = bounds.height - 16 - CGFloat(s) * 14
                attr.draw(at: NSPoint(x: bounds.width - 64, y: yPos))
            }
        }

        // --- k-path label ---
        drawLabel("k-path", at: NSPoint(x: origin.x + plotW / 2, y: origin.y + 16), font: titleFont, color: axis, rightAligned: false)

        // title — show the Fermi energy in the title only when the calculation
        // reports one (metallic); insulators get the plain label.
        let titleStr: String
        if let ef = bs.fermiEnergy {
            titleStr = "Band Structure (E\u{2081} = \(String(format: "%.3f", ef)) eV)"
        } else {
            titleStr = "Band Structure"
        }
        drawLabel(titleStr, at: NSPoint(x: origin.x + plotW / 2, y: 6), font: titleFont, color: axis, rightAligned: false)
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
