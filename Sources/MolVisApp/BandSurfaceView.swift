import AppKit
import simd

/// 3D band-surface plot. Drawn in `draw(_:)` with Core Graphics (NSBezierPath), the
/// same 2D-overlay approach as BandGrapherView. A parallelogram patch of reciprocal
/// space is parameterized by (s,t) in [0,1]^2; each sheet's energy is sampled on a
/// grid over that patch and rendered as a shaded triangulated surface using the
/// painter's algorithm. 3D axes (k_x, k_y, E) are drawn in the rotated frame; a
/// translucent Fermi plane and title are overlaid.
///
/// Interaction: mouse drag rotates the view (azimuth/elevation). All interaction is
/// disabled during export (exportBackground != nil) so exported pixels are identical
/// to the pre-interaction renderer.
///
/// An EMPTY `sheets` array is a valid surface: the axes, base plane, and Fermi plane
/// are drawn without any surface triangles.
final class BandSurfaceView: NSView {
    var bandSurface: BandSurface? {
        didSet { needsDisplay = true }
    }
    /// When set, draw fills with this color (used for export).
    var exportBackground: NSColor?
    /// When true, draw skips the white fill for transparent export output.
    var isExportTransparent: Bool = false

    // --- interaction state (all inert during export) ---
    var azimuthDegrees: Float = 30
    var elevationDegrees: Float = 24 {
        didSet { elevationDegrees = max(-89, min(89, elevationDegrees)) }
    }

    private let axisFont = NSFont.systemFont(ofSize: 11)
    private let titleFont = NSFont.boldSystemFont(ofSize: 13)
    private let marginLeft: CGFloat = 56
    private let marginBottom: CGFloat = 44
    private let marginTop: CGFloat = 24
    private let marginRight: CGFloat = 16

    override var isFlipped: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        rotate(byDeltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
    }

