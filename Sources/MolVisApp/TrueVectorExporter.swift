import AppKit
import Metal
import MetalKit
import simd

/// True-vector export (PDF / SVG) mirroring `RasterExporter`'s shape.
///
/// PDF and SVG render the scene once to a high-resolution offscreen raster via
/// the shared `Renderer.encode(to:target:viewport:camera:)` path (the raster
/// structure layer), then OVERLAY real vector primitives projected with the
/// same camera:
///   - cell frame edges (grey box per supercell replica),
///   - Cartesian axes (the orientation-gizmo triad, pinned to the corner),
///   - Brillouin-zone wireframe (purple face outlines),
///   - k-path route (amber polyline, honoring breaks),
///   - displacement arrows (magenta) when requested,
///   - labels (element symbols, route nodes, scale indicator) as true text.
///
/// EPS / PS are not handled here: they stay raster-backed via `RasterExporter`.
enum TrueVectorExportError: Error {
    case noGPU, noTex, noCGImage, noContext, noData, unsupported,
         noQueue, noCommandBuffer, encodeFailed, commandBufferError(Error?)
}

/// Thrown when an export size is non-finite, non-positive, exceeds the per-axis
/// cap, or overflows the total-pixel ceiling. Mirrors RasterExporter's
/// validation so absurd sizes throw instead of trapping on the Int cast.
enum TrueVectorExporter {
    static let maxAxisDimension: CGFloat = 16_384

    // Colors matching the Metal renderer's draw paths exactly.
    private static let cellFrameColor = SIMD3<Float>(0.75, 0.75, 0.75)
    private static let bzColor = SIMD3<Float>(0.85, 0.30, 0.95)
    private static let kPathColor = SIMD3<Float>(1.0, 0.55, 0.1)
    private static let displacementArrowColor = SIMD3<Float>(1.0, 0.2, 0.9)

