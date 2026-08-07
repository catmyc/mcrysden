import XCTest
import Metal
import simd
@testable import MolVisApp

private enum Thrown: Error { case noGPU, noTex }

final class RendererTests: XCTestCase {

    // Baseline render coverage: a successful encode must put foreground geometry
    // into a readable Metal target, including the alternate space-fill radius
    // path, instancing must preserve atom positions (a wider footprint and a
    // different framebuffer than a one-atom scene), the headless PNG export path
    // must produce foreground pixels through both the default and MSAA-resolve
    // paths, and displacement arrows must alter the exported PNG in both 3D and
    // 2D display modes while being suppressed when the structure is hidden.
    func testRendererGeometryHeadlessExportAndDisplacementArrows() throws {
        // MARK: - Distinct drawable geometry (ball-stick, space-fill, instancing)
        do {
            var scene = Scene()
            scene.background = "#000000"
            scene.showAxes = false
            scene.showCellFrame = false
            scene.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]

            let ballStick = try render(scene: scene, dist: 6)
            XCTAssertGreaterThan(nonzeroPixels(ballStick), 0, "nothing rendered")

            var spaceFill = scene
            spaceFill.displayMode = .spaceFill
            spaceFill.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
                               Atom(coord: SIMD3(1.5, 0, 0), atomicNumber: 6, label: "C")]
            let spaceFillImage = try render(scene: spaceFill, dist: 8)
            XCTAssertGreaterThan(nonzeroPixels(spaceFillImage), 0,
                                 "space-fill geometry must render through the same Metal path")

