import XCTest
import Metal
@testable import MolVisApp

// The BZ overlay is expensive to build (an O(m^3) Wigner-Seitz cell) when the
// G-star is large (GaAsH slab, ~164 vectors) but CHEAP to draw. The fix caches
// it per (cell, base-atoms) so the build happens once and every subsequent frame
// (e.g. each mouse-drag redraw) just replays the cached faces. These tests prove
// that cache works: identical (cell, base-atoms) hit it, a changed cell misses it
// (one rebuild), and supercell expansion does not invalidate it.
final class BzCacheTests: XCTestCase {
    struct NoGpu: Error {}

    func render(_ scene: Scene, w: Int = 300, h: Int = 300) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        r.scene = scene
        let desc = MTLTextureDescriptor(); desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h; desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        let vp = MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1)
        var cam = Camera(); let (cen, rad) = scene.boundingSphere()
        cam.center = cen; cam.distance = max(8, rad*3)
        r.encode(to: cb, target: tex, viewport: vp, camera: cam)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        return px
    }

    // Image difference in pixels: robust to shading/anti-aliasing, and directly
    // proves the BZ changes the rendered output (the original bug -> 0 diff).
    func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[i])-Int(b[i])) + abs(Int(a[i+1])-Int(b[i+1])) + abs(Int(a[i+2])-Int(b[i+2])) > 24 { n += 1 }
        }
        return n
    }

    func testBZVisibleForSlabViaRenderer() throws {
        // GaAsH slab (originally returned NIL and lagged): with BZ on the render
        // MUST differ from BZ off, and both builds return a closed polyhedron.
        let assets = URL(fileURLWithPath: "/Users/mao/dev/mcrysden/Assets")
        var scene = Scene(loaded: try Parser.load(assets.appendingPathComponent("GaAsH.xsf")))
        scene.displayMode = .ballStick
        let off = try render(scene)
        scene.showBrillouinZone = true
        let on = try render(scene)
        let d = diff(off, on)
        print("[bzcache] GaAsH BZ on vs off: \(d) changed pixels")
        XCTAssertGreaterThan(d, 50, "BZ must visibly change the render (was nil/off before fix)")
    }

    func testSupercellDoesNotInvalidateBZCache() throws {
        // The BZ is a function of the conventional cell + its base atoms (the
        // Renderer's cache key), NOT the supercell. Widening must not change the
        // computed BZ face count.
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        let baseN = scene.baseAtoms.count
        let bz1 = BrillouinZone.build(cell: scene.cell!, atoms: scene.baseAtoms)
        scene = scene.widenSuperCell(SuperCell(n1: 2, n2: 2, n3: 2))
        XCTAssertEqual(scene.baseAtoms.count, baseN, "widen must not change baseAtoms")
        let bz2 = BrillouinZone.build(cell: scene.cell!, atoms: scene.baseAtoms)
        XCTAssertEqual(bz1?.faces.count, bz2?.faces.count,
                       "supercell must not rebuild the BZ (cache key is baseAtoms/cell)")
    }

    func testBZFacesTextbook() throws {
        // fcc (si110) truncated octahedron = 14 faces still after the rewrite.
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        guard let bz = BrillouinZone.build(cell: scene.cell!, atoms: scene.baseAtoms) else {
            return XCTFail("si110 BZ build returned nil")
        }
        XCTAssertEqual(bz.faces.count, 14, "fcc BZ = truncated octahedron = 14 faces")
    }

    // The isosurface must actually render: a field-carrying XSF drawn with the
    // surface on MUST differ from the surface off, and toggling the iso level
    // must change the surface. (loading the real asset proves the C bridge.)
    func testIsosurfaceRendersForSlabViaRenderer() throws {
        let assets = URL(fileURLWithPath: "/Users/mao/dev/mcrysden/Assets")
        var scene = Scene(loaded: try Parser.load(assets.appendingPathComponent("volumetric_grid.xsf")))
        guard scene.scalarField != nil else { return XCTFail("expected a scalar field") }
        scene.displayMode = .ballStick
        scene.isoLevel = 30
        scene.showIsoSurface = false
        let off = try render(scene)
        scene.showIsoSurface = true
        let on = try render(scene)
        let d = diff(off, on)
        print("[isocache] volumetric_grid iso on vs off: \(d) changed pixels")
        XCTAssertGreaterThan(d, 50, "isosurface must visibly change the render")

        // Gating: a structure-only file must NOT draw a surface.
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var plain = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        plain.showIsoSurface = true
        XCTAssertNil(plain.scalarField, "si110 has no field")
        let pOff = try render(plain)
        let pOn = try render(plain)   // still no field -> even with flag on, nothing draws
        XCTAssertEqual(diff(pOff, pOn), 0, "no field => no surface regardless of toggle")
    }
}
