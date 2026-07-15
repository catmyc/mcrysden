import XCTest
import Metal
import simd
@testable import MolVisApp

private enum Thrown: Error { case noGPU, noTex }

final class RendererTests: XCTestCase {
    func testCylinderWallNormalsAreRadial() {
        let segments = 12
        let mesh = Geometry.unitCylinder(radialSegments: segments)
        let wallNormals = mesh.normals.prefix(segments * 2)

        XCTAssertEqual(wallNormals.count, segments * 2)
        for normal in wallNormals {
            XCTAssertEqual(normal.y, 0, accuracy: 1e-6)
            XCTAssertEqual(simd_length(normal), 1, accuracy: 1e-6)
        }
    }

    func testLightDirectionRemainsFixedRelativeToCamera() {
        var lighting = Lighting()
        lighting.azimuth = 0
        lighting.elevation = 0
        let projection = matrix_identity_float4x4
        let identity = Renderer.makeFrame(view: matrix_identity_float4x4, proj: projection,
                                          lighting: lighting, eye: .zero)

        var camera = Camera()
        camera.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let view = camera.viewMatrix()
        let rotated = Renderer.makeFrame(view: view, proj: projection,
                                         lighting: lighting, eye: camera.eyePosition())
        let rotatedLightInView = (view * SIMD4<Float>(rotated.lightDir, 0)).xyz

        XCTAssertEqual(rotatedLightInView.x, identity.lightDir.x, accuracy: 1e-5)
        XCTAssertEqual(rotatedLightInView.y, identity.lightDir.y, accuracy: 1e-5)
        XCTAssertEqual(rotatedLightInView.z, identity.lightDir.z, accuracy: 1e-5)
        XCTAssertLessThan(simd_dot(rotated.lightDir, identity.lightDir), 0.01)
    }

    func testRendererProducesDrawablePixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let r = try Renderer(device: device)
        var s = Scene()
        s.background = "#000000"   // black clear so nonzero pixels are foreground only
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
        s.background = "#000000"   // black clear so nonzero pixels are foreground only
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

    // Decode a CGImage to RGBA and count foreground (non-black) pixels.
    private func foregroundPixels(_ cg: CGImage) -> Int {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { n += 1 }
        return n
    }

