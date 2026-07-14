import XCTest
import Metal
@testable import MolVisApp

// Diagnostic: confirm the force-arrow overlay (P1 wiring fix) actually draws.
// Loads a synthetic valid `.pwo` (C parser accepts its atoms/cell) carrying a
// parsed forceSet, enables the toggle, renders, and checks that orange-tinted
// arrow pixels appear near the atoms. Without the wiring fix the scene has no
// forceSet and nothing is drawn; with it, the overlay renders.
final class ForceArrowDiag: XCTestCase {
    func testForceArrowsRender() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pwo = """
             Program PWSCF v.6.7
                 Today is  1Jan2024 at  0:00:00
             bravais-lattice index     =            1
             lattice parameter (alat)  =      10.2000  a.u.
             number of atoms/cell      =            2
             number of atomic types    =            1
             CELL_PARAMETERS (alat)
              1.0000000  0.0000000  0.0000000
              0.0000000  1.0000000  0.0000000
              0.0000000  0.0000000  1.0000000
             ATOMIC_POSITIONS (crystal)
             Si        0.000000   0.000000   0.000000
             Si        0.250000   0.250000   0.250000

                 End of self-consistent calculation

             Forces acting on atoms (Ry/au):

             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =     -.10000000     .00000000     .00000000

             Total force =      .267804     Total SCF correction =      .002682
            !    total energy              =     -15.84123456 Ry
            """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("force.pwo")
        try pwo.write(to: tmp, atomically: true, encoding: .utf8)
        guard let loaded = try? Parser.load(tmp, as: .pwo) else {
            return XCTFail("synthetic .pwo failed to load")
        }
        guard loaded.forceSet != nil else { return XCTFail("no forceSet wired from .pwo") }

        var scene = Scene(loaded: loaded)
        scene.showForces = true            // draw arrows
        scene.forceScale = 80
        scene.background = "#000000"

        let r = try Renderer(device: device)
        let w = 300, h = 300
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm; desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        r.scene = scene
        var cam = scene.defaultCamera()
        r.encode(to: cb, target: tex,
                 viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                 camera: cam)
        cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // Arrow colour is orange (R high, G medium, B low). Count orange-ish px.
        var orange = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if r > 120 && g > 40 && g < 200 && b < 90 { orange += 1 }
        }
        print("[force-arrow] w=\(w) h=\(h) orangePx=\(orange)")
        // Baseline: toggle OFF draws no arrows.
        var off = scene
        off.showForces = false
        r.scene = off
        let cb2 = device.makeCommandQueue()!.makeCommandBuffer()!
        r.encode(to: cb2, target: tex,
                 viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                 camera: cam)
        cb2.commit(); cb2.waitUntilCompleted()
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var orangeOff = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if r > 120 && g > 40 && g < 200 && b < 90 { orangeOff += 1 }
        }
        print("[force-arrow] with toggle OFF orangePx=\(orangeOff)")
        // Arrows appear only when the toggle is on. (The small OFF residual is
        // the Si atoms' CPK tint leaking the loose orange window; the signal is
        // the delta — arrows roughly double the count.)
        XCTAssertGreaterThan(orange, 0, "force arrows should render when enabled")
        XCTAssertGreaterThan(orange - orangeOff, 100,
                             "enabling the toggle should add a clear arrow pixel count")
    }
}
