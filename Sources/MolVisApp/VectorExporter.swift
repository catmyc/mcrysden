import AppKit
import Metal
import MetalKit
import simd

/// Vector-format export (PDF / EPS / PS / SVG) mirroring `PngExporter`'s
/// `export(scene:camera:to:size:)` signature, so the App-side dispatch is a
/// one-line format switch.
///
/// All formats render the scene once to a high-resolution offscreen raster via
/// the shared `Renderer.encode(to:target:viewport:camera:)` path, then wrap the
/// pixels in a vector container:
///   - PDF  : a `CGContext` PDF consumer, one page, bitmap drawn into it.
///   - SVG  : a minimal SVG wrapper around a base64-encoded PNG `<image>`.
///   - EPS  : a minimal EPSF-3.0 document with a hex-encoded `colorimage`.
enum RasterExportError: Error {
    case noGPU, noTex, noCGImage, noContext, noData, unsupported,
         noQueue, noCommandBuffer, encodeFailed, commandBufferError(Error?)
}

/// PDF / EPS / PS / SVG export. The scene is rendered once to a high-res
/// offscreen *raster* via the shared `Renderer.encode(...)` path, then the
/// pixels are wrapped in a vector container (PDF: a bitmap drawn into a
/// CGContext page; SVG: a base64 PNG `<image>`; EPS: a hex `colorimage`).
/// This is raster-in-a-vector-wrapper, not true primitive (GL2PS-style)
/// vector output — the name reflects that honestly.
enum RasterExporter {
    /// Maximum per-axis render dimension. Matches the Metal maximum 2D texture
    /// size on macOS (16384); exports are refused above this rather than silently
    /// producing a texture the device cannot allocate.
    static let maxAxisDimension: CGFloat = 16_384

