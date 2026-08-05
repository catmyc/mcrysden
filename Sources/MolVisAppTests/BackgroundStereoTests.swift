import XCTest
import Metal
import AppKit
import simd
@testable import MolVisApp

/// Tests for the two remaining "Volumetric data and rendering" roadmap items:
/// image backgrounds and stereo/anaglyph rendering.
final class BackgroundStereoTests: XCTestCase {

    // MARK: - Helpers

    /// Render the scene into a Metal texture and return it.
    private func render(scene: Scene, dist: Float = 10,
                        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                        w: Int = 96, h: Int = 96) throws -> MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noGPU
        }
        let renderer = try Renderer(device: device)
        renderer.scene = scene
        renderer.currentCamera.distance = dist
        renderer.currentCamera.rotation = rotation

        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = w
        descriptor.height = h
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TestError.noTexture
        }
        let commandBuffer = device.makeCommandQueue()!.makeCommandBuffer()!
        XCTAssertTrue(renderer.encode(to: commandBuffer, target: texture,
                                      viewport: MTLViewport(originX: 0, originY: 0,
                                                            width: Double(w), height: Double(h),
                                                            znear: 0, zfar: 1),
                                      camera: renderer.currentCamera))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return texture
    }

    /// FNV-1a hash of a texture's pixels.
    private func pixelHash(_ texture: MTLTexture) -> UInt64 {
        let width = texture.width
        let height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels.reduce(into: UInt64(0xcbf29ce484222325)) { hash, byte in
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
    }

    /// Generate a small solid-color PNG file and return its path.
    private func makeTempPNG(r: UInt8, g: UInt8, b: UInt8) throws -> String {
        let width = 16
        let height = 16
        let size = NSSize(width: width, height: height)
        let nsImage = NSImage(size: size, flipped: false) { _ in
            NSColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                    blue: CGFloat(b) / 255.0, alpha: 1.0).setFill()
            NSRect(origin: .zero, size: size).fill()
            return true
        }
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw TestError.noTexture
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-test-bg-\(UUID().uuidString).png").path
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // MARK: - Anaglyph channel masks

    func testAnaglyphModesAndMasks() throws {
        let redCyan = AnaglyphChannelMasks.forMode(.redCyan)
        XCTAssertEqual(redCyan.left, SIMD3<Float>(1, 0, 0), "redCyan left = red only")
        XCTAssertEqual(redCyan.right, SIMD3<Float>(0, 1, 1), "redCyan right = cyan (green+blue)")

        let greenMagenta = AnaglyphChannelMasks.forMode(.greenMagenta)
        XCTAssertEqual(greenMagenta.left, SIMD3<Float>(0, 1, 0), "greenMagenta left = green only")
        XCTAssertEqual(greenMagenta.right, SIMD3<Float>(1, 0, 1), "greenMagenta right = magenta (red+blue)")

        let off = AnaglyphChannelMasks.forMode(.off)
        XCTAssertEqual(off.left, SIMD3<Float>(1, 1, 1), "off left = passthrough")
        XCTAssertEqual(off.right, SIMD3<Float>(0, 0, 0), "off right = nothing")
    
        // --- merged (isolated scope) ---
        do {

        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: SIMD3(-1, 0, 0), atomicNumber: 6, label: "C"),
                       Atom(coord: SIMD3(1, 0, 0), atomicNumber: 6, label: "C")]

        // Render with anaglyph off (default).
        let offHash = pixelHash(try render(scene: scene, dist: 8))

        // Explicitly set anaglyphMode = .off and render again.
        scene.anaglyphMode = .off
        let offExplicitHash = pixelHash(try render(scene: scene, dist: 8))

        XCTAssertEqual(offHash, offExplicitHash,
                       "anaglyphMode .off must be byte-identical to the default render")
        }

        // --- merged (isolated scope) ---
        do {

        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: SIMD3(-1.5, 0, 0), atomicNumber: 6, label: "C"),
                       Atom(coord: SIMD3(1.5, 0, 0), atomicNumber: 6, label: "C")]

        scene.anaglyphMode = .off
        let offHash = pixelHash(try render(scene: scene, dist: 8))

        scene.anaglyphMode = .redCyan
        let redCyanHash = pixelHash(try render(scene: scene, dist: 8))

        XCTAssertNotEqual(offHash, redCyanHash,
                          "redCyan anaglyph must differ from the off render")
        }

        // --- merged (isolated scope) ---
        do {

        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: SIMD3(-1.5, 0, 0), atomicNumber: 6, label: "C"),
                       Atom(coord: SIMD3(1.5, 0, 0), atomicNumber: 6, label: "C")]

        scene.anaglyphMode = .redCyan
        let redCyanHash = pixelHash(try render(scene: scene, dist: 8))

        scene.anaglyphMode = .greenMagenta
        let greenMagentaHash = pixelHash(try render(scene: scene, dist: 8))

        XCTAssertNotEqual(redCyanHash, greenMagentaHash,
                          "greenMagenta must differ from redCyan")
        }

        // --- merged (isolated scope) ---
        do {

        let scene = Scene()
        // Empty scene with anaglyph on must not crash — it falls back to a
        // single-view render.
        var s = scene
        s.anaglyphMode = .redCyan
        XCTAssertNoThrow(try render(scene: s, dist: 8, w: 64, h: 64),
                         "empty scene with anaglyph must render without crashing")
        }
}

    // MARK: - State round-trip

    func testBackgroundStereoStatePersistence() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let sourceURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        var scene = Scene(loaded: try Parser.load(sourceURL))
        scene.backgroundType = .image
        scene.backgroundImagePath = "/tmp/my-background.png"
        scene.anaglyphMode = .redCyan

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-bgstereo-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try StateStore.save(scene, camera: nil, sourceURL: sourceURL, to: tmp)

        var loaded = Scene()
        var loadedCamera: Camera? = nil
        try StateStore.load(into: &loaded, camera: &loadedCamera, from: tmp)

        XCTAssertEqual(loaded.backgroundType, .image)
        XCTAssertEqual(loaded.backgroundImagePath, "/tmp/my-background.png")
        XCTAssertEqual(loaded.anaglyphMode, .redCyan)
    
        // --- merged (isolated scope) ---
        do {

        // A backgroundImagePath pointing to a nonexistent file must NOT fail the
        // load — the renderer falls back to solid/gradient.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-bgstereo-missing-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "backgroundType": "image",
            "backgroundImagePath": "/nonexistent/path/does-not-exist.png",
            "anaglyphMode": 1,
        ]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var scene = Scene()
        var camera: Camera? = nil
        XCTAssertNoThrow(try StateStore.load(into: &scene, camera: &camera, from: tmp))
        XCTAssertEqual(scene.backgroundType, .image)
        XCTAssertEqual(scene.backgroundImagePath, "/nonexistent/path/does-not-exist.png")
        XCTAssertEqual(scene.anaglyphMode, .redCyan)
        }

        // --- merged (isolated scope) ---
        do {

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-bgstereo-emptypath-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "backgroundImagePath": "",
        ]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var scene = Scene()
        var camera: Camera? = nil
        XCTAssertNoThrow(try StateStore.load(into: &scene, camera: &camera, from: tmp))
        XCTAssertNil(scene.backgroundImagePath, "empty path must decode to nil")
        }

        // --- merged (isolated scope) ---
        do {

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mvis-bgstereo-badmode-\(UUID().uuidString).mvis-state")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "anaglyphMode": 99,
        ]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var scene = Scene()
        var camera: Camera? = nil
        XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera, from: tmp),
                             "invalid anaglyphMode must fail the load")
        }
}

    // MARK: - State sync through controller

    // MARK: - Background image rendering

    func testBackgroundImageRendering() throws {
        let imagePath = try makeTempPNG(r: 200, g: 50, b: 50)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: imagePath)) }

        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]

        // Solid background render.
        let solidHash = pixelHash(try render(scene: scene, dist: 6))

        // Image background render.
        scene.backgroundType = .image
        scene.backgroundImagePath = imagePath
        let imageHash = pixelHash(try render(scene: scene, dist: 6))

        XCTAssertNotEqual(solidHash, imageHash,
                          "image background must produce a different frame than solid")
    
        // --- merged (isolated scope) ---
        do {

        var scene = Scene()
        scene.background = "#101014"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]

        // Solid background render.
        let solidHash = pixelHash(try render(scene: scene, dist: 6))

        // Image background with a missing path must fall back to solid.
        scene.backgroundType = .image
        scene.backgroundImagePath = "/nonexistent/missing-image.png"
        let missingHash = pixelHash(try render(scene: scene, dist: 6))

        XCTAssertEqual(solidHash, missingHash,
                       "missing image path must fall back to solid background")
        }

        // --- merged (isolated scope) ---
        do {

        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let sourceURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        let scene = Scene(loaded: try Parser.load(sourceURL))
        let controller = MainWindowController(scene: scene, showWindow: false)

        controller.state.backgroundType = .image
        controller.state.backgroundImagePath = "/tmp/test-image.png"
        controller.state.anaglyphMode = .greenMagenta

        // onChange → syncFromState propagates to the scene.
        XCTAssertEqual(controller.scene.backgroundType, .image)
        XCTAssertEqual(controller.scene.backgroundImagePath, "/tmp/test-image.png")
        XCTAssertEqual(controller.scene.anaglyphMode, .greenMagenta)

        // syncFromScene mirrors back.
        controller.scene.anaglyphMode = .redCyan
        controller.scene.backgroundImagePath = "/tmp/other.png"
        controller.state.syncFromScene(controller.scene)
        XCTAssertEqual(controller.state.anaglyphMode, .redCyan)
        XCTAssertEqual(controller.state.backgroundImagePath, "/tmp/other.png")
        }
}

    // MARK: - Anaglyph rendering

    // MARK: - Anaglyph orientation regression

    /// Read a texture's pixels into a [UInt8] RGBA buffer.
    private func readPixels(_ texture: MTLTexture) -> [UInt8] {
        let width = texture.width
        let height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    /// Count pixels whose summed RGB absolute difference exceeds the threshold.
    private func pixelDiffCount(_ a: [UInt8], _ b: [UInt8], threshold: UInt8 = 30) -> Int {
        XCTAssertEqual(a.count, b.count)
        var count = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let dr = abs(Int(a[i]) - Int(b[i]))
            let dg = abs(Int(a[i + 1]) - Int(b[i + 1]))
            let db = abs(Int(a[i + 2]) - Int(b[i + 2]))
            if dr + dg + db > Int(threshold) {
                count += 1
            }
        }
        return count
    }

    /// Vertically flip a pixel buffer (height rows reversed).
    private func verticallyFlip(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        var flipped = [UInt8](repeating: 0, count: pixels.count)
        let rowBytes = width * 4
        for y in 0..<height {
            let srcOffset = y * rowBytes
            let dstOffset = (height - 1 - y) * rowBytes
            flipped[dstOffset..<dstOffset + rowBytes] = pixels[srcOffset..<srcOffset + rowBytes]
        }
        return flipped
    }

    /// Regression test: the anaglyph merge quad must NOT be vertically flipped.
    /// Renders a fixture scene with anaglyph off and with redCyan, then asserts
    /// that the merged output is closer to the same-orientation off render than
    /// to the vertically-flipped off render. (Parallax at 3% separation only
    /// shifts a small fraction of pixels, so the bulk of the frame matches.)
    func testAnaglyphMergeOrientationIsNotFlipped() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let sourceURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        var scene = Scene(loaded: try Parser.load(sourceURL))
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false

        let w = 320, h = 320
        scene.anaglyphMode = .off
        let offPixels = readPixels(try render(scene: scene, dist: 14, w: w, h: h))

        scene.anaglyphMode = .redCyan
        let anaglyphPixels = readPixels(try render(scene: scene, dist: 14, w: w, h: h))

        let sameOrientationDiff = pixelDiffCount(offPixels, anaglyphPixels)
        let flipped = verticallyFlip(anaglyphPixels, width: w, height: h)
        let flippedDiff = pixelDiffCount(offPixels, flipped)

        // The merged output must be closer to the correct orientation than to
        // the flipped one. The anaglyph channel separation itself creates large
        // pixel differences (red from left eye, cyan from right), so the
        // orientation signal is a fraction of the total — require same-orientation
        // to be at least 15% better than flipped (a flipped merge would score
        // worse, not better).
        XCTAssertLessThan(sameOrientationDiff, flippedDiff,
                          "anaglyph merge must not be vertically flipped (same-orientation diff=\(sameOrientationDiff) vs flipped diff=\(flippedDiff))")
        XCTAssertLessThan(Double(sameOrientationDiff) * 1.15, Double(flippedDiff),
                          "same-orientation must be clearly better than flipped (same=\(sameOrientationDiff), flipped=\(flippedDiff))")
    }
}

private enum TestError: Error { case noGPU, noTexture }