            // Instancing must preserve atom positions: two atoms must occupy a wider
            // footprint and a different framebuffer than a one-atom scene.
            var one = Scene()
            one.background = "#000000"
            one.showAxes = false
            one.showCellFrame = false
            one.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]

            var two = one
            two.atoms = [Atom(coord: SIMD3(-2, 0, 0), atomicNumber: 6, label: "C"),
                         Atom(coord: SIMD3(2, 0, 0), atomicNumber: 6, label: "C")]

            let oneImage = try render(scene: one, dist: 10, w: 160, h: 160)
            let twoImage = try render(scene: two, dist: 10, w: 160, h: 160)
            let (minColumn, maxColumn) = nonzeroColumns(twoImage)
            XCTAssertGreaterThan(maxColumn - minColumn, 30,
                                 "two atoms should render as separate instances")
            XCTAssertNotEqual(pixelHash(oneImage), pixelHash(twoImage),
                              "moving/adding an atom must change the rendered geometry")
        }

        // MARK: - Headless PNG export (default + MSAA resolve)
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
            let renderer = try Renderer(device: device)
            var scene = Scene()

            func highestSupported(_ req: Int) -> Int {
                [8, 4, 2].first { $0 <= req && device.supportsTextureSampleCount($0) } ?? 1
            }

            scene.msaaSampleCount = 4
            renderer.scene = scene
            renderer.msaaSampleCount = nil
            XCTAssertEqual(renderer.effectiveMSAACount, highestSupported(4),
                           "scene value must drive effective live count to highest supported <= request")

            renderer.msaaSampleCount = 4
            scene.msaaSampleCount = 2
            renderer.scene = scene
            XCTAssertEqual(renderer.effectiveMSAACount, highestSupported(4),
                           "explicit override must take precedence over scene value")

            scene.msaaSampleCount = 1
            renderer.scene = scene
            renderer.msaaSampleCount = nil
            XCTAssertEqual(renderer.effectiveMSAACount, 1,
                           "count 1 must remain 1")

            renderer.msaaSampleCount = 8
            let capped = renderer.effectiveMSAACount
            XCTAssertLessThanOrEqual(capped, 8, "effective count must not exceed request")
            XCTAssertTrue([1, 2, 4, 8].contains(capped),
                          "effective count must be a supported sample count")
            XCTAssertEqual(capped, highestSupported(8),
                           "effective count must be highest supported <= request")

            let fixtureDirectory = URL(fileURLWithPath: #file).deletingLastPathComponent()
            let fixture = fixtureDirectory.appendingPathComponent("Fixtures/si110.xsf")
            scene = Scene(loaded: try Parser.load(fixture))
            scene.background = "#000000"
            scene.showAxes = false
            scene.showCellFrame = false

            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("renderer-\(UUID().uuidString).png")
            let image = try PngExporter.export(scene: scene, camera: nil, to: output,
                                               size: CGSize(width: 400, height: 400))
            XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
            XCTAssertGreaterThan(foregroundPixels(image), 0,
                                 "exported PNG must contain foreground pixels")

            // MSAA export: an explicit sample count override must render a valid
            // frame with foreground pixels through the multisample-resolve path.
            let msaaOutput = FileManager.default.temporaryDirectory
                .appendingPathComponent("renderer-msaa-\(UUID().uuidString).png")
            let msaaImage = try PngExporter.export(scene: scene, camera: nil, to: msaaOutput,
                                                   size: CGSize(width: 400, height: 400),
                                                   options: RenderExportOptions(msaaSampleCount: 4))
            XCTAssertGreaterThan(try msaaOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
            XCTAssertGreaterThan(foregroundPixels(msaaImage), 0,
                                 "MSAA-exported PNG must contain foreground pixels")

            // Displacement-arrow export regression: enabling displacement arrows
            // through RenderExportOptions must alter the rendered PNG pixels.
            scene.showAxes = false
            scene.showCellFrame = true
            scene.atoms = [
                Atom(coord: SIMD3(-3, 0, 0), atomicNumber: 6, label: "C"),
                Atom(coord: SIMD3(3, 0, 0), atomicNumber: 6, label: "C"),
            ]
            let noArrowsOutput = FileManager.default.temporaryDirectory
                .appendingPathComponent("renderer-noarrows-\(UUID().uuidString).png")
            let noArrowsImage = try PngExporter.export(scene: scene, camera: nil, to: noArrowsOutput,
                                                       size: CGSize(width: 400, height: 400))
            let noArrowsHash = pixelHash(noArrowsImage)
            let arrowsOutput = FileManager.default.temporaryDirectory
                .appendingPathComponent("renderer-arrows-\(UUID().uuidString).png")
            let arrowsImage = try PngExporter.export(scene: scene, camera: nil, to: arrowsOutput,
                                                    size: CGSize(width: 400, height: 400),
                                                    options: RenderExportOptions(
                                                        displacementArrows: [
                                                            (start: SIMD3(-3, 0, 0), vector: SIMD3<Float>(0, 2, 0)),
                                                            (start: SIMD3(3, 0, 0), vector: SIMD3<Float>(0, 2, 0)),
                                                        ],
                                                        showDisplacementArrows: true))
            let arrowsHash = pixelHash(arrowsImage)
            XCTAssertNotEqual(noArrowsHash, arrowsHash,
                              "enabling displacement arrows must alter the exported PNG")

            // 2D displacement-arrow regression: arrows must also render in 2D
            // display modes (still gated by showStructure), producing a pixel
            // difference versus arrows off.
            var twoDScene = Scene()
            twoDScene.showAxes = false
            twoDScene.showCellFrame = false
            twoDScene.showStructure = true
            twoDScene.displayMode = .line2D
            twoDScene.background = "#000000"
            twoDScene.atoms = [
                Atom(coord: SIMD3(-3, 0, 0), atomicNumber: 6, label: "C"),
                Atom(coord: SIMD3(3, 0, 0), atomicNumber: 6, label: "C"),
            ]
            twoDScene.cell = Cell(a: SIMD3(8, 0, 0), b: SIMD3(0, 8, 0), c: SIMD3(0, 0, 8))
            let twoDArrows = [(start: SIMD3<Float>(-3, 0, 0), vector: SIMD3<Float>(0, 2, 0)),
                              (start: SIMD3<Float>(3, 0, 0), vector: SIMD3<Float>(0, 2, 0))]
            let twoDNoArrowsImage = try PngExporter.export(scene: twoDScene, camera: nil,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("renderer-2d-noarrows-\(UUID().uuidString).png"),
                size: CGSize(width: 400, height: 400))
            let twoDNoArrowsHash = pixelHash(twoDNoArrowsImage)
            let twoDWithArrowsImage = try PngExporter.export(scene: twoDScene, camera: nil,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("renderer-2d-arrows-\(UUID().uuidString).png"),
                size: CGSize(width: 400, height: 400),
                options: RenderExportOptions(
                    displacementArrows: twoDArrows,
                    showDisplacementArrows: true))
            let twoDWithArrowsHash = pixelHash(twoDWithArrowsImage)
            XCTAssertNotEqual(twoDNoArrowsHash, twoDWithArrowsHash,
                              "displacement arrows must alter the 2D exported PNG")
            // Hidden structure must suppress arrows even when the toggle is on:
            twoDScene.showStructure = false
            let twoDHiddenWithArrowsImage = try PngExporter.export(scene: twoDScene, camera: nil,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("renderer-2d-hidden-on-\(UUID().uuidString).png"),
                size: CGSize(width: 400, height: 400),
                options: RenderExportOptions(
                    displacementArrows: twoDArrows,
                    showDisplacementArrows: true))
            let twoDHiddenNoArrowsImage = try PngExporter.export(scene: twoDScene, camera: nil,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("renderer-2d-hidden-off-\(UUID().uuidString).png"),
                size: CGSize(width: 400, height: 400))
            XCTAssertEqual(pixelHash(twoDHiddenWithArrowsImage), pixelHash(twoDHiddenNoArrowsImage),
                           "hidden structure must suppress displacement arrows")
        }
    }

    // MARK: - Orientation gizmo lighting regression
    //
    // The orientation gizmo must be lit from the same lighting basis as the
    // main scene. The gizmo renders in camera space (view = identity), with
    // arrows pointing along `dir = R^T * axis` (the camera-space direction of
    // each world axis). A naive `rotation(fromYTo: dir)` rotates the cylinder's
    // +Y to `dir`, but the resulting surface normals are
    // `rot(Y->dir) * n_local`, which do NOT match the main scene's
    // `R^T * rot(Y->axis) * n_local` in general — rotation composition does not
    // commute with `R^T`. The mismatch makes the gizmo's diffuse shading
    // disagree with the structure's: the dark side appears to rotate with the
    // arrow instead of staying viewer-fixed.
    //
    // `gizmoArrowRotation(worldToView:dir:)` pre-composes with `R^T` so the
    // arrow still points along `dir` (since `R^T * axis = dir`), but the
    // normals become `R^T * rot(Y->axis) * n_local`, whose dot product with the
    // camera-space light `viewLight` equals the main scene's
    // `dot(rot(Y->axis)*n_local, R * viewLight)`. This test verifies that
    // equality across camera rotations, world axes, and lighting directions.
    // It FAILS if `gizmoArrowRotation` reverts to the naive `rot(Y->dir)`.
    func testGizmoArrowLightingMatchesMainScene() {
        struct LightCfg { let name: String; let az: Float; let el: Float }
        struct RotCfg { let name: String; let q: simd_quatf }
        let rotations: [RotCfg] = [
            RotCfg(name: "identity", q: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)),
            RotCfg(name: "90Y", q: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))),
            RotCfg(name: "180Y", q: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))),
            RotCfg(name: "45X", q: simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(1, 0, 0))),
            RotCfg(name: "arb", q: simd_quatf(angle: 1.2, axis: normalize(SIMD3<Float>(1, 2, 3)))),
        ]
        let lightings: [LightCfg] = [
            LightCfg(name: "front", az: 0, el: 45),
            LightCfg(name: "side", az: 90, el: 30),
            LightCfg(name: "back", az: 180, el: 60),
            LightCfg(name: "high", az: 45, el: 75),
        ]
        let axes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        // Local normals on the cylinder surface (perpendicular to the cylinder's
        // local +Y axis). These exercise the full range of surface orientations.
        let localNormals: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(-1, 0, 0), SIMD3(0, 0, -1),
            normalize(SIMD3<Float>(1, 0, 1)), normalize(SIMD3<Float>(1, 0, -1)),
        ]

        for rot in rotations {
            let R = float4x4(rot.q)
            let worldToView = R.transpose
            for light in lightings {
                // Camera-space light direction — same formula as Renderer.makeFrame.
                let azRad = light.az * .pi / 180
                let elRad = light.el * .pi / 180
                let cel = cos(elRad)
                let viewLight = SIMD3<Float>(cel * cos(azRad), cel * sin(azRad), sin(elRad))
                // Main scene's world-space light: L_world = R * viewLight.
                let L_world = (R * SIMD4<Float>(viewLight, 0)).xyz
                for axis in axes {
                    let dir = (worldToView * SIMD4<Float>(axis, 0)).xyz
                    let gizmoRot = Renderer.gizmoArrowRotation(worldToView: worldToView, dir: dir)

                    // The gizmo arrow must still point along dir.
                    let gizmoDir = (gizmoRot * SIMD4<Float>(0, 1, 0, 0)).xyz
                    XCTAssertEqual(gizmoDir.x, dir.x, accuracy: 1e-5,
                        "\(rot.name)/\(light.name)/axis\(axis): dir.x")
                    XCTAssertEqual(gizmoDir.y, dir.y, accuracy: 1e-5,
                        "\(rot.name)/\(light.name)/axis\(axis): dir.y")
                    XCTAssertEqual(gizmoDir.z, dir.z, accuracy: 1e-5,
                        "\(rot.name)/\(light.name)/axis\(axis): dir.z")

                    // Main scene's arrow rotation for the same world axis.
                    let mainRot = float4x4.rotation(fromYTo: axis)
                    for nLocal in localNormals {
                        let gizmoNormal = (gizmoRot * SIMD4<Float>(nLocal, 0)).xyz
                        let mainNormal = (mainRot * SIMD4<Float>(nLocal, 0)).xyz
                        // Shader diffuse = max(dot(N, L), 0).
                        let gizmoDiffuse = max(dot(gizmoNormal, viewLight), 0)
                        let mainDiffuse = max(dot(mainNormal, L_world), 0)
                        XCTAssertEqual(gizmoDiffuse, mainDiffuse, accuracy: 1e-5,
                            "\(rot.name)/\(light.name)/axis\(axis)/n\(nLocal): gizmo \(gizmoDiffuse) != main \(mainDiffuse)")
                    }
                }
            }
        }
    }

    // MARK: - Shared render helpers

    private func foregroundPixels(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] != 0 || pixels[index + 1] != 0 || pixels[index + 2] != 0 {
                count += 1
            }
        }
    }

    private func render(scene: Scene, dist: Float,
                        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                        w: Int = 96, h: Int = 96,
                        coordinationNumbers: [Int] = [],
                        showCoordinationColors: Bool = false) throws -> MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let renderer = try Renderer(device: device)
        renderer.scene = scene
        renderer.coordinationNumbers = coordinationNumbers
        renderer.showCoordinationColors = showCoordinationColors
        renderer.currentCamera.distance = dist
        renderer.currentCamera.rotation = rotation

        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = w
        descriptor.height = h
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Thrown.noTex }
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

    private func pixelHash(_ image: CGImage) -> UInt64 {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.reduce(into: UInt64(0xcbf29ce484222325)) { hash, byte in
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
    }

    private func nonzeroPixels(_ texture: MTLTexture) -> Int {
        let width = texture.width
        let height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] != 0 || pixels[index + 1] != 0 || pixels[index + 2] != 0 {
                count += 1
            }
        }
    }

    private func nonzeroColumns(_ texture: MTLTexture) -> (minC: Int, maxC: Int) {
        let width = texture.width
        let height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var minimum = width
        var maximum = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if pixels[index] != 0 || pixels[index + 1] != 0 || pixels[index + 2] != 0 {
                    minimum = min(minimum, x)
                    maximum = max(maximum, x)
                }
            }
        }
        return (minimum, maximum)
    }

    private func wtx(_ width: Int, _ height: Int) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return descriptor
    }
}
