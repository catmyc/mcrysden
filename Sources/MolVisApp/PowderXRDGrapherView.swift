import AppKit

/// Powder X-ray diffraction diagram. 2θ is horizontal (0...max) and relative
/// intensity is vertical (0...100%). Peaks are drawn as vertical sticks at their
/// 2θ positions with optional Miller-index labels; the curve is a filled region
/// under a stroked line.
///
/// This is a static 2D plot with no interaction. The view is flipped (top-left
/// origin) so screen and export PDF coordinates match, and the shared draw path
/// (`drawPattern`) is used for both on-screen rendering and offscreen export.
final class PowderXRDGrapherView: NSView {
    var pattern: XRDPattern? {
        didSet { needsDisplay = true }
    }
    var showLabels: Bool = true {
        didSet { needsDisplay = true }
    }

    private let axisFont = NSFont.systemFont(ofSize: 11)
    private let titleFont = NSFont.boldSystemFont(ofSize: 13)
    private let curveStroke = NSColor.systemBlue
    private let curveFill = NSColor.systemBlue.withAlphaComponent(0.18)
    private let peakStroke = NSColor.systemRed
    private let labelColor = NSColor.systemTeal

    private let leftMargin: CGFloat = 66
    private let rightMargin: CGFloat = 24
    private let topMargin: CGFloat = 38
    private let bottomMargin: CGFloat = 54

