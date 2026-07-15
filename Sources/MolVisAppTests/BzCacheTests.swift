import XCTest
import Metal
@testable import MolVisApp

// Brillioun-zone, Fermi-surface, isosurface and multi-frame animation tests. The BZ
// overlay is expensive to build but cheap to draw, so it's cached; the render helper
// and the export tests below exercise the camera-framing, surface, frame-state and
// format-dispatch surfaces those features depend on.
final class BzCacheTests: XCTestCase {
    struct NoGpu: Error {}

    // Render helper that frames like the REAL app: the scene owns the canonical default
    // camera (atoms AND volumetric grid, with a grid-only distance floor small enough
    // for reciprocal-space BXSFs). Using scene.defaultCamera() means these tests regress
    // the same framing the GUI and the exporters use.
    func render(_ scene: Scene, w: Int = 300, h: Int = 300) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        r.scene = scene
        let desc = MTLTextureDescriptor(); desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h; desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        let vp = MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1)
        r.encode(to: cb, target: tex, viewport: vp, camera: scene.defaultCamera())
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        return px
    }

    // Image difference in pixels: robust to shading/anti-aliasing, and directly proves a
    // surface changes the rendered output (the original bug -> 0 diff).
    func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[i])-Int(b[i])) + abs(Int(a[i+1])-Int(b[i+1])) + abs(Int(a[i+2])-Int(b[i+2])) > 24 { n += 1 }
        }
        return n
    }

    func testBZVisibleForSlabViaRenderer() throws {
        // GaAsH slab (originally returned NIL and lagged): with BZ on the render MUST
        // differ from BZ off, and both builds return a closed polyhedron.
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
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        guard let bz = BrillouinZone.build(cell: scene.cell!, atoms: scene.baseAtoms) else {
            return XCTFail("si110 BZ build returned nil")
        }
        XCTAssertEqual(bz.faces.count, 14, "fcc BZ = truncated octahedron = 14 faces")
    }

    func testFermiSurfaceRendersBands() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/MgB2.bxsf"), as: .bxsf))
        guard let fs = scene.fermiSurface else { return XCTFail("expected fermiSurface") }
        XCTAssertEqual(fs.bands.count, 3)
        scene.isoLevel = fs.fermiEnergy
        scene.showFermiSurface = false
        let off = try render(scene)
        scene.showFermiSurface = true
        let on = try render(scene)
        let d = diff(off, on)
        print("[fermi] MgB2 surface on vs off: \(d) changed pixels")
        XCTAssertGreaterThan(d, 50, "Fermi surface must visibly change the render")
    }

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

        // Gating: a structure-only file must NOT draw a surface regardless of
        // the toggle (no scalarField present).
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var plain = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        XCTAssertNil(plain.scalarField, "si110 has no field")
        plain.showIsoSurface = false
        let pOff = try render(plain)
        plain.showIsoSurface = true
        let pOn = try render(plain)
        XCTAssertEqual(diff(pOff, pOn), 0, "no field => no surface regardless of toggle")
    }

    // Headless BXSF export must actually render the Fermi surface. The pre-fix exporter
    // used atom-only framing and drew the surface as a microscopic speck; a file-size
    // check alone can't catch that because the PDF/SVG/EPS wrappers and orientation gizmo
    // Headless BXSF export must actually render the Fermi surface (the pre-fix exporter
    // used atom-only framing and drew it as a microscopic speck). A file-size check alone
    // can't catch that — the PDF/SVG/EPS wrappers and orientation gizmo push a blank frame
    // past any small threshold. Every format now returns its wrapped CGImage, so surface-ON
    // and surface-OFF are diffed PIXEL-BY-PIXEL across ALL formats, proving the shared
    // render path drew a visible surface rather than non-empty bytes.
    func testBXSFExportsSurface() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/MgB2.bxsf"), as: .bxsf))
        guard scene.fermiSurface != nil else { return XCTFail("expected fermiSurface") }
        scene.showFermiSurface = false
        let offRaster = try PngExporter.export(scene: scene, camera: nil, to: URL(fileURLWithPath: "/tmp/t_off.png"),
                                                size: CGSize(width: 300, height: 300))
        scene.showFermiSurface = true
        let onRaster = try PngExporter.export(scene: scene, camera: nil, to: URL(fileURLWithPath: "/tmp/t_on.png"),
                                               size: CGSize(width: 300, height: 300))
        let pngDiff = diff(rgba(offRaster), rgba(onRaster))
        print("[export] BXSF PNG surface on vs off: \(pngDiff) changed pixels")
        XCTAssertGreaterThan(pngDiff, 50, "exported Fermi surface must visibly change the render")

        // The four vector formats wrap the SAME returned raster; diff their CGImages too, so a
        // blank-but-wrapped vector output can't slip past a file-size assertion.
        for ext in ["pdf", "svg", "eps", "ps"] {
            scene.showFermiSurface = false
            let vOff = try RasterExporter.export(scene: scene, camera: nil, to: URL(fileURLWithPath: "/tmp/t_off.\(ext)"),
                                                 size: CGSize(width: 300, height: 300))
            scene.showFermiSurface = true
            let vOn = try RasterExporter.export(scene: scene, camera: nil, to: URL(fileURLWithPath: "/tmp/t_on.\(ext)"),
                                                size: CGSize(width: 300, height: 300))
            let d = diff(rgba(vOff), rgba(vOn))
            print("[export] BXSF \(ext) surface on vs off: \(d) changed pixels")
            XCTAssertGreaterThan(d, 50, "\(ext) export must render a visible Fermi surface")
        }
    }

    /// Decode a CGImage to raw RGBA bytes for pixel-level comparison.
    private func rgba(_ cg: CGImage) -> [UInt8] {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    // .bxsf.gz must route to the BXSF parser (the `.gz` layer is peeled) and parse.
    // A real gzip is produced (the loader shells out to gunzip, which needs true gzip).
    func testBXSFRoutesGz() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let src = dir.appendingPathComponent("Fixtures/MgB2.bxsf")
        let gz = URL(fileURLWithPath: "/tmp/t_MgB2.bxsf.gz")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        task.arguments = ["-c", "-k", src.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        // Read BEFORE waiting: a full pipe buffer would otherwise deadlock gzip (it
        // blocks on write while we block on waitUntilExit).
        let gzipOut = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try gzipOut.write(to: gz)
        // Route purely by extension (no --bxsf flag), as File > Open would.
        let resolved = ParseFormat.from(url: gz)
        XCTAssertEqual(resolved, .bxsf, ".bxsf.gz must resolve to the BXSF parser")
        let scene = Scene(loaded: try Parser.load(gz, as: .bxsf))
        XCTAssertNotNil(scene.fermiSurface, "g-zipped BXSF must parse")
    }

    // Fermi visibility must survive a save/load round trip.
    func testFermiVisibilityPersistsInState() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/MgB2.bxsf"), as: .bxsf))
        scene.showFermiSurface = false   // toggle OFF, then save
        let stateURL = URL(fileURLWithPath: "/tmp/t_fermi_state.mvis-state")
        try StateStore.save(scene, camera: nil, sourceURL: dir.appendingPathComponent("Fixtures/MgB2.bxsf"), to: stateURL)
        var loaded = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/MgB2.bxsf"), as: .bxsf))
        XCTAssertTrue(loaded.showFermiSurface, "fresh load defaults to visible")
        var dummyCamera: Camera? = nil
        try StateStore.load(into: &loaded, camera: &dummyCamera, from: stateURL)
        XCTAssertFalse(loaded.showFermiSurface, "saved Fermi-off state must round-trip")
    }

    // A saved animation frame must clamp into the valid range (negative or beyond the
    // last cycle) and must win over a --frame N. This guards the loadScene clamping.
    func testSavedFrameClampsAndOverridesCLI() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/orca.orca")

        // negative saved frame -> clamped to 0
        let neg = URL(fileURLWithPath: "/tmp/t_neg.mvis-state")
        try "{\"version\":1,\"currentFrame\":-5}".write(to: neg, atomically: true, encoding: .utf8)
        let s1 = try loadWithState(url, format: .orca, cliFrame: 0, stateURL: neg)
        XCTAssertEqual(s1.currentFrame, 0, "negative saved frame clamps to 0")

        // beyond last cycle -> clamped to last
        let big = URL(fileURLWithPath: "/tmp/t_big.mvis-state")
        try "{\"version\":1,\"currentFrame\":999}".write(to: big, atomically: true, encoding: .utf8)
        let s2 = try loadWithState(url, format: .orca, cliFrame: 0, stateURL: big)
        XCTAssertLessThan(s2.currentFrame, Parser.frameCount(url, as: .orca),
                          "oversize saved frame clamps below frameCount")

        // valid saved frame overrides CLI --frame
        let saved = URL(fileURLWithPath: "/tmp/t_saved.mvis-state")
        let fc = Parser.frameCount(url, as: .orca)
        try "{\"version\":1,\"currentFrame\":\(fc-1)}".write(to: saved, atomically: true, encoding: .utf8)
        let s3 = try loadWithState(url, format: .orca, cliFrame: 0, stateURL: saved)
        XCTAssertEqual(s3.currentFrame, fc - 1, "valid saved frame overrides CLI frame")

        // fc == 0 (non-animated file): a malformed saved frame or --frame N must NOT
        // desync the scrubber — currentFrame is forced back to 0. (Oraca above covers
        // only the animated fc > 0 path; this branch is exercised exclusively here.)
        let crystalURL = dir.appendingPathComponent("Fixtures/si110.xsf")
        XCTAssertEqual(Parser.frameCount(crystalURL, as: nil), 0, "si110 is non-animated")
        let bogus = URL(fileURLWithPath: "/tmp/t_bogus.mvis-state")
        try "{\"version\":1,\"currentFrame\":7}".write(to: bogus, atomically: true, encoding: .utf8)
        let s4 = try loadWithState(crystalURL, format: nil, cliFrame: 0, stateURL: bogus)
        XCTAssertEqual(s4.currentFrame, 0, "non-animated file: stale saved frame resets to 0")
    }

    // .out dispatch by content: QE PWscf, Orca and FHI-aims all use the .out extension,
    // so the sniffer must separate them by header (File > Open needs no force flag).
    // Each sub-check writes a small header to a temp .out and asserts the sniffed format.
    func testOutFormatDispatch() throws {
        let root = URL(fileURLWithPath: #file).deletingLastPathComponent()
        // QE PWscf: the real fixture opens with "Program PWSCF".
        XCTAssertEqual(ParseFormat.from(url: root.appendingPathComponent("Fixtures/si_relax.out")), .pwo)
        // Orca: banner follows comment lines; sniffer reads 4KB.
        let orca = URL(fileURLWithPath: "/tmp/t_sniff_orca.out")
        try "### Running on host: test\n\n*****************\n* O   R   C   A *\n*****************\n"
            .write(to: orca, atomically: true, encoding: .utf8)
        XCTAssertEqual(ParseFormat.from(url: orca), .orca, "Orca banner sniffs to .orca")
        // FHI-aims coord.out: three numeric lattice-vector lines, no text banner.
        let fhi = URL(fileURLWithPath: "/tmp/t_sniff_fhi.out")
        try "  10.44  0.00  0.00\n   0.00  7.38  0.00\n   0.00  0.00 36.91\n4\n6\nGa\n"
            .write(to: fhi, atomically: true, encoding: .utf8)
        XCTAssertEqual(ParseFormat.from(url: fhi), .fhi, "numeric VH lattice header sniffs to .fhi")
        // Plain unknown .out with no recognizable header -> falls back to QE.
        let plain = URL(fileURLWithPath: "/tmp/t_sniff_plain.out")
        try "some random output\nwith no banner\n1 2 3\n".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertEqual(ParseFormat.from(url: plain), .pwo, "unrecognized .out defaults to QE")
    }
}

// Drives the REAL production frame resolver (App.resolveAnimationFrame) through a minimal
// load + state-restore setup, so the frame-state tests exercise the exact logic the GUI
// uses instead of a stale mirror. @testable import gives access to the internal helper.
func loadWithState(_ url: URL, format: ParseFormat?, cliFrame: Int, stateURL: URL) throws -> Scene {
    let loadedFrame = cliFrame < 0 ? 0 : cliFrame
    var scene = Scene(loaded: try Parser.load(url, as: format, frameIndex: cliFrame))
    scene.currentFrame = loadedFrame
    var dummyCamera: Camera? = nil
    try StateStore.load(into: &scene, camera: &dummyCamera, from: stateURL)
    let fc = Parser.frameCount(url, as: format)
    try App.resolveAnimationFrame(scene: &scene, from: url, format: format, loadedFrame: loadedFrame, fc: fc)
    return scene
}
