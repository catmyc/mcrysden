import AppKit

// Density-of-states diagram. Energy is vertical and DOS is horizontal; signed
// spin channels naturally fall on opposite sides of the zero-DOS axis.
final class DOSGrapherView: NSView {
    var densityOfStates: DensityOfStates? {
        didSet { needsDisplay = true }
    }

    private let axisFont = NSFont.systemFont(ofSize: 11)
    private let titleFont = NSFont.boldSystemFont(ofSize: 13)
    private let palette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPurple,
        .systemPink, .systemTeal, .systemBrown, .systemIndigo
    ]

    override var isFlipped: Bool { true }

    /// When set, draw fills with this color (used for export).
    var exportBackground: NSColor?
    /// When true, draw skips the white fill for transparent export output.
    var isExportTransparent: Bool = false
    override func draw(_ dirtyRect: NSRect) {
        if let bg = exportBackground {
            bg.setFill()
            dirtyRect.fill()
        } else if !isExportTransparent {
            NSColor.white.setFill()
            dirtyRect.fill()
        }

        guard let dos = densityOfStates else {
            drawEmpty("No density of states")
            return
        }

        let samples = dos.series.map { series in
            Array(zip(dos.energies, series.values).filter { $0.0.isFinite && $0.1.isFinite })
        }
        let energies = samples.flatMap { $0.map(\.0) }
        let values = samples.flatMap { $0.map(\.1) }
        guard !energies.isEmpty, !values.isEmpty else {
            drawEmpty("No density-of-states data")
            return
        }

        var energyMin = energies.min()!
        var energyMax = energies.max()!
        expandConstantRange(minimum: &energyMin, maximum: &energyMax, minimumPadding: 0.5)

        var dosMin = min(values.min()!, 0)
        var dosMax = max(values.max()!, 0)
        expandConstantRange(minimum: &dosMin, maximum: &dosMax, minimumPadding: 0.5)
        let dosPadding = max((dosMax - dosMin) * 0.06, 0.05)
        dosMin -= dosPadding
        dosMax += dosPadding

        if let fermi = dos.fermiEnergy, fermi.isFinite {
            if fermi < energyMin { energyMin = fermi - max((energyMax - energyMin) * 0.05, 0.5) }
            if fermi > energyMax { energyMax = fermi + max((energyMax - energyMin) * 0.05, 0.5) }
        }

        let leftMargin: CGFloat = 66
        let rightMargin: CGFloat = 24
        let topMargin: CGFloat = 38
        let bottomMargin: CGFloat = 54
        let plotRect = NSRect(
            x: leftMargin,
            y: topMargin,
            width: max(0, bounds.width - leftMargin - rightMargin),
            height: max(0, bounds.height - topMargin - bottomMargin)
        )
        guard plotRect.width >= 24, plotRect.height >= 24 else { return }

        func project(_ value: Float, _ energy: Float) -> NSPoint {
            let xFraction = CGFloat((value - dosMin) / (dosMax - dosMin))
            let yFraction = CGFloat((energy - energyMin) / (energyMax - energyMin))
            return NSPoint(x: plotRect.minX + xFraction * plotRect.width,
                           y: plotRect.maxY - yFraction * plotRect.height)
        }

        drawGrid(in: plotRect, dosMin: dosMin, dosMax: dosMax,
                 energyMin: energyMin, energyMax: energyMax)

        let zeroX = project(0, energyMin).x
        NSColor.darkGray.setStroke()
        let zeroAxis = NSBezierPath()
        zeroAxis.move(to: NSPoint(x: zeroX, y: plotRect.minY))
        zeroAxis.line(to: NSPoint(x: zeroX, y: plotRect.maxY))
        zeroAxis.lineWidth = 1
        zeroAxis.stroke()

        if let fermi = dos.fermiEnergy, fermi.isFinite {
            let y = project(0, fermi).y
            NSColor.systemRed.withAlphaComponent(0.85).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plotRect.minX, y: y))
            line.line(to: NSPoint(x: plotRect.maxX, y: y))
            line.lineWidth = 1
            line.setLineDash([5, 3], count: 2, phase: 0)
            line.stroke()
            drawText("Ef", at: NSPoint(x: plotRect.maxX - 4, y: y - 3), font: axisFont,
                     color: .systemRed, horizontal: .right, vertical: .bottom)
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plotRect).addClip()
        for (index, points) in samples.enumerated() where !points.isEmpty {
            palette[index % palette.count].setStroke()
            let path = NSBezierPath()
            path.lineWidth = index == 0 ? 1.8 : 1.25
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            for (pointIndex, point) in points.enumerated() {
                let projected = project(point.1, point.0)
                if pointIndex == 0 { path.move(to: projected) } else { path.line(to: projected) }
            }
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.setStroke()
        let border = NSBezierPath(rect: plotRect)
        border.lineWidth = 1
        border.stroke()

        drawText("Density of States", at: NSPoint(x: plotRect.midX, y: 8), font: titleFont,
                 color: .black, horizontal: .center, vertical: .top)
        drawText("DOS", at: NSPoint(x: plotRect.midX, y: plotRect.maxY + 27), font: titleFont,
                 color: .black, horizontal: .center, vertical: .center)
        drawText("E (eV)", at: NSPoint(x: 8, y: plotRect.minY - 20), font: titleFont,
                 color: .black, horizontal: .left, vertical: .center)
        drawLegend(for: dos.series, in: plotRect)
    }

    private func drawGrid(in plotRect: NSRect, dosMin: Float, dosMax: Float,
                          energyMin: Float, energyMax: Float) {
        let xTickCount = 4
        let yTickCount = 5
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        NSColor.lightGray.withAlphaComponent(0.65).setStroke()

        for index in 0...xTickCount {
            let fraction = CGFloat(index) / CGFloat(xTickCount)
            let x = plotRect.minX + fraction * plotRect.width
            grid.move(to: NSPoint(x: x, y: plotRect.minY))
            grid.line(to: NSPoint(x: x, y: plotRect.maxY))
            let value = dosMin + (dosMax - dosMin) * Float(fraction)
            drawText(formatTick(value), at: NSPoint(x: x, y: plotRect.maxY + 7), font: axisFont,
                     color: .darkGray, horizontal: .center, vertical: .top)
        }
        for index in 0...yTickCount {
            let fraction = CGFloat(index) / CGFloat(yTickCount)
            let y = plotRect.maxY - fraction * plotRect.height
            grid.move(to: NSPoint(x: plotRect.minX, y: y))
            grid.line(to: NSPoint(x: plotRect.maxX, y: y))
            let value = energyMin + (energyMax - energyMin) * Float(fraction)
            drawText(formatTick(value), at: NSPoint(x: plotRect.minX - 8, y: y), font: axisFont,
                     color: .darkGray, horizontal: .right, vertical: .center)
        }
        grid.stroke()
    }

    private func drawLegend(for series: [DOSSeries], in plotRect: NSRect) {
        let entries = series.enumerated().filter { !$0.element.values.isEmpty }
        guard !entries.isEmpty else { return }

        let rowHeight: CGFloat = 16
        let swatchWidth: CGFloat = 18
        let labels = entries.map { $0.element.label.isEmpty ? "Series \($0.offset + 1)" : $0.element.label }
        let labelWidths = labels.map {
            NSAttributedString(string: $0, attributes: [.font: axisFont]).size().width
        }
        let width = min(max((labelWidths.max() ?? 0) + swatchWidth + 18, 72), plotRect.width - 12)
        let visibleCount = min(entries.count, max(1, Int((plotRect.height - 12) / rowHeight)))
        let height = CGFloat(visibleCount) * rowHeight + 10
        let rect = NSRect(x: plotRect.maxX - width - 6, y: plotRect.minY + 6,
                          width: width, height: height)

        NSColor.white.withAlphaComponent(0.92).setFill()
        NSColor.lightGray.setStroke()
        let background = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        background.fill()
        background.lineWidth = 0.5
        background.stroke()

        for row in 0..<visibleCount {
            let entry = entries[row]
            let y = rect.minY + 7 + CGFloat(row) * rowHeight + rowHeight / 2
            let color = palette[entry.offset % palette.count]
            color.setStroke()
            let swatch = NSBezierPath()
            swatch.move(to: NSPoint(x: rect.minX + 7, y: y))
            swatch.line(to: NSPoint(x: rect.minX + 7 + swatchWidth, y: y))
            swatch.lineWidth = entry.offset == 0 ? 1.8 : 1.25
            swatch.stroke()
            drawText(labels[row], at: NSPoint(x: rect.minX + swatchWidth + 11, y: y), font: axisFont,
                     color: .black, horizontal: .left, vertical: .center,
                     maximumWidth: rect.width - swatchWidth - 16)
        }
    }

    private func expandConstantRange(minimum: inout Float, maximum: inout Float,
                                     minimumPadding: Float) {
        guard minimum == maximum else { return }
        let padding = max(abs(minimum) * 0.1, minimumPadding)
        minimum -= padding
        maximum += padding
    }

    private func formatTick(_ value: Float) -> String {
        let magnitude = abs(value)
        if magnitude != 0, magnitude < 0.01 || magnitude >= 10_000 {
            return String(format: "%.1e", value)
        }
        return String(format: magnitude < 10 ? "%.2f" : "%.1f", value)
    }

    private func drawEmpty(_ message: String) {
        drawText(message, at: NSPoint(x: bounds.midX, y: bounds.midY), font: titleFont,
                 color: .darkGray, horizontal: .center, vertical: .center)
    }

    private enum HorizontalAlignment { case left, center, right }
    private enum VerticalAlignment { case top, center, bottom }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor,
                          horizontal: HorizontalAlignment, vertical: VerticalAlignment,
                          maximumWidth: CGFloat? = nil) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
        var size = attributed.size()
        if let maximumWidth { size.width = min(size.width, maximumWidth) }
        var origin = point
        switch horizontal {
        case .left: break
        case .center: origin.x -= size.width / 2
        case .right: origin.x -= size.width
        }
        switch vertical {
        case .top: break
        case .center: origin.y -= size.height / 2
        case .bottom: origin.y -= size.height
        }
        attributed.draw(with: NSRect(origin: origin, size: size),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

enum DOSExportError: Error { case invalidSize, noBitmap, noContext, noImage }

/// Offscreen DOS export. GUI and headless output share DOSGrapherView.draw(), so
/// exported axes, labels, colors, and curves match the on-screen graph.
enum DOSExporter {
    @MainActor
    @discardableResult
    static func export(_ dos: DensityOfStates, to url: URL, size: CGSize,
                        background: (r: Double, g: Double, b: Double, a: Double)? = nil) throws -> CGImage {
        let image = try render(dos, size: size, background: background)
        switch url.pathExtension.lowercased() {
        case "pdf", "svg", "eps", "ps":
            try RasterExporter.write(cgImage: image, to: url, size: size)
        case "png":
            try PngExporter.write(cgImage: image, to: url)
        default:
            // An unsupported extension must not silently produce PNG bytes; fail clearly
            // with a truthful unsupported-format error (matches the outer gate).
            throw App.CLIError.invalid("unsupported export extension: \(url.pathExtension)")
        }
        return image
    }

    @MainActor
    static func render(_ dos: DensityOfStates, size: CGSize,
                        background: (r: Double, g: Double, b: Double, a: Double)? = nil) throws -> CGImage {
        // Share the App-side size validator so a huge/NaN/infinite size throws a clear
        // error instead of trapping on the Int cast or hanging on a giant allocation.
        let (width, height) = try App.validatedExportSize(size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw DOSExportError.noBitmap }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw DOSExportError.noContext
        }
        let view = DOSGrapherView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.densityOfStates = dos
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        // Apply custom background if provided; otherwise leave transparent for the view's own fill.
        if let bg = background, bg.a > 0 {
            context.cgContext.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        view.draw(view.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { throw DOSExportError.noImage }
        return image
    }
}
