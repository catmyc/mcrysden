import XCTest
import Metal
import simd
@testable import MolVisApp

/// Consolidated volumetric coverage (Phase 2a + 2b): colormap transfer + contour
/// levels, region integration constant/linear + malformed, slice sampling +
/// diagonal-plane mask, clipTriangles straddle/keep-side, multi-iso rebuild +
/// color-distinct cache keys, clip-plane culling, color-plane/slice state
/// round-trip, slice state persistence + clamping, composited color-plane
/// render, and updateContentVisibility no longer hiding the canvas.
final class VolumetricTests: XCTestCase {

    private enum Thrown: Error { case noGPU, noTex }

    // MARK: - Colormap transfer + contour levels

    // MARK: - Region integration constant/linear + malformed

    func testRegionIntegrationConstantLinearMalformed() {
        let field = constantField(n: 9, value: 5)
        let box = IntegrationRegion(shape: .box, center: SIMD3<Float>(4, 4, 4),
                                    halfExtents: SIMD3<Float>(2, 2, 2), radius: 2)
        let r = RegionIntegration.integrate(field: field, region: box)!
        XCTAssertEqual(r.mean, 5, accuracy: 1e-3)
        XCTAssertEqual(r.integral, 5 * 64, accuracy: 1.0)
        XCTAssertTrue(r.summary.contains("∫"))

        // Malformed: non-finite value -> nil.
        var badVals = [Float](repeating: 1, count: 9 * 9 * 9)
        badVals[100] = .nan
        let badField = makeField(n: 9, values: badVals)
        XCTAssertNil(RegionIntegration.integrate(field: badField, region: box))
        // Zero-volume region -> nil.
        let zeroVol = IntegrationRegion(shape: .box, center: SIMD3<Float>(4, 4, 4),
                                        halfExtents: SIMD3<Float>(0, 2, 2), radius: 2)
        XCTAssertNil(RegionIntegration.integrate(field: field, region: zeroVol))

        // Slice sampling + diagonal-plane mask (merged regression).
        let n = 5
        var vals = [Float]()
        for k in 0..<n { for j in 0..<n { for i in 0..<n { vals.append(Float(i + j + k)) } } }
        let sliceField = ScalarField(nx: n, ny: n, nz: n, origin: .zero,
                                     vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                                     values: vals, minValue: 0, maxValue: Float(3 * (n - 1)))
        let normal = simd_normalize(SIMD3<Float>(1, 1, 1))
        let plane = SlicePlane(origin: SIMD3(0.5, 0.5, 0.5), normal: normal)
        guard let slice = FieldSlice.sample(field: sliceField, plane: plane, resolution: 16) else {
            return XCTFail("expected a slice")
        }
        guard let mask = slice.mask else { return XCTFail("expected non-nil mask") }
        XCTAssertEqual(mask.count, slice.rows * slice.cols)
        XCTAssertGreaterThan(mask.filter({ !$0 }).count, 0)
    }

    // MARK: - clipTriangles straddle/keep-side

    func testClipTrianglesAndPlaneCulling() throws {
        let v: [Float] = [
            0, 0, -1,   0, 0, 1,   1, 0, 0,
            1, 0, 1,    0, 0, 1,   0, 1, 0,
            0, 1, 1,    0, 0, 1,   0, 0, 1,
        ]
        let plane = SlicePlane(origin: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1))
        let result = FieldSlice.clipTriangles(v, plane: plane, keepSide: 1)
        XCTAssertEqual(result.count, 54, "straddling triangle clips to a quad = 54 floats")
        for i in stride(from: 0, to: result.count, by: 9) {
            let p = SIMD3<Float>(result[i], result[i + 1], result[i + 2])
            XCTAssertGreaterThanOrEqual(simd_dot(p - plane.origin, plane.normal), -1e-5)
        }

