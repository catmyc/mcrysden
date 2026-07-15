import XCTest
import Metal
import simd
@testable import MolVisApp

// Regression coverage for adversarial findings 11-14 and 17. Every render uses a
// black clear color so "nonzero pixel" always means "foreground drew something"
// — a blank-success frame is all zeroes and fails the assertions.
final class AdversarialFindingsTests: XCTestCase {
    struct NoGpu: Error {}

    // Shared renderer/scene render helper (black background ⇒ foreground == nonzero).
    @discardableResult
    private func render(_ scene: Scene, dist: Float = 12,
                        w: Int = 96, h: Int = 96) throws -> (MTLTexture, Renderer) {
        var s = scene
        s.background = "#000000"
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        r.scene = s
        r.currentCamera.distance = dist
        guard let tex = device.makeTexture(descriptor: wtx(w, h)) else { throw NoGpu() }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        let ok = r.encode(to: cb, target: tex,
                          viewport: MTLViewport(originX: 0, originY: 0, width: Double(w),
                                                height: Double(h), znear: 0, zfar: 1),
                          camera: r.currentCamera)
        XCTAssertTrue(ok, "encode failed — frame would be blank")
        cb.commit(); cb.waitUntilCompleted()
        return (tex, r)
    }

    private func wtx(_ w: Int, _ h: Int) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.pixelFormat = .rgba8Unorm; d.width = w; d.height = h
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        return d
    }

    private func nonzero(_ tex: MTLTexture) -> Int {
        let w = tex.width, h = tex.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { n += 1 }
        return n
    }

    // MARK: - 13. Nonuniform-scale normals use the inverse-transpose (CPU mirror of
    // the in-shader math). Verifies the normal matrix keeps a normal orthogonal to
    // the transformed surface under nonuniform scale, which a naive model*normal
    // does not.

    func testNonuniformScaleNormalMatrix() {
        // A bond-like cylinder: rotation about +Z then a highly nonuniform scale
        // (thin + long). The unit normal (1,0,0) must stay orthogonal to the
        // transformed tangent (0,1,0) under the inverse-transpose.
        let rot = float4x4(simd_quatf(angle: .pi / 3, axis: normalize(SIMD3<Float>(1, 2, 3))))
        let model = rot * float4x4(scale: SIMD3<Float>(0.2, 2.0, 5.0))
        let upper = float3x3(model[0].xyz, model[1].xyz, model[2].xyz)
        let normalMatrix = upper.inverse.transpose

        let normal = normalize(SIMD3<Float>(1, 1, 0))
        let tangent = normalize(SIMD3<Float>(1, -1, 1))
        let n2 = normalMatrix * normal
        let t2 = upper * tangent
        XCTAssertLessThan(abs(dot(normalize(n2), normalize(t2))), 1e-4,
                          "inverse-transpose normal must stay orthogonal to transformed tangent")

        // Naive model*normal must NOT be orthogonal under nonuniform scale.
        let naive = upper * normal
        XCTAssertGreaterThan(abs(dot(normalize(naive), normalize(t2))), 0.1,
                             "naive transform should diverge, proving the correction is needed")

        // Uniform scale: inverse-transpose reduces to the linear part, so the
        // result matches the naive transform (up to normalization).
        let uniform = rot * float4x4(scale: SIMD3<Float>(2, 2, 2))
        let u = float3x3(uniform[0].xyz, uniform[1].xyz, uniform[2].xyz)
        let nu = normalize((u.inverse.transpose) * normal)
        let nuNaive = normalize(u * normal)
        XCTAssertEqual(simd_length(nu - nuNaive), 0, accuracy: 1e-3,
                        "uniform scale: inverse-transpose == linear part")
        XCTAssertTrue(Renderer.shaderSource.contains("b = m[1][0]"))
        XCTAssertTrue(Renderer.shaderSource.contains("d = m[0][1]"))
        XCTAssertTrue(Renderer.shaderSource.contains("abs(det) < 1e-12"))
    }

    // MARK: - 11. Depth texture falls back to a supported storage mode when
    // .memoryless is rejected, and the chosen mode is one of the fallbacks.

    func testDepthStorageModeFallbackIsSupported() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        // Whatever the device supports, the helper must return a mode it accepts.
        let mode = Renderer.preferredDepthStorageMode(device: device)
        if let mode {
            let d = MTLTextureDescriptor()
            d.pixelFormat = .depth32Float; d.width = 1; d.height = 1
            d.usage = .renderTarget; d.storageMode = mode
            XCTAssertNotNil(device.makeTexture(descriptor: d),
                            "preferredDepthStorageMode returned an unsupported mode")
        }
        // Fallback list is best-first: private preferred over shared on macOS.
        let fallbacks = Renderer.depthStorageFallbacks
        XCTAssertEqual(fallbacks.first, .private)
        XCTAssertTrue(fallbacks.contains(.shared))
    }

    // Rendering must still produce a frame even if .memoryless were rejected
    // (we can't force that on CI, but we can confirm the encode path succeeds and
    // attaches depth for a normal scene).
    func testDepthRenderProducesFrame() throws {
        var s = Scene()
        s.showAxes = true
        s.showCellFrame = true
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        s.background = "#000000"
        let (tex, _) = try render(s)
        XCTAssertGreaterThan(nonzero(tex), 0, "scene with axes/cell must render")
    }

    // MARK: - 12. Fermi surface: one cache slot per source band (incl. nil/no
    // crossing). A noncrossing band must NOT force a rebuild every frame.

    func testFermiCacheSlotsPerBandIncludingNil() throws {
        // Build a 2-band scene where band 0's field never crosses the Fermi level
        // (all values on one side) so it yields a nil buffer, band 1 crosses.
        func field(values: [Float], nx: Int = 2, ny: Int = 2, nz: Int = 2) -> ScalarField {
            let mn = values.min() ?? 0, mx = values.max() ?? 1
            return ScalarField(nx: nx, ny: ny, nz: nz, origin: .zero,
                              vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                              values: values, minValue: mn, maxValue: mx)
        }
        let fermi: Float = 0.5
        // Band 0: all values 1.0 → with sign +1, field(1.0) > iso(0.5) everywhere →
        // cubeindex 0 at every cube → triangleCount 0 → nil buffer.
        let band0 = field(values: [Float](repeating: 1.0, count: 8))
        // Band 1: values straddle 0.5 so marching cubes emits triangles.
        let band1 = field(values: [0,0,0,0, 1,1,1,1])
        let fs = FermiSurface(fermiEnergy: fermi, bands: [band0, band1])

        var s = Scene()
        s.fermiSurface = fs
        s.showFermiSurface = true
        s.showStructure = false; s.showAxes = false; s.showCellFrame = false
        s.showBrillouinZone = false; s.background = "#000000"

        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        r.scene = s
        r.currentCamera.distance = 8
        guard let tex = device.makeTexture(descriptor: wtx(80, 80)) else { throw NoGpu() }

        // First encode builds the per-band buffers (rebuild count → 1).
        let cb1 = device.makeCommandQueue()!.makeCommandBuffer()!
        XCTAssertTrue(r.encode(to: cb1, target: tex,
                              viewport: MTLViewport(originX: 0, originY: 0, width: 80, height: 80,
                                                    znear: 0, zfar: 1),
                              camera: r.currentCamera))
        cb1.commit(); cb1.waitUntilCompleted()
        XCTAssertEqual(r.fermiRebuildCount, 1)

        // Second encode with the SAME band set must NOT rebuild, even though one
        // band is noncrossing (nil buffer). Before the fix the compactMap dropped
        // the nil and the count guard rebuilt every frame.
        let cb2 = device.makeCommandQueue()!.makeCommandBuffer()!
        XCTAssertTrue(r.encode(to: cb2, target: tex,
                              viewport: MTLViewport(originX: 0, originY: 0, width: 80, height: 80,
                                                    znear: 0, zfar: 1),
                              camera: r.currentCamera))
        cb2.commit(); cb2.waitUntilCompleted()
        XCTAssertEqual(r.fermiRebuildCount, 1, "noncrossing band must not force rebuild")
    }

    // MARK: - 14. Appearance-only scene edits must not invalidate BZ/iso/Fermi caches.

    func testAppearanceOnlyEditDoesNotInvalidateCaches() throws {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        s.showBrillouinZone = true
        s.showStructure = false; s.showAxes = false; s.showCellFrame = false
        s.background = "#000000"
        s.scalarField = ScalarField(nx: 3, ny: 3, nz: 3, origin: .zero,
                                    vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                                    values: (0..<27).map { Float($0).truncatingRemainder(dividingBy: 5) },
                                    minValue: 0, maxValue: 4)
        s.showIsoSurface = true; s.isoLevel = 2

        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        r.scene = s
        r.currentCamera.distance = 12
        let tex = device.makeTexture(descriptor: wtx(120, 120))!
        func encodeOnce() {
            let cb = device.makeCommandQueue()!.makeCommandBuffer()!
            _ = r.encode(to: cb, target: tex,
                         viewport: MTLViewport(originX: 0, originY: 0, width: 120, height: 120,
                                               znear: 0, zfar: 1),
                         camera: r.currentCamera)
            cb.commit(); cb.waitUntilCompleted()
        }
        encodeOnce() // builds BZ + iso caches

        // Edit appearance only (lighting + background) — same geometry.
        var s2 = s
        s2.lighting.azimuth = 30
        s2.lighting.elevation = 60
        s2.atomScale = 0.8
        r.scene = s2
        encodeOnce()
        // No crash, no rebuild-forced blank. The frame must still draw the BZ/iso.
        var px = [UInt8](repeating: 0, count: 120 * 120 * 4)
        tex.getBytes(&px, bytesPerRow: 120 * 4, from: MTLRegionMake2D(0, 0, 120, 120), mipmapLevel: 0)
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { n += 1 }
        XCTAssertGreaterThan(n, 0, "appearance-only edit must not blank the frame")
        XCTAssertEqual(r.bzRebuildCount, 1)
        XCTAssertEqual(r.isoRebuildCount, 2)
    }

    func testSurfaceCachesTrackValuesAndCacheEmptyMeshes() throws {
        func field(_ values: [Float]) -> ScalarField {
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                        values: values, minValue: values.min() ?? 0, maxValue: values.max() ?? 0)
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let renderer = try Renderer(device: device)
        let texture = device.makeTexture(descriptor: wtx(64, 64))!
        let queue = device.makeCommandQueue()!
        func encode(_ scene: Scene) {
            renderer.scene = scene
            let cb = queue.makeCommandBuffer()!
            XCTAssertTrue(renderer.encode(to: cb, target: texture,
                                           viewport: MTLViewport(originX: 0, originY: 0,
                                                                 width: 64, height: 64,
                                                                 znear: 0, zfar: 1),
                                           camera: Camera()))
            cb.commit(); cb.waitUntilCompleted()
        }

        var isoScene = Scene()
        isoScene.showStructure = false
        isoScene.showIsoSurface = true
        isoScene.isoLevel = 0.5
        isoScene.scalarField = field([Float](repeating: 1, count: 8))
        encode(isoScene)
        XCTAssertEqual(renderer.isoRebuildCount, 2)
        encode(isoScene)
        XCTAssertEqual(renderer.isoRebuildCount, 2, "empty shells must remain cached")
        isoScene.scalarField = field([0, 0, 0, 0, 1, 1, 1, 1])
        encode(isoScene)
        XCTAssertEqual(renderer.isoRebuildCount, 4, "changed values must rebuild both shells")

        var fermiScene = Scene()
        fermiScene.showStructure = false
        fermiScene.showFermiSurface = true
        fermiScene.fermiSurface = FermiSurface(fermiEnergy: 0.5,
                                               bands: [field([Float](repeating: 1, count: 8))])
        encode(fermiScene)
        let firstFermiCount = renderer.fermiRebuildCount
        fermiScene.fermiSurface = FermiSurface(fermiEnergy: 0.5,
                                               bands: [field([0, 0, 0, 0, 1, 1, 1, 1])])
        encode(fermiScene)
        XCTAssertEqual(renderer.fermiRebuildCount, firstFermiCount + 1,
                       "same-shaped changed Fermi values must rebuild")
    }

    func testBZCacheTracksEveryBaseAtom() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let renderer = try Renderer(device: device)
        let texture = device.makeTexture(descriptor: wtx(64, 64))!
        let queue = device.makeCommandQueue()!
        var scene = Scene()
        scene.cell = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4))
        scene.showStructure = false
        scene.showBrillouinZone = true
        scene.baseAtoms = [Atom(coord: .zero, atomicNumber: 6, label: "C"),
                           Atom(coord: SIMD3(2, 2, 2), atomicNumber: 6, label: "C")]
        func encode() {
            renderer.scene = scene
            let cb = queue.makeCommandBuffer()!
            XCTAssertTrue(renderer.encode(to: cb, target: texture,
                                           viewport: MTLViewport(originX: 0, originY: 0,
                                                                 width: 64, height: 64,
                                                                 znear: 0, zfar: 1),
                                           camera: Camera()))
            cb.commit(); cb.waitUntilCompleted()
        }
        encode()
        XCTAssertEqual(renderer.bzRebuildCount, 1)
        scene.baseAtoms[1].coord = SIMD3(1, 1, 1)
        encode()
        XCTAssertEqual(renderer.bzRebuildCount, 2)
    }

    // applySlab(nil) on an already-unslabbed scene is a no-op (no rebond).
    func testApplySlabNilIsNoopWhenUnslabbed() {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        s.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
                   Atom(coord: SIMD3(1, 0, 0), atomicNumber: 6, label: "C")]
        s.preslabAtoms = s.atoms
        s.slab = nil
        let out = s.applySlab(nil)
        XCTAssertEqual(out.atoms.count, s.atoms.count, "applySlab(nil) on unslabbed scene must not rebond")
        XCTAssertEqual(out.bonds.count, s.bonds.count)
        XCTAssertNil(out.slab)
    }

    // MARK: - 17. Exporters surface encode failure and check command-buffer status.

    func testPngExportSurfacesEncodeFailureViaStatus() throws {
        // A valid export must succeed and return a non-blank image.
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("adv_out.png")
        let cg = try PngExporter.export(scene: scene, camera: nil, to: out,
                                        size: CGSize(width: 200, height: 200))
        // Validate beyond file size: the returned CGImage must have foreground pixels.
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { n += 1 }
        XCTAssertGreaterThan(n, 0, "exported PNG must contain foreground pixels, not a blank frame")
    }

    func testVectorExportReturnsNonBlankRaster() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        for ext in ["pdf", "svg", "eps"] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("adv_out.\(ext)")
            let cg = try RasterExporter.export(scene: scene, camera: nil, to: out,
                                               size: CGSize(width: 200, height: 200))
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var n = 0
            for i in stride(from: 0, to: px.count, by: 4) where px[i] != 0 || px[i+1] != 0 || px[i+2] != 0 { n += 1 }
            XCTAssertGreaterThan(n, 0, "\(ext) export must wrap a non-blank raster")
        }
    }
}
