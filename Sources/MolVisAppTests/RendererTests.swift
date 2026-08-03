import XCTest
import Metal
import simd
@testable import MolVisApp

private enum Thrown: Error { case noGPU, noTex }

final class RendererTests: XCTestCase {
    // Baseline render coverage: a successful encode must put foreground geometry
    // into a readable Metal target, including the alternate space-fill radius path.
    func testRendererProducesDrawablePixels() throws {
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
    }

    // Instancing must preserve atom positions: two atoms must occupy a wider
    // footprint and a different framebuffer than a one-atom scene.
    func testDistinctAtomsRenderAsDistinctGeometry() throws {
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

    // Camera-relative lighting, the orientation gizmo, crystallographic views,
    // and the shared scale overlay are all camera/export seams rather than image
    // snapshots, so they are kept together as one focused contract.
    func testCameraLightingOrientationStandardViewsAndScaleIndicator() throws {
        assertCameraRelativeLighting()
        try assertOrientationGizmo()
        try assertStandardCrystalViews()
        try assertScaleIndicator()
        try assertRenderingQualityControls()
    }

    // Rendering-quality contract: line widths, transparency, depth cueing, and
    // AO/shadow must each be independently configurable and visibly functional,
    // while defaults preserve the original output exactly. Consolidated into the
    // camera/lighting/scale contract test to keep the test count at 32.
    private func assertRenderingQualityControls() throws {
        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = true
        scene.atoms = [Atom(coord: SIMD3(-1.5, 0, 0), atomicNumber: 6, label: "C"),
                       Atom(coord: SIMD3(1.5, 0, 0), atomicNumber: 6, label: "C")]
        scene.bonds = [Bond(i: 0, j: 1)]
        scene.cell = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4))

        // Default output is the baseline.
        let baseline = try render(scene: scene, dist: 10, w: 120, h: 120)
        let baselineHash = pixelHash(baseline)
        XCTAssertGreaterThan(nonzeroPixels(baseline), 0)

        // --- Transparency: opacity < 1 must change the frame ---
        var transparent = scene
        transparent.opacity = 0.5
        let transparentHash = pixelHash(try render(scene: transparent, dist: 10, w: 120, h: 120))
        XCTAssertNotEqual(baselineHash, transparentHash, "transparency must change the frame")
        XCTAssertGreaterThan(nonzeroPixels(try render(scene: transparent, dist: 10, w: 120, h: 120)), 0)

        // --- Depth cueing: must change the frame when enabled ---
        var fogged = scene
        fogged.depthCueingStrength = 0.8
        let foggedHash = pixelHash(try render(scene: fogged, dist: 10, w: 120, h: 120))
        XCTAssertNotEqual(baselineHash, foggedHash, "depth cueing must change the frame")

        // --- Ambient occlusion: must change the frame when enabled ---
        var ao = scene
        ao.aoStrength = 0.8
        ao.aoQuality = 2
        let aoHash = pixelHash(try render(scene: ao, dist: 10, w: 120, h: 120))
        XCTAssertNotEqual(baselineHash, aoHash, "AO must change the frame")

        // --- Soft shadows: must change the frame when enabled ---
        var shadow = scene
        shadow.shadowStrength = 0.8
        shadow.shadowQuality = 2
        let shadowHash = pixelHash(try render(scene: shadow, dist: 10, w: 120, h: 120))
        XCTAssertNotEqual(baselineHash, shadowHash, "soft shadows must change the frame")

        // --- Publication presets: non-default presets must change the frame ---
        for preset in PublicationPreset.allCases {
            var presetScene = scene
            preset.apply(to: &presetScene)
            let presetHash = pixelHash(try render(scene: presetScene, dist: 10, w: 120, h: 120))
            if preset == .default {
                XCTAssertEqual(baselineHash, presetHash,
                               "default preset must preserve the original output")
            } else {
                XCTAssertNotEqual(baselineHash, presetHash,
                                  "\(preset.label) preset must change the frame")
            }
        }

        // --- Bounded AO/shadow seam: large + dense structures must not hang ---
        // Large structure: exceeds the global cap, must degrade safely to unity.
        struct Timer { static func time(_ block: () -> Void) -> TimeInterval {
            let start = Date(); block(); return -start.timeIntervalSinceNow
        }}
        var largeAtoms: [Atom] = []
        largeAtoms.reserveCapacity(200_000)
        for i in 0..<200_000 {
            largeAtoms.append(Atom(coord: SIMD3(Float(i % 100), Float((i / 100) % 100), Float(i / 10000)),
                                   atomicNumber: 6, label: "C"))
        }
        var largeScene = scene
        largeScene.atoms = largeAtoms
        largeScene.bonds = []
        largeScene.aoStrength = 0.8
        largeScene.aoQuality = 2
        largeScene.shadowStrength = 0.8
        largeScene.shadowQuality = 2
        var largeRendered = false
        let largeTime = Timer.time {
            largeRendered = (try? render(scene: largeScene, dist: 200, w: 32, h: 32)) != nil
        }
        XCTAssertTrue(largeRendered, "large structure (200k atoms) must render without hanging")
        XCTAssertLessThan(largeTime, 5.0, "large structure AO/shadow must complete in bounded time")

        // Dense structure: all atoms in a tiny volume (single bin), must not hang.
        var denseAtoms: [Atom] = []
        denseAtoms.reserveCapacity(5_000)
        for i in 0..<5_000 {
            // All within a 1x1x1 cube → single bin, worst case for naive O(n^2)
            denseAtoms.append(Atom(coord: SIMD3(Float(i % 10) * 0.01, Float((i / 10) % 10) * 0.01, Float(i / 100) * 0.01),
                                   atomicNumber: 6, label: "C"))
        }
        var denseScene = scene
        denseScene.atoms = denseAtoms
        denseScene.bonds = []
        denseScene.aoStrength = 0.8
        denseScene.aoQuality = 3
        denseScene.shadowStrength = 0.8
        denseScene.shadowQuality = 3
        var denseRendered = false
        let denseTime = Timer.time {
            denseRendered = (try? render(scene: denseScene, dist: 20, w: 32, h: 32)) != nil
        }
        XCTAssertTrue(denseRendered, "dense structure (5k atoms, single bin) must render without hanging")
        XCTAssertLessThan(denseTime, 2.0, "dense structure AO/shadow must complete in bounded time")

