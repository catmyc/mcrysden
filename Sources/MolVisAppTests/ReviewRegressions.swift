import XCTest
import simd
@testable import MolVisApp

// Coverage for the DeepSeek app/UI/state fixes. Every controller is created with
// showWindow:false — presenting a real AppKit window in XCTest leaves async
// _NSWindowTransformAnimation teardown that crashes later tests. Where possible
// the tests exercise the PURE HELPERS (pan axes/pixel-scale, magnification, hit
// test gate) or the controller's PRODUCTION sync path, never duplicated formulas.
final class ReviewRegressions: XCTestCase {

    // MARK: - Issue 1. Same-mode sidebar changes must NOT reframe; a real
    // 2D↔3D transition must reframe while PRESERVING the user's
    // perspective/orthographic setting.

    @MainActor
    func testSameDisplayModeChangeDoesNotReframe() throws {
        let wc = MainWindowController(scene: sceneWithAtoms(), showWindow: false)
        // A same-mode change (3D ballStick → 3D spaceFill) must not touch the camera.
        wc.camera.rotation = simd_quatf(angle: 0.3, axis: SIMD3<Float>(0, 1, 0))
        let beforeDist = wc.camera.distance
        let beforeRot = wc.camera.rotation
        wc.state.displayMode = .spaceFill
        XCTAssertEqual(wc.camera.distance, beforeDist, accuracy: 1e-4,
                       "same-mode display change must not reframe (distance)")
        XCTAssertEqual(wc.camera.rotation, beforeRot,
                       "same-mode display change must not reframe (rotation)")
    }

    @MainActor
    func test2D3DTransitionReframesButPreservesOrthographic() throws {
        let wc = MainWindowController(scene: sceneWithAtoms(), showWindow: false)
        // Fix the user in PERSPECTIVE 3D: state.orthographic false => camera.perspective true.
        wc.state.orthographic = false
        XCTAssertTrue(wc.camera.perspective)

        // Give the camera a NON-identity rotation so the reframe is observable
        // (loadFile frames with identity rotation; a real orbit would diverge).
        wc.camera.rotation = simd_quatf(angle: 0.4, axis: SIMD3<Float>(1, 2, 3))
        let threeDRot = wc.camera.rotation

        // 3D => 2D triggers a reframe (rotation resets to identity) but the
        // perspective flag must survive because state.orthographic was untouched.
        wc.state.displayMode = .ballStick2D
        XCTAssertNotEqual(wc.camera.rotation, threeDRot, "2D↔3D transition must reframe rotation")
        XCTAssertTrue(wc.scene.displayMode.is2D,
                      "display mode switched to a 2D mode")
        XCTAssertTrue(wc.camera.perspective,
                      "the stored camera projection must match the untouched state.orthographic")

        // 2D => 3D round trip keeps the same projection.
        wc.state.displayMode = .ballStick
        XCTAssertTrue(wc.camera.perspective,
                      "perspective/orthographic state must survive the full 2D↔3D round trip")
    }

    // MARK: - Issue 2. Pan projection + axes. The renderer forces identity rotation
    // + orthographic for 2D, so pan axes must be world axes and pixel scale must be
    // the orthographic scale regardless of the stored camera.perspective.

