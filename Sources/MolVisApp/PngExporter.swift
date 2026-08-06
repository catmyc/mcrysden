import AppKit
import Metal
import MetalKit
import simd

enum PngExportError: Error { case noGPU, noTex, noCGImage, noPNG, noQueue, noCommandBuffer, encodeFailed, commandBufferError(Error?) }

struct RenderExportOptions {
    var labels: [LabelOverlayView.Label] = []
    var showBZLandmarks = false
    var coordinationNumbers: [Int] = []
    var showCoordinationColors: Bool = false
    var selectedKPathNode: Int? = nil
    var msaaSampleCount: Int? = nil
    /// Runtime-only comparison displacement arrows. Populated only for the
    /// visible Metal canvas; headless/vector defaults remain empty so the
    /// unused path is unchanged.
    var displacementArrows: [(start: SIMD3<Float>, vector: SIMD3<Float>)] = []
    var showDisplacementArrows: Bool = false
}

enum PngExporter {
    /// Render the scene offscreen to a CGImage at `size`. Performs the same
    /// dimension validation, Metal setup, encode, readback and label compositing as
    /// `export`, but performs NO file write — callers (PNG export, animation
    /// encoders) consume the CGImage directly.
    static func render(scene: Scene, camera: Camera?, size: CGSize,
                       background: NSColor? = nil, transparent: Bool = false) throws -> CGImage {
        // Validate the rounded dimensions are representable as Int BEFORE converting
        // (greatestFiniteMagnitude.rounded() still overflows Int → trap), then enforce
        // the per-axis Metal texture cap and an overflow-checked total-pixel cap.
        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= CGFloat(RasterExporter.maxAxisDimension), rh <= CGFloat(RasterExporter.maxAxisDimension),
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw PngExportError.noTex
        }
        let w = Int(rw), h = Int(rh)
        let total = w.multipliedReportingOverflow(by: h)
        guard !total.overflow, total.partialValue <= 16_000_000 else { throw PngExportError.noTex }
        guard let device = MTLCreateSystemDefaultDevice() else { throw PngExportError.noGPU }
        let renderer = try Renderer(device: device)
        renderer.scene = scene
        renderer.msaaSampleCount = scene.msaaSampleCount
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw PngExportError.noTex }
        guard let q = device.makeCommandQueue() else { throw PngExportError.noQueue }
        guard let cb = q.makeCommandBuffer() else { throw PngExportError.noCommandBuffer }
        // Only override the clear color when the caller explicitly requests a
        // custom background or transparency; otherwise leave clearColorOverride
        // nil so the scene's own background (including gradients) is preserved.
        if transparent {
            renderer.clearColorOverride = MTLClearColorMake(0, 0, 0, 0)
        } else if let background {
            renderer.clearColorOverride = PngExporter.clearColor(background)
        }
        defer { renderer.clearColorOverride = nil }
        // No camera supplied (headless export)? Fall back to the scene's canonical
        // default framing, which matches what the GUI shows.
        var cam = camera ?? scene.defaultCamera()
        if cam.rotation == simd_quatf(ix:0,iy:0,iz:0,r:0) { cam.rotation = simd_quatf(ix:0,iy:0,iz:0,r:1) }
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        guard renderer.encode(to: cb, target: tex, viewport: viewport, camera: cam) else {
            cb.commit(); cb.waitUntilCompleted()
            throw PngExportError.encodeFailed
        }
        cb.commit(); cb.waitUntilCompleted()
        // The GPU can fail without trapping — surface status/error rather than
        // silently writing a blank/partial frame.
        if let error = cb.error { throw PngExportError.commandBufferError(error) }
        // tex → CGImage
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        tex.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PngExportError.noCGImage
        }
        guard let image = ctx.makeImage() else { throw PngExportError.noCGImage }
        return try composite(labels: [], onto: image)
    }

    /// Render the scene to PNG at `size`. Returns the rendered CGImage so a caller can
    /// validate pixel content (used by the export tests) in addition to the written file.
    @discardableResult
    static func export(scene: Scene, camera: Camera?, to url: URL, size: CGSize,
                       options: RenderExportOptions = RenderExportOptions(),
                       background: NSColor? = nil, transparent: Bool = false) throws -> CGImage {
        // Validate the rounded dimensions are representable as Int BEFORE converting
        // (greatestFiniteMagnitude.rounded() still overflows Int → trap), then enforce
        // the per-axis Metal texture cap and an overflow-checked total-pixel cap.
        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= CGFloat(RasterExporter.maxAxisDimension), rh <= CGFloat(RasterExporter.maxAxisDimension),
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw PngExportError.noTex
        }
        let w = Int(rw), h = Int(rh)
        let total = w.multipliedReportingOverflow(by: h)
        guard !total.overflow, total.partialValue <= 16_000_000 else { throw PngExportError.noTex }
        guard let device = MTLCreateSystemDefaultDevice() else { throw PngExportError.noGPU }
        let renderer = try Renderer(device: device)
        renderer.scene = scene
        renderer.showBZLandmarks = options.showBZLandmarks
        renderer.coordinationNumbers = options.coordinationNumbers
        renderer.showCoordinationColors = options.showCoordinationColors
        renderer.selectedKPathNode = options.selectedKPathNode
        renderer.msaaSampleCount = options.msaaSampleCount ?? scene.msaaSampleCount
        renderer.displacementArrows = options.displacementArrows
        renderer.showDisplacementArrows = options.showDisplacementArrows
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw PngExportError.noTex }
        guard let q = device.makeCommandQueue() else { throw PngExportError.noQueue }
        guard let cb = q.makeCommandBuffer() else { throw PngExportError.noCommandBuffer }
        // Only override the clear color when the caller explicitly requests a
        // custom background or transparency; otherwise leave clearColorOverride
        // nil so the scene's own background (including gradients) is preserved.
        if transparent {
            renderer.clearColorOverride = MTLClearColorMake(0, 0, 0, 0)
        } else if let background {
            renderer.clearColorOverride = PngExporter.clearColor(background)
        }
        defer { renderer.clearColorOverride = nil }
        // No camera supplied (headless export)? Fall back to the scene's canonical
        // default framing, which matches what the GUI shows.
        var cam = camera ?? scene.defaultCamera()
        if cam.rotation == simd_quatf(ix:0,iy:0,iz:0,r:0) { cam.rotation = simd_quatf(ix:0,iy:0,iz:0,r:1) }
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
        guard renderer.encode(to: cb, target: tex, viewport: viewport, camera: cam) else {
            cb.commit(); cb.waitUntilCompleted()
            throw PngExportError.encodeFailed
        }
        cb.commit(); cb.waitUntilCompleted()
        // The GPU can fail without trapping — surface status/error rather than
        // silently writing a blank/partial frame.
        if let error = cb.error { throw PngExportError.commandBufferError(error) }
        // tex → CGImage → PNG
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        tex.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PngExportError.noCGImage
        }
        guard let image = ctx.makeImage() else { throw PngExportError.noCGImage }
        let cg = try composite(labels: options.labels, onto: image)
        try write(cgImage: cg, to: url)
        return cg
    }

    /// Write an already-rendered AppKit graph through the same PNG encoder used
    /// by Metal scenes.
    static func write(cgImage: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw PngExportError.noPNG }
        try png.write(to: url, options: .atomic)
    }

    /// Composite AppKit's top-left-origin label overlay onto an offscreen raster.
    static func composite(labels: [LabelOverlayView.Label], onto image: CGImage) throws -> CGImage {
        let exportableLabels = labels.filter(\.isExportable)
        guard !exportableLabels.isEmpty else { return image }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw PngExportError.noCGImage }
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(image.height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let bounds = NSRect(x: 0, y: 0, width: image.width, height: image.height)
        for label in exportableLabels {
            LabelOverlayView.draw(label, in: bounds)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let composited = rep.cgImage else { throw PngExportError.noCGImage }
        return composited
    }
    static func clearColor(_ hex: String) -> MTLClearColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return MTLClearColorMake(0,0,0,1) }
        return MTLClearColorMake(Double((v >> 16) & 0xFF) / 255.0,
                                 Double((v >> 8) & 0xFF) / 255.0,
                                 Double(v & 0xFF) / 255.0, 1)
    }
    static func clearColor(_ color: NSColor) -> MTLClearColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return MTLClearColorMake(Double(rgb.redComponent), Double(rgb.greenComponent),
                                 Double(rgb.blueComponent), Double(rgb.alphaComponent))
    }
}