    /// When set, draw fills with this color (used for export).
    var exportBackground: NSColor?
    /// When true, draw skips the white fill for transparent export output.
    var isExportTransparent: Bool = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawPattern(pattern, exportBackground: exportBackground, transparent: isExportTransparent)
    }

    /// Shared drawing for screen and export. `background`/`transparent` override
    /// the view's own export state when set.
    private func drawPattern(_ pattern: XRDPattern?, exportBackground: NSColor?, transparent: Bool) {
        if let bg = exportBackground {
            bg.setFill()
            bounds.fill()
        } else if !transparent {
            NSColor.white.setFill()
            bounds.fill()
        }

        guard let pattern else { return }

        if !pattern.isAvailable {
            drawEmpty(pattern.unavailableReason ?? "XRD pattern unavailable")
            return
        }
        guard !pattern.peaks.isEmpty else {
            drawEmpty("No reflections in the selected range")
            return
        }

        let plotRect = NSRect(
            x: leftMargin,
            y: topMargin,
            width: max(0, bounds.width - leftMargin - rightMargin),
            height: max(0, bounds.height - topMargin - bottomMargin)
        )
        guard plotRect.width >= 24, plotRect.height >= 24 else { return }

        let twoThetaMax = niceAxisMax(pattern.maxTwoTheta)

        drawGridAndAxes(in: plotRect, twoThetaMax: twoThetaMax)

        func project(_ twoTheta: Float, _ intensity: Float) -> NSPoint {
            let x = plotRect.minX + CGFloat(twoTheta / twoThetaMax) * plotRect.width
            let y = plotRect.maxY - CGFloat(intensity / 100.0) * plotRect.height
            return NSPoint(x: x, y: y)
        }

        // --- curve: filled region under a stroked line ---
        let curve = pattern.curve
        if curve.count > 1 {
            let fillPath = NSBezierPath()
            fillPath.move(to: project(curve[0].twoTheta, 0))
            for point in curve { fillPath.line(to: project(point.twoTheta, point.intensity)) }
            fillPath.line(to: project(curve[curve.count - 1].twoTheta, 0))
            fillPath.close()
            curveFill.setFill()
            fillPath.fill()

            let strokePath = NSBezierPath()
            strokePath.lineWidth = 1.5
            strokePath.lineJoinStyle = .round
            strokePath.lineCapStyle = .round
            for (index, point) in curve.enumerated() {
                let p = project(point.twoTheta, point.intensity)
                if index == 0 { strokePath.move(to: p) } else { strokePath.line(to: p) }
            }
            curveStroke.setStroke()
            strokePath.stroke()
        }

        // --- peak sticks + labels ---
        var lastLabelRect: NSRect? = nil
        for peak in pattern.peaks {
            let top = project(peak.twoTheta, peak.relativeIntensity)
            let base = project(peak.twoTheta, 0)
            peakStroke.setStroke()
            let stick = NSBezierPath()
            stick.move(to: base)
            stick.line(to: top)
            stick.lineWidth = 1.25
            stick.stroke()

            guard showLabels else { continue }
            let text = peak.hklLabels.joined(separator: ",")
            let attrs: [NSAttributedString.Key: Any] = [.font: axisFont, .foregroundColor: labelColor]
            let attr = NSAttributedString(string: text, attributes: attrs)
            let size = attr.size()
            let padding: CGFloat = 14
            // Clamp inside the plot rect horizontally FIRST so the overlap test
            // below uses the final on-screen position.
            var origin = NSPoint(x: top.x - size.width / 2, y: top.y - size.height - 6)
            if origin.x < plotRect.minX { origin.x = plotRect.minX }
            if origin.x + size.width > plotRect.maxX { origin.x = plotRect.maxX - size.width }
            let labelRect = NSRect(x: origin.x - padding / 2, y: origin.y - padding / 2,
                                   width: size.width + padding, height: size.height + padding)
            if let last = lastLabelRect, labelRect.intersects(last) { continue }
            attr.draw(at: origin)
            lastLabelRect = labelRect
        }

        NSColor.black.setStroke()
        let border = NSBezierPath(rect: plotRect)
        border.lineWidth = 1
        border.stroke()

        drawText("Powder XRD", at: NSPoint(x: plotRect.midX, y: 8), font: titleFont,
                 color: .black, horizontal: .center, vertical: .top)

        if let wavelengthName = wavelengthName(for: pattern.wavelength) {
            let subtitle = "\(wavelengthName) · λ = \(String(format: "%.4f", pattern.wavelength)) Å · \(pattern.sourceDescription)"
            drawText(subtitle, at: NSPoint(x: plotRect.midX, y: 22), font: axisFont,
                     color: .darkGray, horizontal: .center, vertical: .top)
        }
    }

    private func drawGridAndAxes(in plotRect: NSRect, twoThetaMax: Float) {
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
            let value = twoThetaMax * Float(fraction)
            drawText(formatTick(value), at: NSPoint(x: x, y: plotRect.maxY + 7), font: axisFont,
                     color: .darkGray, horizontal: .center, vertical: .top)
        }
        for index in 0...yTickCount {
            let fraction = CGFloat(index) / CGFloat(yTickCount)
            let y = plotRect.maxY - fraction * plotRect.height
            grid.move(to: NSPoint(x: plotRect.minX, y: y))
            grid.line(to: NSPoint(x: plotRect.maxX, y: y))
            let value = 100 * Float(fraction)
            drawText(formatTick(value), at: NSPoint(x: plotRect.minX - 8, y: y), font: axisFont,
                     color: .darkGray, horizontal: .right, vertical: .center)
        }
        grid.stroke()

        drawText("2θ (°)", at: NSPoint(x: plotRect.midX, y: plotRect.maxY + 27), font: titleFont,
                 color: .black, horizontal: .center, vertical: .center)
        drawText("Relative intensity (%)", at: NSPoint(x: 8, y: plotRect.midY), font: titleFont,
                 color: .black, horizontal: .left, vertical: .center)
    }

    /// Round a max data value up to a "nice" 1-2-5 step multiple so the axis
    /// ends on a clean tick boundary.
    private func niceAxisMax(_ value: Float) -> Float {
        guard value.isFinite, value > 0 else { return 10 }
        let magnitude = pow(10, floor(log10(Double(value))))
        let residual = value / Float(magnitude)
        let niceStep: Float
        if residual <= 1 { niceStep = 1 }
        else if residual <= 2 { niceStep = 2 }
        else if residual <= 5 { niceStep = 5 }
        else { niceStep = 10 }
        return niceStep * Float(magnitude)
    }

    private func wavelengthName(for wavelength: Float) -> String? {
        for option in PowderXRD.wavelengthOptions where abs(option.wavelength - wavelength) < 1e-4 {
            return option.name
        }
        return nil
    }

    private func formatTick(_ value: Float) -> String {
        let magnitude = abs(value)
        if magnitude != 0, magnitude < 0.01 || magnitude >= 10_000 {
            return String(format: "%.0f", value)
        }
        return String(format: magnitude < 10 ? "%.1f" : "%.0f", value)
    }

    private func drawEmpty(_ message: String) {
        drawText(message, at: NSPoint(x: bounds.midX, y: bounds.midY), font: titleFont,
                 color: .darkGray, horizontal: .center, vertical: .center)
    }

    private enum HorizontalAlignment { case left, center, right }
    private enum VerticalAlignment { case top, center, bottom }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor,
                          horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
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
        attr.draw(at: origin)
    }
}

