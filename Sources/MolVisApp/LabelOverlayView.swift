import AppKit

/// A transparent overlay that draws element-symbol text labels at projected
/// atom screen positions. Managed by `MainWindowController.updateLabels()`.
final class LabelOverlayView: NSView {
    /// One label to draw during `drawRect`.
    struct Label: Equatable {
        enum Style: Hashable {
            case atom
            case routeNode
            case selectedRouteNode
            case tooltip
            case scaleIndicator
            case bondDistance

            var isExportable: Bool { self != .tooltip }
        }

        let symbol: String
        let x: CGFloat
        let y: CGFloat
        let style: Style
        /// The horizontal scale bar width in points. It is meaningful only for
        /// `.scaleIndicator`; malformed values are ignored by measurement/drawing.
        let barWidth: CGFloat?
        /// Scale-indicator foreground contrast, selected by the controller from
        /// the active scene background. Kept on the label so live and export
        /// compositing use exactly the same appearance.
        let usesLightForeground: Bool

        /// Existing atom/route/tooltip call sites remain source-compatible.
        init(symbol: String, x: CGFloat, y: CGFloat, style: Style = .atom,
             barWidth: CGFloat? = nil, usesLightForeground: Bool = true) {
            self.symbol = symbol
            self.x = x
            self.y = y
            self.style = style
            self.barWidth = barWidth
            self.usesLightForeground = usesLightForeground
        }

        var isExportable: Bool { style.isExportable }
    }