    func testPanAxes2DUsesWorldAxes() {
        let cam = Camera()
        let (right, up) = MetalView.panAxes(camera: cam, is2D: true)
        XCTAssertEqual(right, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(up, SIMD3<Float>(0, 1, 0))
    }

    func testPanAxes3DRotationale() {
        let rot = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        var cam = Camera()
        cam.rotation = rot
        let (right, up) = MetalView.panAxes(camera: cam, is2D: false)
        // 90° about Y maps camera-right (+X world) to -Z world; up stays +Y.
        XCTAssertEqual(simd_length(right - SIMD3<Float>(0, 0, -1)), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_length(up - SIMD3<Float>(0, 1, 0)), 0, accuracy: 1e-4)
        XCTAssertEqual(simd_length(right), 1, accuracy: 1e-4)
        XCTAssertEqual(simd_length(up), 1, accuracy: 1e-4)
    }

    func testPanWorldPerPixel2DAlwaysOrthographic() {
        // 2D forces orthographic pixel scale even if the stored camera is perspective.
        var persp = Camera(); persp.perspective = true; persp.distance = 20
        let h: Float = 400
        let expected = (2.0 * 20) / h   // orthographic: 2*d/h
        XCTAssertEqual(MetalView.panWorldPerPixel(camera: persp, viewHeight: h, is2D: true),
                       expected, accuracy: 1e-4,
                       "2D pan must ignore camera.perspective and use orthographic scale")
        // Orthographic 3D: same formula.
        var ortho = Camera(); ortho.perspective = false; ortho.distance = 20
        XCTAssertEqual(MetalView.panWorldPerPixel(camera: ortho, viewHeight: h, is2D: false),
                       expected, accuracy: 1e-4,
                       "orthographic-3D pan must use 2*d/h")
        // Perspective 3D: 2*d*tan(fov/2)/h, fov = π/4.
        let expectedP = (2.0 * 20 * tan(Float.pi / 8)) / h
        XCTAssertEqual(MetalView.panWorldPerPixel(camera: persp, viewHeight: h, is2D: false),
                       expectedP, accuracy: 1e-4,
                       "perspective-3D pan must use the fov-based scale")
    }

    // MARK: - Issue 3. State-slab Miller indices mirror the UI (-8...8) and keep
    // valid negatives; distances stay finite but are NOT forced positive.

    func testStateLoadSlabIndicesInUIContract() throws {
        let tmp = tempStateURL()
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1],
            "slab": [
                "planeA": ["h": 100, "k": -5, "l": 8, "distance": -2.5],
                "planeB": ["h": 0, "k": -1, "l": -12, "distance": 0.0],
            ],
        ]).write(to: tmp)
        var s = sceneWithCell()
        s = s.applySlab(nil)
        var c: Camera? = nil
        try StateStore.load(into: &s, camera: &c, from: tmp)
        XCTAssertEqual(s.slab?.planeA.h, 8, "h clamped to +8")
        XCTAssertEqual(s.slab?.planeA.k, -5, "valid negative k preserved")
        XCTAssertEqual(s.slab?.planeA.l, 8)
        XCTAssertEqual(s.slab?.planeB.k, -1, "default negative -1 preserved")
        XCTAssertEqual(s.slab?.planeB.l, -8, "l clamped to -8")
        // Negative finite distance passes through (UI slider allows -20...20).
        XCTAssertEqual(s.slab?.planeA.distance ?? 0, Float(-2.5), accuracy: 1e-4,
                       "finite negative slab distance must round-trip")
        XCTAssertTrue(s.slab?.planeA.distance.isFinite == true)
    }

    // MARK: - Issue 4. Camera validation rejects malformed state and normalizes
    // valid non-unit quaternions. All rejections are transactional (scene unchanged).

    func testCameraValidationRejectsAndNormalizes() throws {
        func loadCamera(_ obj: [String: Any]) throws -> Camera {
            let tmp = tempStateURL()
            var payload: [String: Any] = ["version": 1, "displayMode": "ballStick", "supercell": [1, 1, 1]]
            payload["camera"] = obj
            try JSONSerialization.data(withJSONObject: payload).write(to: tmp)
            var s = Scene()
            s.displayMode = .wireFrame
            var c: Camera? = Camera(); c?.distance = 17
            try StateStore.load(into: &s, camera: &c, from: tmp)
            return c!
        }

        // Valid non-unit quaternion (scaled 2x) is normalized on commit.
        let scaled = try loadCamera(["center": [1, 2, 3], "distance": 10,
                                     "rotation": ["x": 0, "y": 0, "z": 0, "w": 2], "perspective": false])
        XCTAssertEqual(simd_length(scaled.rotation.vector), 1, accuracy: 1e-3,
                       "non-unit quaternion must be normalized on commit")
        XCTAssertEqual(scaled.distance, 10, accuracy: 1e-4)

        // Zero quaternion -> rejected (stays at the seeded value).
        XCTAssertThrowsError(try loadCamera(["center": [0, 0, 0], "distance": 10,
                                             "rotation": ["x": 0, "y": 0, "z": 0, "w": 0], "perspective": false]))
        // Overflowed quaternion (huge scalars overflow on squaring) -> rejected.
        XCTAssertThrowsError(try loadCamera(["center": [0, 0, 0], "distance": 10,
                                             "rotation": ["x": 1e20, "y": 0, "z": 0, "w": 0], "perspective": false]))
        // Non-finite center -> rejected (test the validator directly: NaN cannot be
        // encoded as JSON, but the production path decodes into a Camera first).
        var nanCenter = Camera(); nanCenter.center = SIMD3(Float.nan, 0, 0)
        XCTAssertThrowsError(try Camera.validated(nanCenter))
        // Overflowed quaternion -> rejected (scales that overflow on squaring).
        var overflow = Camera(); overflow.rotation = simd_quatf(vector: simd_float4(1e20, 0, 0, 0))
        XCTAssertThrowsError(try Camera.validated(overflow))
        // Valid non-unit quaternion -> accepted AND normalized.
        var nonUnit = Camera(); nonUnit.rotation = simd_quatf(vector: simd_float4(0, 0, 0, 2))
        let normalized = try Camera.validated(nonUnit)
        XCTAssertEqual(simd_length(normalized.rotation.vector), 1, accuracy: 1e-3)
        // Already-unit quaternion passes through unchanged.
        let unit = Camera()
        XCTAssertEqual(try Camera.validated(unit).rotation, unit.rotation)
        // Non-positive / non-finite distance -> rejected.
        var zero = Camera(); zero.distance = 0
        XCTAssertThrowsError(try Camera.validated(zero))
        var neg = Camera(); neg.distance = -5
        XCTAssertThrowsError(try Camera.validated(neg))
        var nanDist = Camera(); nanDist.distance = Float.nan
        XCTAssertThrowsError(try Camera.validated(nanDist))
        // Zero quaternion -> rejected.
        var qzero = Camera(); qzero.rotation = simd_quatf(vector: .zero)
        XCTAssertThrowsError(try Camera.validated(qzero))
    }

    // MARK: - Issue 5. Measurement mode survives the framework reload.

    @MainActor
    func testMeasurementModeSurvivesFrameReload() throws {
        let source = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let initial = Scene(loaded: try Parser.load(source, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(initial, from: source, frameIndex: 0)
        XCTAssertEqual(controller.state.frameCount, 2)
        controller.state.measurementMode = .distance
        controller.state.frameIndex = 1   // production reload path
        XCTAssertEqual(controller.scene.measurementMode, .distance,
                       "scene.measurementMode must match state after frame reload")
        // Idempotent: re-entering the same mode stays consistent.
        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.measurementMode, .distance)
    }

    // MARK: - Issue 8. Hidden-structure hit testing + magnification.

    func testHitTestRespectsHiddenStructure() {
        var visible = Scene()
        visible.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]
        visible.showStructure = true
        XCTAssertTrue(MetalView.hitTestEnabled(scene: visible))

        var hidden = visible
        hidden.showStructure = false
        XCTAssertFalse(MetalView.hitTestEnabled(scene: hidden),
                       "hidden structure must not be pickable")

        let empty = Scene()
        XCTAssertFalse(MetalView.hitTestEnabled(scene: empty),
                       "empty scene is never pickable")
    }

    func testMagnifyFactorDirectionAndDamper() {
        XCTAssertEqual(MetalView.magnifyFactor(for: 0), 1, accuracy: 1e-5)
        // Positive pinch (zoom in) -> factor < 1 -> distance shrinks immediately.
        XCTAssertLessThan(MetalView.magnifyFactor(for: 0.5), 1)
        // Negative pinch (zoom out) -> factor > 1 -> distance grows.
        XCTAssertGreaterThan(MetalView.magnifyFactor(for: -0.5), 1)
    }

    // MARK: - Issue 9. Supercell refusal rolls back scene AND the sidebar state.

    @MainActor
    func testSupercellRefusalRollsBackState() throws {
        let fixture = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let wc = MainWindowController(scene: Scene(), showWindow: false)
        wc.loadFile(Scene(loaded: try Parser.load(fixture)), from: fixture, frameIndex: 0)
        let before = wc.scene.superCell
        XCTAssertEqual(wc.state.n1, 1)
        // One axis far beyond the atom cap (300_000 × baseAtoms(2) >> 500_000)
        // refuses the widen in a SINGLE onChange — using 1 atom keeps this fast.
        wc.state.n1 = 300_000
        XCTAssertEqual(wc.scene.superCell, before, "refused supercell leaves geometry untouched")
        XCTAssertEqual(wc.state.n1, before.n1, "sidebar rolled back to the accepted supercell")
        XCTAssertEqual(wc.state.n2, before.n2)
        XCTAssertEqual(wc.state.n3, before.n3)
    }

    // MARK: - Issue 7. Constant-value grid renders non-white; non-finite grids
    // are treated as empty (AppKit drawing requires the main actor).

    @MainActor
    func testConstantGridRendersNonWhite() throws {
        let view = ColorPlaneView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.grid = [[5.0, 5.0], [5.0, 5.0]]
        let (w, h) = (100, 100)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return XCTFail("no bitmap") }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx
        view.draw(view.bounds)
        ctx.flushGraphics()
        var nonWhite = 0
        for y in 0..<h { for x in 0..<w {
            var px = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&px, atX: x, y: y)
            if px[0] < 250 || px[1] < 250 || px[2] < 250 { nonWhite += 1 }
        } }
        XCTAssertGreaterThan(nonWhite, 0, "constant grid must render non-white pixels")
    }

    @MainActor
    func testNonFiniteGridIsRenderedAsEmpty() {
        // Actually invoke the drawing path on a non-finite grid and verify: (1) it
        // does not trap/crash, (2) it writes a deterministic, fully-populated fallback
        // (no uninitialized/black-transparent pixels left from a zeroed bitmap), and
        // (3) re-drawing is byte-identical (deterministic). The non-finite guard makes
        // the view skip the viridis bitmap and fall back to an empty view.
        let view = ColorPlaneView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.grid = [[1.0, Float.nan], [3.0, 4.0]]
        let (w, h) = (64, 64)
        func render() -> [UInt8] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { XCTFail("no bitmap"); return [] }
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = ctx
            XCTAssertNoThrow(view.draw(view.bounds))
            ctx.flushGraphics()
            guard let data = bitmap.bitmapData else { return [] }
            let count = bitmap.bytesPerRow * h
            return Array(UnsafeBufferPointer(start: data, count: count))
        }
        let first = render()
        XCTAssertFalse(first.isEmpty, "drawing produced no bitmap data")
        // No pixel may be left as the zeroed (0,0,0,0,...) garbage of an untouched bitmap:
        // every 4-byte slot must have alpha == 255 (opaque) so nothing is "random".
        for base in stride(from: 0, to: first.count, by: 4) {
            XCTAssertEqual(first[base + 3], 255, "non-finite grid fallback must paint opaque pixels")
        }
        // Determinism: a second draw into a fresh bitmap must be byte-for-byte identical.
        let second = render()
        XCTAssertEqual(first, second, "non-finite grid fallback must be deterministic across draws")
    }

    // MARK: - drawEmpty() diagnostic must be truthful: it must not label a
    // non-finite (or otherwise invalid) grid "Constant 2D field".

    func testColorPlaneEmptyLabelIsTruthful() {
        // No field at all.
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: nil), "No 2D field")
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: []), "No 2D field")
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: [[]]), "No 2D field")
        // A genuinely finite, constant grid → the only case that is constant.
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: [[5, 5], [5, 5]]), "Constant 2D field")
        // Non-finite value: NOT "Constant".
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: [[1.0, Float.nan], [3.0, 4.0]]), "Invalid 2D field")
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: [[Float.infinity, 1], [2, 3]]), "Invalid 2D field")
        // Jagged (non-rectangular) grid: render-invalid.
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: [[1, 2], [3]]), "Invalid 2D field")
        // Finite but genuinely varying: NOT "Constant" (it's a real field, not a flat one).
        XCTAssertEqual(ColorPlaneView.diagnosticLabel(for: [[1, 2], [3, 4]]), "Invalid 2D field")
    }

    // MARK: - Helpers

    // MARK: - Issue: resetView() must preserve the user's perspective/orthographic
    // projection after it replaces the camera with scene.defaultCamera().

    @MainActor
    func testResetViewPreservesProjection() throws {
        let wc = MainWindowController(scene: sceneWithAtoms(), showWindow: false)
        // Perspective: state.orthographic false => camera.perspective true.
        wc.state.orthographic = false
        XCTAssertTrue(wc.camera.perspective)
        wc.resetView()
        XCTAssertTrue(wc.camera.perspective,
                      "resetView must preserve a perspective projection (state.orthographic=false)")

        // Orthographic: state.orthographic true => camera.perspective false.
        wc.state.orthographic = true
        XCTAssertFalse(wc.camera.perspective)
        wc.resetView()
        XCTAssertFalse(wc.camera.perspective,
                       "resetView must preserve an orthographic projection (state.orthographic=true)")
    }

    // MARK: - Issue: structural atom mutations must not leave stale selectedAtoms or
    // measurementResult; true no-op paths must preserve them.

    func testWidenSuperCellClearsStaleSelection() {
        var s = sceneWithCell()
        s.selectedAtoms = [0]
        s.measurementResult = MeasurementResult(mode: .distance, atomIndices: [0, 1], value: 1.5, summary: "x")
        // Widening to (2,1,1) rebuilds the atom set.
        let widened = s.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertGreaterThan(widened.atoms.count, s.atoms.count, "supercell actually expanded")
        XCTAssertTrue(widened.selectedAtoms.isEmpty, "widening must clear stale selection indices")
        XCTAssertNil(widened.measurementResult, "widening must clear the locked measurement")
    }

    func testWidenIdentityPreservesSelection() {
        var s = sceneWithCell()
        s.selectedAtoms = [0]
        s.measurementResult = MeasurementResult(mode: .distance, atomIndices: [0], value: 0, summary: "x")
        // (1,1,1) on a scene whose baseAtoms == atoms is a no-op on the atom set.
        let same = s.widenSuperCell(SuperCell(n1: 1, n2: 1, n3: 1))
        XCTAssertEqual(same.atoms, s.atoms, "identity widen leaves the atom set unchanged")
        XCTAssertEqual(same.selectedAtoms, [0], "identity widen must preserve selection")
        XCTAssertNotNil(same.measurementResult, "identity widen must preserve the locked measurement")
    }

    func testApplySlabClearsStaleSelection() {
        var s = sceneWithCell()
        // Two atoms at distinct fractional heights so a slab plane can drop one.
        s.atoms = [Atom(coord: SIMD3(0, 1, 0), atomicNumber: 14, label: "Si"),
                   Atom(coord: SIMD3(0, 3, 0), atomicNumber: 14, label: "Si")]
        s.baseAtoms = s.atoms
        s.isCrystal = true
        s.selectedAtoms = [0, 1]
        s.measurementResult = MeasurementResult(mode: .distance, atomIndices: [0, 1], value: 2, summary: "x")
        // planeA n=(0,1,0) dA=0.4 keeps frac.y >= 0.4; planeB n=(0,1,0) dB=0.8 keeps frac.y<=0.8.
        // frac.y are 0.2 and 0.6 => only the second atom survives.
        var planeA = Plane(); planeA.k = 1; planeA.distance = 0.4
        var planeB = Plane(); planeB.k = 1; planeB.distance = 0.8
        let slab = Slab(planeA: planeA, planeB: planeB)
        let out = s.applySlab(slab)
        XCTAssertEqual(out.atoms.count, 1, "slab should filter down to one atom")
        XCTAssertTrue(out.selectedAtoms.isEmpty, "slab filter must clear stale selection indices")
        XCTAssertNil(out.measurementResult, "slab filter must clear the locked measurement")
    }

    func testApplySlabNoOpPreservesSelection() {
        var s = sceneWithCell()
        s.selectedAtoms = [0]
        s.measurementResult = MeasurementResult(mode: .distance, atomIndices: [0], value: 0, summary: "x")
        // A trivial slab that keeps every atom (wide bounds) leaves the set unchanged.
        var planeA = Plane(); planeA.k = 1; planeA.distance = -0.1
        var planeB = Plane(); planeB.k = 1; planeB.distance = 1.1
        let slab = Slab(planeA: planeA, planeB: planeB)
        let out = s.applySlab(slab)
        XCTAssertEqual(out.atoms, s.atoms, "all-keeping slab leaves the atom set unchanged")
        XCTAssertEqual(out.selectedAtoms, [0], "no-op slab must preserve selection")
        XCTAssertNotNil(out.measurementResult, "no-op slab must preserve the locked measurement")
        // Removing a slab that was never applied is a no-op and must preserve selection too.
        XCTAssertEqual(s.applySlab(nil).selectedAtoms, [0])
    }

    private func sceneWithAtoms() -> Scene {
        var s = Scene()
        s.atoms = [
            Atom(coord: SIMD3(-1, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 6, label: "C"),
        ]
        return s
    }

    private func sceneWithCell() -> Scene {
        var s = Scene()
        s.isCrystal = true
        s.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        s.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 14, label: "Si")]
        s.baseAtoms = s.atoms
        return s
    }

    private func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("regress-\(UUID().uuidString).mvis-state")
    }

    // MARK: - Round-2: export-size validation must reject non-finite / huge / overflowing
    // sizes BEFORE any graph CGContext/bitmap allocation.

    func testValidatedExportSizeRejectsNonFiniteAndOversized() {
        XCTAssertNoThrow(try App.validatedExportSize(CGSize(width: 800, height: 600)))
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: CGFloat.nan, height: 600)))
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: CGFloat.signalingNaN, height: 600)))
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: CGFloat.infinity, height: 600)))
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: -1, height: 600)))
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: 0, height: 600)))
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 600)))
    }

    func testValidatedExportSizeRejectsSubPixelAndTotalOverflow() {
        // 0.4 rounds to 0 → degenerate, non-drawable size.
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: 0.4, height: 0.4)))
        // Two large-but-in-range axes whose product exceeds the per-axis-derived ceiling.
        XCTAssertThrowsError(try App.validatedExportSize(CGSize(width: 100_000, height: 100_000)))
    }

    @MainActor
    func testDOSExportThrowsOnInvalidSizeInsteadOfTrapping() throws {
        let loaded = try loadTemporaryDOS(suffix: "dos")
        let dos = try XCTUnwrap(loaded.densityOfStates)
        let url = tempDir().appendingPathComponent("dos-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // NaN size must throw cleanly rather than trapping inside render().
        XCTAssertThrowsError(try DOSExporter.render(dos, size: CGSize(width: CGFloat.nan, height: 200)))
        // Int-overflowing size must throw cleanly.
        XCTAssertThrowsError(try DOSExporter.render(dos, size: CGSize(
            width: CGFloat.greatestFiniteMagnitude, height: 200)))
    }

    @MainActor
    func testGraphExportThrowsOnUnsupportedExtension() throws {
        // Unsupported extensions on any graph route must clearly fail, NOT silently
        // write PNG bytes (the old default branch). Band route tested here.
        _ = try loadTemporaryDOS(suffix: "dos")
        let loadedBand = Scene(loaded: try Parser.load(
            URL(fileURLWithPath: #file).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/CH3Rh111.out"), as: .bands))
        XCTAssertNotNil(loadedBand.bandStructure)
        let out = tempDir().appendingPathComponent("band-\(UUID().uuidString).bmp")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertThrowsError(try App.exportScene(loadedBand, camera: nil, to: out, size: CGSize(width: 160, height: 120)),
                            "unsupported .bmp extension must not silently produce PNG bytes")
    }

    private func loadTemporaryDOS(suffix: String) throws -> LoadedScene {
        let text = """
        # E (eV) dos(E) Int dos(E) EFermi = 2.5 eV
        -1.0  0.25  0.00
         0.0  1.50  0.75
         1.0  0.50  1.75
        """
        let url = tempDir().appendingPathComponent("regress-dos-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: url) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try Parser.load(url)
    }

    private func tempDir() -> URL { FileManager.default.temporaryDirectory }

    // MARK: - Round-2: magnification clamp

    func testMagnifyFactorClampsExtremeAndNonFiniteEvents() {
        XCTAssertEqual(MetalView.magnifyFactor(for: 0), 1, accuracy: 1e-5)
        // Directionality preserved at the clamp boundary.
        XCTAssertLessThan(MetalView.magnifyFactor(for: 0.5), 1)
        XCTAssertGreaterThan(MetalView.magnifyFactor(for: -0.5), 1)
        // Clamp bounds: factor is always finite, strictly positive, and at most 2.0.
        for raw in [Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, Float.nan, Float.infinity] {
            let f = MetalView.magnifyFactor(for: raw)
            XCTAssertTrue(f.isFinite, "factor must be finite for input \(raw)")
            XCTAssertGreaterThan(f, 0, "factor must stay positive for input \(raw)")
            XCTAssertLessThanOrEqual(f, 2, "factor must be clamped at/below 2 for input \(raw)")
        }
        // Non-finite events are treated as a no-op (factor 1.0) so they never corrupt
        // the camera distance; extreme finite input is clamped, not collapsed to zero.
        XCTAssertEqual(MetalView.magnifyFactor(for: Float.infinity), 1.0, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: -Float.infinity), 1.0, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: Float.nan), 1.0, accuracy: 1e-5)
        // Extreme finite forward pinch → a tiny-but-positive factor (would-be-zero avoided).
        XCTAssertGreaterThan(MetalView.magnifyFactor(for: Float.greatestFiniteMagnitude), 0,
                             "extreme finite pinch must not collapse to a zero factor")
    }

    // MARK: - Round-3: route-level unsupported-extension defense branches must throw a
    // truthful unsupported-format error, not invalidSize/noPNG. The outer App.exportScene
    // gate catches these first, but the inner branches are defense-in-depth and are tested
    // directly here (DOSExporter.export is public; App.exportGraph is internal).

    @MainActor
    func testDOSExportInnerDefaultThrowsUnsupportedFormat() throws {
        let loaded = try loadTemporaryDOS(suffix: "dos")
        let dos = try XCTUnwrap(loaded.densityOfStates)
        // .bmp passes DOSExporter.export's own size validation but is not a supported
        // container; the inner default branch must report the truthful reason.
        let out = tempDir().appendingPathComponent("dos-\(UUID().uuidString).bmp")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try DOSExporter.export(dos, to: out, size: CGSize(width: 200, height: 200))
            XCTFail("unsupported extension must throw")
        } catch let error as App.CLIError {
            XCTAssertTrue(error.description.contains("unsupported export extension"),
                          "expected truthful unsupported-format error, got \(error.description)")
        }
    }

    @MainActor
    func testGraphExportInnerDefaultThrowsUnsupportedFormat() throws {
        // App.exportGraph is the shared band/colorplane route. Call it directly with an
        // unsupported container so the test exercises the inner default branch, not the
        // outer App.exportScene extension gate.
        let view = ColorPlaneView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        let out = tempDir().appendingPathComponent("plane-\(UUID().uuidString).bmp")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try App.exportGraph(view, configure: { $0.grid = [[1.0, 2.0], [3.0, 4.0]] },
                                to: out, size: CGSize(width: 120, height: 120))
            XCTFail("unsupported extension must throw")
        } catch let error as App.CLIError {
            XCTAssertTrue(error.description.contains("unsupported export extension"),
                          "expected truthful unsupported-format error, got \(error.description)")
        }
    }

    // MARK: - Round-3: magnifyFactor clamps to a strictly positive 0.01 floor for extreme
    // finite input while preserving the normal 0.5 damper. Quantitative exact-value checks
    // for the damped range plus boundary/extreme cases.

    func testMagnifyFactorQuantitativeNormalAndExtreme() {
        // Normal inputs: exact 0.5 damper, no floor interference.
        XCTAssertEqual(MetalView.magnifyFactor(for: 0), 1.0, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: 0.5), 0.75, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: -0.5), 1.25, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: 1.0), 0.5, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: -1.0), 1.5, accuracy: 1e-5)
        // Upper clamp: raw -2 → factor 2.0 (the maximum).
        XCTAssertEqual(MetalView.magnifyFactor(for: -2.0), 2.0, accuracy: 1e-5)
        // Just inside the floor boundary: a large-but-finite forward pinch still damps.
        XCTAssertEqual(MetalView.magnifyFactor(for: 1.9), 0.05, accuracy: 1e-5)
        // Crossing into the floor: raw 2.0 → unclamped ~0 → pinned to 0.01.
        XCTAssertEqual(MetalView.magnifyFactor(for: 2.0), 0.01, accuracy: 1e-4)
        // Extreme finite forward pinch clamps raw to ~2, unclamped factor → ~0, floor pins to 0.01.
        XCTAssertEqual(MetalView.magnifyFactor(for: Float.greatestFiniteMagnitude), 0.01, accuracy: 1e-4,
                       "extreme finite pinch must bottom out at the 0.01 floor")
        // Extreme finite reverse pinch clamps raw to -2 → factor 2.0.
        XCTAssertEqual(MetalView.magnifyFactor(for: -Float.greatestFiniteMagnitude), 2.0, accuracy: 1e-5)
        // Non-finite events remain a no-op (factor 1.0), never hitting the floor.
        XCTAssertEqual(MetalView.magnifyFactor(for: Float.infinity), 1.0, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: -Float.infinity), 1.0, accuracy: 1e-5)
        XCTAssertEqual(MetalView.magnifyFactor(for: Float.nan), 1.0, accuracy: 1e-5)
    }

    // MARK: - Round-2: graceful Renderer-unavailable fallback

    @MainActor
    func testMainWindowControllerDegradesGracefullyWithoutRenderer() {
        // Force the renderer-creation failure seam and confirm the controller still
        // initializes, exposes valid state, and keeps the 3D canvas hidden-ish but
        // never traps. Metal devices are rare to truly fail on macOS, so this seam is
        // the only deterministic way to exercise the fallback path.
        MainWindowController.forceRendererFailure = true
        defer { MainWindowController.forceRendererFailure = false }
        let wc = MainWindowController(scene: sceneWithAtoms(), showWindow: false)
        XCTAssertNil(wc.renderer, "forced Metal failure must yield a nil renderer")
        // State and sidebar must remain fully functional for graphs/labels.
        wc.state.displayMode = .ballStick2D
        XCTAssertTrue(wc.scene.displayMode.is2D)
        XCTAssertNoThrow(wc.setNeedsRender())
    }

    // MARK: - Round: an animated XSF carries a SINGLE volumetric grid that the
    // XCrySDen parser attaches to the LAST animation frame (frame 0 has none).
    // reloadFrame copies scene.isoLevel onto the freshly parsed frame; if that
    // frame's scalarField span is narrower than the carried level, the level must
    // be clamped into the new range so it stays meaningful (out-of-range levels
    // must never leak through). Valid values and showIsoSurface visibility are
    // preserved across the reload.

    @MainActor
    func testReloadFrameClampsIsoLevelIntoNarrowerRangeOnAnimatedGrid() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        // Sanity-check the fixture: grid lives on frame 1 (range [0, 1.4]); frame 0 none.
        XCTAssertNil(try Parser.load(url, as: nil, frameIndex: 0).scalarField, "frame 0 must carry no grid")
        let f1 = try Parser.load(url, as: nil, frameIndex: 1).scalarField
        guard let field1 = f1 else { return XCTFail("frame 1 expected the single animation grid") }
        XCTAssertEqual(field1.minValue, 0.0, accuracy: 1e-4)
        XCTAssertEqual(field1.maxValue, 1.4, accuracy: 1e-4)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        // Load frame 0 (no grid -> isoLevel is currently inert).
        controller.loadFile(try Scene(loaded: Parser.load(url, as: nil, frameIndex: 0)),
                            from: url, format: nil, frameIndex: 0)
        XCTAssertEqual(controller.state.frameCount, 2)

        // A level valid for any sensible field but OUT OF RANGE for frame 1 (max 1.4).
        controller.scene.isoLevel = 10.0
        controller.scene.showIsoSurface = true

        // Reload into frame 1 (production sync->reloadFrame path).
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        guard controller.scene.scalarField != nil else { return XCTFail("frame 1 lost its grid after reload") }
        // Carried level (10) clamped into [0, 1.4]; visibility preserved.
        XCTAssertEqual(controller.scene.isoLevel, 1.4, accuracy: 1e-4,
                       "carried isoLevel must be clamped into the destination frame's scalar range")
        XCTAssertTrue(controller.scene.showIsoSurface, "isoSurface visibility must survive the reload")
    }

    @MainActor
    func testReloadFramePreservesValidIsoLevelWhenInDestRange() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(try Scene(loaded: Parser.load(url, as: nil, frameIndex: 0)),
                            from: url, format: nil, frameIndex: 0)
        // 0.7 sits inside frame 1's span [0, 1.4] -> must survive unchanged.
        controller.scene.isoLevel = 0.7
        controller.scene.showIsoSurface = true
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertEqual(controller.scene.isoLevel, 0.7, accuracy: 1e-4,
                       "an in-destination-range isoLevel must be preserved exactly")
        XCTAssertTrue(controller.scene.showIsoSurface)
    }

    // MARK: - Round: a non-finite scrolling delta must not corrupt the camera
    // distance to NaN/Inf. scrollZoomFactor() collapses non-finite input to a
    // no-op (= nil) so scrollWheel() returns early; finite input scales normally.

    func testScrollZoomFactorRejectsNonFinitePreservesFinite() {
        XCTAssertNil(MetalView.scrollZoomFactor(CGFloat.nan), "NaN delta -> no-op")
        XCTAssertNil(MetalView.scrollZoomFactor(CGFloat.infinity), "+Inf delta -> no-op")
        XCTAssertNil(MetalView.scrollZoomFactor(-CGFloat.infinity), "-Inf delta -> no-op")
        // The helper returns Float?, so unwrap with a sentinel for finite-input comparisons.
        func f(_ d: CGFloat) -> Float { MetalView.scrollZoomFactor(d) ?? Float.nan }
        // Zero delta is a no-op zoom; finite zooms scale as before.
        XCTAssertEqual(f(0), 1.0, accuracy: 1e-5)
        XCTAssertEqual(f(200), 1.2, accuracy: 1e-4)
        XCTAssertEqual(f(-200), 0.8, accuracy: 1e-4)
        XCTAssertEqual(f(1000), 2.0, accuracy: 1e-4, "large finite delta -> factor 2")
    }

    // MARK: - Round: restoring a saved animation frame rebuilds the atom set.
    // A saved selection/measurement is only portable when EVERY saved index is
    // valid for the REBUILT frame (a different cycle / supercell / slab can shrink
    // the count). resolveAnimationFrame must preserve a valid selection AND clear
    // the lock when ANY saved index is out of range for the new atom count.

    func testResolveAnimationFrameClearsStaleSelectionOnFrameRebuild() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_3to1.axsf")
        // Frame 0 parses to 3 atoms; frame 1 parses to 1 atom.
        let fc0 = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0))
        let fc1Count = try Scene(loaded: Parser.load(url, as: nil, frameIndex: 1)).atoms.count
        XCTAssertEqual(fc0.atoms.count, 3)
        XCTAssertEqual(fc1Count, 1)

        var scene = fc0
        let savedSel = [0, 2]      // valid in the 3-atom frame
        let savedResult = MeasurementResult(mode: .distance, atomIndices: [0, 2], value: 2.0, summary: "d")
        scene.selectedAtoms = savedSel
        scene.measurementResult = savedResult
        scene.currentFrame = 1     // diverge from loadedFrame(0) so the rebuild path runs
        scene.measurementMode = .distance

        try App.resolveAnimationFrame(scene: &scene, from: url, format: nil, loadedFrame: 0, fc: 2)
        XCTAssertEqual(scene.currentFrame, 1)
        XCTAssertEqual(scene.atoms.count, 1, "rebuild must reflect the 1-atom frame")
        // Index 2 is invalid for the 1-atom -> selection cleared, lock released.
        XCTAssertTrue(scene.selectedAtoms.isEmpty, "stale selection indices must be dropped")
        XCTAssertNil(scene.measurementResult, "locked measurement must be cleared with stale indices")
        XCTAssertEqual(scene.measurementMode, .distance, "measurement MODE survives (only indices are stale)")
    }

    func testResolveAnimationFramePreservesValidSelectionOnFrameRebuild() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_3to1.axsf")
        // Frame 0: 3 atoms; frame 1: 1 atom. Only index 0 survives into the 1-atom frame.
        let fc0 = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0))
        let fc1Count = try Scene(loaded: Parser.load(url, as: nil, frameIndex: 1)).atoms.count
        XCTAssertEqual(fc0.atoms.count, 3)
        XCTAssertEqual(fc1Count, 1)
        var scene = fc0
        // EVERY reference (selectedAtoms + measurementResult.atomIndices) points at index 0,
        // the only valid index in the 1-atom rebuilt frame -- so all of it must survive.
        let savedResult = MeasurementResult(mode: .distance, atomIndices: [0, 0], value: 1.5, summary: "d")
        scene.selectedAtoms = [0]
        scene.measurementResult = savedResult
        scene.currentFrame = 1
        try App.resolveAnimationFrame(scene: &scene, from: url, format: nil, loadedFrame: 0, fc: 2)
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.selectedAtoms, [0], "a selection valid for the new frame must be preserved")
        XCTAssertNotNil(scene.measurementResult, "the locked measurement must survive when all indices are valid")
        XCTAssertEqual(scene.measurementResult?.atomIndices, [0, 0],
                       "saved measurement atomIndices (all valid for new count) preserved in full")
    }
}