    /// The 12 edges of a parallelepiped in terms of its 8 corner indices:
    /// corners = [o, a, a+b, b, c, a+c, b+c, a+b+c].
    private static let cellEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0), // bottom face
        (4, 5), (5, 7), (7, 6), (6, 4), // top face
        (0, 4), (1, 5), (2, 7), (3, 6), // verticals
    ]

    /// Render the scene to a vector container (PDF / SVG) at `size`. Returns the
    /// CGImage raster that was wrapped + overlaid, so a caller can validate
    /// pixel content across formats.
    @discardableResult
    static func export(scene: Scene, camera: Camera?, to url: URL, size: CGSize,
                       options: RenderExportOptions = RenderExportOptions(),
                       background: (r: Double, g: Double, b: Double, a: Double)? = nil) throws -> CGImage {
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || ext == "svg" else { throw TrueVectorExportError.unsupported }

        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= CGFloat(maxAxisDimension), rh <= CGFloat(maxAxisDimension),
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw TrueVectorExportError.noTex
        }
        let w = Int(rw), h = Int(rh)
        let total = w.multipliedReportingOverflow(by: h)
        guard !total.overflow, total.partialValue <= 16_000_000 else { throw TrueVectorExportError.noTex }

        let cg = try render(scene: scene, camera: camera, w: w, h: h, options: options, background: background)
        try write(cgImage: cg, scene: scene, camera: camera, options: options,
                  to: url, size: CGSize(width: w, height: h))
        return cg
    }

    // MARK: Metal → CGImage (shared raster render, mirrors RasterExporter)

    private static func render(scene: Scene, camera: Camera?, w: Int, h: Int,
                               options: RenderExportOptions,
                               background: (r: Double, g: Double, b: Double, a: Double)? = nil) throws -> CGImage {
        guard w > 0, h > 0 else { throw TrueVectorExportError.noTex }
        guard let device = MTLCreateSystemDefaultDevice() else { throw TrueVectorExportError.noGPU }
        let renderer = try Renderer(device: device)
        renderer.scene = scene
        renderer.showBZLandmarks = options.showBZLandmarks
        renderer.coordinationNumbers = options.coordinationNumbers
        renderer.showCoordinationColors = options.showCoordinationColors
        renderer.selectedKPathNode = options.selectedKPathNode
        renderer.msaaSampleCount = options.msaaSampleCount ?? scene.msaaSampleCount
        renderer.displacementArrows = options.displacementArrows
        renderer.showDisplacementArrows = options.showDisplacementArrows
        if let bg = background {
            renderer.clearColorOverride = MTLClearColorMake(bg.r, bg.g, bg.b, bg.a)
        }
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw TrueVectorExportError.noTex }
        guard let q = device.makeCommandQueue() else { throw TrueVectorExportError.noQueue }
        guard let cb = q.makeCommandBuffer() else { throw TrueVectorExportError.noCommandBuffer }
        renderer.background = PngExporter.clearColor(scene.background)
        var cam = camera ?? scene.defaultCamera()
        if cam.rotation == simd_quatf(ix: 0, iy: 0, iz: 0, r: 0) {
            cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        guard renderer.encode(to: cb, target: tex, viewport: viewport, camera: cam) else {
            cb.commit(); cb.waitUntilCompleted()
            throw TrueVectorExportError.encodeFailed
        }
        cb.commit(); cb.waitUntilCompleted()
        if let error = cb.error { throw TrueVectorExportError.commandBufferError(error) }
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        tex.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw TrueVectorExportError.noCGImage
        }
        guard let image = ctx.makeImage() else { throw TrueVectorExportError.noCGImage }
        return try PngExporter.composite(labels: options.labels, onto: image)
    }

    // MARK: Dispatch

    private static func write(cgImage: CGImage, scene: Scene, camera: Camera?,
                              options: RenderExportOptions, to url: URL, size: CGSize) throws {
        let ext = url.pathExtension.lowercased()
        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= maxAxisDimension, rh <= maxAxisDimension,
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw TrueVectorExportError.noTex
        }
        let w = Int(rw), h = Int(rh)
        let pixels = w.multipliedReportingOverflow(by: h)
        guard !pixels.overflow, pixels.partialValue <= 16_000_000,
              w == cgImage.width, h == cgImage.height else {
            throw TrueVectorExportError.noTex
        }
        switch ext {
        case "pdf":
            try emitPDF(cgImage: cgImage, scene: scene, camera: camera, options: options, w: w, h: h, to: url)
        case "svg":
            try emitSVG(cgImage: cgImage, scene: scene, camera: camera, options: options, w: w, h: h, to: url)
        default:
            throw TrueVectorExportError.unsupported
        }
    }

    // MARK: Projection

    /// Project a world-space point to screen pixels (top-left origin, y-down)
    /// using the same view/proj/viewport convention as `Renderer.encode`.
    private static func project(_ world: SIMD3<Float>, view: float4x4, proj: float4x4,
                                w: Float, h: Float) -> SIMD2<Float>? {
        let clip = proj * view * SIMD4<Float>(world, 1)
        guard clip.w > 1e-6 else { return nil }
        let ndc = clip.xyz / clip.w
        guard ndc.x.isFinite, ndc.y.isFinite, ndc.z.isFinite else { return nil }
        let sx = (ndc.x * 0.5 + 0.5) * w
        // Metal's viewport y is flipped: NDC +y (up) maps to the top of the target.
        let sy = (1 - (ndc.y * 0.5 + 0.5)) * h
        return SIMD2<Float>(sx, sy)
    }

    // MARK: PDF

    private static func emitPDF(cgImage: CGImage, scene: Scene, camera: Camera?,
                                options: RenderExportOptions, w: Int, h: Int, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: w, height: h)
        let data = NSMutableData()
        // Fixed metadata so two exports of the same scene are byte-identical
        // (no timestamps/UUIDs in the output).
        let info: [CFString: Any] = [
            kCGPDFContextCreator: "mcrysden",
        ]
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw TrueVectorExportError.noContext
        }
        ctx.beginPDFPage(nil)

        // Raster structure layer.
        ctx.draw(cgImage, in: mediaBox)

        // Resolve the camera the same way render() does so projection matches.
        var cam = camera ?? scene.defaultCamera()
        if cam.rotation == simd_quatf(ix: 0, iy: 0, iz: 0, r: 0) {
            cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let aspect = h > 0 ? Float(w) / Float(h) : 1.0
        let view = cam.viewMatrix()
        let proj = cam.projectionMatrix(aspect: aspect)
        let wF = Float(w), hF = Float(h)

        // Vector overlays (y-flip: PDF y is bottom-up, our screen y is top-down).
        ctx.saveGState()
        drawVectorOverlays(ctx: ctx, scene: scene, cam: cam, view: view, proj: proj, w: wF, h: hF, options: options)
        ctx.restoreGState()

        // Labels as true vector text via the existing LabelOverlayView.
        drawPDFLabels(ctx: ctx, options: options, w: w, h: h)

        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    /// Draw cell frame, axes, BZ, k-path, displacement arrows into a PDF context.
    /// `ctx` uses bottom-up y; `project` returns top-down y — flip when drawing.
    private static func drawVectorOverlays(ctx: CGContext, scene: Scene, cam: Camera,
                                           view: float4x4, proj: float4x4,
                                           w: Float, h: Float,
                                           options: RenderExportOptions) {
        let lw = CGFloat(max(1.0, scene.lineWidth))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Cell frame.
        if scene.showCellFrame, let cell = scene.cell {
            drawCellFrame(ctx: ctx, scene: scene, cell: cell, view: view, proj: proj, w: w, h: h, lw: lw)
        }

        // Cartesian axes (orientation-gizmo triad, pinned to the corner).
        if scene.showAxes {
            drawAxesOverlay(ctx: ctx, cam: cam, w: w, h: h, lw: lw)
        }

        // Brillouin-zone wireframe.
        if scene.showBrillouinZone, let cell = scene.cell {
            if let bz = BrillouinZone.build(cell: cell, atoms: scene.baseAtoms) {
                let pres = BZPresentation(bz: bz, scene: scene)
                if pres.inv.isFinite, pres.inv > 0,
                   pres.displayedHalfExtent.isFinite, pres.displayedHalfExtent > 1e-5 {
                    ctx.saveGState()
                    ctx.setStrokeColor(red: 0.85, green: 0.30, blue: 0.95, alpha: 1)
                    ctx.setLineWidth(lw)
                    var path = CGMutablePath()
                    for face in bz.faces {
                        let mapped = face.map { pres.world(cartesian: $0) }
                        var first = true
                        for vert in mapped {
                            guard let p = project(vert, view: view, proj: proj, w: w, h: h) else { continue }
                            if first {
                                path.move(to: CGPoint(x: CGFloat(p.x), y: CGFloat(h - p.y)))
                                first = false
                            } else {
                                path.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(h - p.y)))
                            }
                        }
                        if !first { path.closeSubpath() }
                    }
                    ctx.addPath(path)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }

        // k-path route.
        if !scene.kPathPoints.isEmpty, let cell = scene.cell {
            if let bz = BrillouinZone.build(cell: cell, atoms: scene.baseAtoms) {
                let pres = BZPresentation(bz: bz, scene: scene)
                if pres.inv.isFinite, pres.inv > 0 {
                    let mapped = scene.kPathPoints.prefix(1024).map { pres.world(frac: $0.frac) }
                    let valid = mapped.map { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    let breaks = scene.kPathBreaks
                    ctx.saveGState()
                    ctx.setStrokeColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1)
                    ctx.setLineWidth(lw)
                    var path = CGMutablePath()
                    for i in 0..<mapped.count {
                        guard valid[i], let p = project(mapped[i], view: view, proj: proj, w: w, h: h) else { continue }
                        if i + 1 < mapped.count, valid[i + 1], !breaks.contains(i),
                           let next = project(mapped[i + 1], view: view, proj: proj, w: w, h: h) {
                            path.move(to: CGPoint(x: CGFloat(p.x), y: CGFloat(h - p.y)))
                            path.addLine(to: CGPoint(x: CGFloat(next.x), y: CGFloat(h - next.y)))
                        }
                    }
                    ctx.addPath(path)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }

        // Displacement arrows.
        if options.showDisplacementArrows, !options.displacementArrows.isEmpty {
            drawDisplacementArrows(ctx: ctx, arrows: options.displacementArrows, view: view, proj: proj, w: w, h: h, lw: lw)
        }
    }

    private static func drawCellFrame(ctx: CGContext, scene: Scene, cell: Cell,
                                      view: float4x4, proj: float4x4, w: Float, h: Float, lw: CGFloat) {
        let a = cell.a, b = cell.b, c = cell.c
        let n = max(1, scene.atoms.count)
        var centroid = SIMD3<Float>.zero
        for at in scene.atoms { centroid += at.coord }
        centroid /= Float(n)
        let sc = scene.superCell
        let base = centroid - (Float(sc.n1) * 0.5) * a
                          - (Float(sc.n2) * 0.5) * b
                          - (Float(sc.n3) * 0.5) * c
        if let replicas = cellBoxCount(sc), replicas <= Scene.superCellAtomCap {
            ctx.saveGState()
            ctx.setStrokeColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
            ctx.setLineWidth(lw)
            var path = CGMutablePath()
            for i in 0..<sc.n1 {
                for j in 0..<sc.n2 {
                    for k in 0..<sc.n3 {
                        let t = a * Float(i) + b * Float(j) + c * Float(k)
                        let o = base + t
                        let corners = [o, a + o, a + b + o, b + o, c + o, a + c + o, b + c + o, a + b + c + o]
                        for (ci, cj) in cellEdges {
                            guard let p0 = project(corners[ci], view: view, proj: proj, w: w, h: h),
                                  let p1 = project(corners[cj], view: view, proj: proj, w: w, h: h) else { continue }
                            path.move(to: CGPoint(x: CGFloat(p0.x), y: CGFloat(h - p0.y)))
                            path.addLine(to: CGPoint(x: CGFloat(p1.x), y: CGFloat(h - p1.y)))
                        }
                    }
                }
            }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Draw the orientation-gizmo triad (camera-relative x/y/z arrows) into the
    /// bottom-left corner sub-viewport, matching the renderer's
    /// `drawOrientationGizmo`. The renderer pins the gizmo to the bottom-left
    /// corner: sub-viewport x ∈ [margin, margin+gSize], y_img ∈ [h-gSize-margin,
    /// h-margin] in image space (y-down), so the center is at
    /// (margin + gSize/2, h - margin - gSize/2). The PDF context uses bottom-up
    /// y, so we flip: y_pdf = h - y_img.
    private static func drawAxesOverlay(ctx: CGContext, cam: Camera, w: Float, h: Float, lw: CGFloat) {
        let gSize = max(72.0, Double(min(w, h)) * 0.16)
        let margin = 14.0
        // Gizmo center in image space (y-down), pinned to the bottom-left corner.
        let centerX = margin + gSize / 2
        let centerYImg = Double(h) - margin - gSize / 2
        // PDF uses bottom-up y: flip the image-space y coordinate.
        let centerYPdf = Double(h) - centerYImg

        let worldToView = float4x4(cam.rotation).transpose
        let half: Float = 1.05
        let shaftLen: Float = 0.62
        struct Axis { let dir: SIMD3<Float>; let r: CGFloat; let g: CGFloat; let b: CGFloat }
        let axes = [
            Axis(dir: (worldToView * SIMD4<Float>(1, 0, 0, 0)).xyz, r: 1, g: 0.2, b: 0.2),
            Axis(dir: (worldToView * SIMD4<Float>(0, 1, 0, 0)).xyz, r: 0.2, g: 1, b: 0.2),
            Axis(dir: (worldToView * SIMD4<Float>(0, 0, 1, 0)).xyz, r: 0.2, g: 0.2, b: 1),
        ]
        ctx.saveGState()
        ctx.setLineWidth(lw * 2.0)
        ctx.setLineCap(.round)
        for axis in axes {
            let tipLocal = axis.dir * shaftLen
            let tipNDC = tipLocal / half
            // Tip offset in the gizmo's NDC space, converted to pixels within
            // the gSize×gSize sub-viewport. NDC +y is up in Metal, so the
            // image-space y offset is -tipNDC.y. After the y_pdf = h - y_img
            // flip the sign reverses: the PDF y offset is +tipNDC.y.
            let tipX = centerX + Double(tipNDC.x) * gSize / 2
            let tipYPdf = centerYPdf + Double(tipNDC.y) * gSize / 2
            ctx.setStrokeColor(red: axis.r, green: axis.g, blue: axis.b, alpha: 1)
            ctx.move(to: CGPoint(x: centerX, y: centerYPdf))
            ctx.addLine(to: CGPoint(x: tipX, y: tipYPdf))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawDisplacementArrows(ctx: CGContext, arrows: [(start: SIMD3<Float>, vector: SIMD3<Float>)],
                                                view: float4x4, proj: float4x4, w: Float, h: Float, lw: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(red: 1.0, green: 0.2, blue: 0.9, alpha: 1)
        ctx.setLineWidth(lw)
        let headFrac: Float = 0.18
        let headSpread: Float = 0.5
        var path = CGMutablePath()
        for arrow in arrows {
            let start = arrow.start
            let vector = arrow.vector
            guard start.isFinite, vector.isFinite else { continue }
            let length = simd_length(vector)
            guard length > 1e-6, length.isFinite else { continue }
            let tip = start + vector
            guard let pStart = project(start, view: view, proj: proj, w: w, h: h),
                  let pTip = project(tip, view: view, proj: proj, w: w, h: h) else { continue }
            path.move(to: CGPoint(x: CGFloat(pStart.x), y: CGFloat(h - pStart.y)))
            path.addLine(to: CGPoint(x: CGFloat(pTip.x), y: CGFloat(h - pTip.y)))
            let dir = vector / length
            let perp = makePerpendicular(dir)
            let side = length * headFrac
            let back = tip - dir * side
            let left = back + perp * side * headSpread
            let right = back - perp * side * headSpread
            if let pLeft = project(left, view: view, proj: proj, w: w, h: h) {
                path.move(to: CGPoint(x: CGFloat(pTip.x), y: CGFloat(h - pTip.y)))
                path.addLine(to: CGPoint(x: CGFloat(pLeft.x), y: CGFloat(h - pLeft.y)))
            }
            if let pRight = project(right, view: view, proj: proj, w: w, h: h) {
                path.move(to: CGPoint(x: CGFloat(pTip.x), y: CGFloat(h - pTip.y)))
                path.addLine(to: CGPoint(x: CGFloat(pRight.x), y: CGFloat(h - pRight.y)))
            }
        }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Draw labels as true vector text over the PDF context, using the existing
    /// `LabelOverlayView.draw` so text, chips, and the scale bar are real vector.
    private static func drawPDFLabels(ctx: CGContext, options: RenderExportOptions, w: Int, h: Int) {
        let exportableLabels = options.labels.filter(\.isExportable)
        guard !exportableLabels.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        nsCtx.cgContext.translateBy(x: 0, y: CGFloat(h))
        nsCtx.cgContext.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: nsCtx.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        let bounds = NSRect(x: 0, y: 0, width: w, height: h)
        for label in exportableLabels {
            LabelOverlayView.draw(label, in: bounds)
        }
        nsCtx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: SVG

    private static func emitSVG(cgImage: CGImage, scene: Scene, camera: Camera?,
                                options: RenderExportOptions, w: Int, h: Int, to url: URL) throws {
        let pngData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil) else {
            throw TrueVectorExportError.noContext
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw TrueVectorExportError.noData }
        let b64 = (pngData as Data).base64EncodedString()

        var cam = camera ?? scene.defaultCamera()
        if cam.rotation == simd_quatf(ix: 0, iy: 0, iz: 0, r: 0) {
            cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let aspect = h > 0 ? Float(w) / Float(h) : 1.0
        let viewMatrix = cam.viewMatrix()
        let projMatrix = cam.projectionMatrix(aspect: aspect)
        let wF = Float(w), hF = Float(h)

        var overlays = ""
        overlays += svgVectorOverlays(scene: scene, cam: cam, view: viewMatrix, proj: projMatrix,
                                      w: wF, h: hF, options: options)
        overlays += svgLabels(options: options, w: w, h: h)

        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
             width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
          <image width="\(w)" height="\(h)" xlink:href="data:image/png;base64,\(b64)"/>
          \(overlays)
        </svg>
        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func svgVectorOverlays(scene: Scene, cam: Camera, view: float4x4, proj: float4x4,
                                          w: Float, h: Float, options: RenderExportOptions) -> String {
        var s = ""
        let lw = max(1.0, scene.lineWidth)

        // Cell frame.
        if scene.showCellFrame, let cell = scene.cell {
            let a = cell.a, b = cell.b, c = cell.c
            let n = max(1, scene.atoms.count)
            var centroid = SIMD3<Float>.zero
            for at in scene.atoms { centroid += at.coord }
            centroid /= Float(n)
            let sc = scene.superCell
            let base = centroid - (Float(sc.n1) * 0.5) * a
                              - (Float(sc.n2) * 0.5) * b
                              - (Float(sc.n3) * 0.5) * c
            // Skip only this overlay if the replica count is invalid; do not
            // drop later overlays (axes, BZ, k-path, arrows).
            if let replicas = cellBoxCount(sc), replicas <= Scene.superCellAtomCap {
                var d = ""
                for i in 0..<sc.n1 {
                    for j in 0..<sc.n2 {
                        for k in 0..<sc.n3 {
                            let t = a * Float(i) + b * Float(j) + c * Float(k)
                            let o = base + t
                            let corners = [o, a + o, a + b + o, b + o, c + o, a + c + o, b + c + o, a + b + c + o]
                            for (ci, cj) in cellEdges {
                                guard let p0 = project(corners[ci], view: view, proj: proj, w: w, h: h),
                                      let p1 = project(corners[cj], view: view, proj: proj, w: w, h: h) else { continue }
                                d += " M \(fmt(p0.x)) \(fmt(p0.y)) L \(fmt(p1.x)) \(fmt(p1.y))"
                            }
                        }
                    }
                }
                if !d.isEmpty {
                    s += "<path d=\"\(d)\" fill=\"none\" stroke=\"#bfbfbf\" stroke-width=\"\(fmt(lw))\" stroke-linecap=\"round\"/>\n"
                }
            }
        }

        // Cartesian axes (orientation-gizmo triad), pinned to the bottom-left
        // corner to match the Metal renderer's `drawOrientationGizmo`. Image
        // space is y-down; the renderer's sub-viewport y_img ∈ [h-gSize-margin,
        /// h-margin] puts the center at (margin+gSize/2, h-margin-gSize/2).
        if scene.showAxes {
            let gSize = max(72.0, Double(min(w, h)) * 0.16)
            let margin = 14.0
            let centerX = margin + gSize / 2
            let centerY = Double(h) - margin - gSize / 2
            let worldToView = float4x4(cam.rotation).transpose
            let half: Float = 1.05
            let shaftLen: Float = 0.62
            struct Axis { let dir: SIMD3<Float>; let color: String }
            let axes = [
                Axis(dir: (worldToView * SIMD4<Float>(1, 0, 0, 0)).xyz, color: "#ff3333"),
                Axis(dir: (worldToView * SIMD4<Float>(0, 1, 0, 0)).xyz, color: "#33ff33"),
                Axis(dir: (worldToView * SIMD4<Float>(0, 0, 1, 0)).xyz, color: "#3333ff"),
            ]
            let axLw = lw * 2.0
            for axis in axes {
                let tipLocal = axis.dir * shaftLen
                let tipNDC = tipLocal / half
                // NDC +y is up in Metal → image-space y offset is -tipNDC.y.
                let tipX = centerX + Double(tipNDC.x) * gSize / 2
                let tipY = centerY - Double(tipNDC.y) * gSize / 2
                s += "<line x1=\"\(fmt(centerX))\" y1=\"\(fmt(centerY))\" x2=\"\(fmt(tipX))\" y2=\"\(fmt(tipY))\" stroke=\"\(axis.color)\" stroke-width=\"\(fmt(axLw))\" stroke-linecap=\"round\"/>\n"
            }
        }

        // Brillouin-zone wireframe.
        if scene.showBrillouinZone, let cell = scene.cell {
            if let bz = BrillouinZone.build(cell: cell, atoms: scene.baseAtoms) {
                let pres = BZPresentation(bz: bz, scene: scene)
                // Skip only this overlay if the BZ presentation is degenerate.
                if pres.inv.isFinite, pres.inv > 0,
                   pres.displayedHalfExtent.isFinite, pres.displayedHalfExtent > 1e-5 {
                    for face in bz.faces {
                        let mapped = face.map { pres.world(cartesian: $0) }
                        var d = ""
                        var first = true
                        for vert in mapped {
                            guard let p = project(vert, view: view, proj: proj, w: w, h: h) else { continue }
                            d += first ? " M \(fmt(p.x)) \(fmt(p.y))" : " L \(fmt(p.x)) \(fmt(p.y))"
                            first = false
                        }
                        if !first {
                            d += " Z"
                            s += "<path d=\"\(d)\" fill=\"none\" stroke=\"#d94ce6\" stroke-width=\"\(fmt(lw))\" stroke-linejoin=\"round\"/>\n"
                        }
                    }
                }
            }
        }

        // k-path route.
        if !scene.kPathPoints.isEmpty, let cell = scene.cell {
            if let bz = BrillouinZone.build(cell: cell, atoms: scene.baseAtoms) {
                let pres = BZPresentation(bz: bz, scene: scene)
                // Skip only this overlay if the BZ presentation is degenerate.
                if pres.inv.isFinite, pres.inv > 0 {
                    let mapped = scene.kPathPoints.prefix(1024).map { pres.world(frac: $0.frac) }
                    let valid = mapped.map { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    let breaks = scene.kPathBreaks
                    var run = ""
                    for i in 0..<mapped.count {
                        guard valid[i], let p = project(mapped[i], view: view, proj: proj, w: w, h: h) else {
                            if !run.isEmpty {
                                s += "<polyline points=\"\(run)\" fill=\"none\" stroke=\"#ff8c1a\" stroke-width=\"\(fmt(lw))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
                                run = ""
                            }
                            continue
                        }
                        let connected = i + 1 < mapped.count && valid[i + 1] && !breaks.contains(i)
                        run += "\(fmt(p.x)),\(fmt(p.y)) "
                        if !connected {
                            s += "<polyline points=\"\(run)\" fill=\"none\" stroke=\"#ff8c1a\" stroke-width=\"\(fmt(lw))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
                            run = ""
                        }
                    }
                    if !run.isEmpty {
                        s += "<polyline points=\"\(run)\" fill=\"none\" stroke=\"#ff8c1a\" stroke-width=\"\(fmt(lw))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
                    }
                }
            }
        }

        // Displacement arrows.
        if options.showDisplacementArrows, !options.displacementArrows.isEmpty {
            let headFrac: Float = 0.18
            let headSpread: Float = 0.5
            for arrow in options.displacementArrows {
                let start = arrow.start
                let vector = arrow.vector
                guard start.isFinite, vector.isFinite else { continue }
                let length = simd_length(vector)
                guard length > 1e-6, length.isFinite else { continue }
                let tip = start + vector
                guard let pStart = project(start, view: view, proj: proj, w: w, h: h),
                      let pTip = project(tip, view: view, proj: proj, w: w, h: h) else { continue }
                s += "<line x1=\"\(fmt(pStart.x))\" y1=\"\(fmt(pStart.y))\" x2=\"\(fmt(pTip.x))\" y2=\"\(fmt(pTip.y))\" stroke=\"#ff33e6\" stroke-width=\"\(fmt(lw))\" stroke-linecap=\"round\"/>\n"
                let dir = vector / length
                let perp = makePerpendicular(dir)
                let side = length * headFrac
                let back = tip - dir * side
                let left = back + perp * side * headSpread
                let right = back - perp * side * headSpread
                if let pLeft = project(left, view: view, proj: proj, w: w, h: h) {
                    s += "<line x1=\"\(fmt(pTip.x))\" y1=\"\(fmt(pTip.y))\" x2=\"\(fmt(pLeft.x))\" y2=\"\(fmt(pLeft.y))\" stroke=\"#ff33e6\" stroke-width=\"\(fmt(lw))\" stroke-linecap=\"round\"/>\n"
                }
                if let pRight = project(right, view: view, proj: proj, w: w, h: h) {
                    s += "<line x1=\"\(fmt(pTip.x))\" y1=\"\(fmt(pTip.y))\" x2=\"\(fmt(pRight.x))\" y2=\"\(fmt(pRight.y))\" stroke=\"#ff33e6\" stroke-width=\"\(fmt(lw))\" stroke-linecap=\"round\"/>\n"
                }
            }
        }

        return s
    }

    private static func svgLabels(options: RenderExportOptions, w: Int, h: Int) -> String {
        let exportable = options.labels.filter(\.isExportable)
        guard !exportable.isEmpty else { return "" }
        var s = ""
        for label in exportable {
            let color: String
            switch label.style {
            case .atom: color = "#ffffff"
            case .bondDistance: color = "#ffffff"
            case .routeNode: color = "#73eaff"
            case .selectedRouteNode: color = "#141414"
            case .tooltip: color = "#ffffff"
            case .scaleIndicator: color = label.usesLightForeground ? "#ffffff" : "#141414"
            }
            let fontSize: CGFloat
            switch label.style {
            case .atom, .tooltip: fontSize = NSFont.smallSystemFontSize
            case .bondDistance: fontSize = 10
            case .routeNode, .selectedRouteNode, .scaleIndicator: fontSize = NSFont.smallSystemFontSize
            }
            let weight = (label.style == .routeNode || label.style == .selectedRouteNode || label.style == .scaleIndicator) ? "bold" : "normal"
            s += "<text x=\"\(fmt(label.x))\" y=\"\(fmt(label.y))\" font-family=\"sans-serif\" font-size=\"\(fmt(fontSize))\" font-weight=\"\(weight)\" fill=\"\(color)\" xml:space=\"preserve\">\(xmlEscape(label.symbol))</text>\n"

            if label.style == .scaleIndicator, let barWidth = label.barWidth,
               barWidth.isFinite, barWidth > 0, barWidth <= 1_000_000 {
                let barY = label.y + CGFloat(NSFont.smallSystemFontSize) + 3 + 4
                let startX = label.x
                let endX = startX + barWidth
                s += "<rect x=\"\(fmt(startX))\" y=\"\(fmt(barY - 1))\" width=\"\(fmt(barWidth))\" height=\"2\" fill=\"\(color)\" opacity=\"0.8\"/>\n"
                s += "<line x1=\"\(fmt(startX))\" y1=\"\(fmt(barY - 4))\" x2=\"\(fmt(startX))\" y2=\"\(fmt(barY + 4))\" stroke=\"\(color)\" stroke-width=\"2\"/>\n"
                s += "<line x1=\"\(fmt(endX))\" y1=\"\(fmt(barY - 4))\" x2=\"\(fmt(endX))\" y2=\"\(fmt(barY + 4))\" stroke=\"\(color)\" stroke-width=\"2\"/>\n"
            }
        }
        return s
    }

    // MARK: Helpers

    private static func cellBoxCount(_ sc: SuperCell) -> Int? {
        guard sc.n1 > 0, sc.n2 > 0, sc.n3 > 0 else { return nil }
        let ab = sc.n1.multipliedReportingOverflow(by: sc.n2)
        guard !ab.overflow else { return nil }
        let abc = ab.partialValue.multipliedReportingOverflow(by: sc.n3)
        return abc.overflow ? nil : abc.partialValue
    }

    private static func makePerpendicular(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let cand = abs(d.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return normalize(cand - d * simd_dot(cand, d))
    }

    private static func fmt(_ v: Float) -> String { String(format: "%.2f", v) }
    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension TrueVectorExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noGPU: return "no Metal GPU is available"
        case .noTex: return "the requested export dimensions are invalid or unsupported"
        case .noCGImage: return "could not create the rendered image"
        case .noContext: return "could not create the export graphics context"
        case .noData: return "could not write export data"
        case .unsupported: return "the requested export format is unsupported"
        case .noQueue, .noCommandBuffer: return "could not prepare the Metal export command"
        case .encodeFailed: return "Metal could not encode the export frame"
        case .commandBufferError(let error): return error?.localizedDescription ?? "Metal failed while rendering the export"
        }
    }
}