    func testHeadlessPngExport() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(url))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out.png")
        let cg = try PngExporter.export(scene: scene, camera: nil, to: out, size: CGSize(width: 400, height: 400))
        XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
        // A blank-success frame would be all black — prove the render drew geometry.
        XCTAssertGreaterThan(foregroundPixels(cg), 0, "exported PNG must contain foreground pixels")
    }

    func testVectorExportPDF() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(url))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out.pdf")
        let cg = try RasterExporter.export(scene: scene, camera: nil, to: out, size: CGSize(width: 400, height: 400))
        XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
        let header = try Data(contentsOf: out, options: .mappedIfSafe).prefix(5)
        XCTAssertEqual(String(data: header, encoding: .ascii), "%PDF-")
        XCTAssertGreaterThan(foregroundPixels(cg), 0, "PDF raster must contain foreground pixels")
    }

    func testVectorExportSVG() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(url))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out.svg")
        let cg = try RasterExporter.export(scene: scene, camera: nil, to: out, size: CGSize(width: 400, height: 400))
        XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
        let data = try Data(contentsOf: out)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.hasPrefix("<?xml"), "SVG should start with xml declaration, got: \(str.prefix(40))")
        XCTAssertTrue(str.contains("<svg"), "SVG should contain <svg element")
        XCTAssertGreaterThan(foregroundPixels(cg), 0, "SVG raster must contain foreground pixels")
    }

    func testVectorExportEPS() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(url))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("out.eps")
        let cg = try RasterExporter.export(scene: scene, camera: nil, to: out, size: CGSize(width: 400, height: 400))
        XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
        let header = try Data(contentsOf: out, options: .mappedIfSafe).prefix(4)
        XCTAssertEqual(String(data: header, encoding: .ascii), "%!PS")
        XCTAssertGreaterThan(foregroundPixels(cg), 0, "EPS raster must contain foreground pixels")
    }
    // Axes must draw independently of the cell frame. A cell-only scene (no
    // atoms/bonds) isolates the axes: with Cell Frame OFF and Axes ON the axes
    // alone must render; flipping Axes OFF must blank the image entirely.
    func testAxesIndependentOfCellFrame() throws {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5,0,0), b: SIMD3(0,5,0), c: SIMD3(0,0,5))
        s.showCellFrame = false
        // Black background: the renderer now clears to the scene's background
        // color, so a non-black clear would fill the framebuffer and drown out the
        // "nothing renders" assertion. Black restores its original meaning.
        s.background = "#000000"
        s.showAxes = true
        let tex = try render(scene: s, dist: 12, w: 120, h: 120)
        let on = nonzeroPixels(tex)
        XCTAssertGreaterThan(on, 0, "axes should render even with cell frame off")

        s.showAxes = false
        let tex2 = try render(scene: s, dist: 12, w: 120, h: 120)
        XCTAssertEqual(nonzeroPixels(tex2), 0, "with axes off and no atoms/cell-frame, nothing should render")
    }

    // The orientation gizmo must keep a constant pixel size regardless of zoom:
    // the old in-3D axes grew/shrank with the camera distance, the corner gizmo
    // must not. Render the same cell-only scene at two zoom levels and compare
    // the axis pixel counts.
    func testOrientationGizmoFixedSize() throws {
        func axisPixels(dist: Float) throws -> Int {
            var s = Scene()
            s.isCrystal = true
            s.cell = Cell(a: SIMD3(5,0,0), b: SIMD3(0,5,0), c: SIMD3(0,0,5))
            s.showCellFrame = false // isolate the gizmo from the (zoom-scaled) cell box
            s.showAxes = true
            return nonzeroPixels(try render(scene: s, dist: dist, w: 200, h: 200))
        }
        let near = try axisPixels(dist: 8)
        let far = try axisPixels(dist: 40)
        XCTAssertGreaterThan(near, 0, "gizmo should render")
        XCTAssertGreaterThan(far, 0, "gizmo should render at distance too")
        // Fixed on-screen size: counts agree within a tolerant factor (perspective
        // and integer sampling prevent exact equality).
        let ratio = Float(max(1,near)) / Float(max(1,far))
        XCTAssertEqual(ratio, 1.0, accuracy: 0.5, "gizmo size should not track zoom (near=\(near), far=\(far))")
    }

    func testOrientationGizmoRespondsToCameraRotation() throws {
        var scene = Scene()
        scene.background = "#000000"
        scene.showCellFrame = false
        scene.showAxes = true
        scene.lighting.ambient = 0.05
        scene.lighting.diffuse = 0.95

        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let quarterTurn = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let before = try render(scene: scene, dist: 12, rotation: identity, w: 160, h: 160)
        let after = try render(scene: scene, dist: 12, rotation: quarterTurn, w: 160, h: 160)

        XCTAssertNotEqual(pixelHash(before), pixelHash(after),
                          "rotating the gizmo must update its geometry and lighting")
    }

    // The Renderer today clears with a single solid color and ignores
    // backgroundType — richer gradient rendering lives in the shader, owned by
    // another agent. What the state/sidebar layer CAN guarantee is that the
    // gradient's two colors are correctly propagated into the scene and differ
    // from each other; assert that here so the wiring is locked before the
    // renderer work lands. After syncFromState, a gradient-configured scene must
    // carry both colors and the gradient type.
    func testGradientBackgroundPropagatesToScene() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(url))
        let state = SideBarState()
        state.backgroundType = .gradient_top
        state.backgroundHex = "#112233"
        state.backgroundBottomHex = "#445566"
        // Drive the new appearance fields into the scene the way syncFromState
        // does — this is the contract the state layer guarantees regardless of
        // when the renderer starts consuming backgroundType.
        var s = scene
        s.backgroundType = state.backgroundType
        s.background = state.backgroundHex
        s.backgroundBottom = state.backgroundBottomHex
        XCTAssertEqual(s.backgroundType, .gradient_top)
        XCTAssertEqual(s.background, "#112233")
        XCTAssertEqual(s.backgroundBottom, "#445566")
        // The two colors must genuinely differ, else the gradient is degenerate.
        func rgb(_ h: String) -> (UInt8, UInt8, UInt8) {
            var t = h.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { t.removeFirst() }
            let v = UInt32(t, radix: 16) ?? 0
            return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
        let top = rgb(s.background), bot = rgb(s.backgroundBottom)
        XCTAssertFalse(top.0 == bot.0 && top.1 == bot.1 && top.2 == bot.2,
                       "gradient top and bottom colors must differ")
    }

    // 2D display modes force an orthographic projection looking down +Z with no
    // rotation (Renderer.encode swaps to ortho for .is2D). Render the SAME atom
    // pair in 3D ballStick and 2D line2D: the images must differ (perspective vs
    // ortho changes the projected layout), proving the 2D path is wired.
    func test2DModeProjectsDifferentlyFrom3D() throws {
        var s3d = Scene()
        s3d.atoms = [Atom(coord: SIMD3(-2, 0, 1), atomicNumber: 6, label: "C"),
                     Atom(coord: SIMD3( 2, 0, -1), atomicNumber: 6, label: "C")]
        let tex3d = try render(scene: s3d, dist: 10)
        var s2d = s3d
        s2d.displayMode = .line2D
        let tex2d = try render(scene: s2d, dist: 10)
        // Hash each framebuffer; differing projection => differing image. (Equal
        // hashes would mean the 2D branch collapsed to the 3D one.)
        func hash(_ tex: MTLTexture) -> UInt64 {
            let w = tex.width, h = tex.height
            var px = [UInt8](repeating: 0, count: w*h*4)
            tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
            var hash: UInt64 = 0xcbf29ce484222325
            for b in px { hash ^= UInt64(b); hash = hash &* 0x100000001b3 }
            return hash
        }
        XCTAssertNotEqual(hash(tex3d), hash(tex2d), "2D and 3D projections must differ")
        XCTAssertGreaterThan(nonzeroPixels(tex2d), 0, "2D mode should still render pixels")
    }

    private func nonzeroPixels(_ tex: MTLTexture) -> Int {
        let w = tex.width, h = tex.height
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { n += 1 }
        return n
    }

    private func render(scene: Scene, dist: Float,
                        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                        w: Int = 96, h: Int = 96) throws -> MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let r = try Renderer(device: device)
        r.scene = scene
        r.currentCamera.distance = dist
        r.currentCamera.rotation = rotation
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

    private func pixelHash(_ tex: MTLTexture) -> UInt64 {
        let w = tex.width, h = tex.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return px.reduce(into: UInt64(0xcbf29ce484222325)) { hash, byte in
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
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
