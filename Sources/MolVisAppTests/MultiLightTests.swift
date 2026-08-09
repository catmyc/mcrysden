import XCTest
import Metal
import simd
@testable import MolVisApp

/// Multi-light rig behavioral/smoke test. `Scene.lights: [SceneLightSource]`
/// (Model.swift) drives `Renderer.multiLightDir(view:)` (Renderer.swift:474),
/// which the encode paths consult at Renderer.swift:1008/1333/1517/2996. This
/// test builds a small scene, enables the multi-light rig with 3 sources, and
/// renders through the same headless `PngExporter.render` path used by
/// `RendererTests`/`Snapshotter`. The test is a no-op on hosts without a Metal
/// device (mirrors the `XCTSkip` guard in `VolumetricTests.swift`).
final class MultiLightTests: XCTestCase {

    func testMultiLightRendersWithoutError() throws {
        // Mirror the exact Metal-availability guard from VolumetricTests.swift.
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available")
        }

        var scene = Scene()
        scene.background = "#000000"
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 14, label: "Si"),
            Atom(coord: SIMD3(1.36, 0, 0), atomicNumber: 14, label: "Si"),
        ]

        // Enable the multi-light rig with 3 sources at distinct directions and
        // intensities. Empty `lights` keeps the legacy single-light path; a
        // non-empty array routes through `multiLightDir`.
        scene.lights = [
            SceneLightSource(azimuth: 45, elevation: 60, intensity: 1.5,
                             colorHex: "#FF8080"),
            SceneLightSource(azimuth: 180, elevation: 30, intensity: 1.0,
                             colorHex: "#80FF80"),
            SceneLightSource(azimuth: 270, elevation: 75, intensity: 0.8,
                             colorHex: "#8080FF"),
        ]

        let size = CGSize(width: 96, height: 96)
        // render() returning (rather than throwing) implies a non-nil CGImage.
        let image = try PngExporter.render(scene: scene, camera: nil, size: size)
        XCTAssertGreaterThan(image.width, 0, "rendered image must have non-zero width")
        XCTAssertGreaterThan(image.height, 0, "rendered image must have non-zero height")
    }
}