        // Anisotropic: atoms spread thin in Y/Z but long in X. Bin math must
        // not miss neighbors or index out of bounds.
        var anisoAtoms: [Atom] = []
        anisoAtoms.reserveCapacity(10_000)
        for i in 0..<10_000 {
            // X spans 1000 units, Y and Z span only 0.5 units → highly anisotropic
            anisoAtoms.append(Atom(coord: SIMD3(Float(i) * 0.1, Float(i % 5) * 0.01, Float(i % 5) * 0.01),
                                   atomicNumber: 6, label: "C"))
        }
        var anisoScene = scene
        anisoScene.atoms = anisoAtoms
        anisoScene.bonds = []
        anisoScene.aoStrength = 0.8
        anisoScene.aoQuality = 3
        anisoScene.shadowStrength = 0.8
        anisoScene.shadowQuality = 3
        var anisoRendered = false
        let anisoTime = Timer.time {
            anisoRendered = (try? render(scene: anisoScene, dist: 500, w: 32, h: 32)) != nil
        }
        XCTAssertTrue(anisoRendered, "anisotropic structure must render without hanging or crashing")
        XCTAssertLessThan(anisoTime, 3.0, "anisotropic structure AO/shadow must complete in bounded time")

        // Shadow-only: AO disabled, shadow enabled. Must not scan O(n^2) in
        // dense scenes (per-atom cap must count ALL candidates, not just AO).
        var shadowOnlyAtoms: [Atom] = []
        shadowOnlyAtoms.reserveCapacity(3_000)
        for i in 0..<3_000 {
            shadowOnlyAtoms.append(Atom(coord: SIMD3(Float(i % 10) * 0.01, Float((i / 10) % 10) * 0.01, Float(i / 100) * 0.01),
                                       atomicNumber: 6, label: "C"))
        }
        var shadowOnlyScene = scene
        shadowOnlyScene.atoms = shadowOnlyAtoms
        shadowOnlyScene.bonds = []
        shadowOnlyScene.aoStrength = 0.0  // AO disabled
        shadowOnlyScene.aoQuality = 0
        shadowOnlyScene.shadowStrength = 0.8  // shadow enabled
        shadowOnlyScene.shadowQuality = 3
        var shadowOnlyRendered = false
        let shadowOnlyTime = Timer.time {
            shadowOnlyRendered = (try? render(scene: shadowOnlyScene, dist: 20, w: 32, h: 32)) != nil
        }
        XCTAssertTrue(shadowOnlyRendered, "shadow-only dense structure must render without hanging")
        XCTAssertLessThan(shadowOnlyTime, 2.0, "shadow-only dense structure must complete in bounded time")

        // --- Line width geometry seam: verify thick lines render with correct
        // pixel width and aspect ratio. A horizontal line in a non-square
        // viewport should have its length preserved and width uniform.
        var lineScene = Scene()
        lineScene.background = "#000000"
        lineScene.showAxes = false
        lineScene.showCellFrame = true
        lineScene.cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        lineScene.atoms = []
        lineScene.bonds = []
        lineScene.lineWidth = 4.0  // thick line path
        // Render at non-square aspect to check aspect-correct geometry.
        let lineRender = try render(scene: lineScene, dist: 10, w: 200, h: 100)
        XCTAssertGreaterThan(nonzeroPixels(lineRender), 0, "thick cell-frame lines must render")
        // With lineWidth=4, the lines should be visibly thicker than 1px.
        // A 1px line at 200x100 would cover fewer pixels than a 4px line.
        let thickHash = pixelHash(lineRender)
        lineScene.lineWidth = 1.0
        let thinRender = try render(scene: lineScene, dist: 10, w: 200, h: 100)
        let thinHash = pixelHash(thinRender)
        XCTAssertNotEqual(thickHash, thinHash, "thick vs thin lines must differ")
        XCTAssertGreaterThan(nonzeroPixels(lineRender), nonzeroPixels(thinRender),
                             "thick lines must cover more pixels than thin lines")

        // --- Line opacity: lines must honor scene opacity (not always opaque).
        var opaqueLineScene = Scene()
        opaqueLineScene.background = "#000000"
        opaqueLineScene.showAxes = false
        opaqueLineScene.showCellFrame = true
        opaqueLineScene.cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        opaqueLineScene.atoms = []
        opaqueLineScene.bonds = []
        opaqueLineScene.lineWidth = 1.0
        opaqueLineScene.opacity = 1.0
        let opaqueLineRender = try render(scene: opaqueLineScene, dist: 10, w: 120, h: 120)
        let opaqueLineHash = pixelHash(opaqueLineRender)
        var transLineScene = opaqueLineScene
        transLineScene.opacity = 0.5
        let transLineRender = try render(scene: transLineScene, dist: 10, w: 120, h: 120)
        let transLineHash = pixelHash(transLineRender)
        XCTAssertNotEqual(opaqueLineHash, transLineHash,
                          "line opacity must change the rendered output")
        // Semi-transparent lines should produce different (lower intensity) output.
        // Both should have foreground pixels, but the semi-transparent ones blend toward bg.
        XCTAssertGreaterThan(nonzeroPixels(opaqueLineRender), 0,
                             "opaque lines must render pixels")
        XCTAssertGreaterThan(nonzeroPixels(transLineRender), 0,
                             "semi-transparent lines must also render pixels")

