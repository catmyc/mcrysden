import AppKit

/// A container that shows the band grapher and DOS grapher side by side when
/// BOTH datasets are present, or a single grapher full-width when only one is
/// present. The children's bandStructure/densityOfStates are set directly on
/// the children (the controller keeps `bandGrapher`/`dosGrapher` properties
/// pointing at `linkedGraphs.bandView`/`.dosView`).
final class LinkedGraphsView: NSView {
    let bandView: BandGrapherView
    let dosView: DOSGrapherView

    /// Presence flags; when false the child is hidden and the other child (if
    /// any) takes the full width. Both true -> 50/50 split, band left, DOS right.
    var bandPresent: Bool {
        didSet { layoutChildren() }
    }
    var dosPresent: Bool {
        didSet { layoutChildren() }
    }

    /// Forwarded to the children (their draw paths treat non-nil as export mode).
    var exportBackground: NSColor? {
        didSet {
            bandView.exportBackground = exportBackground
            dosView.exportBackground = exportBackground
            needsDisplay = true
        }
    }
    var isExportTransparent: Bool = false {
        didSet {
            bandView.isExportTransparent = isExportTransparent
            dosView.isExportTransparent = isExportTransparent
        }
    }

    init(frame: NSRect, bandView: BandGrapherView, dosView: DOSGrapherView,
         band: BandStructure?, dos: DensityOfStates?, bandPresent: Bool, dosPresent: Bool) {
        self.bandView = bandView
        self.bandView.bandStructure = band
        self.dosView = dosView
        self.dosView.densityOfStates = dos
        self.bandPresent = bandPresent
        self.dosPresent = dosPresent
        super.init(frame: frame)
        bandView.translatesAutoresizingMaskIntoConstraints = false
        dosView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bandView)
        addSubview(dosView)
        layoutChildren()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layoutChildren() {
        bandView.isHidden = !bandPresent
        dosView.isHidden = !dosPresent
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        if bandPresent && dosPresent {
            let half = (w - 1) / 2
            bandView.frame = NSRect(x: 0, y: 0, width: half, height: h)
            dosView.frame = NSRect(x: half + 1, y: 0, width: w - half - 1, height: h)
        } else if bandPresent {
            bandView.frame = bounds
        } else if dosPresent {
            dosView.frame = bounds
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutChildren()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Export/print path: the container is drawn directly by exportGraph /
        // renderGraph. Paint each visible child by translating to its frame origin
        // and calling its draw(). The background is filled only when an explicit
        // opaque background is supplied; transparent exports (exportBackground nil,
        // isExportTransparent true) still paint the children but skip the fill.
        // In live mode (exportBackground nil AND not transparent) children draw
        // themselves via AppKit — the container paints nothing.
        guard exportBackground != nil || isExportTransparent else { return }
        // Defensively relayout against current bounds (zero-safe).
        layoutChildren()
        // Fill the container background explicitly when one is provided, so the
        // children paint on top without an undefined fill after the export
        // context's translate/scale. Transparent exports skip the fill entirely.
        if let bg = exportBackground {
            bg.setFill()
            dirtyRect.fill()
        }
        let children: [(NSView, Bool)] = [(bandView, bandPresent), (dosView, dosPresent)]
        for (child, present) in children where !child.isHidden && present {
            let f = child.frame
            guard f.width > 0, f.height > 0 else { continue }
            let ctx = NSGraphicsContext.current!.cgContext
            NSGraphicsContext.saveGraphicsState()
            ctx.translateBy(x: f.origin.x, y: f.origin.y)
            child.draw(child.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        // Thin divider line between the two panels when both are present.
        if bandPresent && dosPresent {
            let x = (bounds.width - 1) / 2 + 0.5
            NSColor.separatorColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 0))
            line.line(to: NSPoint(x: x, y: bounds.height))
            line.lineWidth = 1
            line.stroke()
        }
    }
}