    /// Render the scene to a vector container (PDF/SVG/EPS/PS) at `size`. Returns the
    /// CGImage raster that was wrapped, so a caller can validate pixel content (used by
    // the export tests) across all formats — not just the written file's byte size.
    @discardableResult
    static func export(scene: Scene, camera: Camera?, to url: URL, size: CGSize,
                       options: RenderExportOptions = RenderExportOptions(),
                       background: (r: Double, g: Double, b: Double, a: Double)? = nil) throws -> CGImage {
        // Validate representability before Int conversion (mirrors PngExporter) so an
        // absurd size throws instead of trapping on the Int cast.
        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= CGFloat(RasterExporter.maxAxisDimension), rh <= CGFloat(RasterExporter.maxAxisDimension),
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw RasterExportError.noTex
        }
        let w = Int(rw), h = Int(rh)
        let total = w.multipliedReportingOverflow(by: h)
        guard !total.overflow, total.partialValue <= 16_000_000 else { throw RasterExportError.noTex }
        let cg = try render(scene: scene, camera: camera, w: w, h: h, options: options, background: background)
        try write(cgImage: cg, to: url, size: CGSize(width: w, height: h))
        return cg
    }

    /// Wrap an already-rendered AppKit graph in the requested vector container.
    static func write(cgImage: CGImage, to url: URL, size: CGSize) throws {
        let ext = url.pathExtension.lowercased()
        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= maxAxisDimension, rh <= maxAxisDimension,
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw RasterExportError.noTex
        }
        let w = Int(rw), h = Int(rh)
        let pixels = w.multipliedReportingOverflow(by: h)
        guard !pixels.overflow, pixels.partialValue <= 16_000_000,
              w == cgImage.width, h == cgImage.height else {
            throw RasterExportError.noTex
        }
        switch ext {
        case "pdf": try emitPDF(cgImage: cgImage, w: w, h: h, to: url)
        case "svg": try emitSVG(cgImage: cgImage, w: w, h: h, to: url)
        case "eps", "ps": try emitEPS(cgImage: cgImage, w: w, h: h, to: url)
        default: throw RasterExportError.unsupported
        }
    }

    // MARK: Metal → CGImage (mirrors PngExporter, reused for all formats)

    private static func render(scene: Scene, camera: Camera?, w: Int, h: Int,
                               options: RenderExportOptions,
                               background: (r: Double, g: Double, b: Double, a: Double)? = nil) throws -> CGImage {
        guard w > 0, h > 0 else { throw RasterExportError.noTex }
        guard let device = MTLCreateSystemDefaultDevice() else { throw RasterExportError.noGPU }
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
        guard let tex = device.makeTexture(descriptor: desc) else { throw RasterExportError.noTex }
        guard let q = device.makeCommandQueue() else { throw RasterExportError.noQueue }
        guard let cb = q.makeCommandBuffer() else { throw RasterExportError.noCommandBuffer }
        renderer.background = PngExporter.clearColor(scene.background)
        // No camera supplied (headless export)? Fall back to the scene's canonical
        // default framing, which matches what the GUI shows.
        var cam = camera ?? scene.defaultCamera()
        if cam.rotation == simd_quatf(ix: 0, iy: 0, iz: 0, r: 0) {
            cam.rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        guard renderer.encode(to: cb, target: tex, viewport: viewport, camera: cam) else {
            cb.commit(); cb.waitUntilCompleted()
            throw RasterExportError.encodeFailed
        }
        cb.commit(); cb.waitUntilCompleted()
        // Surface a GPU failure rather than wrapping a blank/partial raster.
        if let error = cb.error { throw RasterExportError.commandBufferError(error) }
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        tex.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw RasterExportError.noCGImage
        }
        guard let image = ctx.makeImage() else { throw RasterExportError.noCGImage }
        return try PngExporter.composite(labels: options.labels, onto: image)
    }

    // MARK: PDF

    private static func emitPDF(cgImage: CGImage, w: Int, h: Int, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: w, height: h)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RasterExportError.noContext
        }
        ctx.beginPDFPage(nil)
        ctx.draw(cgImage, in: mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    // MARK: SVG (base64 PNG wrapper)

    private static func emitSVG(cgImage: CGImage, w: Int, h: Int, to url: URL) throws {
        let pngData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil) else {
            throw RasterExportError.noContext
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw RasterExportError.noData }
        let b64 = (pngData as Data).base64EncodedString()
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
             width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
          <image width="\(w)" height="\(h)" xlink:href="data:image/png;base64,\(b64)"/>
        </svg>
        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: EPS / PostScript (hex-encoded colorimage)

    private static func emitEPS(cgImage: CGImage, w: Int, h: Int, to url: URL) throws {
        guard let providerData = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(providerData) else {
            throw RasterExportError.noCGImage
        }
        // Validate the source dimensions before raster allocation: a mismatch between
        // the declared size and the actual image would read past the pixel buffer.
        let bpr = cgImage.bytesPerRow
        guard w > 0, h > 0, w == cgImage.width, h == cgImage.height, bpr >= w * 4 else {
            throw RasterExportError.noCGImage
        }
        // Stream into a TEMPORARY file next to the destination, then replace the
        // destination atomically. `replaceItem` restores the original destination if
        // placing the new item ever fails, so a valid existing file is never deleted
        // before the replacement is guaranteed. On any write error the temp file is
        // removed, so the output path never holds a truncated document.
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString + ".eps.tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw RasterExportError.noData
        }
        var moved = false
        defer {
            if !moved { try? FileManager.default.removeItem(at: tmp) }
        }
        let fh = try FileHandle(forWritingTo: tmp)
        let header = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 \(w) \(h)\n%%EndComments\n"
            + "/picstr \(w * 3) string def\n\(w) \(h) 8 [\(w) 0 0 \(-h) 0 \(h)]\n{ currentfile picstr readhexstring pop } false 3 colorimage\n"
        guard let headerData = header.data(using: .utf8) else { throw RasterExportError.noData }
        try fh.write(contentsOf: headerData)
        let tbl: [UInt8] = [0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
                            0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66]
        var rowBuf = [UInt8]()
        rowBuf.reserveCapacity(w * 6 + 1)
        for y in 0..<h {
            let base = y * bpr
            rowBuf.removeAll(keepingCapacity: true)
            for x in 0..<w {
                let i = base + x * 4
                rowBuf.append(tbl[Int(ptr[i] >> 4)])
                rowBuf.append(tbl[Int(ptr[i] & 0xF)])
                rowBuf.append(tbl[Int(ptr[i+1] >> 4)])
                rowBuf.append(tbl[Int(ptr[i+1] & 0xF)])
                rowBuf.append(tbl[Int(ptr[i+2] >> 4)])
                rowBuf.append(tbl[Int(ptr[i+2] & 0xF)])
            }
            rowBuf.append(0x0A)
            try fh.write(contentsOf: rowBuf)
        }
        guard let trailerData = "%%EOF\n".data(using: .utf8) else { throw RasterExportError.noData }
        try fh.write(contentsOf: trailerData)
        try fh.close()
        // replaceItem requires an existing destination. New exports therefore move
        // the completed temporary into place; overwrites retain replacement's
        // rollback semantics so an old valid document survives any failure.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil,
                                                options: [], resultingItemURL: nil)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        moved = true
    }


}