    /// Apply a mouse-drag rotation. Horizontal motion orbits the view
    /// (azimuth); vertical motion tilts it (elevation, clamped to ±89°).
    /// Dragging UP raises the viewpoint (standard 3D-plot convention:
    /// `deltaY` is positive downward in AppKit, so it is subtracted).
    /// Internal so tests can exercise the rotation without synthesizing
    /// NSEvent deltas (which the NSEvent factory cannot set).
    func rotate(byDeltaX dx: Float, deltaY dy: Float) {
        azimuthDegrees -= dx * 0.5
        elevationDegrees = max(-89, min(89, elevationDegrees - dy * 0.5))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current?.cgContext != nil,
              let surface = bandSurface,
              surface.gridSize >= 2,
              surface.region.count == 4,
              surface.region.allSatisfy(\.isFinite)
        else { drawEmpty(dirtyRect, "No band surface"); return }

        // Every sheet value must be finite (skip when sheets is empty — that is valid).
        for sheet in surface.sheets {
            if !sheet.values.allSatisfy(\.isFinite) {
                drawEmpty(dirtyRect, "No band surface")
                return
            }
        }

        // Performance guard: too many triangles to draw interactively.
        let triCount = surface.sheets.count * (surface.gridSize - 1) * (surface.gridSize - 1) * 2
        if triCount > 200_000 {
            drawEmpty(dirtyRect, "Band surface too large to draw")
            return
        }

        // Export path: force interaction to defaults so exported pixels match the
        // pre-interaction renderer exactly.
        let isExport = exportBackground != nil
        let effAzimuth = isExport ? Float(30) : azimuthDegrees
        let effElevation = isExport ? Float(24) : elevationDegrees

        // Background fill.
        if let bg = exportBackground {
            bg.setFill()
            dirtyRect.fill()
        } else if !isExportTransparent {
            NSColor.white.setFill()
            dirtyRect.fill()
        }

        let plot = plotRect()
        guard plot.width > 0, plot.height > 0 else { drawEmpty(dirtyRect, "No band surface"); return }

        let gridSize = surface.gridSize
        let energyMin = surface.energyMin
        let energyMax = surface.energyMax
        let energyCenter = (energyMin + energyMax) / 2
        let energyRange = max(1e-6, energyMax - energyMin)
        let energyScale: Float = 0.75 * Float(min(plot.width, plot.height)) / energyRange

        // Light direction (world space, normalized).
        let L = SIMD3<Float>(0.35, 0.45, 0.85)
        let Llen = simd_length(L)
        let Lnorm = Llen > 1e-6 ? L / Llen : SIMD3<Float>(0, 0, 1)

        // --- Ground-plane geometry ---
        // u, v are the fractional-space edge vectors of the parallelogram.
        let u = surface.region[1] - surface.region[0]
        let v = surface.region[2] - surface.region[0]

        // Physical ground vectors: map fractional edges through kBasis when present.
        let U: SIMD3<Float>
        let V: SIMD3<Float>
        let unitLabel: String
        if let kBasis = surface.kBasis, kBasis.count == 3, kBasis.allSatisfy(\.isFinite) {
            U = u.x * kBasis[0] + u.y * kBasis[1] + u.z * kBasis[2]
            V = v.x * kBasis[0] + v.y * kBasis[1] + v.z * kBasis[2]
            unitLabel = "Å⁻¹"
        } else {
            U = u
            V = v
            unitLabel = "frac"
        }

        // Decompose U into length L along x and V into (c, h) so the ground
        // parallelogram has corners g0=(0,0), g1=(L,0), g2=(c,h), g3=(L+c,h).
        let Llen0 = simd_length(U)
        let Lsafe = Llen0 > 1e-6 ? Llen0 : 1
        let Ueff = Llen0 > 1e-6 ? U : SIMD3<Float>(1, 0, 0)
        let c = simd_dot(Ueff, V) / Lsafe
        let VlenSq = simd_length_squared(V)
        let hraw = sqrt(max(0, VlenSq - c * c))
        let h = hraw > 1e-6 ? hraw : 1e-3
        let Vlen = sqrt(c * c + h * h)

        // Ground center for centering the plot.
        let GC = SIMD2<Float>((Lsafe + c) / 2, h / 2)

        // Energy → z.
        func zEnergy(_ e: Float) -> Float { (e - energyCenter) * energyScale }
        let zBase = zEnergy(energyMin)
        let zTop = zEnergy(energyMax)

        // Map (s,t) in [0,1]^2 to a centered 3D point with energy e.
        func point3D(_ si: Int, _ ti: Int, _ e: Float) -> SIMD3<Float> {
            let sf = Float(si) / Float(gridSize - 1)
            let tf = Float(ti) / Float(gridSize - 1)
            let gx = sf * Lsafe + tf * c
            let gy = tf * h
            return SIMD3<Float>(gx - GC.x, gy - GC.y, zEnergy(e))
        }

        // --- Projection: azimuth about z, then elevation about x ---
        let cosA = cos(effAzimuth * .pi / 180)
        let sinA = sin(effAzimuth * .pi / 180)
        let cosE = cos(effElevation * .pi / 180)
        let sinE = sin(effElevation * .pi / 180)

        func project(_ p: SIMD3<Float>) -> (sx: Float, sy: Float, depth: Float) {
            let x1 = p.x * cosA - p.y * sinA
            let y1 = p.x * sinA + p.y * cosA
            let z1 = p.z
            let y2 = y1 * cosE - z1 * sinE
            let z2 = y1 * sinE + z1 * cosE
            return (x1, y2, z2)
        }

        // --- Build triangles (skipped when sheets is empty) ---
        struct Tri {
            var pts: [(sx: Float, sy: Float, depth: Float)]
            var depth: Float
            var color: NSColor
        }
        var tris: [Tri] = []
        tris.reserveCapacity(triCount)

        for sheet in surface.sheets {
            let values = sheet.values
            for ti in 0..<(gridSize - 1) {
                for si in 0..<(gridSize - 1) {
                    func val(_ s: Int, _ t: Int) -> Float { values[t * gridSize + s] }
                    let e00 = val(si, ti), e10 = val(si + 1, ti)
                    let e01 = val(si, ti + 1), e11 = val(si + 1, ti + 1)

                    let p00 = point3D(si, ti, e00)
                    let p10 = point3D(si + 1, ti, e10)
                    let p01 = point3D(si, ti + 1, e01)
                    let p11 = point3D(si + 1, ti + 1, e11)

                    let avgEnergy = (e00 + e10 + e01) / 3
                    let avgEnergy1 = (e10 + e01 + e11) / 3

                    let n1 = simd_normalize(simd_cross(p10 - p00, p01 - p00))
                    let shade1 = 0.55 + 0.45 * max(0, simd_dot(n1, Lnorm))
                    let cmap1 = Colormap.viridis.rgb((avgEnergy - energyMin) / energyRange)
                    let color1 = NSColor(red: CGFloat(cmap1.x) * CGFloat(shade1),
                                         green: CGFloat(cmap1.y) * CGFloat(shade1),
                                         blue: CGFloat(cmap1.z) * CGFloat(shade1), alpha: 1)

                    let n2 = simd_normalize(simd_cross(p11 - p10, p01 - p10))
                    let shade2 = 0.55 + 0.45 * max(0, simd_dot(n2, Lnorm))
                    let cmap2 = Colormap.viridis.rgb((avgEnergy1 - energyMin) / energyRange)
                    let color2 = NSColor(red: CGFloat(cmap2.x) * CGFloat(shade2),
                                         green: CGFloat(cmap2.y) * CGFloat(shade2),
                                         blue: CGFloat(cmap2.z) * CGFloat(shade2), alpha: 1)

                    let tri1 = Tri(pts: [p00, p10, p01].map(project),
                                   depth: 0, color: color1)
                    let tri2 = Tri(pts: [p10, p11, p01].map(project),
                                   depth: 0, color: color2)
                    var t1 = tri1, t2 = tri2
                    t1.depth = (t1.pts[0].depth + t1.pts[1].depth + t1.pts[2].depth) / 3
                    t2.depth = (t2.pts[0].depth + t2.pts[1].depth + t2.pts[2].depth) / 3
                    tris.append(t1)
                    tris.append(t2)
                }
            }
        }

        // --- Fit: compute projected bounds over triangles + base + E-axis ---
        var minSX = Float.greatestFiniteMagnitude, maxSX = -Float.greatestFiniteMagnitude
        var minSY = Float.greatestFiniteMagnitude, maxSY = -Float.greatestFiniteMagnitude

        func include(_ p: SIMD3<Float>) {
            let proj = project(p)
            minSX = min(minSX, proj.sx); maxSX = max(maxSX, proj.sx)
            minSY = min(minSY, proj.sy); maxSY = max(maxSY, proj.sy)
        }

        // 4 base corners at zBase.
        include(SIMD3<Float>(0 - GC.x, 0 - GC.y, zBase))
        include(SIMD3<Float>(Lsafe - GC.x, 0 - GC.y, zBase))
        include(SIMD3<Float>(c - GC.x, h - GC.y, zBase))
        include(SIMD3<Float>(Lsafe + c - GC.x, h - GC.y, zBase))
        // E-axis top at zTop.
        include(SIMD3<Float>(0 - GC.x, 0 - GC.y, zTop))

        for tri in tris {
            for p in tri.pts {
                minSX = min(minSX, p.sx); maxSX = max(maxSX, p.sx)
                minSY = min(minSY, p.sy); maxSY = max(maxSY, p.sy)
            }
        }
        if let Ef = surface.fermiEnergy {
            let zf = zEnergy(Ef)
            for (si, ti) in [(0,0),(1,0),(0,1),(1,1)] {
                let gx = Float(si) * Lsafe + Float(ti) * c
                let gy = Float(ti) * h
                include(SIMD3<Float>(gx - GC.x, gy - GC.y, zf))
            }
        }

        let dataW = maxSX - minSX
        let dataH = maxSY - minSY
        guard dataW > 1e-6, dataH > 1e-6 else { drawEmpty(dirtyRect, "No band surface"); return }

        let scaleX = plot.width / CGFloat(dataW)
        let scaleY = plot.height / CGFloat(dataH)
        let scale = min(scaleX, scaleY)
        let cx = plot.midX - CGFloat((minSX + maxSX) / 2) * scale
        let cy = plot.midY - CGFloat((minSY + maxSY) / 2) * scale

        func toScreen(_ p: (sx: Float, sy: Float, depth: Float)) -> NSPoint {
            NSPoint(x: cx + CGFloat(p.sx) * scale,
                    y: cy - CGFloat(p.sy) * scale)
        }

        // --- Draw order ---
        // 1. Base plane (all surfaces lie at z >= zBase).
        let base3D = [
            SIMD3<Float>(0 - GC.x, 0 - GC.y, zBase),
            SIMD3<Float>(Lsafe - GC.x, 0 - GC.y, zBase),
            SIMD3<Float>(Lsafe + c - GC.x, h - GC.y, zBase),
            SIMD3<Float>(c - GC.x, h - GC.y, zBase)
        ]
        let baseScreen = base3D.map { toScreen(project($0)) }
        let basePath = NSBezierPath()
        basePath.move(to: baseScreen[0])
        basePath.line(to: baseScreen[1])
        basePath.line(to: baseScreen[2])
        basePath.line(to: baseScreen[3])
        basePath.close()
        NSColor(white: 0.9, alpha: 0.25).setFill()
        basePath.fill()
        NSColor.gray.withAlphaComponent(0.6).setStroke()
        basePath.lineWidth = 1
        basePath.stroke()

        // 2. 3D axes (drawn before surfaces so surfaces occlude them).
        NSColor.black.setStroke()
        let axisOrigin = toScreen(project(SIMD3<Float>(0 - GC.x, 0 - GC.y, zBase)))
        let axisKxEnd = toScreen(project(SIMD3<Float>(Lsafe - GC.x, 0 - GC.y, zBase)))
        let axisKyEnd = toScreen(project(SIMD3<Float>(c - GC.x, h - GC.y, zBase)))
        let axisETop = toScreen(project(SIMD3<Float>(0 - GC.x, 0 - GC.y, zTop)))

        for (a, b) in [(axisOrigin, axisKxEnd), (axisOrigin, axisKyEnd), (axisOrigin, axisETop)] {
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = 1
            path.stroke()
        }

        // Ticks: small crosses in the base plane for k axes, screen-space crosses for E.
        let tickLen = 0.03 * max(Lsafe, h)
        let tickColor = NSColor.darkGray
        tickColor.setStroke()

        // k_x ticks at s in {0, 1/4, 1/2, 3/4, 1}.
        for s in [Float(0), 0.25, 0.5, 0.75, 1.0] {
            let pos = SIMD3<Float>(s * Lsafe - GC.x, -GC.y, zBase)
            let cross = [
                project(SIMD3<Float>(pos.x - tickLen, pos.y, pos.z)),
                project(SIMD3<Float>(pos.x + tickLen, pos.y, pos.z)),
                project(SIMD3<Float>(pos.x, pos.y - tickLen, pos.z)),
                project(SIMD3<Float>(pos.x, pos.y + tickLen, pos.z))
            ].map(toScreen)
            let tp = NSBezierPath()
            tp.move(to: cross[0]); tp.line(to: cross[1])
            tp.move(to: cross[2]); tp.line(to: cross[3])
            tp.lineWidth = 1
            tp.stroke()
            let lp = toScreen(project(pos))
            drawLabel(String(format: "%.2f", s * Lsafe), at: NSPoint(x: lp.x - 4, y: lp.y + 6),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }

        // k_y ticks at t in {0, 1/4, 1/2, 3/4, 1}.
        for t in [Float(0), 0.25, 0.5, 0.75, 1.0] {
            let pos = SIMD3<Float>(t * c - GC.x, t * h - GC.y, zBase)
            let cross = [
                project(SIMD3<Float>(pos.x - tickLen, pos.y, pos.z)),
                project(SIMD3<Float>(pos.x + tickLen, pos.y, pos.z)),
                project(SIMD3<Float>(pos.x, pos.y - tickLen, pos.z)),
                project(SIMD3<Float>(pos.x, pos.y + tickLen, pos.z))
            ].map(toScreen)
            let tp = NSBezierPath()
            tp.move(to: cross[0]); tp.line(to: cross[1])
            tp.move(to: cross[2]); tp.line(to: cross[3])
            tp.lineWidth = 1
            tp.stroke()
            let lp = toScreen(project(pos))
            drawLabel(String(format: "%.2f", t * Vlen), at: NSPoint(x: lp.x - 4, y: lp.y + 6),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }

        // E ticks at 5 evenly spaced energies.
        let eTickCount = 5
        for i in 0...eTickCount {
            let e = energyMin + (energyMax - energyMin) * Float(i) / Float(eTickCount)
            let lp = toScreen(project(SIMD3<Float>(-GC.x, -GC.y, zEnergy(e))))
            let tp = NSBezierPath()
            tp.move(to: NSPoint(x: lp.x - 3, y: lp.y))
            tp.line(to: NSPoint(x: lp.x + 3, y: lp.y))
            tp.move(to: NSPoint(x: lp.x, y: lp.y - 3))
            tp.line(to: NSPoint(x: lp.x, y: lp.y + 3))
            tp.lineWidth = 1
            tp.stroke()
            drawLabel(String(format: "%.1f", e), at: NSPoint(x: lp.x - 8, y: lp.y),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }

        // Axis name labels.
        NSColor.black.setStroke()
        drawLabel("k_x (\(unitLabel))", at: NSPoint(x: axisKxEnd.x + 6, y: axisKxEnd.y + 6),
                  font: titleFont, color: .black, rightAligned: false)
        drawLabel("k_y (\(unitLabel))", at: NSPoint(x: axisKyEnd.x + 6, y: axisKyEnd.y + 6),
                  font: titleFont, color: .black, rightAligned: false)
        drawLabel("E (eV)", at: NSPoint(x: axisETop.x - 6, y: axisETop.y - 4),
                  font: titleFont, color: .black, rightAligned: false)

        // 3. Surfaces (painter's algorithm: far first).
        tris.sort { $0.depth > $1.depth }
        for tri in tris {
            let path = NSBezierPath()
            let screenPts = tri.pts.map(toScreen)
            path.move(to: screenPts[0])
            path.line(to: screenPts[1])
            path.line(to: screenPts[2])
            path.close()
            tri.color.setFill()
            path.fill()
        }

        // 4. Fermi plane (drawn AFTER surfaces).
        if let Ef = surface.fermiEnergy {
            let zf = zEnergy(Ef)
            let fermi3D = [(0,0),(1,0),(1,1),(0,1)].map { (si: Int, ti: Int) in
                let gx = Float(si) * Lsafe + Float(ti) * c
                let gy = Float(ti) * h
                return SIMD3<Float>(gx - GC.x, gy - GC.y, zf)
            }
            let fermiScreen = fermi3D.map { toScreen(project($0)) }
            let plane = NSBezierPath()
            plane.move(to: fermiScreen[0])
            plane.line(to: fermiScreen[1])
            plane.line(to: fermiScreen[2])
            plane.line(to: fermiScreen[3])
            plane.close()
            NSColor.red.withAlphaComponent(0.15).setFill()
            plane.fill()
            NSColor.red.withAlphaComponent(0.6).setStroke()
            plane.lineWidth = 1
            plane.stroke()
        }

        // 5. Title.
        let titleStr = surface.fermiEnergy.map { "Band Surface\nEf = \(String(format: "%.3f", $0)) eV" }
            ?? "Band Surface"
        let titleLines = titleStr.components(separatedBy: "\n")
        for (i, line) in titleLines.enumerated() {
            drawLabel(line, at: NSPoint(x: plot.midX, y: marginTop + CGFloat(i) * 16),
                      font: titleFont, color: .black, rightAligned: false)
        }
    }

    // MARK: - Geometry helpers

    private func plotRect() -> NSRect {
        NSRect(x: marginLeft,
               y: marginBottom,
               width: bounds.width - marginLeft - marginRight,
               height: bounds.height - marginBottom - marginTop)
    }

    private func drawEmpty(_ dirtyRect: NSRect, _ message: String) {
        if let bg = exportBackground {
            bg.setFill()
            dirtyRect.fill()
        } else if !isExportTransparent {
            NSColor.white.setFill()
            dirtyRect.fill()
        }
        drawLabel(message, at: NSPoint(x: bounds.midX, y: bounds.midY),
                  font: titleFont, color: .gray, rightAligned: false)
    }

    private func drawLabel(_ s: String, at p: NSPoint, font: NSFont, color: NSColor, rightAligned: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attr = NSAttributedString(string: s, attributes: attrs)
        var pt = p
        if rightAligned { pt.x -= attr.size().width } else { pt.x -= attr.size().width / 2; pt.y -= attr.size().height / 2 }
        attr.draw(at: pt)
    }
}
