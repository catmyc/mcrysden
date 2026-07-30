import AppKit

// Band-structure diagram. Drawn in `draw(_:)` with Core Graphics (NSBezierPath), the
// same 2D-overlay approach as LabelOverlayView — no Metal needed for a static plot.
// x-axis = k-path distance (cumulative fractional-reciprocal length), y-axis = energy
// in eV; a dashed Fermi-level line and high-symmetry k-point gridlines are overlaid.
//
// Interaction: an energy window clips the y-axis, a Fermi shift slides the displayed
// energy reference, and a cursor callback reports the energy/k-distance at the mouse.
// Zoom/pan apply a transform to the plot content only (axes/labels stay fixed). All
// interaction is disabled during export (exportBackground != nil) so exported pixels
// are identical to the pre-interaction renderer.
final class BandGrapherView: NSView {
    var bandStructure: BandStructure? {
        didSet { needsDisplay = true }
    }
    /// Indices (into kDistances) of high-symmetry points to mark with vertical gridlines.
    var highSymmetryIndices: [Int] = []
    /// When set, draw fills with this color (used for export).
    var exportBackground: NSColor?
    /// When true, draw skips the white fill for transparent export output.
    var isExportTransparent: Bool = false

    // --- interaction state (all inert during export) ---
    /// When set, the y-axis is clipped to this range (in DISPLAYED / shifted eV).
    /// nil auto-fits to the (shifted) eigenvalues.
    var energyWindow: ClosedRange<Float>? {
        didSet { needsDisplay = true }
    }
    /// Energy reference shift in eV. Displayed energy = energy - fermiShift. The Fermi
    /// line moves with the shift. 0 preserves the original rendering.
    var fermiShift: Float = 0 {
        didSet { needsDisplay = true }
    }
    /// Plot-content zoom (1.0 = no zoom). Axes and labels stay fixed.
    var zoomScale: CGFloat = 1.0 {
        didSet { needsDisplay = true }
    }
    /// Plot-content pan in view points.
    var panOffset: NSPoint = .zero {
        didSet { needsDisplay = true }
    }
    /// Fires on mouse move with the data-coordinate under the cursor, or nil on exit.
    var onCursor: ((BandCursorInfo?) -> Void)?

    private let axisFont = NSFont.systemFont(ofSize: 11)
    private let titleFont = NSFont.boldSystemFont(ofSize: 13)
    private let margin = NSPoint(x: 64, y: 44)   // left/bottom margin for axes
    private let topMargin: CGFloat = 28

    override var isFlipped: Bool { true }