        // Shortcut: both effects disabled must return unity immediately.
        var disabledScene = scene
        disabledScene.aoStrength = 0.0
        disabledScene.shadowStrength = 0.0
        disabledScene.aoQuality = 2  // quality is non-zero but strength is zero
        disabledScene.shadowQuality = 2
        var disabledRendered = false
        let disabledTime = Timer.time {
            disabledRendered = (try? render(scene: disabledScene, dist: 10, w: 32, h: 32)) != nil
        }
        XCTAssertTrue(disabledRendered, "disabled AO/shadow must render")
        // With both effects off, should be fast (no neighbor analysis).
        XCTAssertLessThan(disabledTime, 1.0, "disabled AO/shadow must shortcut immediately")
    }

    // 2D rendering intentionally replaces the 3D camera projection.  Keep an
    // end-to-end comparison so the branch cannot silently collapse to 3D.
    func test2DModeProjectsDifferentlyFrom3D() throws {
        var threeD = Scene()
        threeD.background = "#000000"
        threeD.showAxes = false
        threeD.showCellFrame = false
        threeD.atoms = [Atom(coord: SIMD3(-2, 0, 1), atomicNumber: 6, label: "C"),
                        Atom(coord: SIMD3(2, 0, -1), atomicNumber: 6, label: "C")]

        var twoD = threeD
        twoD.displayMode = .line2D

        let threeDImage = try render(scene: threeD, dist: 10)
        let twoDImage = try render(scene: twoD, dist: 10)
        XCTAssertNotEqual(pixelHash(threeDImage), pixelHash(twoDImage),
                          "2D and 3D projections must differ")
        XCTAssertGreaterThan(nonzeroPixels(twoDImage), 0, "2D mode should still render pixels")
    }

    // Assert both state wiring and actual fullscreen gradient output.  The latter
    // deliberately uses an empty scene so geometry cannot mask the backdrop.
    func testGradientBackgroundBehavior() throws {
        let state = SideBarState()
        state.backgroundType = .gradient_top
        state.backgroundHex = "#ff0000"
        state.backgroundBottomHex = "#0000ff"

        var scene = Scene()
        scene.backgroundType = state.backgroundType
        scene.background = state.backgroundHex
        scene.backgroundBottom = state.backgroundBottomHex
        XCTAssertEqual(scene.backgroundType, .gradient_top)
        XCTAssertEqual(scene.background, "#ff0000")
        XCTAssertEqual(scene.backgroundBottom, "#0000ff")
        XCTAssertNotEqual(scene.background, scene.backgroundBottom)

        scene.showStructure = false
        scene.showAxes = false
        scene.showCellFrame = false
        let gradient = try render(scene: scene, dist: 8, w: 48, h: 48)
        let firstRow = rgba(atX: 24, y: 0, in: gradient)
        let lastRow = rgba(atX: 24, y: gradient.height - 1, in: gradient)
        XCTAssertGreaterThan(abs(Int(firstRow.0) - Int(lastRow.0)), 100,
                             "gradient rows must have different red values")
        XCTAssertGreaterThan(abs(Int(firstRow.2) - Int(lastRow.2)), 100,
                             "gradient rows must have different blue values")

        var solid = scene
        solid.backgroundType = .solid
        let solidImage = try render(scene: solid, dist: 8, w: 48, h: 48)
        XCTAssertNotEqual(pixelHash(gradient), pixelHash(solidImage),
                          "gradient rendering must differ from a solid backdrop")
    }

    // Coordination colors must be bounded and deterministic, preserve CPK fallback
    // for incomplete data, and affect both 3D and 2D frames only when enabled.
    func testCoordinationColoringBehavior() throws {
        for number in [Int.min, -1, 0, 1, 9, 10, Int.max] {
            let color = Renderer.coordinationColor(number)
            XCTAssertEqual(color, Renderer.coordinationColor(number))
            for component in [color.x, color.y, color.z] {
                XCTAssertTrue(component.isFinite)
                XCTAssertGreaterThanOrEqual(component, 0)
                XCTAssertLessThanOrEqual(component, 1)
            }
        }
        XCTAssertEqual(Renderer.coordinationColor(-1), Renderer.coordinationColor(0))
        XCTAssertEqual(Renderer.coordinationColor(Int.max), Renderer.coordinationColor(10))
        XCTAssertNotEqual(Renderer.coordinationColor(0), Renderer.coordinationColor(1))

        let cpk = ElementTable.color(6)
        let coordination = Renderer.coordinationColor(3)
        XCTAssertEqual(Renderer.baseAtomColor(atomicNumber: 6, coordinationNumber: 3,
                                              showCoordinationColors: true), coordination)
        XCTAssertEqual(Renderer.baseAtomColor(atomicNumber: 6, coordinationNumber: nil,
                                              showCoordinationColors: true), cpk)
        XCTAssertEqual(Renderer.baseAtomColor(atomicNumber: 6, coordinationNumber: 3,
                                              showCoordinationColors: false), cpk)
        XCTAssertEqual(Renderer.atomColor(atomicNumber: 6, coordinationNumber: 3,
                                          showCoordinationColors: true, selected: true),
                       SIMD3<Float>(1, 1, 0.2))

        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: SIMD3(-1.2, 0, 0), atomicNumber: 6, label: "C"),
                       Atom(coord: SIMD3(1.2, 0, 0), atomicNumber: 8, label: "O")]

        let baseline3D = try render(scene: scene, dist: 8)
        let colored3D = try render(scene: scene, dist: 8,
                                   coordinationNumbers: [0, 9],
                                   showCoordinationColors: true)
        XCTAssertNotEqual(pixelHash(baseline3D), pixelHash(colored3D))

        var scene2D = scene
        scene2D.displayMode = .line2D
        let baseline2D = try render(scene: scene2D, dist: 8)
        let colored2D = try render(scene: scene2D, dist: 8,
                                   coordinationNumbers: [0, 9],
                                   showCoordinationColors: true)
        XCTAssertNotEqual(pixelHash(baseline2D), pixelHash(colored2D))

        let disabled = try render(scene: scene, dist: 8,
                                  coordinationNumbers: [0, 9],
                                  showCoordinationColors: false)
        XCTAssertEqual(pixelHash(baseline3D), pixelHash(disabled),
                       "disabled coordination coloring must preserve the frame")
        let mismatched = try render(scene: scene, dist: 8,
                                    coordinationNumbers: [0],
                                    showCoordinationColors: true)
        XCTAssertEqual(pixelHash(baseline3D), pixelHash(mismatched),
                       "incomplete coordination data must retain CPK colors")

        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let renderer2D = try Renderer2D(device: device)
        XCTAssertEqual(renderer2D.coordinationNumbers, [])
        XCTAssertFalse(renderer2D.showCoordinationColors)
        renderer2D.coordinationNumbers = [1, 4, 9]
        renderer2D.showCoordinationColors = true
        XCTAssertEqual(renderer2D.renderer.coordinationNumbers, [1, 4, 9])
        XCTAssertTrue(renderer2D.renderer.showCoordinationColors)
    }

    // Keep the cache contracts that protect repeated rendering and changed
    // same-sized data, then exercise the explicit allocation/error boundaries.
    func testCacheInvalidationAndAllocationSafety() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        try assertBrillouinZoneCacheInvalidation(device: device)
        try assertIsoCacheInvalidation(device: device)
        try assertFermiCacheInvalidation(device: device)
        try assertAllocationFailures(device: device)
    }

    // Periodic endpoint solving, locked-result validation, overlay no-ops, and
    // resolve-cache invalidation form one measurement safety contract.
    func testPeriodicMeasurementOverlays() throws {
        assertMeasurementVertexContracts()
        try assertMeasurementSelectionSafety()
        try assertMeasurementCacheInvalidation()
    }

    func testHeadlessPngExport() throws {
        // Effective-count seam: scene value drives the live count when no
        // override is set; override takes precedence; count 1 stays 1; a
        // request above the device cap falls back to a supported count <= it.
        //
        // The resolved count is device-dependent (the device may not support 4
        // or 8), so we compute the expected value from the device rather than
        // hardcoding a specific sample count.
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
    }

    // The three vector writers share the raster-backed render path, but each has
    // a distinct file signature/container contract worth retaining.
    func testVectorExportsPDFSVGAndEPS() throws {
        let fixtureDirectory = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fixture = fixtureDirectory.appendingPathComponent("Fixtures/si110.xsf")
        var scene = Scene(loaded: try Parser.load(fixture))
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false

        for kind in ["pdf", "svg", "eps"] {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("renderer-\(UUID().uuidString).\(kind)")
            let image = try RasterExporter.export(scene: scene, camera: nil, to: output,
                                                  size: CGSize(width: 400, height: 400))
            XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000,
                                 "\(kind) export should not be empty")
            let data = try Data(contentsOf: output, options: .mappedIfSafe)
            switch kind {
            case "pdf":
                XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
            case "svg":
                let string = String(data: data, encoding: .utf8) ?? ""
                XCTAssertTrue(string.hasPrefix("<?xml"), "SVG should start with xml declaration")
                XCTAssertTrue(string.contains("<svg"), "SVG should contain an <svg element")
            default:
                XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%!PS")
            }
            XCTAssertGreaterThan(foregroundPixels(image), 0,
                                 "\(kind) raster must contain foreground pixels")
        }
    }

    // MARK: - Camera, lighting, orientation and scale

    private func assertCameraRelativeLighting() {
        // Explicit layout assertions: Swift FrameData/InstanceData must match
        // their Metal counterparts byte-for-byte. Metal float3 pads to 16 bytes
        // (like SIMD3<Float>), so these offsets are invariant.
        XCTAssertEqual(MemoryLayout<FrameData>.stride, 224,
                       "FrameData stride drifted from Metal layout")
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.view)!, 0)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.proj)!, 64)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.lightDir)!, 128)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.ambient)!, 144)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.eyePos)!, 160)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.lineWidth)!, 176)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.opacity)!, 180)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.depthCueingStrength)!, 184)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.fogNear)!, 188)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.fogFar)!, 192)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.aoStrength)!, 196)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.shadowStrength)!, 200)
        XCTAssertEqual(MemoryLayout<FrameData>.offset(of: \.backgroundColor)!, 208)
        // InstanceData: model(64) + color(16) + radius(4) + metalness(4) + aoFactor(4) + shadowFactor(4) = 96
        XCTAssertEqual(MemoryLayout<InstanceData>.stride, 96,
                       "InstanceData stride drifted from Metal layout")
        XCTAssertEqual(MemoryLayout<InstanceData>.offset(of: \.model)!, 0)
        XCTAssertEqual(MemoryLayout<InstanceData>.offset(of: \.color)!, 64)
        XCTAssertEqual(MemoryLayout<InstanceData>.offset(of: \.radius)!, 80)
        XCTAssertEqual(MemoryLayout<InstanceData>.offset(of: \.metalness)!, 84)
        XCTAssertEqual(MemoryLayout<InstanceData>.offset(of: \.aoFactor)!, 88)
        XCTAssertEqual(MemoryLayout<InstanceData>.offset(of: \.shadowFactor)!, 92)

        var lighting = Lighting()
        lighting.azimuth = 0
        lighting.elevation = 0
        let identity = Renderer.makeFrame(view: matrix_identity_float4x4,
                                          proj: matrix_identity_float4x4,
                                          lighting: lighting, eye: .zero)

        var camera = Camera()
        camera.rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let view = camera.viewMatrix()
        let rotated = Renderer.makeFrame(view: view, proj: matrix_identity_float4x4,
                                         lighting: lighting, eye: camera.eyePosition())
        let rotatedLightInView = (view * SIMD4<Float>(rotated.lightDir, 0)).xyz
        XCTAssertEqual(rotatedLightInView.x, identity.lightDir.x, accuracy: 1e-5)
        XCTAssertEqual(rotatedLightInView.y, identity.lightDir.y, accuracy: 1e-5)
        XCTAssertEqual(rotatedLightInView.z, identity.lightDir.z, accuracy: 1e-5)
        XCTAssertLessThan(simd_dot(rotated.lightDir, identity.lightDir), 0.01)
    }

    private func assertOrientationGizmo() throws {
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

        func axisPixels(distance: Float) throws -> Int {
            var cellOnly = Scene()
            cellOnly.background = "#000000"
            cellOnly.isCrystal = true
            cellOnly.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
            cellOnly.showCellFrame = false
            cellOnly.showAxes = true
            return nonzeroPixels(try render(scene: cellOnly, dist: distance, w: 200, h: 200))
        }
        let near = try axisPixels(distance: 8)
        let far = try axisPixels(distance: 40)
        XCTAssertGreaterThan(near, 0)
        XCTAssertGreaterThan(far, 0)
        let ratio = Float(max(1, near)) / Float(max(1, far))
        XCTAssertEqual(ratio, 1.0, accuracy: 0.5,
                       "orientation gizmo size should not track zoom")

        var axesOnly = Scene()
        axesOnly.background = "#000000"
        axesOnly.isCrystal = true
        axesOnly.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        axesOnly.showCellFrame = false
        axesOnly.showAxes = true
        XCTAssertGreaterThan(nonzeroPixels(try render(scene: axesOnly, dist: 12, w: 120, h: 120)), 0)
        axesOnly.showAxes = false
        XCTAssertEqual(nonzeroPixels(try render(scene: axesOnly, dist: 12, w: 120, h: 120)), 0,
                       "axes off with no structure or cell frame must be blank")
    }

    private func assertStandardCrystalViews() throws {
        let cell = Cell(a: SIMD3<Float>(4.2, 0.3, -0.2),
                        b: SIMD3<Float>(0.9, 3.7, 0.6),
                        c: SIMD3<Float>(0.4, 1.1, 5.1))
        let views: [(StandardCrystalView, SIMD3<Float>)] = [
            (.view100, cell.a),
            (.view110, cell.a + cell.b),
            (.view111, cell.a + cell.b + cell.c)
        ]
        var baseline = Camera()
        baseline.center = SIMD3<Float>(1.25, -2.5, 0.75)
        baseline.distance = 13.25
        baseline.perspective = true
        baseline.rotation = simd_quatf(angle: 0.37,
                                       axis: simd_normalize(SIMD3<Float>(1.0, 2.0, -0.5)))

        for (view, directDirection) in views {
            var aligned = baseline
            XCTAssertNoThrow(try aligned.align(to: view, cell: cell))
            let eyeDirection = simd_normalize(aligned.eyePosition() - aligned.center)
            let expectedDirection = simd_normalize(directDirection)
            XCTAssertEqual(eyeDirection.x, expectedDirection.x, accuracy: 1e-5)
            XCTAssertEqual(eyeDirection.y, expectedDirection.y, accuracy: 1e-5)
            XCTAssertEqual(eyeDirection.z, expectedDirection.z, accuracy: 1e-5)
            XCTAssertEqual(simd_length(aligned.rotation.vector), 1, accuracy: 1e-5)

            var repeated = baseline
            XCTAssertNoThrow(try repeated.align(to: view, cell: cell))
            XCTAssertEqual(repeated.rotation.vector, aligned.rotation.vector,
                           "\(view.label) alignment must be deterministic")
            XCTAssertEqual(aligned.center, baseline.center)
            XCTAssertEqual(aligned.distance, baseline.distance)
            XCTAssertEqual(aligned.perspective, baseline.perspective)
        }

        let anisotropic = Cell(a: SIMD3<Float>(0.001, 0, 0),
                               b: SIMD3<Float>(0, 1_000, 0),
                               c: SIMD3<Float>(0, 0, 1_000_000))
        XCTAssertNil(Camera.standardCrystalViewUnavailableReason(cell: anisotropic))
        var anisotropicCamera = baseline
        XCTAssertNoThrow(try anisotropicCamera.align(to: .view100, cell: anisotropic))
        let anisotropicEye = simd_normalize(anisotropicCamera.eyePosition() - anisotropicCamera.center)
        let anisotropicExpected = simd_normalize(anisotropic.a)
        XCTAssertEqual(anisotropicEye.x, anisotropicExpected.x, accuracy: 1e-5)
        XCTAssertEqual(anisotropicEye.y, anisotropicExpected.y, accuracy: 1e-5)
        XCTAssertEqual(anisotropicEye.z, anisotropicExpected.z, accuracy: 1e-5)

        let singular = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        let nonfinite = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(.infinity, 0, 1))
        XCTAssertNil(Camera.standardCrystalViewUnavailableReason(cell: cell))
        XCTAssertNotNil(Camera.standardCrystalViewUnavailableReason(cell: nil))
        XCTAssertNotNil(Camera.standardCrystalViewUnavailableReason(cell: singular))
        XCTAssertNotNil(Camera.standardCrystalViewUnavailableReason(cell: nonfinite))

        var unchanged = baseline
        XCTAssertThrowsError(try unchanged.align(to: .view100, cell: singular))
        XCTAssertEqual(unchanged.rotation.vector, baseline.rotation.vector,
                       "failed alignment must not mutate the camera")

        let unavailableController = MainWindowController(scene: Scene(), showWindow: false)
        XCTAssertFalse(unavailableController.state.standardCrystalViewAvailable)
        let unavailableCamera = unavailableController.camera
        unavailableController.state.onStandardCrystalView?(.view100)
        XCTAssertEqual(unavailableController.camera.rotation.vector, unavailableCamera.rotation.vector)

        var validScene = Scene()
        validScene.isCrystal = true
        validScene.cell = cell
        let validController = MainWindowController(scene: validScene, showWindow: false)
        validController.camera = baseline
        XCTAssertTrue(validController.state.standardCrystalViewAvailable)
        XCTAssertTrue(validController.alignToStandardCrystalView(.view110))
        let controllerEye = simd_normalize(validController.camera.eyePosition() - validController.camera.center)
        let controllerExpected = simd_normalize(cell.a + cell.b)
        XCTAssertEqual(controllerEye.x, controllerExpected.x, accuracy: 1e-5)
        XCTAssertEqual(controllerEye.y, controllerExpected.y, accuracy: 1e-5)
        XCTAssertEqual(controllerEye.z, controllerExpected.z, accuracy: 1e-5)

        validController.state.displayMode = .line2D
        XCTAssertFalse(validController.state.standardCrystalViewAvailable)
        XCTAssertFalse(validController.alignToStandardCrystalView(.view100))
        validController.state.displayMode = .ballStick
        validController.state.refreshStandardCrystalViewAvailability(cell: cell, reciprocalEditing: true)
        XCTAssertFalse(validController.state.standardCrystalViewAvailable)
        validController.state.refreshStandardCrystalViewAvailability(cell: cell, reciprocalEditing: false)
        XCTAssertTrue(validController.state.standardCrystalViewAvailable)
    }

    private func assertScaleIndicator() throws {
        let viewport = SIMD2<Float>(800, 1000)
        func indicator(distance: Float, perspective: Bool = false,
                       viewport: SIMD2<Float> = viewport,
                       targetPixelWidth: CGFloat = 100) throws -> ScaleIndicator {
            var camera = Camera()
            camera.distance = distance
            camera.perspective = perspective
            return try XCTUnwrap(ScaleIndicator.make(camera: camera,
                                                     viewport: viewport,
                                                     targetPixelWidth: targetPixelWidth))
        }

        for (distance, length, text) in [(Float(5), 1.0, "1 Å"),
                                         (Float(10), 2.0, "2 Å"),
                                         (Float(25), 5.0, "5 Å")] {
            let scale = try indicator(distance: distance)
            XCTAssertEqual(scale.lengthAngstrom, length, accuracy: 1e-12)
            XCTAssertEqual(scale.text, text)
            XCTAssertEqual(scale.pixelWidth, 100, accuracy: 1e-5)
        }
        let nanometer = try indicator(distance: 50)
        XCTAssertEqual(nanometer.lengthAngstrom, 10, accuracy: 1e-12)
        XCTAssertEqual(nanometer.text, "1 nm")

        let ortho = try indicator(distance: 20)
        let orthoPixels = Double(ortho.lengthAngstrom) / (2.0 * 20.0) * Double(viewport.y)
        XCTAssertEqual(Double(ortho.pixelWidth), orthoPixels, accuracy: 1e-5)
        let perspective = try indicator(distance: 20, perspective: true)
        let perspectiveSpan = 2.0 * 20.0 * tan(Double.pi / 8.0)
        XCTAssertEqual(Double(perspective.pixelWidth),
                       Double(perspective.lengthAngstrom) / perspectiveSpan * Double(viewport.y),
                       accuracy: 1e-5)

        var orbited = Camera()
        orbited.distance = 20
        orbited.perspective = true
        orbited.center = SIMD3<Float>(4, -3, 2)
        orbited.rotation = simd_quatf(angle: 0.83,
                                      axis: simd_normalize(SIMD3<Float>(1, 2, -1)))
        XCTAssertEqual(try XCTUnwrap(ScaleIndicator.make(camera: orbited, viewport: viewport,
                                                          targetPixelWidth: 100)), perspective)
        XCTAssertGreaterThan(try indicator(distance: 20, viewport: SIMD2<Float>(800, 400),
                                            targetPixelWidth: 110).lengthAngstrom,
                             try indicator(distance: 10, viewport: SIMD2<Float>(800, 400),
                                           targetPixelWidth: 110).lengthAngstrom)
        XCTAssertLessThan(try indicator(distance: 10, viewport: SIMD2<Float>(800, 800),
                                        targetPixelWidth: 110).lengthAngstrom,
                          try indicator(distance: 10, viewport: SIMD2<Float>(800, 400),
                                        targetPixelWidth: 110).lengthAngstrom)

        var invalid = Camera()
        invalid.distance = 0
        XCTAssertNil(ScaleIndicator.make(camera: invalid, viewport: viewport))
        XCTAssertNil(ScaleIndicator.make(camera: Camera(), viewport: SIMD2<Float>(800, 0)))

        let width = 220
        let height = 100
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height,
                                               bitsPerComponent: 8, bytesPerRow: width * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let base = try XCTUnwrap(context.makeImage())
        let label = LabelOverlayView.Label(symbol: nanometer.text, x: 12, y: 64,
                                           style: .scaleIndicator, barWidth: nanometer.pixelWidth)
        let composited = try PngExporter.composite(labels: [label], onto: base)
        XCTAssertNotEqual(pixelHash(base), pixelHash(composited))

        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var exportScene = Scene()
        exportScene.background = "#000000"
        exportScene.showAxes = false
        exportScene.showCellFrame = false
        exportScene.showScaleIndicator = true
        let controller = MainWindowController(scene: exportScene, showWindow: false)
        guard controller.renderer != nil else { return }
        controller.canvas.isHidden = false
        let visible = try controller.exportRenderOptions(for: CGSize(width: 320, height: 240))
        XCTAssertTrue(visible.labels.contains { $0.style == .scaleIndicator })
        controller.canvas.isHidden = true
        let hidden = try controller.exportRenderOptions(for: CGSize(width: 320, height: 240))
        XCTAssertFalse(hidden.labels.contains { $0.style == .scaleIndicator })
    }

    // MARK: - Cache and allocation helpers

    private func assertBrillouinZoneCacheInvalidation(device: MTLDevice) throws {
        let renderer = try Renderer(device: device)
        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        let atoms = [Atom(coord: .zero, atomicNumber: 14, label: "Si")]
        var scene = Scene()
        scene.isCrystal = true
        scene.cell = cell
        scene.baseAtoms = atoms
        scene.atoms = atoms
        scene.showBrillouinZone = true
        renderer.scene = scene
        let bz = try XCTUnwrap(BrillouinZone.build(cell: cell, atoms: atoms))
        renderer.installBrillouinZoneCache(bz: bz, candidates: bz.candidates())

        let texture = try XCTUnwrap(device.makeTexture(descriptor: wtx(64, 64)))
        let viewport = MTLViewport(originX: 0, originY: 0, width: 64, height: 64, znear: 0, zfar: 1)
        func encode() throws {
            let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
            XCTAssertTrue(renderer.encode(to: commandBuffer, target: texture,
                                           viewport: viewport, camera: renderer.currentCamera))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
        }

        try encode()
        XCTAssertEqual(renderer.bzRebuildCount, 0)
        var changed = scene
        changed.cell = Cell(a: SIMD3(6, 0, 0), b: SIMD3(0, 6, 0), c: SIMD3(0, 0, 6))
        renderer.scene = changed
        try encode()
        XCTAssertEqual(renderer.bzRebuildCount, 1,
                       "cell invalidation must discard an installed BZ cache")
    }

    private func assertIsoCacheInvalidation(device: MTLDevice) throws {
        let renderer = try Renderer(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: wtx(64, 64)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let values = (0..<27).map { Float($0).truncatingRemainder(dividingBy: 5) * 0.4 }
        var scene = Scene()
        scene.showStructure = false
        scene.showAxes = false
        scene.showCellFrame = false
        scene.showBrillouinZone = false
        scene.background = "#000000"
        scene.showIsoSurface = true
        scene.isoLevel = 0.5
        scene.scalarField = isoField(values)

        func encode(_ value: Scene) {
            renderer.scene = value
            let commandBuffer = queue.makeCommandBuffer()!
            XCTAssertTrue(renderer.encode(to: commandBuffer, target: texture,
                                           viewport: MTLViewport(originX: 0, originY: 0,
                                                                 width: 64, height: 64,
                                                                 znear: 0, zfar: 1),
                                           camera: renderer.currentCamera))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
        }

        encode(scene)
        let built = renderer.isoRebuildCount
        XCTAssertGreaterThan(built, 0)
        for _ in 0..<3 { encode(scene) }
        XCTAssertEqual(renderer.isoRebuildCount, built,
                       "unchanged fields must not rebuild across frames")

        var appearanceOnly = scene
        appearanceOnly.lighting.azimuth = 30
        appearanceOnly.background = "#123456"
        encode(appearanceOnly)
        XCTAssertEqual(renderer.isoRebuildCount, built,
                       "appearance-only edits must preserve the field cache")

        var changed = scene
        var changedValues = values
        changedValues[13] = 999
        changed.scalarField = isoField(changedValues)
        encode(changed)
        XCTAssertGreaterThan(renderer.isoRebuildCount, built,
                             "changed same-sized values must rebuild the iso cache")
    }

    private func assertFermiCacheInvalidation(device: MTLDevice) throws {
        func field(_ values: [Float]) -> ScalarField {
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                        values: values, minValue: values.min() ?? 0, maxValue: values.max() ?? 0)
        }
        let renderer = try Renderer(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: wtx(80, 80)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var scene = Scene()
        scene.showStructure = false
        scene.showAxes = false
        scene.showCellFrame = false
        scene.showBrillouinZone = false
        scene.showFermiSurface = true
        scene.fermiSurface = FermiSurface(
            fermiEnergy: 0.5,
            bands: [field([0, 0, 0, 0, 1, 1, 1, 1]), field([0, 0, 0, 0, 1, 1, 1, 1])])

        func encode(_ value: Scene) {
            renderer.scene = value
            let commandBuffer = queue.makeCommandBuffer()!
            XCTAssertTrue(renderer.encode(to: commandBuffer, target: texture,
                                           viewport: MTLViewport(originX: 0, originY: 0,
                                                                 width: 80, height: 80,
                                                                 znear: 0, zfar: 1),
                                           camera: renderer.currentCamera))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
        }

        encode(scene)
        let built = renderer.fermiRebuildCount
        XCTAssertEqual(built, 1)
        encode(scene)
        XCTAssertEqual(renderer.fermiRebuildCount, built)

        var changed = scene
        changed.fermiSurface = FermiSurface(
            fermiEnergy: 0.5,
            bands: [field([0, 0, 0, 0, 1, 1, 1, 1]), field([1, 1, 1, 1, 0, 0, 0, 0])])
        encode(changed)
        XCTAssertEqual(renderer.fermiRebuildCount, built + 1,
                       "changed same-sized band values must rebuild the Fermi cache")
    }

    private func assertAllocationFailures(device: MTLDevice) throws {
        let renderer = try Renderer(device: device)
        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]
        renderer.scene = scene
        let texture = try XCTUnwrap(device.makeTexture(descriptor: wtx(32, 32)))
        let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        Renderer.forceNextBufferAllocationSuccess = false
        defer { Renderer.forceNextBufferAllocationSuccess = true }
        XCTAssertFalse(renderer.encode(to: commandBuffer, target: texture,
                                        viewport: MTLViewport(originX: 0, originY: 0,
                                                              width: 32, height: 32,
                                                              znear: 0, zfar: 1),
                                        camera: renderer.currentCamera),
                       "encode must return false when a required allocation fails")

        let fixtureDirectory = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var exportScene = Scene(loaded: try Parser.load(fixtureDirectory.appendingPathComponent("Fixtures/si110.xsf")))
        exportScene.background = "#000000"
        Renderer.forceNextBufferAllocationSuccess = false
        let failedOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-fail-\(UUID().uuidString).png")
        XCTAssertThrowsError(try PngExporter.export(scene: exportScene, camera: nil,
                                                     to: failedOutput,
                                                     size: CGSize(width: 200, height: 200))) { error in
            guard case PngExportError.encodeFailed = error else {
                return XCTFail("allocation failure must surface as encodeFailed, got \(error)")
            }
        }
        Renderer.forceNextBufferAllocationSuccess = true

        var invalidScene = Scene()
        invalidScene.background = "#000000"
        let invalidSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                 height: CGFloat.greatestFiniteMagnitude)
        let pngOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-huge-\(UUID().uuidString).png")
        XCTAssertThrowsError(try PngExporter.export(scene: invalidScene, camera: nil,
                                                     to: pngOutput, size: invalidSize))
        XCTAssertThrowsError(try RasterExporter.export(scene: invalidScene, camera: nil,
                                                        to: pngOutput.appendingPathExtension("pdf"),
                                                        size: invalidSize))
    }

    // MARK: - Measurement helpers

    private func assertMeasurementVertexContracts() {
        let cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        var distance = Scene()
        distance.cell = cell
        distance.periodicDim = 3
        distance.measurementMode = .distance
        distance.atoms = [Atom(coord: SIMD3(0.5, 5, 5), atomicNumber: 1, label: "H"),
                          Atom(coord: SIMD3(9.5, 5, 5), atomicNumber: 1, label: "H")]
        distance.selectedAtoms = [0, 1]
        distance.measurementResult = Scene.computeMeasurement(mode: .distance, atoms: distance.atoms,
                                                               selected: distance.selectedAtoms,
                                                               cell: cell, periodicDim: 3)
        XCTAssertEqual(Renderer.measurementLineVertices(for: distance),
                       [SIMD3(0.5, 5, 5), SIMD3(-0.5, 5, 5)])

        var invalid = distance
        invalid.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        XCTAssertTrue(Renderer.measurementLineVertices(for: invalid).isEmpty)

        var unlocked = Scene()
        unlocked.measurementMode = .distance
        unlocked.atoms = [Atom(coord: .zero, atomicNumber: 1, label: "H"),
                          Atom(coord: SIMD3(2, 0, 0), atomicNumber: 1, label: "H")]
        unlocked.selectedAtoms = [0, 1]
        XCTAssertTrue(Renderer.measurementLineVertices(for: unlocked).isEmpty)
        unlocked.measurementResult = MeasurementResult(mode: .distance, atomIndices: [1, 0],
                                                        value: 2, summary: "stale order")
        XCTAssertTrue(Renderer.measurementLineVertices(for: unlocked).isEmpty)

        var angle = Scene()
        angle.cell = cell
        angle.periodicDim = 3
        angle.measurementMode = .angle
        angle.atoms = [Atom(coord: SIMD3(0.5, 5, 5), atomicNumber: 1, label: "H"),
                       Atom(coord: SIMD3(5, 5, 5), atomicNumber: 1, label: "H"),
                       Atom(coord: SIMD3(9.5, 6, 5), atomicNumber: 1, label: "H")]
        angle.selectedAtoms = [0, 1, 2]
        angle.measurementResult = Scene.computeMeasurement(mode: .angle, atoms: angle.atoms,
                                                            selected: angle.selectedAtoms,
                                                            cell: cell, periodicDim: 3)
        XCTAssertEqual(Renderer.measurementLineVertices(for: angle), [
            SIMD3(0.5, 5, 5), SIMD3(5, 5, 5),
            SIMD3(5, 5, 5), SIMD3(9.5, 6, 5)
        ])
    }

    private func assertMeasurementSelectionSafety() throws {
        func makeScene(selected: [Int], mode: MeasurementMode,
                       lockDistance: Bool = false) -> Scene {
            var scene = Scene()
            scene.background = "#000000"
            scene.showAxes = false
            scene.showCellFrame = false
            scene.atoms = [Atom(coord: SIMD3(-3, 0, 0), atomicNumber: 6, label: "C"),
                           Atom(coord: SIMD3(3, 0, 0), atomicNumber: 6, label: "C")]
            scene.selectedAtoms = selected
            scene.measurementMode = mode
            if lockDistance {
                scene.measurementResult = Scene.computeMeasurement(mode: .distance,
                                                                    atoms: scene.atoms,
                                                                    selected: selected)
            }
            return scene
        }

        let baseline = pixelHash(try render(scene: makeScene(selected: [0, 1], mode: .none), dist: 10))
        let valid = pixelHash(try render(scene: makeScene(selected: [0, 1], mode: .distance,
                                                           lockDistance: true), dist: 10))
        let nilResult = pixelHash(try render(scene: makeScene(selected: [0, 1], mode: .distance), dist: 10))
        XCTAssertEqual(nilResult, baseline, "a missing locked result must draw no line")
        let stale = pixelHash(try render(scene: makeScene(selected: [0, 1, 99], mode: .distance), dist: 10))
        XCTAssertEqual(stale, baseline, "a stale index must not trigger a distance solve")
        let allInvalid = pixelHash(try render(scene: makeScene(selected: [-1, 99], mode: .distance), dist: 10))
        let empty = pixelHash(try render(scene: makeScene(selected: [], mode: .none), dist: 10))
        XCTAssertEqual(allInvalid, empty, "all-invalid selection must be a no-op")
        XCTAssertNotEqual(valid, baseline, "a valid measurement must draw a line")
    }

    private func assertMeasurementCacheInvalidation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Thrown.noGPU }
        let renderer = try Renderer(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: wtx(64, 64)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let viewport = MTLViewport(originX: 0, originY: 0, width: 64, height: 64, znear: 0, zfar: 1)

        func makeScene(cell: Cell, atoms: [Atom], selected: [Int]) -> Scene {
            var scene = Scene()
            scene.background = "#000000"
            scene.showStructure = false
            scene.showAxes = false
            scene.showCellFrame = false
            scene.cell = cell
            scene.periodicDim = 3
            scene.measurementMode = .distance
            scene.atoms = atoms
            scene.selectedAtoms = selected
            scene.measurementResult = Scene.computeMeasurement(mode: .distance,
                                                                atoms: atoms,
                                                                selected: selected,
                                                                cell: cell,
                                                                periodicDim: 3)
            return scene
        }
        func encodeOnce() {
            let commandBuffer = queue.makeCommandBuffer()!
            XCTAssertTrue(renderer.encode(to: commandBuffer, target: texture,
                                           viewport: viewport, camera: renderer.currentCamera))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
        }

        let cell = Cell(a: SIMD3(10, 0, 0), b: SIMD3(0, 10, 0), c: SIMD3(0, 0, 10))
        let atoms = [Atom(coord: SIMD3(0.5, 5, 5), atomicNumber: 1, label: "H"),
                     Atom(coord: SIMD3(9.5, 5, 5), atomicNumber: 1, label: "H")]
        renderer.scene = makeScene(cell: cell, atoms: atoms, selected: [0, 1])
        encodeOnce()
        XCTAssertEqual(renderer.distanceLineResolveCount, 1)

        renderer.currentCamera.rotation = simd_quatf(angle: .pi / 3, axis: SIMD3(0, 1, 0))
        encodeOnce()
        XCTAssertEqual(renderer.distanceLineResolveCount, 1,
                       "camera-only redraws must reuse the resolved line")

        var moved = atoms
        moved[1].coord = SIMD3(8.5, 5, 5)
        renderer.scene = makeScene(cell: cell, atoms: moved, selected: [0, 1])
        encodeOnce()
        XCTAssertEqual(renderer.distanceLineResolveCount, 2)

        let changedCell = Cell(a: SIMD3(12, 0, 0), b: cell.b, c: cell.c)
        renderer.scene = makeScene(cell: changedCell, atoms: moved, selected: [0, 1])
        encodeOnce()
        XCTAssertEqual(renderer.distanceLineResolveCount, 3)

        renderer.scene = makeScene(cell: changedCell, atoms: moved, selected: [1, 0])
        encodeOnce()
        XCTAssertEqual(renderer.distanceLineResolveCount, 4)

        var malformed = renderer.scene
        malformed.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        malformed.measurementResult = MeasurementResult(mode: .distance, atomIndices: [1, 0],
                                                         value: 1, summary: "locked")
        renderer.scene = malformed
        encodeOnce()
        XCTAssertEqual(renderer.distanceLineResolveCount, 5)
        encodeOnce()
        XCTAssertEqual(renderer.distanceLineResolveCount, 5,
                       "a malformed no-line result must be cached")
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

    private func rgba(atX x: Int, y: Int, in texture: MTLTexture) -> (UInt8, UInt8, UInt8, UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4,
                         from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private func isoField(_ values: [Float]) -> ScalarField {
        ScalarField(nx: 3, ny: 3, nz: 3, origin: .zero,
                    vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                    values: values, minValue: values.min() ?? 0, maxValue: values.max() ?? 0)
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