        // Display-only clip-plane structure culling (merged regression).
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        var scene = Scene()
        scene.cell = cell
        scene.atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(2.5, 2.5, 2.5), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(5, 5, 5), atomicNumber: 6, label: "C"),
        ]
        scene.clipPlane = ClipPlane(enabled: true, h: 0, k: 1, l: 0, distance: 2.0,
                                    applyToStructure: true, applyToIsosurfaces: true)
        let renderer = try Renderer(device: MTLCreateSystemDefaultDevice()!)
        renderer.scene = scene
        XCTAssertEqual(renderer.structureCullFlags(), [true, true, true])
        scene.clipPlane = ClipPlane(enabled: true, h: 0, k: 1, l: 0, distance: -1.0,
                                    applyToStructure: true, applyToIsosurfaces: true)
        renderer.scene = scene
        XCTAssertEqual(renderer.structureCullFlags(), [false, false, false])
        scene.clipPlane = ClipPlane(enabled: true, h: 0, k: 1, l: 0, distance: 0.4,
                                    applyToStructure: true, applyToIsosurfaces: true)
        renderer.scene = scene
        XCTAssertEqual(renderer.structureCullFlags(), [true, false, false])

        // Composited color-plane render: a scene with grid2D + showColorPlane must
        // render the plane in the Metal scene, changing the rendered output.
        let tex = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeTexture(descriptor: wtx(64, 64)))
        let queue = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        var cpScene = Scene()
        cpScene.showStructure = false; cpScene.showAxes = false; cpScene.showCellFrame = false
        cpScene.showBrillouinZone = false; cpScene.background = "#000000"
        cpScene.grid2D = Grid2D(cols: 4, rows: 4, origin: .zero,
                                vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                values: [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11], [12, 13, 14, 15]],
                                minValue: 0, maxValue: 15, ident: "test")
        cpScene.showColorPlane = true
        cpScene.colorPlaneColormap = .viridis
        func encodeHash(_ value: Scene) -> UInt64 {
            renderer.scene = value
            let cb = queue.makeCommandBuffer()!
            XCTAssertTrue(renderer.encode(to: cb, target: tex,
                                           viewport: MTLViewport(originX: 0, originY: 0,
                                                                 width: 64, height: 64, znear: 0, zfar: 1),
                                           camera: renderer.currentCamera))
            cb.commit(); cb.waitUntilCompleted()
            return pixelHash(tex)
        }
        let withPlane = encodeHash(cpScene)
        var withoutPlane = cpScene
        withoutPlane.showColorPlane = false
        let planeBytes = Renderer.colorPlaneTextureBytes(grid: cpScene.grid2D!, colormap: .viridis)
        XCTAssertEqual(planeBytes.count, 4 * 4 * 4)
        for i in stride(from: 3, to: planeBytes.count, by: 4) { XCTAssertEqual(planeBytes[i], 255) }
        XCTAssertNotEqual(withPlane, encodeHash(withoutPlane), "color plane must change the rendered frame")
    }

    // MARK: - Multi-iso rebuild + color-distinct cache keys

    func testMultiIsoRebuildAndColorDistinctCaches() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let renderer = try Renderer(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: wtx(64, 64)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let values = (0..<27).map { Float($0).truncatingRemainder(dividingBy: 5) * 0.4 }
        var scene = Scene()
        scene.showStructure = false; scene.showAxes = false; scene.showCellFrame = false
        scene.showBrillouinZone = false; scene.background = "#000000"
        scene.showIsoSurface = true; scene.isoLevel = 0.5
        scene.scalarField = isoField(values)

        func encode(_ value: Scene) {
            renderer.scene = value
            let cb = queue.makeCommandBuffer()!
            XCTAssertTrue(renderer.encode(to: cb, target: texture,
                                           viewport: MTLViewport(originX: 0, originY: 0,
                                                                 width: 64, height: 64, znear: 0, zfar: 1),
                                           camera: renderer.currentCamera))
            cb.commit(); cb.waitUntilCompleted()
        }
        encode(scene)
        let legacyBuilt = renderer.isoRebuildCount
        XCTAssertGreaterThan(legacyBuilt, 0)
        for _ in 0..<3 { encode(scene) }
        XCTAssertEqual(renderer.isoRebuildCount, legacyBuilt)

        var withSpec = scene
        withSpec.isoSurfaces = [IsoSurfaceSpec(level: 0.5, colorHex: "#1f6f99", sign: 1, enabled: true)]
        encode(withSpec)
        XCTAssertGreaterThan(renderer.isoRebuildCount, legacyBuilt)

        // Color must be part of IsoCacheKey.
        let blue = SIMD3<Float>(0.30, 0.62, 0.95)
        let orange = SIMD3<Float>(0.95, 0.45, 0.25)
        let keyBlue = renderer.testIsoKey(field: isoField(values), isoLevel: 0.5, sign: 1, color: blue, clip: nil)
        let keyOrange = renderer.testIsoKey(field: isoField(values), isoLevel: 0.5, sign: 1, color: orange, clip: nil)
        XCTAssertNotEqual(keyBlue, keyOrange, "color must be part of IsoCacheKey")
    }

    // MARK: - Clip-plane culling


    // MARK: - Color-plane/slice state round-trip

    /// Color-plane/slice state round-trip, plus colormap transfer + contour
    /// levels and the bilinear saddle-cell segment count (consolidated).
    func testColorPlaneAndSliceStateRoundTrip() throws {
        // Colormap transfer + contour levels.
        let cm = Colormap.viridis
        let lo = cm.rgb(0)
        XCTAssertEqual(lo.x, 0.267004, accuracy: 1e-5)
        XCTAssertEqual(lo.y, 0.004874, accuracy: 1e-5)
        XCTAssertEqual(lo.z, 0.329415, accuracy: 1e-5)
        let (r8, g8, b8) = cm.rgb8(0.5)
        let c = cm.rgb(0.5)
        XCTAssertEqual(r8, UInt8(c.x * 255.5))
        XCTAssertEqual(g8, UInt8(c.y * 255.5))
        XCTAssertEqual(b8, UInt8(c.z * 255.5))

        // ContourConfig.levels replicates legacy formula.
        let legacy = ContourConfig.defaultLevels(min: -3, max: 7)
        XCTAssertEqual(legacy.count, 5)
        let expected = (1...5).map { -3.0 + (7.0 - (-3.0)) * Float($0) / 6 }
        for (a, e) in zip(legacy, expected) { XCTAssertEqual(a, e, accuracy: 1e-5) }
        XCTAssertTrue(ContourConfig.levels(min: 5, max: 5, count: 6).isEmpty)
        XCTAssertTrue(ContourConfig.levels(min: 0, max: 10, count: 1).isEmpty)
        XCTAssertEqual(ContourConfig.levels(min: 0, max: 1, count: 100).count, 23)

        // Saddle cell produces 2 segments (bilinear asymptotic-decider).
        let segs = ColorPlaneView.contourSegments(tl: 10, tr: -2, br: 0.1, bl: -2, level: 0)
        XCTAssertEqual(segs.count, 2)

        var scene = Scene()
        scene.colorPlaneColormap = .turbo
        scene.colorPlaneContourEnabled = false
        scene.colorPlaneContourCount = 12
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcrysden_test_vc.state")
        try StateStore.save(scene, camera: nil, sourceURL: nil, to: url)
        var loaded = Scene()
        var camera: Camera? = nil
        try StateStore.load(into: &loaded, camera: &camera, from: url)
        XCTAssertEqual(loaded.colorPlaneColormap, .turbo)
        XCTAssertEqual(loaded.colorPlaneContourEnabled, false)
        XCTAssertEqual(loaded.colorPlaneContourCount, 12)
        try? FileManager.default.removeItem(at: url)

        // Defaults.
        let defaults = Scene()
        XCTAssertEqual(defaults.colorPlaneColormap, .viridis)
        XCTAssertEqual(defaults.colorPlaneContourEnabled, true)
        XCTAssertEqual(defaults.colorPlaneContourCount, 6)

        // Slice persistence round-trip + clamping (merged regression).
        scene.volumeSlices = [
            VolumeSlice(enabled: true, h: 1, k: 0, l: 0, distance: 0.5),
            VolumeSlice(enabled: false, h: 0, k: 2, l: -1, distance: -1.5),
        ]
        try StateStore.save(scene, camera: nil, sourceURL: nil, to: url)
        var loadedSlices = Scene()
        try StateStore.load(into: &loadedSlices, camera: &camera, from: url)
        XCTAssertEqual(loadedSlices.volumeSlices.count, 2)
        XCTAssertEqual(loadedSlices.volumeSlices[0].h, 1)
        XCTAssertEqual(loadedSlices.volumeSlices[0].distance, 0.5, accuracy: 1e-5)
        XCTAssertFalse(loadedSlices.volumeSlices[1].enabled)
        XCTAssertEqual(loadedSlices.volumeSlices[1].l, -1)
        XCTAssertEqual(loadedSlices.volumeSlices[1].distance, -1.5, accuracy: 1e-5)
        try? FileManager.default.removeItem(at: url)

        // Clamping: out-of-range h/k/l and distance are clamped.
        scene.volumeSlices = [VolumeSlice(enabled: true, h: 100, k: -100, l: 50, distance: 99)]
        try StateStore.save(scene, camera: nil, sourceURL: nil, to: url)
        var loaded2 = Scene()
        try StateStore.load(into: &loaded2, camera: &camera, from: url)
        XCTAssertEqual(loaded2.volumeSlices[0].h, 8)
        XCTAssertEqual(loaded2.volumeSlices[0].k, -8)
        XCTAssertEqual(loaded2.volumeSlices[0].distance, 2, accuracy: 1e-5)
        try? FileManager.default.removeItem(at: url)

        // Cap at 3: a 4-slice save loads only 3.
        scene.volumeSlices = (0..<4).map { VolumeSlice(enabled: true, h: $0, k: 0, l: 0, distance: 0) }
        try StateStore.save(scene, camera: nil, sourceURL: nil, to: url)
        var loaded3 = Scene()
        try StateStore.load(into: &loaded3, camera: &camera, from: url)
        XCTAssertEqual(loaded3.volumeSlices.count, 3)
        try? FileManager.default.removeItem(at: url)

        // updateContentVisibility no longer hides the canvas: the color plane now
        // lives in the Metal scene, so the canvas must stay visible.
        var visScene = Scene()
        visScene.grid2D = Grid2D(cols: 2, rows: 2, origin: .zero,
                                 vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                                 values: [[0, 1], [2, 3]], minValue: 0, maxValue: 3, ident: "t")
        visScene.showColorPlane = true
        let controller = MainWindowController(scene: visScene, showWindow: false)
        controller.state.showColorPlane = true
        XCTAssertFalse(controller.canvas.isHidden, "canvas must not be hidden by the color plane")
    }

    // MARK: - Helpers

    private func makeField(n: Int, values: [Float]) -> ScalarField {
        ScalarField(nx: n, ny: n, nz: n, origin: .zero,
                    vec: [SIMD3<Float>(Float(n - 1), 0, 0),
                          SIMD3<Float>(0, Float(n - 1), 0),
                          SIMD3<Float>(0, 0, Float(n - 1))],
                    values: values, minValue: values.min() ?? 0, maxValue: values.max() ?? 0)
    }

    private func constantField(n: Int, value: Float) -> ScalarField {
        makeField(n: n, values: [Float](repeating: value, count: n * n * n))
    }

    private func isoField(_ values: [Float]) -> ScalarField {
        ScalarField(nx: 3, ny: 3, nz: 3, origin: .zero,
                    vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                    values: values, minValue: values.min() ?? 0, maxValue: values.max() ?? 0)
    }

    private func wtx(_ width: Int, _ height: Int) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.pixelFormat = .rgba8Unorm; d.width = width; d.height = height
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        return d
    }

    private func pixelHash(_ texture: MTLTexture) -> UInt64 {
        let w = texture.width, h = texture.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&pixels, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return pixels.reduce(into: UInt64(0xcbf29ce484222325)) { hash, byte in
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
    }
}