/// Errors thrown by the offscreen XRD export path.
enum XRDExportError: Error { case invalidSize, noBitmap, noContext, noImage, transparentRaster, unsupported }

/// Offscreen Powder XRD export. GUI and headless output share
/// PowderXRDGrapherView.draw(), so exported axes, labels, peaks, and curve match
/// the on-screen graph.
enum PowderXRDExporter {
    @MainActor
    @discardableResult
    static func export(_ pattern: XRDPattern, to url: URL, size: CGSize,
                       background: (r: Double, g: Double, b: Double, a: Double)? = nil,
                       transparent: Bool = false) throws -> CGImage {
        let image = try render(pattern, size: size, background: background, transparent: transparent)
        switch url.pathExtension.lowercased() {
        case "pdf":
            do {
                try writeGraphVectorPDF(pattern, to: url, size: size, background: background)
                return image
            } catch {
                // Fall back to raster-wrapped PDF on vector failure (matches App.swift).
                try RasterExporter.write(cgImage: image, to: url, size: size)
                return image
            }
        case "svg", "eps", "ps":
            if transparent { throw XRDExportError.transparentRaster }
            try RasterExporter.write(cgImage: image, to: url, size: size)
        case "png":
            try PngExporter.write(cgImage: image, to: url)
        default:
            throw App.CLIError.invalid("unsupported export extension: \(url.pathExtension)")
        }
        return image
    }

    @MainActor
    static func render(_ pattern: XRDPattern, size: CGSize,
                       background: (r: Double, g: Double, b: Double, a: Double)? = nil,
                       transparent: Bool = false) throws -> CGImage {
        let (width, height) = try App.validatedExportSize(size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw XRDExportError.noBitmap }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw XRDExportError.noContext
        }
        let view = PowderXRDGrapherView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.pattern = pattern
        view.showLabels = true
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        if let bg = background, bg.a > 0 {
            context.cgContext.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        view.draw(view.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { throw XRDExportError.noImage }
        return image
    }

    /// True-vector PDF: draw the view into a CGContext PDF page through a flipped
    /// NSGraphicsContext so all axes, text, and paths are captured as vectors.
    private static func writeGraphVectorPDF(_ pattern: XRDPattern, to url: URL,
                                            size: CGSize,
                                            background: (r: Double, g: Double, b: Double, a: Double)?) throws {
        let (width, height) = try App.validatedExportSize(size)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let data = NSMutableData()
        let info: [CFString: Any] = [kCGPDFContextCreator: "mcrysden"]
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw XRDExportError.noContext
        }
        ctx.beginPDFPage(nil)
        if let bg = background, bg.a > 0 {
            ctx.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a)
            ctx.fill(mediaBox)
        }
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        nsCtx.cgContext.translateBy(x: 0, y: CGFloat(height))
        nsCtx.cgContext.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: nsCtx.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        let view = PowderXRDGrapherView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.pattern = pattern
        view.showLabels = true
        view.draw(view.bounds)
        nsCtx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }
}
