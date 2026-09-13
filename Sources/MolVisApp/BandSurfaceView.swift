import AppKit
import Darwin
import simd
import BandSurfaceRaster

/// 3D band-surface plot. A parallelogram patch of reciprocal space is parameterized
/// by (s,t) in [0,1]^2; each sheet's energy is sampled on a grid over that patch and
/// rendered as a shaded triangulated surface. Rasterization uses a CPU z-buffer
/// (per-pixel depth test) instead of the painter's algorithm, so crossing bands and
/// the translucent Fermi plane composite correctly. 3D axes (k₁, k₂, E) are drawn in
/// the rotated frame and depth-tested; ticks, axis labels and the title are overlaid
/// on top of the rasterized image. The whole plot is fitted to the plot rect and the
/// energy axis is scaled relative to the reciprocal-plane extent so it is not
/// collapsed into a sliver.
///
/// Interaction: mouse drag rotates the view (azimuth/elevation). The same rotation
/// applies during export and print so the exported image matches the interactive view
/// (WYSIWYG).
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

    /// Whether the Fermi plane is inside the displayed energy domain for `surface`.
    /// Pure helper (no side effects) so the domain gate (Finding 7) is unit-testable
    /// independently of the raster pipeline.
    func isFermiPlaneInDomain(_ surface: BandSurface) -> Bool {
        surface.fermiEnergy.map { Ef in Ef >= surface.energyMin && Ef <= surface.energyMax } ?? false
    }

    // --- interaction state (live during export/print for WYSIWYG) ---
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
        let area = surfaceGridArea(bandSurface)
        guard NSGraphicsContext.current?.cgContext != nil,
              let surface = bandSurface,
              surface.gridSize >= 2,
              area > 0,
              surface.region.count == 4,
              surface.region.allSatisfy(\.isFinite),
              surface.energyMin.isFinite, surface.energyMax.isFinite,
              surface.energyMin <= surface.energyMax,
              surface.sheets.allSatisfy({ $0.values.count == area && $0.values.allSatisfy(\.isFinite) })
        else { drawEmpty(dirtyRect, "No band surface"); return }

        // Performance guard: too many triangles to draw interactively.
        let triCount = surface.sheets.count * (surface.gridSize - 1) * (surface.gridSize - 1) * 2
        if triCount > 200_000 {
            drawEmpty(dirtyRect, "Band surface too large to draw")
            return
        }

        // Background fill.
        if let bg = exportBackground {
            bg.setFill()
            bounds.fill()
        } else if !isExportTransparent {
            NSColor.white.setFill()
            bounds.fill()
        }

        let plot = plotRect()
        guard plot.width > 0, plot.height > 0 else { drawEmpty(dirtyRect, "No band surface"); return }

        let gridSize = surface.gridSize
        let energyMin = surface.energyMin
        let energyMax = surface.energyMax
        // Validate and normalize the energy window in Double. Float arithmetic
        // overflows for otherwise finite band data, e.g. a BXSF band sampled
        // near -3e38...+3e38; the resulting infinity then becomes NaN inside
        // NSBezierPath ticks (or a NaN projection), which raises an AppKit
        // exception instead of failing the draw.
        let energyLoD = Double(energyMin)
        let energyHiD = Double(energyMax)
        let energySpanD = energyHiD - energyLoD
        let maxRenderableEnergy = BandSurface.maxRenderableEnergyMagnitude
        guard energySpanD.isFinite,
              energySpanD <= BandSurface.maxRenderableEnergySpan,
              abs(energyLoD) <= maxRenderableEnergy,
              abs(energyHiD) <= maxRenderableEnergy else {
            drawEmpty(dirtyRect, "Band surface energy range is invalid")
            return
        }
        let energyCenter = Float(energyLoD + energySpanD / 2)
        let energyRange = Float(max(1e-6, energySpanD))

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

        // Scale energy height relative to the reciprocal-plane extent (not the pixel
        // size) so the single model->screen fit below is the ONLY normalization step
        // and the energy axis is not collapsed into a sliver.
        let energyScale: Float = 0.75 * max(simd_length(U), Vlen) / energyRange

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
        let cosA = cos(azimuthDegrees * .pi / 180)
        let sinA = sin(azimuthDegrees * .pi / 180)
        let cosE = cos(elevationDegrees * .pi / 180)
        let sinE = sin(elevationDegrees * .pi / 180)

        func project(_ p: SIMD3<Float>) -> (sx: Float, sy: Float, depth: Float) {
            let x1 = p.x * cosA - p.y * sinA
            let y1 = p.x * sinA + p.y * cosA
            let z1 = p.z
            let y2 = y1 * cosE - z1 * sinE
            let z2 = y1 * sinE + z1 * cosE
            return (x1, y2, z2)
        }
        func vert(_ p: SIMD3<Float>) -> ProjVert {
            let pr = project(p); return ProjVert(sx: pr.sx, sy: pr.sy, depth: pr.depth)
        }

        // --- Decide whether the Fermi plane lies inside the displayed domain ---
        let drawFermi = surface.fermiEnergy.map { Ef in Ef >= energyMin && Ef <= energyMax } ?? false

        // --- Build surface triangles (skipped when sheets is empty) ---
        // Each triangle stores its three projected model-space vertices (sx, sy, depth)
        // and a flat-shaded RGB color (viridis of mean energy * lambert shade).
        struct ProjVert { var sx, sy, depth: Float }
        struct SurfTri { var v: (ProjVert, ProjVert, ProjVert); var r, g, b: Float }
        var surfTris: [SurfTri] = []
        surfTris.reserveCapacity(triCount)

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

                    let n2 = simd_normalize(simd_cross(p11 - p10, p01 - p10))
                    let shade2 = 0.55 + 0.45 * max(0, simd_dot(n2, Lnorm))
                    let cmap2 = Colormap.viridis.rgb((avgEnergy1 - energyMin) / energyRange)

                    surfTris.append(SurfTri(v: (vert(p00), vert(p10), vert(p01)),
                                            r: cmap1.x * shade1, g: cmap1.y * shade1, b: cmap1.z * shade1))
                    surfTris.append(SurfTri(v: (vert(p10), vert(p11), vert(p01)),
                                            r: cmap2.x * shade2, g: cmap2.y * shade2, b: cmap2.z * shade2))
                }
            }
        }

        // --- Fit: compute projected model-space bounds over everything visible ---
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
        // Fermi corners (only when inside the displayed domain).
        if drawFermi, let Ef = surface.fermiEnergy {
            let zf = zEnergy(Ef)
            for (si, ti) in [(0,0),(1,0),(0,1),(1,1)] {
                let gx = Float(si) * Lsafe + Float(ti) * c
                let gy = Float(ti) * h
                include(SIMD3<Float>(gx - GC.x, gy - GC.y, zf))
            }
        }

        for tri in surfTris {
            for v in [tri.v.0, tri.v.1, tri.v.2] {
                minSX = min(minSX, v.sx); maxSX = max(maxSX, v.sx)
                minSY = min(minSY, v.sy); maxSY = max(maxSY, v.sy)
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
        guard scale.isFinite, scale > 0, cx.isFinite, cy.isFinite else {
            drawEmpty(dirtyRect, "Band surface projection is invalid")
            return
        }

        // Model-space projection -> view coordinates. Larger screen y is nearer the
        // bottom of the (flipped) view.
        func toScreen(_ p: ProjVert) -> NSPoint {
            NSPoint(x: cx + CGFloat(p.sx) * scale,
                    y: cy - CGFloat(p.sy) * scale)
        }
        let baseCorners3D = [
            SIMD3<Float>(0 - GC.x, 0 - GC.y, zBase),
            SIMD3<Float>(Lsafe - GC.x, 0 - GC.y, zBase),
            SIMD3<Float>(Lsafe + c - GC.x, h - GC.y, zBase),
            SIMD3<Float>(c - GC.x, h - GC.y, zBase)
        ]

        // --- Raster pipeline: z-buffer into a pixel buffer sized to the plot rect ---
        let W = max(1, Int(plot.width.rounded(.up)))
        let H = max(1, Int(plot.height.rounded(.up)))
        let pix = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H * 4)
        defer { pix.deallocate() }
        let zbuf = UnsafeMutablePointer<Float>.allocate(capacity: W * H)
        defer { zbuf.deallocate() }

        // The raster buffer starts fully transparent. The view background was
        // painted above, so transparent pixels composite over the correct
        // backdrop when the buffer image is blitted below.
        memset(pix, 0, W * H * 4)
        zbuf.initialize(repeating: -Float.greatestFiniteMagnitude, count: W * H)

        // Map a view-coordinate point to clamped buffer indices. The plot rect sits
        // inside the view; we offset by the plot origin so buffer (0,0) = plot's
        // bottom-left (which, in the flipped view, is the lower-left corner).
        let originX = plot.minX, originY = plot.minY
        func bufXY(_ p: NSPoint) -> (Int, Int) {
            (min(W - 1, max(0, Int((p.x - originX).rounded()))),
             min(H - 1, max(0, Int((p.y - originY).rounded()))))
        }
        func idx(_ x: Int, _ y: Int) -> Int { y * W + x }

        // Write a pixel with depth testing. `depth` larger = nearer. When the test
        // passes, blend the source over the existing pixel and, optionally, update
        // the depth buffer. Source colors arrive STRAIGHT (non-premultiplied):
        // translucent lines pass e.g. (1,0,0,0.6), so RGB is premultiplied by
        // alpha here — the blend equation and the final premultipliedLast CGImage
        // both require premultiplied values, otherwise transparent pixels carry
        // invalid (too-bright) RGB.
        func writePx(_ x: Int, _ y: Int, _ sr: Float, _ sg: Float, _ sb: Float, _ sa: Float,
                     _ depth: Float, _ writeDepth: Bool) {
            let i = idx(x, y)
            guard depth > zbuf[i] else { return }
            let o = i * 4
            let dr = Float(pix[o]) / 255, dg = Float(pix[o + 1]) / 255
            let db = Float(pix[o + 2]) / 255, da = Float(pix[o + 3]) / 255
            let pr = sr * sa, pg = sg * sa, pb = sb * sa   // premultiply source
            let oa = sa + da * (1 - sa)
            let or = pr + dr * (1 - sa)
            let og = pg + dg * (1 - sa)
            let ob = pb + db * (1 - sa)
            pix[o] = UInt8(min(255, (or * 255).rounded()))
            pix[o + 1] = UInt8(min(255, (og * 255).rounded()))
            pix[o + 2] = UInt8(min(255, (ob * 255).rounded()))
            pix[o + 3] = UInt8(min(255, (oa * 255).rounded()))
            if writeDepth { zbuf[i] = depth }
        }

        // Viewer-direction depth bias applied to interpolated depth before the test.
        // Axes are coplanar with the base plane; line-vs-triangle interpolation
        // rounding makes strict `>` ties a coin-flip, so the axes vanish/dither. A
        // tiny bias (~1e-3 vs O(0.1–2) model-space depth) deterministically wins
        // coplanar ties while surfaces far in front still occlude (their margin dwarfs
        // the bias). Surfaces genuinely in front still write their larger depth and
        // occlude, because depth write stays enabled.
        let axisDepthBias: Float = 1e-3

        // Rasterize a flat-shaded screen-space line with per-pixel depth (linearly
        // interpolated between endpoints). `depthBias` nudges coplanar lines in front
        // of coincident geometry.
        func rasterLine(_ a: NSPoint, _ b: NSPoint, _ da: Float, _ db: Float,
                        _ sr: Float, _ sg: Float, _ sb: Float, _ sa: Float, _ writeDepth: Bool,
                        _ depthBias: Float = 0) {
            let steps = max(1, Int(max(abs(b.x - a.x), abs(b.y - a.y)).rounded()))
            for k in 0...steps {
                let t = Float(k) / Float(steps)
                let p = NSPoint(x: a.x + (b.x - a.x) * CGFloat(t), y: a.y + (b.y - a.y) * CGFloat(t))
                let d = da + (db - da) * t + depthBias
                let (x, y) = bufXY(p)
                writePx(x, y, sr, sg, sb, sa, d, writeDepth)
            }
        }

        // Convert a model-space projected vertex into its screen point + depth pair.
        func projToScreen(_ pr: ProjVert) -> (NSPoint, Float) {
            (toScreen(pr), pr.depth)
        }

        // 1. Base plane (floor): translucent gray quad, drawn with CoreGraphics
        //    BEHIND the raster buffer (which starts transparent). It never
        //    writes depth and nothing lies behind the floor, so drawing it
        //    first is equivalent to the old per-pixel rasterization, but a
        //    path fill is GPU-backed and much faster. A band exactly at
        //    energyMin is rasterized into the buffer above the fill, so it
        //    wins the coplanar tie exactly as before.
        let b0 = projToScreen(vert(baseCorners3D[0]))
        let b1 = projToScreen(vert(baseCorners3D[1]))
        let b2 = projToScreen(vert(baseCorners3D[2]))
        let b3 = projToScreen(vert(baseCorners3D[3]))
        func finitePoint(_ p: NSPoint) -> Bool { p.x.isFinite && p.y.isFinite }
        guard finitePoint(b0.0), finitePoint(b1.0), finitePoint(b2.0), finitePoint(b3.0),
              b0.1.isFinite, b1.1.isFinite, b2.1.isFinite, b3.1.isFinite else {
            drawEmpty(dirtyRect, "Band surface projection is invalid")
            return
        }

        // 2. Surface triangles (opaque, depth write). Project them once and
        //    hand the flat-shaded triangles to the C rasterizer: a tight
        //    native loop is several times faster than a Swift per-pixel
        //    barycentric walk during mouse rotation. Validate every projected
        //    coordinate before writing anything, so malformed geometry can
        //    never reach NSBezierPath/the C rasterizer.
        var triXYZ: [Float] = []
        triXYZ.reserveCapacity(surfTris.count * 9)
        var triRGB: [UInt8] = []
        triRGB.reserveCapacity(surfTris.count * 3)
        for tri in surfTris {
            let a = projToScreen(tri.v.0), b = projToScreen(tri.v.1), c = projToScreen(tri.v.2)
            guard finitePoint(a.0), finitePoint(b.0), finitePoint(c.0),
                  a.1.isFinite, b.1.isFinite, c.1.isFinite else {
                drawEmpty(dirtyRect, "Band surface geometry is invalid")
                return
            }
            triXYZ.append(contentsOf: [Float(a.0.x - originX), Float(a.0.y - originY), a.1,
                                       Float(b.0.x - originX), Float(b.0.y - originY), b.1,
                                       Float(c.0.x - originX), Float(c.0.y - originY), c.1])
            triRGB.append(contentsOf: [UInt8(min(255, max(0, (tri.r * 255).rounded()))),
                                       UInt8(min(255, max(0, (tri.g * 255).rounded()))),
                                       UInt8(min(255, max(0, (tri.b * 255).rounded())))])
        }

        // 1. Base plane (floor): translucent gray quad, drawn with CoreGraphics
        //    BEHIND the raster buffer (which starts transparent). It never
        //    writes depth and nothing lies behind the floor, so drawing it
        //    first is equivalent to the old per-pixel rasterization, but a
        //    path fill is GPU-backed and much faster. A band exactly at
        //    energyMin is rasterized into the buffer above the fill, so it
        //    wins the coplanar tie exactly as before.
        NSColor(calibratedWhite: 0.9, alpha: 0.25).setFill()
        let basePath = NSBezierPath()
        basePath.move(to: b0.0)
        basePath.line(to: b1.0)
        basePath.line(to: b2.0)
        basePath.line(to: b3.0)
        basePath.close()
        basePath.fill()

        if surfTris.isEmpty == false {
            triXYZ.withUnsafeBufferPointer { xyz in
                triRGB.withUnsafeBufferPointer { rgb in
                    band_surface_raster_triangles_opaque(pix, zbuf, Int32(W), Int32(H),
                                                         xyz.baseAddress, rgb.baseAddress,
                                                         Int32(surfTris.count))
                }
            }
        }

        // 3. 3D axes (depth-tested lines from the origin along k₁, k₂ and E). Coplanar
        //    with the base plane, so they use the viewer-depth bias to avoid z-fighting.
        let axisOriginP = projToScreen(vert(SIMD3<Float>(0 - GC.x, 0 - GC.y, zBase)))
        let axisK1EndP = projToScreen(vert(SIMD3<Float>(Lsafe - GC.x, 0 - GC.y, zBase)))
        let axisK2EndP = projToScreen(vert(SIMD3<Float>(c - GC.x, h - GC.y, zBase)))
        let axisETopP = projToScreen(vert(SIMD3<Float>(0 - GC.x, 0 - GC.y, zTop)))
        for (p, q, dd) in [(axisOriginP, axisK1EndP, axisK1EndP.1),
                            (axisOriginP, axisK2EndP, axisK2EndP.1),
                            (axisOriginP, axisETopP, axisETopP.1)] {
            rasterLine(p.0, q.0, p.1, dd, 0, 0, 0, 1, true, axisDepthBias)
        }

        // 3b. Base parallelogram outline (restores the stroked outline the legacy
        //     renderer drew). Depth-biased so it sits just in front of the fill; no
        //     depth write since nothing meaningful lies behind the floor.
        let baseOutline: Float = 0.6
        rasterLine(b0.0, b1.0, b0.1, b1.1, baseOutline, baseOutline, baseOutline, 0.6, false, axisDepthBias)
        rasterLine(b1.0, b2.0, b1.1, b2.1, baseOutline, baseOutline, baseOutline, 0.6, false, axisDepthBias)
        rasterLine(b2.0, b3.0, b2.1, b3.1, baseOutline, baseOutline, baseOutline, 0.6, false, axisDepthBias)
        rasterLine(b3.0, b0.0, b3.1, b0.1, baseOutline, baseOutline, baseOutline, 0.6, false, axisDepthBias)

        // 4. Fermi plane (only inside the displayed domain): translucent red quad
        //    + outline, depth-tested but NO depth write (never overpaints
        //    surfaces). One primitive => no shared-diagonal double blend.
        if drawFermi, let Ef = surface.fermiEnergy {
            let zf = zEnergy(Ef)
            let f3D = [(0,0),(1,0),(1,1),(0,1)].map { (si: Int, ti: Int) -> ProjVert in
                let gx = Float(si) * Lsafe + Float(ti) * c
                let gy = Float(ti) * h
                return vert(SIMD3<Float>(gx - GC.x, gy - GC.y, zf))
            }
            let f = f3D.map { projToScreen($0) }
            let fermiXYZ: [Float] = [
                Float(f[0].0.x - originX), Float(f[0].0.y - originY), f[0].1,
                Float(f[1].0.x - originX), Float(f[1].0.y - originY), f[1].1,
                Float(f[2].0.x - originX), Float(f[2].0.y - originY), f[2].1,
                Float(f[3].0.x - originX), Float(f[3].0.y - originY), f[3].1
            ]
            fermiXYZ.withUnsafeBufferPointer { xyz in
                band_surface_raster_quad_blended(pix, zbuf, Int32(W), Int32(H),
                                                 xyz.baseAddress, 1, 0, 0, 0.15, 0)
            }
            for (p, q) in [(f[0], f[1]), (f[1], f[2]), (f[2], f[3]), (f[3], f[0])] {
                rasterLine(p.0, q.0, p.1, q.1, 1, 0, 0, 0.6, false)
            }
        }

        // Blit the pixel buffer into the current context as a CGImage. The buffer is
        // top-down (row 0 = smallest view y); the view is flipped, so we draw it
        // upright at the plot origin.
        let ctx = NSGraphicsContext.current!.cgContext
        if let cspace = CGColorSpace(name: CGColorSpace.sRGB),
           let provider = CGDataProvider(data: Data(bytesNoCopy: pix, count: W * H * 4,
                                                    deallocator: .none) as CFData),
           let image = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: W * 4, space: cspace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) {
            ctx.saveGState()
            ctx.translateBy(x: plot.minX, y: plot.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -CGFloat(H))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.restoreGState()
        }

        // --- Annotations drawn on top of the rasterized image ---
        let axisK1End = axisK1EndP.0
        let axisK2End = axisK2EndP.0
        let axisETop = axisETopP.0

        // High-symmetry / reciprocal-vector labels at the four parallelogram
        // corners: p0, p0+b1, p0+b1+b2, p0+b2 in that order (the rasterized
        // base corners follow the same order). Labels may be empty for
        // computed corners. Drawn AFTER the raster blit so the surface fill
        // cannot paint over them.
        for (corner, label) in zip([b0, b1, b2, b3], surface.regionLabels) where !label.isEmpty {
            drawLabel(label, at: NSPoint(x: corner.0.x - 2, y: corner.0.y + 8),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }

        // Ticks: small screen-space crosses for the k axes and E axis.
        for s in [Float(0), 0.25, 0.5, 0.75, 1.0] {
            let lp = toScreen(vert(SIMD3<Float>(s * Lsafe - GC.x, -GC.y, zBase)))
            let (x, y) = (lp.x, lp.y)
            drawLabel(String(format: "%.2f", s * Lsafe), at: NSPoint(x: x - 4, y: y + 6),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }
        for t in [Float(0), 0.25, 0.5, 0.75, 1.0] {
            let lp = toScreen(vert(SIMD3<Float>(t * c - GC.x, t * h - GC.y, zBase)))
            let (x, y) = (lp.x, lp.y)
            drawLabel(String(format: "%.2f", t * Vlen), at: NSPoint(x: x - 4, y: y + 6),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }
        let eTickCount = 5
        for i in 0...eTickCount {
            let e = Float(energyLoD + energySpanD * Double(i) / Double(eTickCount))
            let lp = toScreen(vert(SIMD3<Float>(-GC.x, -GC.y, zEnergy(e))))
            let (x, y) = (lp.x, lp.y)
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x - 3, y: y)); tick.line(to: NSPoint(x: x + 3, y: y))
            tick.move(to: NSPoint(x: x, y: y - 3)); tick.line(to: NSPoint(x: x, y: y + 3))
            tick.lineWidth = 1; tick.stroke()
            drawLabel(String(format: "%.1f", e), at: NSPoint(x: x - 8, y: y),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }

        // Axis name labels (k₁ / k₂ — not Cartesian k_x / k_y).
        drawLabel("k₁ (\(unitLabel))", at: NSPoint(x: axisK1End.x + 6, y: axisK1End.y + 6),
                  font: titleFont, color: .black, rightAligned: false)
        drawLabel("k₂ (\(unitLabel))", at: NSPoint(x: axisK2End.x + 6, y: axisK2End.y + 6),
                  font: titleFont, color: .black, rightAligned: false)
        drawLabel("E (eV)", at: NSPoint(x: axisETop.x - 6, y: axisETop.y - 4),
                  font: titleFont, color: .black, rightAligned: false)

        // Colorbar: the viridis energy scale used by the surface sheets, drawn as
        // a compact overlay in the top-right corner of the plot. Overlay placement
        // preserves the plot geometry (and its calibrated axis pixel counts) while
        // still giving the energy scale a key.
        let barWidth: CGFloat = 14
        let barHeight: CGFloat = 64
        let barX = plot.maxX - barWidth - 6
        let barBottom = plot.maxY - barHeight - 4
        let barSteps = 64
        for step in 0..<barSteps {
            let t = Float(step) / Float(barSteps - 1)
            let rgb = Colormap.viridis.rgb(t)
            NSColor(calibratedRed: CGFloat(rgb.x), green: CGFloat(rgb.y),
                    blue: CGFloat(rgb.z), alpha: 1).setFill()
            let y = barBottom + CGFloat(step) * barHeight / CGFloat(barSteps - 1)
            let h = barHeight / CGFloat(barSteps - 1) + 1
            NSBezierPath(rect: NSRect(x: barX, y: y, width: barWidth, height: h)).fill()
        }
        NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
        let barOutline = NSBezierPath(rect: NSRect(x: barX, y: barBottom, width: barWidth, height: barHeight))
        barOutline.lineWidth = 1
        barOutline.stroke()
        for i in 0...4 {
            let t = Float(i) / 4
            let e = energyMin + (energyMax - energyMin) * t
            let y = barBottom + CGFloat(t) * barHeight
            NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: barX + barWidth, y: y))
            tick.line(to: NSPoint(x: barX + barWidth + 4, y: y))
            tick.lineWidth = 1
            tick.stroke()
            drawLabel(String(format: "%.1f", e), at: NSPoint(x: barX + barWidth + 10, y: y),
                      font: axisFont, color: .darkGray, rightAligned: false)
        }
        drawLabel("E (eV)", at: NSPoint(x: barX + barWidth + 8, y: barBottom - 10),
                  font: axisFont, color: .darkGray, rightAligned: false)

        // Fermi-level tick on the colorbar when it is inside the domain.
        if drawFermi, let Ef = surface.fermiEnergy {
            let t = (Ef - energyMin) / energyRange
            let y = barBottom + CGFloat(t) * barHeight
            NSColor(calibratedRed: 0.7, green: 0, blue: 0, alpha: 1).setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: barX - 6, y: y))
            tick.line(to: NSPoint(x: barX + barWidth + 6, y: y))
            tick.lineWidth = 1
            tick.stroke()
        }

        // Band legend: one swatch per displayed sheet, colored by that sheet's
        // mid-range energy (the same viridis map the surface uses), listed in
        // the top-left corner under the title.
        if !surface.sheets.isEmpty {
            var legendY = marginTop + 30
            drawLabel("Bands", at: NSPoint(x: marginLeft, y: marginTop + 18),
                      font: axisFont, color: .darkGray, rightAligned: false)
            for sheet in surface.sheets.prefix(12) {
                let mn = sheet.values.min() ?? 0
                let mx = sheet.values.max() ?? 0
                let mid = (mn + mx) / 2
                let t = min(1, max(0, (mid - energyMin) / energyRange))
                let rgb = Colormap.viridis.rgb(t)
                NSColor(calibratedRed: CGFloat(rgb.x), green: CGFloat(rgb.y),
                        blue: CGFloat(rgb.z), alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: marginLeft, y: legendY - 9, width: 12, height: 12)).fill()
                drawLabel(sheet.label, at: NSPoint(x: marginLeft + 18, y: legendY - 3),
                          font: axisFont, color: .darkGray, rightAligned: false)
                legendY += 14
            }
            if surface.sheets.count > 12 {
                drawLabel("…", at: NSPoint(x: marginLeft + 18, y: legendY - 3),
                          font: axisFont, color: .darkGray, rightAligned: false)
            }
        }

        // Title.
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

    /// The expected number of values per sheet (gridSize^2), or 0 when the surface
    /// is too malformed to interpret (used to reject out-of-bounds indexing). Capped
    /// at 256 samples per side (matching the decoder) so an absurd gridSize cannot
    /// overflow Int before the triCount guard runs.
    private func surfaceGridArea(_ surface: BandSurface?) -> Int {
        guard let surface, surface.gridSize >= 2, surface.gridSize <= 256 else { return 0 }
        return surface.gridSize * surface.gridSize
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