    /// Data-coordinate under a view point, used for cursor readout and tests. Returns
    /// nil when the point is outside the plot area. Reported in ORIGINAL eV (unshifted).
    func energyAtViewPoint(_ point: NSPoint) -> Float? {
        guard let bs = bandStructure, bs.nKPoints > 1, bs.nBands > 0 else { return nil }
        let origin = NSPoint(x: margin.x, y: bounds.height - margin.y)
        // Top edge is topMargin from the top (flipped coords: smaller y = higher up).
        let plot = NSPoint(x: bounds.width - 20, y: topMargin)
        let plotW = plot.x - origin.x, plotH = origin.y - plot.y
        guard plotW > 0, plotH > 0 else { return nil }
        let fx = (point.x - origin.x) / plotW
        guard fx >= 0, fx <= 1 else { return nil }
        // Mirror draw()'s range computation: shifted energies (e - fermiShift) with
        // the same padding and Fermi-level inclusion, so the cursor readout matches
        // what is actually drawn.
        func dE(_ e: Float) -> Float { e - fermiShift }
        let allE = bs.kPoints.flatMap { $0.energies.map(dE) }
        var yMin = allE.min()!, yMax = allE.max()!
        let yPad = max(0.5, (yMax - yMin) * 0.08)
        yMin -= yPad; yMax += yPad
        let shiftedFermi = bs.fermiEnergy.map(dE)
        if let ef = shiftedFermi {
            if ef < yMin { yMin = ef - 0.5 }
            if ef > yMax { yMax = ef + 0.5 }
        }
        if let window = energyWindow { yMin = window.lowerBound; yMax = window.upperBound }
        let fy = (origin.y - point.y) / plotH
        guard fy >= 0, fy <= 1 else { return nil }
        let displayed = yMin + (yMax - yMin) * Float(fy)
        return displayed + fermiShift   // back to original eV
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                   owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let e = energyAtViewPoint(p) {
            let dist = kDistanceAtViewPoint(p) ?? 0
            onCursor?(BandCursorInfo(energy: e, kDistance: dist))
        } else {
            onCursor?(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        onCursor?(nil)
    }

    private func kDistanceAtViewPoint(_ point: NSPoint) -> Float? {
        guard let bs = bandStructure, bs.nKPoints > 1 else { return nil }
        let origin = NSPoint(x: margin.x, y: bounds.height - margin.y)
        let plotW = (bounds.width - 20) - origin.x
        guard plotW > 0 else { return nil }
        let fx = (point.x - origin.x) / plotW
        guard fx >= 0, fx <= 1 else { return nil }
        let distances = bs.kDistances
        let xMin = distances.first!, xMax = distances.last!
        return xMin + (xMax - xMin) * Float(fx)
    }

    /// Compute VBM/CBM marker data for the current band structure. Returns nil when
    /// the analysis is unavailable (no Fermi level, mesh, invalid layout). For
    /// metallic paths, returns the highest-occupied / lowest-unoccupied extrema
    /// (gap = 0) — the same VBM/CBM reported by BandAnalysis and the electronic
    /// analysis presentation, so markers always link to plotted points. Energies in
    /// original eV, k-point indices into `kPoints`. Testable directly.
    func bandMarkerData() -> (vbm: (kIndex: Int, energy: Float), cbm: (kIndex: Int, energy: Float))? {
        guard let bs = bandStructure, !bs.isMesh, bs.hasValidChannelLayout,
              bs.nBands > 0, bs.nKPoints > 1 else { return nil }
        guard let result = BandAnalysis.bandGap(bs) else { return nil }
        guard result.vbmKPointIndex >= 0, result.vbmKPointIndex < bs.nKPoints,
              result.cbmKPointIndex >= 0, result.cbmKPointIndex < bs.nKPoints,
              result.vbm.isFinite, result.cbm.isFinite else { return nil }
        return (vbm: (kIndex: result.vbmKPointIndex, energy: result.vbm),
                cbm: (kIndex: result.cbmKPointIndex, energy: result.cbm))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current?.cgContext != nil,
              let bs = bandStructure, bs.nKPoints > 1, bs.nBands > 0,
              bs.isMesh || bs.hasValidChannelLayout,
              bs.kPoints.allSatisfy({ point in
                  point.k.x.isFinite && point.k.y.isFinite && point.k.z.isFinite
                      && point.energies.prefix(bs.nBands).allSatisfy(\.isFinite)
              }),
              bs.fermiEnergy?.isFinite ?? true
        else { drawEmpty(dirtyRect); return }

        // Export path: force interaction to defaults so exported pixels match the
        // pre-interaction renderer exactly (snapshot/export identity).
        let isExport = exportBackground != nil
        let effShift = isExport ? 0 : fermiShift
        let effWindow: ClosedRange<Float>? = isExport ? nil : energyWindow
        let effZoom = isExport ? 1.0 : zoomScale
        let effPan = isExport ? .zero : panOffset

        func dE(_ e: Float) -> Float { e - effShift }

        // Export path: fill with custom background if provided; transparent export
        // leaves the context empty. On-screen: default white fill.
        if let bg = exportBackground {
            bg.setFill()
            dirtyRect.fill()
        } else if !isExportTransparent {
            NSColor.white.setFill()
            dirtyRect.fill()
        }

        // Top edge is topMargin from the top (flipped coords: smaller y = higher up).
        let plot = NSPoint(x: bounds.width - 20, y: topMargin)
        let origin = NSPoint(x: margin.x, y: bounds.height - margin.y)
        let plotW = plot.x - origin.x
        let plotH = origin.y - plot.y
        guard plotW > 0, plotH > 0 else { drawEmpty(dirtyRect); return }

        let distances = bs.kDistances
        let xMin = distances.first!, xMax = distances.last!
        let allE = bs.kPoints.flatMap { $0.energies.map(dE) }
        var yMin = allE.min()!, yMax = allE.max()!
        // pad range; include the (shifted) Fermi level in the window ONLY when present
        // (metallic). Insulating outputs have no Fermi energy and we must not
        // forge a 0 eV line, so nil leaves the window to the eigenvalues.
        let yPad = max(0.5, (yMax - yMin) * 0.08)
        yMin -= yPad; yMax += yPad
        let shiftedFermi = bs.fermiEnergy.map(dE)
        if let ef = shiftedFermi {
            if ef < yMin { yMin = ef - 0.5 }
            if ef > yMax { yMax = ef + 0.5 }
        }
        // Energy window overrides the auto range (interpreted in the shifted frame).
        if let window = effWindow { yMin = window.lowerBound; yMax = window.upperBound }

        func proj(_ ix: Int, _ energy: Float) -> NSPoint {
            let fx = xMin == xMax ? 0 : CGFloat((distances[ix] - xMin) / (xMax - xMin))
            let fy = yMin == yMax ? 0.5 : CGFloat((dE(energy) - yMin) / (yMax - yMin))
            return NSPoint(x: origin.x + fx * plotW, y: origin.y - fy * plotH)
        }

        // --- box + axes (drawn in view space, outside the zoom/pan transform) ---
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
            // Tick labels show original eV (shifted frame + shift) so they match the
            // unshifted energies the user expects to read.
            drawLabel(String(format: "%.1f", e + effShift), at: NSPoint(x: p.x - 8, y: p.y), font: axisFont,
                      color: axis, rightAligned: true)
        }
        // "E (eV)" axis label
        drawLabel("E (eV)", at: NSPoint(x: 6, y: origin.y - plotH - 14), font: titleFont, color: axis, rightAligned: false)

        // --- plot content (gridlines, Fermi, bands) under the zoom/pan transform ---
        // Clip to the plot rectangle so out-of-window bands never overwrite axes.
        NSBezierPath(rect: NSRect(x: origin.x, y: origin.y - plotH, width: plotW, height: plotH)).addClip()
        let ctx = NSGraphicsContext.current!.cgContext
        let center = NSPoint(x: origin.x + plotW / 2, y: origin.y - plotH / 2)
        NSGraphicsContext.saveGraphicsState()
        ctx.translateBy(x: center.x + effPan.x, y: center.y + effPan.y)
        ctx.scaleBy(x: effZoom, y: effZoom)
        ctx.translateBy(x: -center.x, y: -center.y)

        // --- Fermi level (metallic only) ---
        if shiftedFermi != nil {
            NSColor.red.withAlphaComponent(0.8).setStroke()
            let fermiPath = NSBezierPath()
            fermiStyle(fermiPath)
            let f0 = proj(0, bs.fermiEnergy!), f1 = proj(bs.nKPoints - 1, bs.fermiEnergy!)
            fermiPath.move(to: f0); fermiPath.line(to: f1)
            fermiPath.stroke()
            drawLabel("Ef", at: NSPoint(x: f1.x + 3, y: f1.y), font: axisFont, color: .red, rightAligned: false)
        }

        // --- high-symmetry k-point gridlines + labels ---
        // Only meaningful for a band path: markers are placed at the k-point's
        // cumulative path distance. A mesh uses an index-based x coordinate, so the
        // two projections disagree — skip markers entirely in mesh mode (they would
        // otherwise be misprojected once highSymmetryIndices is populated).
        if !bs.isMesh {
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
        }

        // --- band lines ---
        // A uniform-weight sampling mesh is NOT a band path, so its points must not
        // be connected; render it as disconnected dots instead. Plot EVERY band: a
        // mesh holds spectra at all bands, not just the first. Its x-axis is the
        // k-point INDEX (categorical), not a physical distance — cumulative path
        // length through the mesh's arbitrary listing order would be meaningless.
        let xLabel: String
        if bs.isMesh {
            let n = bs.kPoints.count
            let fxOf: (Int) -> CGFloat = { n > 1 ? CGFloat($0) / CGFloat(n - 1) : 0 }
            NSColor.systemBlue.set()
            for ik in 0..<n {
                let px = origin.x + fxOf(ik) * plotW
                for ib in 0..<bs.nBands {
                    let fy = yMin == yMax ? 0.5 : CGFloat((dE(bs.kPoints[ik].energies[ib]) - yMin) / (yMax - yMin))
                    let py = origin.y - fy * plotH
                    let rect = NSRect(x: px - 1.5, y: py - 1.5, width: 3, height: 3)
                    NSBezierPath(ovalIn: rect).fill()
                }
            }
            xLabel = "k-point index"
        } else {
            xLabel = "k-path"   // set here so the label below compiles for both branches
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

        // --- band gap markers ---
        // Draw VBM/CBM markers for every band structure with a valid analysis
        // result. For insulators these are the true gap edges; for metallic paths
        // they are the highest-occupied / lowest-unoccupied extrema (gap = 0), so
        // the markers always link to the VBM/CBM reported by the electronic
        // analysis presentation.
        if let markers = bandMarkerData() {
            let vbmPoint = proj(markers.vbm.kIndex, markers.vbm.energy)
            let cbmPoint = proj(markers.cbm.kIndex, markers.cbm.energy)
            drawBandMarker(at: vbmPoint, label: "VBM", color: .systemGreen)
            drawBandMarker(at: cbmPoint, label: "CBM", color: .systemRed)
        }

        NSGraphicsContext.restoreGraphicsState()

        // --- x-axis label + title (view space) ---
        drawLabel(xLabel, at: NSPoint(x: origin.x + plotW / 2, y: origin.y + 16), font: titleFont, color: axis, rightAligned: false)

        // title — show the Fermi energy in the title only when the calculation
        // reports one (metallic); insulators get the plain label. Reported in original eV.
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

    /// Draw a labelled VBM/CBM marker at a projected point. The marker is a filled
    /// circle with a contrasting halo and a coloured label, drawn in the current
    /// (zoom/pan-transformed) coordinate space.
    private func drawBandMarker(at point: NSPoint, label: String, color: NSColor) {
        let radius: CGFloat = 5
        // White halo for contrast against band lines.
        let halo = NSBezierPath(ovalIn: NSRect(
            x: point.x - radius - 2, y: point.y - radius - 2,
            width: (radius + 2) * 2, height: (radius + 2) * 2))
        NSColor.white.setFill()
        halo.fill()
        // Colored marker with black border.
        let marker = NSBezierPath(ovalIn: NSRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2))
        color.setFill()
        NSColor.black.setStroke()
        marker.fill()
        marker.lineWidth = 1.5
        marker.stroke()
        // Label to the right of the marker.
        let attrs: [NSAttributedString.Key: Any] = [.font: axisFont, .foregroundColor: color]
        let attr = NSAttributedString(string: label, attributes: attrs)
        var labelPt = NSPoint(x: point.x + radius + 4, y: point.y)
        labelPt.y -= attr.size().height / 2
        attr.draw(at: labelPt)
    }
}

/// Data-coordinate under the cursor for the band grapher. Energies in original eV.
struct BandCursorInfo { let energy: Float; let kDistance: Float }
