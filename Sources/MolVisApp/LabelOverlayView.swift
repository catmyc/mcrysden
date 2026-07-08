import AppKit

/// A transparent overlay that draws element-symbol text labels at projected
/// atom screen positions. Managed by `MainWindowController.updateLabels()`.
final class LabelOverlayView: NSView {
    /// One label to draw during `drawRect`.
    struct Label { let symbol: String; let x: CGFloat; let y: CGFloat }

    var labels: [Label] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }   // so y = 0 is the top

    override func draw(_ dirtyRect: NSRect) {
        guard !labels.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let fg = [NSAttributedString.Key.font: font,
                  .foregroundColor: NSColor.white]
        for l in labels {
            (l.symbol as NSString).draw(at: NSPoint(x: l.x, y: l.y), withAttributes: fg)
        }
    }
}
