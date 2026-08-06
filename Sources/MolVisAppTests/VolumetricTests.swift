import XCTest
import Metal
import simd
@testable import MolVisApp

/// Consolidated volumetric coverage: clipTriangles straddle/keep-side + clip-plane
/// structure culling, and the composited color-plane render.
final class VolumetricTests: XCTestCase {

    private enum Thrown: Error { case noGPU, noTex }

    // MARK: - Colormap transfer + contour levels

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

    // MARK: - Helpers

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
