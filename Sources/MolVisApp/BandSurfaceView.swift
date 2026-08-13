import AppKit
import simd

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
        let baseCorners = baseCorners3D.map { toScreen(vert($0)) }

        // --- Raster pipeline: z-buffer into a pixel buffer sized to the plot rect ---
        let W = max(1, Int(plot.width.rounded(.up)))
        let H = max(1, Int(plot.height.rounded(.up)))
        let pix = UnsafeMutablePointer<UInt8>.allocate(capacity: W * H * 4)
        defer { pix.deallocate() }
        let zbuf = UnsafeMutablePointer<Float>.allocate(capacity: W * H)
        defer { zbuf.deallocate() }

        // Background color (premultiplied RGBA in 0...1).
        let bgR: Float, bgG: Float, bgB: Float, bgA: Float
        if let bg = exportBackground {
            let rgb = bg.usingColorSpace(.deviceRGB) ?? bg
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
            bgA = Float(a); bgR = Float(r) * bgA; bgG = Float(g) * bgA; bgB = Float(b) * bgA
        } else if !isExportTransparent {
            bgA = 1; bgR = 1; bgG = 1; bgB = 1
        } else {
            bgA = 0; bgR = 0; bgG = 0; bgB = 0
        }
        for i in 0..<(W * H) {
            let o = i * 4
            pix[o] = UInt8((bgR * 255).rounded()); pix[o + 1] = UInt8((bgG * 255).rounded())
            pix[o + 2] = UInt8((bgB * 255).rounded()); pix[o + 3] = UInt8((bgA * 255).rounded())
            zbuf[i] = -Float.greatestFiniteMagnitude
        }

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
        // translucent primitives (base plane, Fermi plane) pass e.g. (1,0,0,0.15),
        // so RGB is premultiplied by alpha here — the blend equation and the final
        // premultipliedLast CGImage both require premultiplied values, otherwise
        // transparent pixels carry invalid (too-bright) RGB.
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

        // Barycentric rasterization of a flat-shaded triangle with linearly
        // interpolated depth. The buffer is plot-local: vertices arrive in
        // absolute view coordinates (as toScreen produces), so they are first
        // offset by the plot origin — matching rasterLine/bufXY — otherwise the
        // fill would be shifted and clipped relative to axes and outlines.
        func rasterTri(_ a: NSPoint, _ da: Float, _ b: NSPoint, _ db: Float,
                       _ c: NSPoint, _ dc: Float, _ sr: Float, _ sg: Float, _ sb: Float,
                       _ sa: Float, _ writeDepth: Bool) {
            let ax = a.x - originX, ay = a.y - originY
            let bx = b.x - originX, by = b.y - originY
            let cx = c.x - originX, cy = c.y - originY
            let minX = max(0, Int(min(ax, bx, cx).rounded(.down)))
            let maxX = min(W - 1, Int(max(ax, bx, cx).rounded(.up)))
            let minY = max(0, Int(min(ay, by, cy).rounded(.down)))
            let maxY = min(H - 1, Int(max(ay, by, cy).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { return }
            let v0x = bx - ax, v0y = by - ay
            let v1x = cx - ax, v1y = cy - ay
            let d00 = v0x * v0x + v0y * v0y
            let d01 = v0x * v1x + v0y * v1y
            let d11 = v1x * v1x + v1y * v1y
            let denom = d00 * d11 - d01 * d01
            guard denom != 0 else { return }
            let invDenom = 1 / denom
            for y in minY...maxY {
                for x in minX...maxX {
                    let v2x = CGFloat(x) - ax, v2y = CGFloat(y) - ay
                    let d20 = v2x * v0x + v2y * v0y
                    let d21 = v2x * v1x + v2y * v1y
                    let vv = (d11 * d20 - d01 * d21) * invDenom
                    let ww = (d00 * d21 - d01 * d20) * invDenom
                    let uu = 1 - vv - ww
                    if uu < 0 || vv < 0 || ww < 0 { continue }
                    let depth = Float(uu) * da + Float(vv) * db + Float(ww) * dc
                    writePx(x, y, sr, sg, sb, sa, depth, writeDepth)
                }
            }
        }

        // Convert a model-space projected vertex into its screen point + depth pair.
        func projToScreen(_ pr: ProjVert) -> (NSPoint, Float) {
            (toScreen(pr), pr.depth)
        }

        // Rasterize a convex quadrilateral (parallelogram in screen space — the
        // affine image of the model-space patch under orthographic projection)
        // with bilinear depth. Rasterizing the quad as ONE primitive avoids the
        // shared-diagonal double-blend of a two-triangle split: translucent
        // planes (base, Fermi) would otherwise show a darker seam along the
        // diagonal. Depth is bilinear over the parallelogram, which is exact for
        // the affine screen mapping of a flat plane.
        func rasterQuad(_ p0: NSPoint, _ d0: Float, _ p1: NSPoint, _ d1: Float,
                        _ p2: NSPoint, _ d2: Float, _ p3: NSPoint, _ d3: Float,
                        _ sr: Float, _ sg: Float, _ sb: Float, _ sa: Float,
                        _ writeDepth: Bool) {
            // Corners in parameter order (0,0), (1,0), (1,1), (0,1):
            // p1 = p0 + U, p3 = p0 + V.
            let x0 = p0.x - originX, y0 = p0.y - originY
            let x1 = p1.x - originX, y1 = p1.y - originY
            let x2 = p2.x - originX, y2 = p2.y - originY
            let x3 = p3.x - originX, y3 = p3.y - originY
            let ux = x1 - x0, uy = y1 - y0
            let vx = x3 - x0, vy = y3 - y0
            let denom = ux * vy - uy * vx
            guard abs(denom) > 1e-6 else { return }   // edge-on: nothing to fill
            let minX = max(0, Int(min(x0, x1, x2, x3).rounded(.down)))
            let maxX = min(W - 1, Int(max(x0, x1, x2, x3).rounded(.up)))
            let minY = max(0, Int(min(y0, y1, y2, y3).rounded(.down)))
            let maxY = min(H - 1, Int(max(y0, y1, y2, y3).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { return }
            let invDenom = 1 / denom
            for y in minY...maxY {
                for x in minX...maxX {
                    let qx = CGFloat(x) - x0, qy = CGFloat(y) - y0
                    let s = (qx * vy - qy * vx) * invDenom
                    let t = (ux * qy - uy * qx) * invDenom
                    guard s >= 0, t >= 0, s <= 1, t <= 1 else { continue }
                    let w00 = Float((1 - s) * (1 - t))
                    let w10 = Float(s * (1 - t))
                    let w11 = Float(s * t)
                    let w01 = Float((1 - s) * t)
                    let depth = w00 * d0 + w10 * d1 + w11 * d2 + w01 * d3
                    writePx(x, y, sr, sg, sb, sa, depth, writeDepth)
                }
            }
        }

        // 1. Base plane (floor): translucent gray quad, NO depth write. A band
        //    fragment exactly at energyMin is coplanar with the floor; the
        //    strict `>` depth test would hide it. Nothing lies behind the floor,
        //    so it never needs to occlude anything.
        let b0 = projToScreen(vert(baseCorners3D[0]))
        let b1 = projToScreen(vert(baseCorners3D[1]))
        let b2 = projToScreen(vert(baseCorners3D[2]))
        let b3 = projToScreen(vert(baseCorners3D[3]))
        rasterQuad(b0.0, b0.1, b1.0, b1.1, b2.0, b2.1, b3.0, b3.1, 0.9, 0.9, 0.9, 0.25, false)

        // 2. Surface triangles (opaque, depth write).
        for tri in surfTris {
            let a = projToScreen(tri.v.0), b = projToScreen(tri.v.1), c = projToScreen(tri.v.2)
            rasterTri(a.0, a.1, b.0, b.1, c.0, c.1, tri.r, tri.g, tri.b, 1, true)
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
            rasterQuad(f[0].0, f[0].1, f[1].0, f[1].1, f[2].0, f[2].1, f[3].0, f[3].1,
                       1, 0, 0, 0.15, false)
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
            let e = energyMin + (energyMax - energyMin) * Float(i) / Float(eTickCount)
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
