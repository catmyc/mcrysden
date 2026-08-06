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
}

private enum TestError: Error { case noGPU, noTexture }
