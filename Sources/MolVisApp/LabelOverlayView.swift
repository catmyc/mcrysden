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

            var isExportable: Bool { self != .tooltip }
        }

        let symbol: String
        let x: CGFloat
        let y: CGFloat
        let style: Style

        /// The default preserves the original atom-label call site and layout.
        init(symbol: String, x: CGFloat, y: CGFloat, style: Style = .atom) {
            self.symbol = symbol
            self.x = x
            self.y = y
            self.style = style
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

    /// Size of the text itself, excluding any style background or padding.
    static func measuredSize(for label: Label) -> CGSize {
        let attributes = textAttributes(for: label.style)
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

    /// Full visual bounds at the label's requested origin. The origin is the
    /// text origin for the backwards-compatible atom style.
    static func drawingRect(for label: Label) -> NSRect {
        drawingRect(for: label, measuredSize: measuredSize(for: label))
    }

    /// Full visual bounds using a caller-provided measurement. Controllers that
    /// redraw persistent labels frequently can cache the text measurement while
    /// still sharing this geometry implementation with exports and drawing.
    static func drawingRect(for label: Label, measuredSize size: CGSize) -> NSRect {
        let padding = padding(for: label.style)
        return NSRect(x: label.x - padding.width,
                      y: label.y - padding.height,
                      width: size.width + 2 * padding.width,
                      height: size.height + 2 * padding.height)
    }

    /// The text area inside a label's padded background. Multiline drawing is
    /// constrained to this rect so it uses the same geometry as measurement.
    static func textDrawingRect(for label: Label, in rect: NSRect) -> NSRect {
        let padding = padding(for: label.style)
        return NSRect(x: rect.minX + padding.width,
                      y: rect.minY + padding.height,
                      width: max(0, rect.width - 2 * padding.width),
                      height: max(0, rect.height - 2 * padding.height))
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
    /// `bounds` is only needed to clamp transient tooltips.
    static func draw(_ label: Label, in bounds: NSRect? = nil) {
        guard label.isExportable || label.style == .tooltip else { return }
        let rect: NSRect
        if let bounds, label.style == .tooltip {
            rect = clampedDrawingRect(for: label, in: bounds)
        } else {
            rect = drawingRect(for: label)
        }

        if hasBackground(for: label.style) {
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: cornerRadius(for: label.style),
                                    yRadius: cornerRadius(for: label.style))
            backgroundColor(for: label.style).setFill()
            path.fill()
            borderColor(for: label.style).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let textRect = textDrawingRect(for: label, in: rect)
        let attributes = textAttributes(for: label.style)
        if label.symbol.rangeOfCharacter(from: .newlines) != nil {
            (label.symbol as NSString).draw(with: textRect,
                                            options: multilineTextOptions,
                                            attributes: attributes)
        } else {
            (label.symbol as NSString).draw(at: textRect.origin,
                                            withAttributes: attributes)
        }
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
        case .routeNode, .selectedRouteNode:
            return NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        case .tooltip:
            return NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }
    }

    private static let multilineTextOptions: NSString.DrawingOptions = [
        .usesLineFragmentOrigin,
        .usesFontLeading,
    ]

    private static func textColor(for style: Label.Style) -> NSColor {
        switch style {
        case .atom:
            return .white
        case .routeNode:
            return NSColor(calibratedRed: 0.45, green: 0.92, blue: 1, alpha: 1)
        case .selectedRouteNode:
            return NSColor(calibratedWhite: 0.08, alpha: 1)
        case .tooltip:
            return .white
        }
    }

    private static func textAttributes(for style: Label.Style) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style),
            .foregroundColor: textColor(for: style),
        ]
        if style != .selectedRouteNode {
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
        case .routeNode:
            return CGSize(width: 3, height: 2)
        case .selectedRouteNode:
            return CGSize(width: 4, height: 2)
        case .tooltip:
            return CGSize(width: 6, height: 4)
        }
    }

    private static func hasBackground(for style: Label.Style) -> Bool {
        style != .atom
    }

    private static func cornerRadius(for style: Label.Style) -> CGFloat {
        style == .tooltip ? 4 : 3
    }

    private static func backgroundColor(for style: Label.Style) -> NSColor {
        switch style {
        case .atom:
            return .clear
        case .routeNode:
            return NSColor.black.withAlphaComponent(0.62)
        case .selectedRouteNode:
            return NSColor(calibratedRed: 1, green: 0.83, blue: 0.2, alpha: 0.95)
        case .tooltip:
            return NSColor.black.withAlphaComponent(0.84)
        }
    }

    private static func borderColor(for style: Label.Style) -> NSColor {
        switch style {
        case .atom:
            return .clear
        case .routeNode:
            return NSColor(calibratedRed: 0.45, green: 0.92, blue: 1, alpha: 0.9)
        case .selectedRouteNode:
            return .white
        case .tooltip:
            return NSColor.white.withAlphaComponent(0.6)
        }
    }
}
