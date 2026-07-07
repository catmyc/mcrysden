import AppKit
import Metal
import MetalKit
import simd

enum PngExportError: Error { case noGPU, noTex, noCGImage, noPNG }

enum PngExporter {
    static func export(scene: Scene, camera: Camera?, to url: URL, size: CGSize) throws {
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
        var cam = camera ?? {
            var c = Camera()
            let (cen, r) = scene.boundingSphere()
            c.center = cen; c.distance = max(8, r*3)
            return c
        }()
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
    }
}
