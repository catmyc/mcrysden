import XCTest
import Metal
@testable import MolVisApp

private enum Thrown: Error { case noGPU, noTex }

final class RendererTests: XCTestCase {
    func testRendererProducesDrawablePixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let r = try Renderer(device: device)
        var s = Scene()
        s.atoms = [Atom(coord: SIMD3(0,0,0), atomicNumber: 6, label: "C")]
        r.scene = s
        r.currentCamera.distance = 6
        let w = 64, h = 64
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared            // CPU-readable without blit
        guard let tex = device.makeTexture(descriptor: desc) else { throw Thrown.noTex }
        let q = device.makeCommandQueue()!
        let cb = q.makeCommandBuffer()!
        r.encode(to: cb, target: tex, viewport: MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1), camera: r.currentCamera)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        var nonzero = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { nonzero += 1 }
        XCTAssertGreaterThan(nonzero, 0, "nothing rendered")
    }

    func testSpaceFillUsesVDW() throws {
        // build a 2-atom scene in spaceFill; ensure it renders without error and produces pixels
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let r = try Renderer(device: device)
        var s = Scene()
        s.displayMode = .spaceFill
        s.atoms = [Atom(coord: SIMD3(0,0,0), atomicNumber: 6, label: "C"),
                   Atom(coord: SIMD3(1.5,0,0), atomicNumber: 6, label: "C")]
        r.scene = s
        r.currentCamera.distance = 8
        let w = 64, h = 64
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw Thrown.noTex }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        r.encode(to: cb, target: tex, viewport: MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1), camera: r.currentCamera)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        var nonzero = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { nonzero += 1 }
        XCTAssertGreaterThan(nonzero, 0)
    }

    func testElementTableCPK() {
        let c = ElementTable.color(6)
        XCTAssertGreaterThan(c.x, 0)
        XCTAssertEqual(ElementTable.symbol(1), "H")
        XCTAssertEqual(ElementTable.symbol(79), "Au")
        XCTAssertEqual(ElementTable.covalentRadius(1), 0.31, accuracy: 0.01)
    }

    func testHeadlessPngExport() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(url))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out.png")
        try PngExporter.export(scene: scene, camera: nil, to: out, size: CGSize(width: 400, height: 400))
        XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
    }
    private func render(scene: Scene, dist: Float, w: Int = 96, h: Int = 96) throws -> MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let r = try Renderer(device: device)
        r.scene = scene
        r.currentCamera.distance = dist
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw Thrown.noTex }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        r.encode(to: cb, target: tex, viewport: MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1), camera: r.currentCamera)
        cb.commit(); cb.waitUntilCompleted()
        return tex
    }

    private func nonzeroColumns(_ tex: MTLTexture) -> (minC: Int, maxC: Int) {
        let w = tex.width, h = tex.height
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        var minC = w, maxC = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            if px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { if x < minC { minC = x }; if x > maxC { maxC = x } }
        } }
        return (minC, maxC)
    }

    // Locks the Critical instancing fix: two distinct atoms must render as two
    // spatially separate blobs, not collapsed onto one instance.
    func testTwoAtomsRenderDistinct() throws {
        var s = Scene()
        s.atoms = [Atom(coord: SIMD3(-2,0,0), atomicNumber: 6, label: "C"),
                   Atom(coord: SIMD3( 2,0,0), atomicNumber: 6, label: "C")]
        let tex = try render(scene: s, dist: 10)
        let (minC, maxC) = nonzeroColumns(tex)
        XCTAssertGreaterThan(maxC - minC, 30, "two atoms should render as two distinct instances (spread was \(maxC-minC))")
    }

}
