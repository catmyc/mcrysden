import XCTest
import Metal
import simd
@testable import MolVisApp

// Regression coverage for round-2 rendering/model/export fixes. Each test exercises
// the CONSUMER behavior (renderer/exporter/scene), not just the underlying helper flag.
final class Round2FindingsTests: XCTestCase {
    struct NoGpu: Error {}

    // MARK: - 1. IsoMesh.overflow must make the renderer drop the frame, never render a
    // truncated/empty shell as success. The marching-cubes Int-overflow guard reads only
    // nx/ny/nz (never `values`), so a field with huge dims + a tiny values array triggers
    // overflow deterministically without allocating a giant grid.

    private func makeRenderer(_ scene: Scene, w: Int = 64, h: Int = 64) throws -> (Renderer, MTLTexture) {
        var s = scene
        s.background = "#000000"
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        r.scene = s
        r.currentCamera.distance = 8
        let d = MTLTextureDescriptor()
        d.pixelFormat = .rgba8Unorm; d.width = w; d.height = h
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { throw NoGpu() }
        return (r, tex)
    }

    private func encode(_ r: Renderer, _ tex: MTLTexture, w: Int = 64, h: Int = 64) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        let ok = r.encode(to: cb, target: tex,
                          viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h),
                                                znear: 0, zfar: 1),
                          camera: r.currentCamera)
        cb.commit(); cb.waitUntilCompleted()
        return ok
    }

    func testIsosurfaceOverflowFailsFrame() throws {
        // (nx-1)(ny-1)(nz-1)*27 overflows Int → marching cubes bails with overflow=true.
        let field = ScalarField(nx: 2_000_000, ny: 2_000_000, nz: 2_000_000, origin: .zero,
                                vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                                values: [1, 2, 3, 4], minValue: 1, maxValue: 4)
        var s = Scene()
        s.showStructure = false
        s.showIsoSurface = true
        s.isoLevel = 0.5
        s.scalarField = field
        let (r, tex) = try makeRenderer(s)
        XCTAssertFalse(encode(r, tex), "frame must drop when the isosurface overflows")
    }

    // The IsoMesh boundary must reject a ScalarField whose nx*ny*nz != values.count
    // rather than trap on an out-of-bounds read. The field here is small enough that
    // the cubes-overflow guard does NOT trip (so it reaches the shape guard), and its
    // count is deliberately one short of the product. Result: empty, non-overflowing,
    // no crash. A parser-produced field always satisfies the product, so this only
    // affects malformed input.
    func testIsosurfaceRejectsShapeMismatchedField() {
        let field = ScalarField(nx: 4, ny: 4, nz: 4, origin: .zero,
                                vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                                values: [Float](repeating: 1, count: 63), // 4*4*4 == 64
                                minValue: 1, maxValue: 1)
        let mesh = IsoMesh(field: field, isoLevel: 0.5, sign: 1)
        XCTAssertFalse(mesh.overflow, "shape-mismatched field must not set overflow")
        XCTAssertEqual(mesh.triangleCount, 0, "shape-mismatched field must yield an empty mesh")
    }

    func testIsosurfaceEmptyShellStillCachedAsEmpty() throws {
        // A field that never crosses the iso level yields overflow==false, triangleCount==0:
        // a valid empty surface that must NOT drop the frame.
        let field = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                                values: [Float](repeating: 1, count: 8), minValue: 1, maxValue: 1)
        var s = Scene()
        s.showStructure = false
        s.showIsoSurface = true
        s.isoLevel = 0.5
        s.scalarField = field
        let (r, tex) = try makeRenderer(s)
        XCTAssertTrue(encode(r, tex), "valid empty isosurface must render without dropping the frame")
        // Second identical frame must reuse the cached empty surface (no rebuild, no failure).
        XCTAssertTrue(encode(r, tex))
    }

    // A field with very large but arithmetic-non-overflowing dimensions and a tiny
    // values array must NOT reserve up to maxTriangles*27 floats (~540 MB) before being
    // rejected: the shape guard now runs before reserveCapacity. The declared grid
    // here is (10^5)^3 samples while values holds only 8 — and (99999^3)*27 ≈ 2.7e16 is
    // below both Int64.max and Int.max, so the OLD reserve path (shape check after the
    // reserve) would have reserved maxTriangles*27 == 135M floats (~540 MB). Result is an
    // empty, non-overflowing mesh, never a trap or a giant allocation.
    func testMalformedHugeDimsShapeGuardPrecedesReserve() {
        let field = ScalarField(nx: 100_000, ny: 100_000, nz: 100_000, origin: .zero,
                                vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                                values: [0, 0, 0, 0, 1, 1, 1, 1], minValue: 0, maxValue: 1)
        let mesh = IsoMesh(field: field, isoLevel: 0.5, sign: 1)
        XCTAssertFalse(mesh.overflow, "huge-but-finite malformed dims must not set overflow")
        XCTAssertEqual(mesh.triangleCount, 0, "huge-but-finite malformed dims must yield an empty mesh")
    }

    // Through the renderer: huge-but-finite malformed dims must render without a giant
    // allocation or a trap — the shape guard rejects the field, the empty surface is
    // cached, and the frame succeeds.
    func testMalformedHugeDimsRenderWithoutLargeAlloc() throws {
        let field = ScalarField(nx: 100_000, ny: 100_000, nz: 100_000, origin: .zero,
                                vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                                values: [0, 0, 0, 0, 1, 1, 1, 1], minValue: 0, maxValue: 1)
        var s = Scene()
        s.showStructure = false
        s.showIsoSurface = true
        s.isoLevel = 0.5
        s.scalarField = field
        let (r, tex) = try makeRenderer(s)
        XCTAssertTrue(encode(r, tex), "huge-but-finite malformed field must render without hanging")
    }

    // Degenerate geometry: a ScalarField with fewer than 3 span vectors must not trap on
    // the vec[0..2] indexing inside marching cubes. Rejected as an empty, non-overflowing
    // mesh — the same safe outcome as a shape mismatch.
    func testShortVecFieldYieldsEmptyMesh() {
        let field = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                vec: [SIMD3(1,0,0)],   // only 1 span vector
                                values: [Float](repeating: 1, count: 8), minValue: 1, maxValue: 1)
        let mesh = IsoMesh(field: field, isoLevel: 0.5, sign: 1)
        XCTAssertFalse(mesh.overflow, "short-vec field must not set overflow")
        XCTAssertEqual(mesh.triangleCount, 0, "short-vec field must yield an empty mesh")
    }

    // Through the renderer: a scalar field with fewer than 3 span vectors must not trap
    // during IsoCacheKey construction (which indexes vec[0..2] before IsoMesh runs). The
    // frame encodes cleanly, skipping the isosurface.
    func testShortVecFieldDoesNotTrapInRenderer() throws {
        let field = ScalarField(nx: 3, ny: 3, nz: 3, origin: .zero,
                                vec: [SIMD3(1,0,0), SIMD3(0,1,0)],   // only 2 span vectors
                                values: [Float](repeating: 1, count: 27), minValue: 1, maxValue: 1)
        var s = Scene()
        s.showStructure = false
        s.showIsoSurface = true
        s.isoLevel = 0.5
        s.scalarField = field
        let (r, tex) = try makeRenderer(s)
        XCTAssertTrue(encode(r, tex), "short-vec field must not trap the renderer cache-key path")
    }

    func testFermiSurfaceOverflowFailsFrame() throws {
        let band = ScalarField(nx: 2_000_000, ny: 2_000_000, nz: 2_000_000, origin: .zero,
                               vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                               values: [1, 2, 3, 4], minValue: 1, maxValue: 4)
        var s = Scene()
        s.showStructure = false
        s.showFermiSurface = true
        s.fermiSurface = FermiSurface(fermiEnergy: 0.5, bands: [band])
        let (r, tex) = try makeRenderer(s)
        XCTAssertFalse(encode(r, tex), "frame must drop when a Fermi band overflows")
    }

    // MARK: - 3. VectorExporter EPS: dimension mismatch must be rejected before raster
    // allocation, and overwriting an existing file must preserve a valid document.

    func testEpsRejectsMismatchedDimensions() throws {
        // Build a real CGImage at one size, but ask emitEPS to wrap it at another.
        let w = 4, h = 4
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = 200; px[i+1] = 100; px[i+2] = 50; px[i+3] = 255 }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return XCTFail("could not build CGImage") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("r2_mismatch.eps")
        try? FileManager.default.removeItem(at: out)
        // Declared size 8x8 != actual image 4x4 → must throw noCGImage.
        XCTAssertThrowsError(try RasterExporter.write(cgImage: cg, to: out, size: CGSize(width: 8, height: 8)),
                             "mismatched source dimensions must be rejected") { err in
            XCTAssertTrue(err is RasterExportError, "expected a RasterExportError, got \(type(of: err))")
        }
    }

    func testEpsOverwritePreservesValidDocument() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var scene = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf")))
        scene.background = "#000000"
        scene.showAxes = false; scene.showCellFrame = false
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("r2_overwrite.eps")
        // First export creates the file.
        _ = try RasterExporter.export(scene: scene, camera: nil, to: out, size: CGSize(width: 120, height: 120))
        let first = try Data(contentsOf: out)
        // Second export to the SAME path must atomically replace, not truncate.
        _ = try RasterExporter.export(scene: scene, camera: nil, to: out, size: CGSize(width: 120, height: 120))
        let second = try Data(contentsOf: out)
        XCTAssertTrue(String(data: second.prefix(24), encoding: .ascii)?.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0") == true)
        XCTAssertTrue(second.suffix(6).elementsEqual("%%EOF\n".utf8), "overwritten EPS must end with %%EOF")
        XCTAssertGreaterThanOrEqual(second.count, first.count, "overwrite must not produce a smaller/truncated document")
    }

    // MARK: - 4. SuperCell.total must not trap on overflow.

    func testSuperCellTotalSaturates() {
        let huge = SuperCell(n1: Int.max, n2: Int.max, n3: Int.max)
        XCTAssertEqual(huge.total, Int.max, "overflow must saturate, not trap")
        let normal = SuperCell(n1: 2, n2: 3, n3: 4)
        XCTAssertEqual(normal.total, 24)
        XCTAssertTrue(huge.total > 1, "saturating total must still read as > 1 for call sites")
    }

    // MARK: - 5. Manual-supercell round-trip must retain a valid base snapshot so shrinking
    // recovers the original atoms.

    func testManualSupercellRoundTrip() throws {
        var s = Scene(loaded: try Parser.load(URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")))
        // Wipe the pristine base to simulate a hand-built scene.
        s.baseAtoms = []
        s.baseBonds = []
        s.superCell = SuperCell()
        let originalCount = s.atoms.count
        XCTAssertTrue(s.baseAtoms.isEmpty)
        s = s.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertEqual(s.atoms.count, originalCount * 2, "widen must double the atoms")
        XCTAssertFalse(s.baseAtoms.isEmpty, "widening a hand-built scene must snapshot a base")
        XCTAssertEqual(s.baseAtoms.count, originalCount, "base snapshot must be the pristine set")
        // Shrink back: must recover the original atom count.
        s = s.widenSuperCell(SuperCell(n1: 1, n2: 1, n3: 1))
        XCTAssertEqual(s.atoms.count, originalCount, "shrink must recover the original atoms")
        XCTAssertEqual(s.superCell, SuperCell())
    }

    // MARK: - 7. Performance caches must not silently return stale geometry. Verify the
    // documented invariants: polyhedral output changes when atoms change but is stable
    // across camera-only re-renders (proves the cache key + guard agree).

    func testPolyhedralCacheTracksAtomsAndStabilizes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NoGpu() }
        let r = try Renderer(device: device)
        let w = 64, h = 64
        let d = MTLTextureDescriptor()
        d.pixelFormat = .rgba8Unorm; d.width = w; d.height = h
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let tex = device.makeTexture(descriptor: d)!
        let queue = device.makeCommandQueue()!
        func hash(_ scene: Scene) -> UInt64 {
            r.scene = scene
            let cb = queue.makeCommandBuffer()!
            _ = r.encode(to: cb, target: tex,
                         viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                         camera: Camera())
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return px.reduce(into: UInt64(0xcbf29ce484222325)) { $0 ^= UInt64($1); $0 &*= 0x100000001b3 }
        }
        var scene = Scene()
        scene.displayMode = .polyhedral
        scene.showAxes = false; scene.showCellFrame = false
        scene.isCrystal = true
        scene.cell = Cell(a: SIMD3(4,0,0), b: SIMD3(0,4,0), c: SIMD3(0,0,4))
        scene.atoms = [
            Atom(coord: .zero, atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(1,1,1), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(1,-1,-1), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(-1,1,-1), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(-1,-1,1), atomicNumber: 6, label: "C"),
        ]
        scene.bonds = [Bond(i: 0, j: 1), Bond(i: 0, j: 2), Bond(i: 0, j: 3), Bond(i: 0, j: 4)]
        let h1 = hash(scene)
        // Camera-only re-render (same geometry) → cache hit, identical output.
        let h2 = hash(scene)
        XCTAssertEqual(h1, h2, "camera-only frame must reuse the cached polyhedron")
        // Move an atom → cache key changes → geometry must differ.
        scene.atoms[1].coord = SIMD3(2, 2, 2)
        let h3 = hash(scene)
        XCTAssertNotEqual(h1, h3, "changing atoms must invalidate the polyhedral cache")
    }

    // MARK: - 2. drawCell must refuse a pathological supercell rather than allocate
    // gigabytes or hang. A direct Scene construction bypasses widenSuperCell's atom cap,
    // so the renderer itself must bound the box count. 100_000^3 = 1e15 boxes fits Int and
    // fits 24*total, so the old reserve-overflow guard alone did not stop it.

    func testDrawCellHugeSupercellFailsFast() throws {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5,0,0), b: SIMD3(0,5,0), c: SIMD3(0,0,5))
        s.showStructure = false; s.showAxes = false
        s.showCellFrame = true
        s.superCell = SuperCell(n1: 100_000, n2: 100_000, n3: 100_000)
        let (r, tex) = try makeRenderer(s)
        XCTAssertFalse(encode(r, tex), "huge supercell must fail the frame, not hang/allocate")
    }

    func testDrawCellOverflowSupercellFailsFast() throws {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5,0,0), b: SIMD3(0,5,0), c: SIMD3(0,0,5))
        s.showStructure = false; s.showAxes = false
        s.showCellFrame = true
        s.superCell = SuperCell(n1: Int.max, n2: Int.max, n3: Int.max)
        let (r, tex) = try makeRenderer(s)
        XCTAssertFalse(encode(r, tex), "overflowing supercell product must fail the frame")
    }

    func testDrawCellZeroSupercellFactorFailsFast() throws {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5,0,0), b: SIMD3(0,5,0), c: SIMD3(0,0,5))
        s.showStructure = false; s.showAxes = false
        s.showCellFrame = true
        s.superCell = SuperCell(n1: 0, n2: 2, n3: 2)
        let (r, tex) = try makeRenderer(s)
        XCTAssertFalse(encode(r, tex), "zero supercell factor must fail the frame")
    }

    func testDrawCellNormalSupercellStillRenders() throws {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5,0,0), b: SIMD3(0,5,0), c: SIMD3(0,0,5))
        s.showStructure = false; s.showAxes = false
        s.showCellFrame = true
        s.superCell = SuperCell(n1: 2, n2: 2, n3: 2)
        let (r, tex) = try makeRenderer(s)
        XCTAssertTrue(encode(r, tex), "a normal supercell must still render the cell frame")
    }

    // MARK: - 6. applySlab on a molecule (no cell) must refuse and leave bonds intact.

    func testApplySlabRefusesMolecule() throws {
        var s = Scene(loaded: try Parser.load(URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")))
        s.cell = nil // molecule: no unit cell
        // si110 has no parsed bonds; inject one so a "wipe" would be observable.
        s.bonds = [Bond(i: 0, j: 1)]
        let bondsBefore = s.bonds.count
        XCTAssertGreaterThan(bondsBefore, 0)
        let out = s.applySlab(Slab(planeA: Plane(h: 0, k: 1, l: 0, distance: 0),
                                   planeB: Plane(h: 0, k: -1, l: 0, distance: 1)))
        XCTAssertEqual(out.bonds.count, bondsBefore, "slab on a molecule must not wipe bonds")
        XCTAssertNil(out.slab)
        XCTAssertEqual(out.atoms.count, s.atoms.count)
    }
}
