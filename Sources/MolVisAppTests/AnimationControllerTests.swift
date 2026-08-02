import XCTest

@testable import MolVisApp

final class AnimationControllerTests: XCTestCase {
    @MainActor
    func testReloadFrameIsNonReentrantAndMutatesOnce() throws {
        let relaxURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/si_relax.out")
        let relaxInitial = Scene(loaded: try Parser.load(relaxURL, as: nil, frameIndex: 0))
        let relaxController = MainWindowController(scene: Scene(), showWindow: false)
        relaxController.loadFile(relaxInitial, from: relaxURL, format: nil, frameIndex: 0)

        // QE relaxation frames must scrub without re-entering reloadFrame.
        XCTAssertEqual(relaxController.state.frameCount, 2)
        relaxController.state.frameIndex = 1
        XCTAssertEqual(relaxController.scene.currentFrame, 1)
        XCTAssertEqual(relaxController.state.frameIndex, 1)
        relaxController.state.frameIndex = 0
        XCTAssertEqual(relaxController.scene.currentFrame, 0)
        XCTAssertEqual(relaxController.state.frameIndex, 0)

        // The held reload transaction must also perform only one scene mutation
        // for an AXSF field frame and return cleanly to the no-field frame.
        let gridURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        let gridController = MainWindowController(scene: Scene(), showWindow: false)
        gridController.loadFile(try Scene(loaded: Parser.load(gridURL, as: nil, frameIndex: 0)),
                                from: gridURL, format: nil, frameIndex: 0)
        XCTAssertEqual(gridController.state.frameCount, 2)
        gridController.state.frameIndex = 1
        XCTAssertEqual(gridController.scene.currentFrame, 1)
        XCTAssertEqual(gridController.state.frameIndex, 1)
        gridController.state.frameIndex = 0
        XCTAssertEqual(gridController.scene.currentFrame, 0)
        XCTAssertEqual(gridController.state.frameIndex, 0)
    }

    // MARK: - Per-frame metadata gates + orbital/iso selection must track the
    // displayed frame. Before the reloadFrame fix only hasForceSet was refreshed;
    // scrubbing onto a frame that lost its scalarField (or gained one) left the
    // stale gate on the previous frame, and the orbitalCount/iso slider used
    // the prior frame's values.

    @MainActor
    func testReloadFrameSynchronizesMetadataAndFieldPresence() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid.axsf")
        // Fixture: scalar grid lives on frame 1 (range [0, 1.4]); frame 0 has none.
        XCTAssertNil(try Parser.load(url, as: nil, frameIndex: 0).scalarField)
        XCTAssertNotNil(try Parser.load(url, as: nil, frameIndex: 1).scalarField)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(try Scene(loaded: Parser.load(url, as: nil, frameIndex: 0)),
                            from: url, format: nil, frameIndex: 0)
        XCTAssertEqual(controller.state.frameCount, 2)
        XCTAssertEqual(controller.state.frameIndex, 0)
        // Simulate a stale gate from a prior grid frame; reload must refresh all
        // per-frame metadata when stepping onto and back off the field frame.
        controller.state.hasScalarField = true
        XCTAssertFalse((try Parser.load(url, as: nil, frameIndex: 0).scalarField != nil),
                       "baseline frame parses with no grid")

        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertNotNil(controller.scene.scalarField)
        XCTAssertTrue(controller.state.hasScalarField, "stepped onto grid -> gate ON")
        XCTAssertEqual(controller.state.isoRange.lowerBound, 0.0, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoRange.upperBound, 1.4, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoLevel, controller.scene.isoLevel, accuracy: 1e-4)

        controller.state.frameIndex = 0
        XCTAssertEqual(controller.scene.currentFrame, 0)
        XCTAssertNil(controller.scene.scalarField)
        XCTAssertFalse(controller.state.hasScalarField, "stepped off grid -> gate OFF")
        XCTAssertEqual(controller.state.isoRange.lowerBound, 0.0, accuracy: 1e-4)
        XCTAssertEqual(controller.state.isoRange.upperBound, 1.0, accuracy: 1e-4)

        // The same field-presence transaction must refresh the 2D color plane,
        // its labels/contours/spans, and sibling visibility.
        let planeURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.anim_grid2d.axsf")
        XCTAssertNil(try Parser.load(planeURL, as: nil, frameIndex: 0).grid2D)
        XCTAssertNotNil(try Parser.load(planeURL, as: nil, frameIndex: 1).grid2D)

        let planeController = MainWindowController(scene: Scene(), showWindow: false)
        planeController.loadFile(try Scene(loaded: Parser.load(planeURL, as: nil, frameIndex: 0)),
                                 from: planeURL, format: nil, frameIndex: 0)
        XCTAssertEqual(planeController.state.frameCount, 2)

        planeController.state.frameIndex = 1
        XCTAssertEqual(planeController.scene.currentFrame, 1)
        XCTAssertNotNil(planeController.colorPlane.grid, "grid data must be pushed onto the plane")
        XCTAssertEqual(planeController.colorPlane.zLabel, "density")
        XCTAssertFalse(planeController.colorPlane.contourLevels.isEmpty, "contours must be refreshed")
        XCTAssertEqual(planeController.colorPlane.physicalSpan.count, 2)
        XCTAssertFalse(planeController.colorPlane.isHidden, "plane must be visible on a grid frame")
        XCTAssertTrue(planeController.canvas.isHidden, "canvas must be hidden while the plane shows")

        planeController.state.frameIndex = 0
        XCTAssertEqual(planeController.scene.currentFrame, 0)
        XCTAssertNil(planeController.colorPlane.grid, "grid data must be cleared off the plane")
        XCTAssertTrue(planeController.colorPlane.isHidden, "plane must hide on a no-grid frame")
        XCTAssertFalse(planeController.canvas.isHidden, "canvas must be restored when the plane hides")
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

}