    var labels: [Label] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }   // so y = 0 is the top

    /// The overlay is visual-only. Let the Metal view below receive all pointer
    /// tracking and click events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Size of the text itself for ordinary labels. Scale indicators extend the
    /// measured content to include their bar and end ticks so every caller uses
    /// a rectangle that contains the complete visual.
    static func measuredSize(for label: Label) -> CGSize {
        let textSize = measuredTextSize(for: label)
        guard let barWidth = validBarWidth(for: label) else { return textSize }
        let width = max(textSize.width, barWidth)
        let height = textSize.height + scaleBarGap + scaleTickHeight
        guard width.isFinite, height.isFinite else { return textSize }
        return CGSize(width: ceil(width), height: ceil(height))
    }

    /// Full visual bounds at the label's requested origin. The origin is the
    /// text origin for the backwards-compatible atom style.
    static func drawingRect(for label: Label) -> NSRect {
        drawingRect(for: label, measuredSize: measuredSize(for: label))
    }

    /// Full visual bounds using a caller-provided measurement. Controllers that
    /// redraw persistent labels frequently can cache the text measurement while
    /// still sharing this geometry implementation with exports and drawing.
    static func drawingRect(for label: Label, measuredSize size: CGSize) -> NSRect {
        let content = contentSize(for: label, measuredSize: size)
        let padding = padding(for: label.style)
        return NSRect(x: label.x - padding.width,
                      y: label.y - padding.height,
                      width: content.width + 2 * padding.width,
                      height: content.height + 2 * padding.height)
    }

    /// The text area inside a label's padded background. Multiline drawing is
    /// constrained to this rect so it uses the same geometry as measurement.
    static func textDrawingRect(for label: Label, in rect: NSRect) -> NSRect {
        let padding = padding(for: label.style)
        let availableWidth = max(0, rect.width - 2 * padding.width)
        let availableHeight = max(0, rect.height - 2 * padding.height)
        guard label.style == .scaleIndicator else {
            return NSRect(x: rect.minX + padding.width,
                          y: rect.minY + padding.height,
                          width: availableWidth,
                          height: availableHeight)
        }

        let textSize = measuredTextSize(for: label)
        return NSRect(x: rect.minX + padding.width,
                      y: rect.minY + padding.height,
                      width: min(availableWidth, textSize.width),
                      height: min(availableHeight, textSize.height))
    }

    /// Return a tooltip rect moved wholly inside `bounds` when its natural size
    /// permits it. This is deterministic and keeps the tooltip's text origin
    /// aligned with its padded background.
    static func clampedDrawingRect(for label: Label, in bounds: NSRect) -> NSRect {
        let rect = drawingRect(for: label)
        guard label.style == .tooltip, !bounds.isEmpty else { return rect }

        var x = rect.origin.x
        var y = rect.origin.y
        if rect.width <= bounds.width {
            x = min(max(x, bounds.minX), bounds.maxX - rect.width)
        } else {
            x = bounds.minX
        }
        if rect.height <= bounds.height {
            y = min(max(y, bounds.minY), bounds.maxY - rect.height)
        } else {
            y = bounds.minY
        }
        return NSRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Draw one label using the same style implementation used by PNG export.
    /// `bounds` clamps transient tooltips and constrains scale indicators.
    static func draw(_ label: Label, in bounds: NSRect? = nil) {
        guard label.isExportable || label.style == .tooltip else { return }
        // A scale label without a finite, positive bar width is not a valid
        // indicator. Reject it before constructing any AppKit geometry.
        if label.style == .scaleIndicator && validBarWidth(for: label) == nil { return }
        let rect: NSRect
        if label.style == .scaleIndicator {
            let candidate = drawingRect(for: label)
            guard finiteRect(candidate),
                  bounds.map({ finiteRect($0) && rectFits(candidate, in: $0) }) ?? true else {
                return
            }
            rect = candidate
        } else if let bounds, label.style == .tooltip {
            rect = clampedDrawingRect(for: label, in: bounds)
        } else {
            rect = drawingRect(for: label)
        }

        if hasBackground(for: label.style) {
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: cornerRadius(for: label.style),
                                    yRadius: cornerRadius(for: label.style))
            backgroundColor(for: label).setFill()
            path.fill()
            borderColor(for: label).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let textRect = textDrawingRect(for: label, in: rect)
        let attributes = textAttributes(for: label)
        if label.symbol.rangeOfCharacter(from: .newlines) != nil {
            (label.symbol as NSString).draw(with: textRect,
                                            options: multilineTextOptions,
                                            attributes: attributes)
        } else {
            (label.symbol as NSString).draw(at: textRect.origin,
                                            withAttributes: attributes)
        }

        guard label.style == .scaleIndicator,
              let barWidth = validBarWidth(for: label) else { return }
        let barY = textRect.maxY + scaleBarGap + scaleTickHeight * 0.5
        let startX = textRect.minX
        let endX = startX + barWidth
        guard startX.isFinite, endX.isFinite, barY.isFinite else { return }

        let path = NSBezierPath()
        path.move(to: NSPoint(x: startX, y: barY))
        path.line(to: NSPoint(x: endX, y: barY))
        let tickHalfHeight = scaleTickHeight * 0.5
        path.move(to: NSPoint(x: startX, y: barY - tickHalfHeight))
        path.line(to: NSPoint(x: startX, y: barY + tickHalfHeight))
        path.move(to: NSPoint(x: endX, y: barY - tickHalfHeight))
        path.line(to: NSPoint(x: endX, y: barY + tickHalfHeight))
        textColor(for: label).setStroke()
        path.lineWidth = scaleBarLineWidth
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !labels.isEmpty else { return }
        for label in labels {
            Self.draw(label, in: bounds)
        }
    }

    private static func font(for style: Label.Style) -> NSFont {
        switch style {
        case .atom:
            return NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        case .bondDistance:
            return NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        case .routeNode, .selectedRouteNode, .scaleIndicator:
            return NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        case .tooltip:
            return NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }
    }

    private static let multilineTextOptions: NSString.DrawingOptions = [
        .usesLineFragmentOrigin,
        .usesFontLeading,
    ]

    private static func textColor(for label: Label) -> NSColor {
        switch label.style {
        case .atom:
            return .white
        case .bondDistance:
            return .white
        case .routeNode:
            return NSColor(calibratedRed: 0.45, green: 0.92, blue: 1, alpha: 1)
        case .selectedRouteNode:
            return NSColor(calibratedWhite: 0.08, alpha: 1)
        case .tooltip:
            return .white
        case .scaleIndicator:
            return label.usesLightForeground ? .white : NSColor(calibratedWhite: 0.08, alpha: 1)
        }
    }

    private static func textAttributes(for label: Label) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: label.style),
            .foregroundColor: textColor(for: label),
        ]
        if label.style != .selectedRouteNode {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: 1)
            attributes[.shadow] = shadow
        }
        return attributes
    }

    private static func padding(for style: Label.Style) -> CGSize {
        switch style {
        case .atom:
            return .zero
        case .bondDistance:
            return CGSize(width: 3, height: 1)
        case .routeNode:
            return CGSize(width: 3, height: 2)
        case .selectedRouteNode:
            return CGSize(width: 4, height: 2)
        case .tooltip:
            return CGSize(width: 6, height: 4)
        case .scaleIndicator:
            return CGSize(width: 6, height: 5)
        }
    }

    private static func hasBackground(for style: Label.Style) -> Bool {
        style != .atom
    }

    private static func cornerRadius(for style: Label.Style) -> CGFloat {
        style == .tooltip ? 4 : 3
    }

    private static func backgroundColor(for label: Label) -> NSColor {
        switch label.style {
        case .atom:
            return .clear
        case .bondDistance:
            return NSColor.black.withAlphaComponent(0.55)
        case .routeNode:
            return NSColor.black.withAlphaComponent(0.62)
        case .selectedRouteNode:
            return NSColor(calibratedRed: 1, green: 0.83, blue: 0.2, alpha: 0.95)
        case .tooltip:
            return NSColor.black.withAlphaComponent(0.84)
        case .scaleIndicator:
            // A low-alpha inverse backing keeps the indicator legible without
            // obscuring the rendered structure beneath it.
            return label.usesLightForeground
                ? NSColor.black.withAlphaComponent(0.34)
                : NSColor.white.withAlphaComponent(0.34)
        }
    }

    private static func borderColor(for label: Label) -> NSColor {
        switch label.style {
        case .atom:
            return .clear
        case .bondDistance:
            return NSColor.white.withAlphaComponent(0.35)
        case .routeNode:
            return NSColor(calibratedRed: 0.45, green: 0.92, blue: 1, alpha: 0.9)
        case .selectedRouteNode:
            return .white
        case .tooltip:
            return NSColor.white.withAlphaComponent(0.6)
        case .scaleIndicator:
            return textColor(for: label).withAlphaComponent(0.55)
        }
    }

    private static let scaleBarGap: CGFloat = 3
    private static let scaleTickHeight: CGFloat = 8
    private static let scaleBarLineWidth: CGFloat = 2
    /// AppKit can represent much larger finite CGFloat values, but they are not
    /// meaningful screen-space bars and can create pathological paths. This is
    /// deliberately far above any practical 1/2/5 scale indicator.
    private static let maximumScaleBarWidth: CGFloat = 1_000_000

    private static func validBarWidth(for label: Label) -> CGFloat? {
        guard label.style == .scaleIndicator,
              let width = label.barWidth,
              width.isFinite, width > 0,
              width <= maximumScaleBarWidth else { return nil }
        return width
    }

    private static func finiteRect(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func rectFits(_ rect: NSRect, in bounds: NSRect) -> Bool {
        finiteRect(rect) && finiteRect(bounds)
            && rect.minX >= bounds.minX && rect.minY >= bounds.minY
            && rect.maxX <= bounds.maxX && rect.maxY <= bounds.maxY
    }

    private static func measuredTextSize(for label: Label) -> CGSize {
        let attributes = textAttributes(for: label)
        let limit = CGSize(width: 4096, height: 4096)
        let measured = (label.symbol as NSString).boundingRect(
            with: limit,
            options: multilineTextOptions,
            attributes: attributes
        )
        let font = font(for: label.style)
        let lineHeight = font.ascender - font.descender + font.leading
        return CGSize(width: ceil(max(0, measured.width)),
                      height: ceil(max(lineHeight, measured.height)))
    }

    private static func contentSize(for label: Label, measuredSize size: CGSize) -> CGSize {
        var width = size.width.isFinite ? max(0, size.width) : 0
        var height = size.height.isFinite ? max(0, size.height) : 0
        if let barWidth = validBarWidth(for: label) {
            let textSize = measuredTextSize(for: label)
            width = max(width, textSize.width, barWidth)
            height = max(height, textSize.height + scaleBarGap + scaleTickHeight)
        }
        let maxDimension = CGFloat.greatestFiniteMagnitude - 2 * padding(for: label.style).width
        guard maxDimension.isFinite else { return CGSize(width: width, height: height) }
        return CGSize(width: min(width, maxDimension), height: min(height, maxDimension))
    }
}
