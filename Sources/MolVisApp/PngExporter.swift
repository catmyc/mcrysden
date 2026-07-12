import AppKit
import Metal
import MetalKit
import simd

enum PngExportError: Error { case noGPU, noTex, noCGImage, noPNG }

enum PngExporter {
    /// Render the scene to PNG at `size`. Returns the rendered CGImage so a caller can
    /// validate pixel content (used by the export tests) in addition to the written file.
    @discardableResult
    static func export(scene: Scene, camera: Camera?, to url: URL, size: CGSize) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PngExportError.noGPU }
        let renderer = try Renderer(device: device)
        renderer.scene = scene
        let w = Int(size.width), h = Int(size.height)
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw PngExportError.noTex }
        let q = device.makeCommandQueue()!
        let cb = q.makeCommandBuffer()!
        renderer.background = PngExporter.clearColor(scene.background)
        // No camera supplied (headless export)? Fall back to the scene's canonical
        // default framing, which matches what the GUI shows.
        var cam = camera ?? scene.defaultCamera()
        if cam.rotation == simd_quatf(ix:0,iy:0,iz:0,r:0) { cam.rotation = simd_quatf(ix:0,iy:0,iz:0,r:1) }
        let viewport = MTLViewport(originX: 0, originY: 0, width: Double(size.width), height: Double(size.height), znear: 0, zfar: 1)
        renderer.encode(to: cb, target: tex, viewport: viewport, camera: cam)
        cb.commit(); cb.waitUntilCompleted()
        // tex → CGImage → PNG
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        tex.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        guard let cg = ctx.makeImage() else { throw PngExportError.noCGImage }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw PngExportError.noPNG }
        try png.write(to: url)
        return cg
    }
    static func clearColor(_ hex: String) -> MTLClearColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return MTLClearColorMake(0,0,0,1) }
        return MTLClearColorMake(Double((v >> 16) & 0xFF) / 255.0,
                                 Double((v >> 8) & 0xFF) / 255.0,
                                 Double(v & 0xFF) / 255.0, 1)
    }
}
