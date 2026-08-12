import AppKit
import simd

/// 3D band-surface plot. Drawn in `draw(_:)` with Core Graphics (NSBezierPath), the
/// same 2D-overlay approach as BandGrapherView. A parallelogram patch of reciprocal
/// space is parameterized by (s,t) in [0,1]^2; each sheet's energy is sampled on a
/// grid over that patch and rendered as a shaded triangulated surface using the
/// painter's algorithm. A translucent Fermi plane and energy axes are overlaid.
///
/// Interaction: mouse drag rotates the view (azimuth/elevation). All interaction is
/// disabled during export (exportBackground != nil) so exported pixels are identical
/// to the pre-interaction renderer.
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
              !surface.sheets.isEmpty,
              surface.region.count == 4,
              surface.region.allSatisfy(\.isFinite)
        else { drawEmpty(dirtyRect, "No band surface"); return }

        // Every value must be finite.
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

        // Precompute the 3D surface points for all sheets.
        // Point in pre-projection 3D space:
        //   x = s - 0.5, y = t - 0.5, z = (e - energyCenter) * energyScale
        // where s,t in [0,1].
        let cosA = cos(effAzimuth * .pi / 180)
        let sinA = sin(effAzimuth * .pi / 180)
        let cosE = cos(effElevation * .pi / 180)
        let sinE = sin(effElevation * .pi / 180)

        /// Map a pre-projection 3D point to screen space (orthographic projection
        /// with cx/cy/scale applied later). Returns the projected (x', y', z'') where
        /// z'' is depth (larger = closer to viewer).
        func project(_ p: SIMD3<Float>) -> (sx: Float, sy: Float, depth: Float) {
            // Azimuth rotation about z-axis.
            let x1 = p.x * cosA - p.y * sinA
            let y1 = p.x * sinA + p.y * cosA
            let z1 = p.z
            // Elevation rotation about x-axis.
            let y2 = y1 * cosE - z1 * sinE
            let z2 = y1 * sinE + z1 * cosE
            return (x1, y2, z2)
        }

        // Build all triangles across all sheets. Each triangle stores projected
        // screen points, depth (mean z''), and color.
        struct Tri {
            var pts: [(sx: Float, sy: Float, depth: Float)]   // 3 projected corners
            var depth: Float     // mean z'' (painter's: larger = closer)
            var color: NSColor
        }
        var tris: [Tri] = []
        tris.reserveCapacity(triCount)

        for sheet in surface.sheets {
            let values = sheet.values
            for ti in 0..<(gridSize - 1) {
                for si in 0..<(gridSize - 1) {
                    // 4 corners of the cell: (si,ti), (si+1,ti), (si,ti+1), (si+1,ti+1)
                    func val(_ s: Int, _ t: Int) -> Float { values[t * gridSize + s] }
                    let e00 = val(si, ti), e10 = val(si + 1, ti)
                    let e01 = val(si, ti + 1), e11 = val(si + 1, ti + 1)

                    func point3D(_ s: Int, _ t: Int, _ e: Float) -> SIMD3<Float> {
                        let sf = Float(s) / Float(gridSize - 1)
                        let tf = Float(t) / Float(gridSize - 1)
                        return SIMD3<Float>(sf - 0.5, tf - 0.5, (e - energyCenter) * energyScale)
                    }

                    let p00 = point3D(si, ti, e00)
                    let p10 = point3D(si + 1, ti, e10)
                    let p01 = point3D(si, ti + 1, e01)
                    let p11 = point3D(si + 1, ti + 1, e11)

                    let avgEnergy = (e00 + e10 + e01) / 3
                    let avgEnergy1 = (e10 + e01 + e11) / 3

                    // Normal for triangle 1 (p00, p10, p01).
                    let n1 = simd_normalize(simd_cross(p10 - p00, p01 - p00))
                    let shade1 = 0.55 + 0.45 * max(0, simd_dot(n1, Lnorm))
                    let cmap1 = Colormap.viridis.rgb((avgEnergy - energyMin) / energyRange)
                    let color1 = NSColor(red: CGFloat(cmap1.x) * CGFloat(shade1),
                                         green: CGFloat(cmap1.y) * CGFloat(shade1),
                                         blue: CGFloat(cmap1.z) * CGFloat(shade1), alpha: 1)

                    // Normal for triangle 2 (p10, p11, p01).
                    let n2 = simd_normalize(simd_cross(p11 - p10, p01 - p10))
                    let shade2 = 0.55 + 0.45 * max(0, simd_dot(n2, Lnorm))
                    let cmap2 = Colormap.viridis.rgb((avgEnergy1 - energyMin) / energyRange)
                    let color2 = NSColor(red: CGFloat(cmap2.x) * CGFloat(shade2),
                                         green: CGFloat(cmap2.y) * CGFloat(shade2),
                                         blue: CGFloat(cmap2.z) * CGFloat(shade2), alpha: 1)

                    tris.append(Tri(pts: [], depth: 0, color: color1))
                    tris[tris.count - 1].pts = [p00, p10, p01].map { project($0) }
                    tris[tris.count - 1].depth = (tris[tris.count - 1].pts[0].depth + tris[tris.count - 1].pts[1].depth + tris[tris.count - 1].pts[2].depth) / 3
                    tris[tris.count - 1].color = color1

                    tris.append(Tri(pts: [], depth: 0, color: color2))
                    tris[tris.count - 1].pts = [p10, p11, p01].map { project($0) }
                    tris[tris.count - 1].depth = (tris[tris.count - 1].pts[0].depth + tris[tris.count - 1].pts[1].depth + tris[tris.count - 1].pts[2].depth) / 3
                    tris[tris.count - 1].color = color2
                }
            }
        }

        // Compute projected bounds of all triangles + Fermi plane corners to fit.
        var minSX = Float.greatestFiniteMagnitude, maxSX = -Float.greatestFiniteMagnitude
        var minSY = Float.greatestFiniteMagnitude, maxSY = -Float.greatestFiniteMagnitude
        for tri in tris {
            for p in tri.pts {
                minSX = min(minSX, p.sx); maxSX = max(maxSX, p.sx)
                minSY = min(minSY, p.sy); maxSY = max(maxSY, p.sy)
            }
        }
        // Include Fermi plane corners in the bounds.
        if let Ef = surface.fermiEnergy {
            let zf = (Ef - energyCenter) * energyScale
            for (si, ti) in [(0,0),(1,0),(0,1),(1,1)] {
                let p = project(SIMD3<Float>(Float(si) - 0.5, Float(ti) - 0.5, zf))
                minSX = min(minSX, p.sx); maxSX = max(maxSX, p.sx)
                minSY = min(minSY, p.sy); maxSY = max(maxSY, p.sy)
            }
        }
        // Include region corner labels' anchor points (at z=0 plane) — these are
        // the four UNIT-SQUARE (s,t) corners, not the fractional region corners.
        for (si, ti) in [(0,0),(1,0),(0,1),(1,1)] {
            let p = project(SIMD3<Float>(Float(si) - 0.5, Float(ti) - 0.5, 0))
            minSX = min(minSX, p.sx); maxSX = max(maxSX, p.sx)
            minSY = min(minSY, p.sy); maxSY = max(maxSY, p.sy)
        }

        let dataW = maxSX - minSX
        let dataH = maxSY - minSY
        guard dataW > 1e-6, dataH > 1e-6 else { drawEmpty(dirtyRect, "No band surface"); return }

        let scaleX = plot.width / CGFloat(dataW)
        let scaleY = plot.height / CGFloat(dataH)
        let scale = min(scaleX, scaleY)
        let cx = plot.midX - CGFloat((minSX + maxSX) / 2) * scale
        let cy = plot.midY - CGFloat((minSY + maxSY) / 2) * scale

        /// Convert a projected 3D point to a screen NSPoint using the fit transform.
        func toScreen(_ p: (sx: Float, sy: Float, depth: Float)) -> NSPoint {
            NSPoint(x: cx + CGFloat(p.sx) * scale,
                    y: cy - CGFloat(p.sy) * scale)
        }

        // Sort triangles by depth DESCENDING (far first for painter's algorithm).
        // Stable sort preserves sheet/cell order for ties.
        tris.sort { $0.depth > $1.depth }

        // Draw triangles.
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

        // Fermi plane: drawn AFTER all surfaces.
        if let Ef = surface.fermiEnergy {
            let zf = (Ef - energyCenter) * energyScale
            let corners3D = [(0,0),(1,0),(0,1),(1,1)].map { (si: Int, ti: Int) in
                project(SIMD3<Float>(Float(si) - 0.5, Float(ti) - 0.5, zf))
            }
            let screenCorners = corners3D.map(toScreen)
            let plane = NSBezierPath()
            plane.move(to: screenCorners[0])
            plane.line(to: screenCorners[1])
            plane.line(to: screenCorners[3])
            plane.line(to: screenCorners[2])
            plane.close()
            NSColor.red.withAlphaComponent(0.15).setFill()
            plane.fill()
            NSColor.red.withAlphaComponent(0.6).setStroke()
            plane.lineWidth = 1
            plane.stroke()
        }

        // --- Axes/labels (view space, NOT rotated) ---
        drawAxes(plot: plot, energyMin: energyMin, energyMax: energyMax,
                 surface: surface, toScreen: toScreen, project: project)
    }

    // MARK: - Geometry helpers

    private func plotRect() -> NSRect {
        NSRect(x: marginLeft,
               y: marginBottom,
               width: bounds.width - marginLeft - marginRight,
               height: bounds.height - marginBottom - marginTop)
    }

    /// Draw the energy axis, title, region corner labels, and caption.
    private func drawAxes(plot: NSRect, energyMin: Float, energyMax: Float,
                          surface: BandSurface,
                          toScreen: ((sx: Float, sy: Float, depth: Float)) -> NSPoint,
                          project: (SIMD3<Float>) -> (sx: Float, sy: Float, depth: Float)) {
        let axis = NSColor.black
        axis.setStroke()

        // Left vertical axis line.
        let axisPath = NSBezierPath()
        axisPath.move(to: NSPoint(x: plot.minX, y: plot.minY))
        axisPath.line(to: NSPoint(x: plot.minX, y: plot.maxY))
        axisPath.lineWidth = 1
        axisPath.stroke()

        // 5 energy ticks + labels.
        let yTicks = 5
        for i in 0...yTicks {
            let frac = CGFloat(i) / CGFloat(yTicks)
            let e = energyMin + (energyMax - energyMin) * Float(frac)
            let py = plot.maxY - plot.height * frac
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: plot.minX, y: py))
            tick.line(to: NSPoint(x: plot.minX - 4, y: py))
            tick.stroke()
            drawLabel(String(format: "%.1f eV", e), at: NSPoint(x: plot.minX - 8, y: py),
                      font: axisFont, color: axis, rightAligned: true)
        }
        drawLabel("E (eV)", at: NSPoint(x: 6, y: plot.minY - 14), font: titleFont, color: axis, rightAligned: false)

        // Title centered at top.
        let titleStr = surface.fermiEnergy.map { "Band Surface\nEf = \(String(format: "%.3f", $0)) eV" }
            ?? "Band Surface"
        let titleLines = titleStr.components(separatedBy: "\n")
        for (i, line) in titleLines.enumerated() {
            drawLabel(line, at: NSPoint(x: plot.midX, y: marginTop + CGFloat(i) * 16),
                      font: titleFont, color: axis, rightAligned: false)
        }

        // Region corner labels near projected corners — anchored at the four
        // UNIT-SQUARE (s,t) corners (p0=(0,0), p1=(1,0), p2=(0,1), p3=(1,1)).
        let unitCorners: [(Float, Float)] = [(0,0),(1,0),(0,1),(1,1)]
        for (i, (si, ti)) in unitCorners.enumerated() {
            let label = i < surface.regionLabels.count ? surface.regionLabels[i] : ""
            guard !label.isEmpty else { continue }
            let p = toScreen(project(SIMD3<Float>(si - 0.5, ti - 0.5, 0)))
            drawLabel(label, at: NSPoint(x: p.x, y: p.y), font: axisFont, color: .darkGray, rightAligned: false)
        }

        // Caption at bottom.
        drawLabel("k-plane: (s,t) ∈ [0,1]² over the surface region",
                  at: NSPoint(x: plot.midX, y: bounds.height - 8),
                  font: axisFont, color: .gray, rightAligned: false)
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
