import AppKit

/// A backdrop that gives the docked readout macOS Sonoma aesthetics: rounded
/// top corners, a solid fill matching the system window background, and a
/// 1-pt hairline separator along the top edge so the readout reads as a panel
/// gently detached from the structure view above it.
final class ReadoutView: NSView {
    override var isFlipped: Bool { true }   // coordinate with the text view

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        // Rounded path on the top corners only; bottom corners stay square so
        // the panel can sit flush against any surface beneath it.  Use a CGPath
        // for the corner arcs — its arc primitive is unambiguous.
        let r: CGFloat = 10
        let p = CGMutablePath()
        p.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        p.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY - r))
        p.addArc(center: CGPoint(x: bounds.minX + r, y: bounds.maxY - r),
                 radius: r, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        p.addLine(to: CGPoint(x: bounds.maxX - r, y: bounds.maxY))
        p.addArc(center: CGPoint(x: bounds.maxX - r, y: bounds.maxY - r),
                 radius: r, startAngle: 1.5 * .pi, endAngle: 2 * .pi, clockwise: false)
        p.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        p.closeSubpath()

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.addPath(p)
        ctx?.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx?.fillPath()

        // Hairline separator inset along the top edge.
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: bounds.minX + r, y: bounds.maxY - 0.5))
        sep.line(to: NSPoint(x: bounds.maxX - r, y: bounds.maxY - 0.5))
        sep.lineWidth = 1
        NSColor.separatorColor.setStroke()
        sep.stroke()
    }
}
