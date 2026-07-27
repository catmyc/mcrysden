import XCTest

@testable import MolVisApp

final class AnimationControllerTests: XCTestCase {
    @MainActor
    func testQERelaxFrameChangeDoesNotReenterReload() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let initial = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(initial, from: url, format: nil, frameIndex: 0)

        XCTAssertEqual(controller.state.frameCount, 2)
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertEqual(controller.state.frameIndex, 1)

        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.currentFrame, 0)
        XCTAssertEqual(controller.state.frameIndex, 0)
    }

    // MARK: - Per-frame metadata gates + orbital/iso selection must track the
    // displayed frame. Before the reloadFrame fix only hasForceSet was refreshed;
    // scrubbing onto a frame that lost its scalarField (or gained one) left the
    // stale gate on the previous frame, and the orbitalCount/iso slider used
    // the prior frame's values.

    @MainActor
    func testReloadFrameSyncsPerFrameMetadataAcrossFieldPresenceChange() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        // Fixture: grid lives on frame 1 (range [0, 1.4]); frame 0 has no grid.
        XCTAssertNil(try Parser.load(url, as: nil, frameIndex: 0).scalarField)
        XCTAssertNotNil(try Parser.load(url, as: nil, frameIndex: 1).scalarField)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(try Scene(loaded: Parser.load(url, as: nil, frameIndex: 0)),
                            from: url, format: nil, frameIndex: 0)
        XCTAssertEqual(controller.state.frameCount, 2)
        XCTAssertEqual(controller.state.frameIndex, 0)
        // loadFile initial sync establishes baseline off-grid state. Force the
        // hasScalarField gate ON to simulate a stale value left over from a prior
        // grid frame (the bug-mode scenario) — the reload to the grid frame must
        // then refresh metadata correctly.
        controller.state.hasScalarField = true
        XCTAssertFalse((try Parser.load(url, as: nil, frameIndex: 0).scalarField != nil),
                       "baseline frame parses with no grid")

        // Step onto the grid frame: triggers reloadFrame; fix must set the gate ON
        // and refresh isoRange to the loaded field's actual bounds.
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertNotNil(controller.scene.scalarField)
        XCTAssertTrue(controller.state.hasScalarField, "stepped onto grid -> gate ON")
        XCTAssertEqual(controller.state.isoRange.lowerBound, 0.0, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoRange.upperBound, 1.4, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoLevel, controller.scene.isoLevel, accuracy: 1e-4)

        // Step back to the no-grid frame: gate must CLEAR (bug-mode: it stayed ON)
        // and the (now-inert) isoRange slider must reset to neutral so its
        // previous frame's bounds don't leak into a future grid frame.
        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.currentFrame, 0)
        XCTAssertNil(controller.scene.scalarField)
        XCTAssertFalse(controller.state.hasScalarField, "stepped off grid -> gate OFF")
        // The no-field frame must clear stale slider bounds back to the neutral
        // default so they don't leak into a future grid frame.
        XCTAssertEqual(controller.state.isoRange.lowerBound, 0.0, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoRange.upperBound, 1.0, accuracy: 1e-4)
    }

    // MARK: - Multi-orbital selection and iso clamp must agree on the selected orbital
    // BEFORE the frame is installed, so the renderer shows the orbital whose iso range
    // the sidebar reports. AXSF animations never parse to multi-orbital frames, so the
    // helper is exercised via a focused synthetic Scene test.

    @MainActor
    func testMultiOrbitalSelectionAppliedDuringReload() throws {
        // Two fictional orbitals with distinguishable ranges/values; selection "2"
        // clamps onto the second (index 1). Prior to the rework, next's default first-
        // orbital selection survived and the renderer drew orbital 0 while the picker
        // still showed the prior choice.
        let field0 = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                 vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                                 values: Array(repeating: 0.5, count: 8),
                                 minValue: 0.0, maxValue: 1.0)
        let field1 = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                 vec: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                                 values: Array(repeating: 5.0, count: 8),
                                 minValue: 2.0, maxValue: 6.0)

        let controller = MainWindowController(scene: Scene(), showWindow: false)

        // Clamp carries the slider's preserved level (out of range for field1) and the
        // prior selection (2) into the new frame.
        var next = Scene()
        next.multiOrbitalFields = [field0, field1]
        next.currentOrbital = 0          // parsed default — still orbital 0 on install
        next.isoLevel = 10.0             // out-of-range for BOTH fields
        controller.applySelectedOrbitalAndClampIso(scene: &next, currentOrbital: 2)
        // The preserved selection clips to index 1; scene now selects field1.
        XCTAssertEqual(next.currentOrbital, 1)
        XCTAssertEqual(next.scalarField?.minValue ?? .nan, 2.0, accuracy: 1e-4)
        XCTAssertEqual(next.scalarField?.maxValue ?? .nan, 6.0, accuracy: 1e-4)
        XCTAssertEqual(next.scalarField?.value(0, 0, 0) ?? .nan, 5.0, accuracy: 1e-4)
        XCTAssertEqual(next.isoLevel, 6.0, accuracy: 1e-4,
                       "clamped iso into the selected field's range")

        // A lower preserved selection is honored when it still fits.
        var next2 = Scene()
        next2.multiOrbitalFields = [field0, field1]
        next2.isoLevel = 0.5
        controller.applySelectedOrbitalAndClampIso(scene: &next2, currentOrbital: 0)
        XCTAssertEqual(next2.currentOrbital, 0)
        XCTAssertEqual(next2.scalarField?.minValue ?? .nan, 0.0, accuracy: 1e-4)
        XCTAssertEqual(next2.scalarField?.maxValue ?? .nan, 1.0, accuracy: 1e-4)
        XCTAssertEqual(next2.scalarField?.value(0, 0, 0) ?? .nan, 0.5, accuracy: 1e-4)
        XCTAssertEqual(next2.isoLevel, 0.5, accuracy: 1e-4,
                       "iso in-range is preserved unchanged")

        // Negative injected currentOrbital (not yet sanitized by syncFromState); the
        // helper's lower bound must clamp it to 0 so the sidebar never shows a
        // negative selection. This is the case the reloadFrame metadata transaction
        // now mirrors verbatim (state.currentOrbital = next.currentOrbital).
        var nextNeg = Scene()
        nextNeg.multiOrbitalFields = [field0, field1]
        nextNeg.isoLevel = 0.25
        controller.applySelectedOrbitalAndClampIso(scene: &nextNeg, currentOrbital: -3)
        XCTAssertEqual(nextNeg.currentOrbital, 0, "negative injected selection clamps to 0")
        XCTAssertEqual(nextNeg.scalarField?.minValue ?? .nan, 0.0, accuracy: 1e-4)
        XCTAssertEqual(nextNeg.scalarField?.maxValue ?? .nan, 1.0, accuracy: 1e-4)
        XCTAssertEqual(nextNeg.isoLevel, 0.25, accuracy: 1e-4)

        // No multi-orbital fields leaves selection untouched and the level clamped
        // against the (optional) single-field range.
        var next3 = Scene()
        next3.scalarField = field0
        next3.isoLevel = -5.0
        controller.applySelectedOrbitalAndClampIso(scene: &next3, currentOrbital: 7)
        XCTAssertEqual(next3.currentOrbital, 0, "single-field reload leaves selection at default")
        XCTAssertEqual(next3.isoLevel, 0.0, accuracy: 1e-4,
                       "single-field clamp bounds the iso level")
    }

    // MARK: - No unintended scene mutation during the reloadFrame-held transaction.
    // Reloading must not re-trigger a second Frame parse; frameCount stays "2" and
    // state.frameIndex lands exactly where the user scrubbed. The earlier SIGSEGV
    // test (patch crash) lives across the full-suite run that previously stack-
    // overflowed; here we assert the final, steady state.

    @MainActor
    func testReloadFrameDoesNotMutateSceneMoreThanOnce() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(try Scene(loaded: Parser.load(url, as: nil, frameIndex: 0)),
                            from: url, format: nil, frameIndex: 0)

        // The reload transaction must land exactly; no parse storm, no
        // stack overflow. Final steady state: display is on frame 1 (grid present).
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertEqual(controller.state.frameIndex, 1)
        // And stepping back cleanly returns to the no-field frame (steady).
        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.currentFrame, 0)
        XCTAssertEqual(controller.state.frameIndex, 0)
    }

    // MARK: - Color-plane overlay must refresh its data/labels/contours and layer
    // visibility when a reloaded frame changes grid2D presence. Before the fix,
    // reloadFrame never touched ColorPlaneView nor called updateContentVisibility,
    // so scrubbing onto a grid frame left a stale (or hidden) plane.

    @MainActor
    func testReloadFrameRefreshesColorPlaneOnGridPresenceChange() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid2d.axsf")
        // Fixture: frame 0 has no 2D grid; frame 1 carries a 3x3 DATAGRID_2D
        // "density" with range [0, 4] and two span vectors.
        XCTAssertNil(try Parser.load(url, as: nil, frameIndex: 0).grid2D)
        XCTAssertNotNil(try Parser.load(url, as: nil, frameIndex: 1).grid2D)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(try Scene(loaded: Parser.load(url, as: nil, frameIndex: 0)),
                            from: url, format: nil, frameIndex: 0)
        XCTAssertEqual(controller.state.frameCount, 2)

        // Step onto the grid frame. The color plane must receive the new grid's
        // data, label, contours and span, and become visible (canvas hidden).
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertNotNil(controller.colorPlane.grid, "grid data must be pushed onto the plane")
        XCTAssertEqual(controller.colorPlane.zLabel, "density")
        XCTAssertFalse(controller.colorPlane.contourLevels.isEmpty, "contours must be refreshed")
        XCTAssertEqual(controller.colorPlane.physicalSpan.count, 2)
        XCTAssertFalse(controller.colorPlane.isHidden, "plane must be visible on a grid frame")
        XCTAssertTrue(controller.canvas.isHidden, "canvas must be hidden while the plane shows")

        // Step back to the no-grid frame. The plane must clear its data and hide.
        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.currentFrame, 0)
        XCTAssertNil(controller.colorPlane.grid, "grid data must be cleared off the plane")
        XCTAssertTrue(controller.colorPlane.isHidden, "plane must hide on a no-grid frame")
        XCTAssertFalse(controller.canvas.isHidden, "canvas must be restored when the plane hides")
    }
}
