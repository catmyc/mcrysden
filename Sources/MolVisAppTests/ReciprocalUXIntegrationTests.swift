import AppKit
import XCTest
import simd

@testable import MolVisApp

@MainActor
final class ReciprocalUXIntegrationTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func crystal() throws -> Scene {
        Scene(loaded: try Parser.load(fixture("si110.xsf")))
    }

    private func controller(_ scene: Scene? = nil) throws -> MainWindowController {
        let c = MainWindowController(scene: try scene ?? crystal(), showWindow: false)
        c.canvas.setFrameSize(NSSize(width: 400, height: 400))
        c.canvas.isHidden = false
        return c
    }

    private func presentation(for c: MainWindowController) throws -> (BrillouinZone, BZPresentation) {
        guard let cell = c.scene.cell,
              let bz = BrillouinZone.build(cell: cell, atoms: c.scene.baseAtoms) else {
            throw NSError(domain: "ReciprocalUXIntegrationTests", code: 1)
        }
        return (bz, BZPresentation(bz: bz, scene: c.scene))
    }

    private func project(_ world: SIMD3<Float>, camera: Camera,
                         viewport: SIMD2<Float>) -> SIMD2<Float> {
        let aspect = viewport.x / viewport.y
        let clip = camera.projectionMatrix(aspect: aspect)
            * camera.viewMatrix() * SIMD4<Float>(world.x, world.y, world.z, 1)
        let ndc = clip / clip.w
        return SIMD2((ndc.x * 0.5 + 0.5) * viewport.x,
                     (1 - (ndc.y * 0.5 + 0.5)) * viewport.y)
    }

    private func assertCameraEqual(_ lhs: Camera, _ rhs: Camera,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.center, rhs.center, file: file, line: line)
        XCTAssertEqual(lhs.distance, rhs.distance, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(lhs.perspective, rhs.perspective, file: file, line: line)
        XCTAssertEqual(lhs.rotation.vector.x, rhs.rotation.vector.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(lhs.rotation.vector.y, rhs.rotation.vector.y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(lhs.rotation.vector.z, rhs.rotation.vector.z, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(lhs.rotation.vector.w, rhs.rotation.vector.w, accuracy: 1e-6, file: file, line: line)
    }

    private func assertRotationEqual(_ lhs: Camera, _ rhs: Camera,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.rotation.vector.x, rhs.rotation.vector.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(lhs.rotation.vector.y, rhs.rotation.vector.y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(lhs.rotation.vector.z, rhs.rotation.vector.z, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(lhs.rotation.vector.w, rhs.rotation.vector.w, accuracy: 1e-6, file: file, line: line)
    }

    private func assertProjectedBZFits(_ c: MainWindowController,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let (bz, presentation) = try presentation(for: c)
        let viewport = SIMD2<Float>(400, 400)
        let aspect = viewport.x / viewport.y
        let camera = c.renderCamera()
        for face in bz.faces {
            for cartesian in face {
                let world = presentation.world(cartesian: cartesian)
                let clip = camera.projectionMatrix(aspect: aspect)
                    * camera.viewMatrix() * SIMD4<Float>(world.x, world.y, world.z, 1)
                let ndc = clip / clip.w
                XCTAssertLessThanOrEqual(abs(ndc.x), aspect * 0.9 + 1e-4, file: file, line: line)
                XCTAssertLessThanOrEqual(abs(ndc.y), 0.9 + 1e-4, file: file, line: line)
                XCTAssertGreaterThanOrEqual(ndc.z, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(ndc.z, 1, file: file, line: line)
            }
        }
    }

    private func routeLabels(_ c: MainWindowController) -> [LabelOverlayView.Label] {
        c.labelOverlay.labels.filter {
            $0.style == .routeNode || $0.style == .selectedRouteNode
        }
    }

    private func tooltip(_ c: MainWindowController) -> LabelOverlayView.Label? {
        c.labelOverlay.labels.first { $0.style == .tooltip }
    }

    func testHoverHitMissExitAndNilDoNotMutateRoute() throws {
        let c = try controller()
        let (bz, presentation) = try presentation(for: c)
        c.state.editKPathOnBZ = true
        let gamma = try XCTUnwrap(bz.candidates().first { $0.type == .center })
        let viewport = SIMD2<Float>(400, 400)
        let point = project(presentation.world(cartesian: gamma.cartesian),
                            camera: c.camera, viewport: viewport)
        let routeBefore = c.state.kPathPoints
        let buildCount = c.bzBuildCount

        c.handleReciprocalPathHover(at: point, viewport: viewport)

        XCTAssertEqual(c.state.kPathPoints, routeBefore)
        XCTAssertNotNil(tooltip(c))
        XCTAssertEqual(c.bzBuildCount, buildCount, "hover must reuse the entry BZ cache")

        c.handleReciprocalPathHover(at: SIMD2<Float>(2, 2), viewport: viewport)
        XCTAssertNil(tooltip(c), "a miss clears the transient tooltip")
        c.handleReciprocalPathHover(at: point, viewport: viewport)
        XCTAssertNotNil(tooltip(c))
        c.handleReciprocalPathHover(at: nil, viewport: viewport)
        XCTAssertNil(tooltip(c))

        c.handleReciprocalPathHover(at: point, viewport: viewport)
        c.state.editKPathOnBZ = false
        XCTAssertNil(tooltip(c), "edit-mode exit clears hover")
        c.handleReciprocalPathHover(at: point, viewport: viewport)
        XCTAssertNil(tooltip(c), "hover is ignored outside edit mode")
        XCTAssertEqual(c.state.kPathPoints, routeBefore)
    }

    func testProjectionChangeClearsTransientReciprocalHover() throws {
        let c = try controller()
        let (bz, presentation) = try presentation(for: c)
        c.state.editKPathOnBZ = true
        let gamma = try XCTUnwrap(bz.candidates().first { $0.type == .center })
        let viewport = SIMD2<Float>(400, 400)
        let point = project(presentation.world(cartesian: gamma.cartesian),
                            camera: c.camera, viewport: viewport)
        c.handleReciprocalPathHover(at: point, viewport: viewport)
        XCTAssertNotNil(tooltip(c))

        c.state.orthographic.toggle()

        XCTAssertNil(tooltip(c), "a projection change must invalidate the old hover")
    }

    func testSupercellChangeClearsTransientReciprocalHover() throws {
        let c = try controller()
        let (bz, presentation) = try presentation(for: c)
        c.state.editKPathOnBZ = true
        let gamma = try XCTUnwrap(bz.candidates().first { $0.type == .center })
        let viewport = SIMD2<Float>(400, 400)
        let point = project(presentation.world(cartesian: gamma.cartesian),
                            camera: c.camera, viewport: viewport)
        c.handleReciprocalPathHover(at: point, viewport: viewport)
        XCTAssertNotNil(tooltip(c))

        c.state.n1 = 2

        XCTAssertEqual(c.scene.superCell.n1, 2)
        XCTAssertNil(tooltip(c), "a supercell presentation change must invalidate hover")
    }

    func testAcceptedSupercellChangeInvalidatesReciprocalAccessibilityChildren() throws {
        let c = try controller()
        c.state.editKPathOnBZ = true
        _ = c.canvas.reciprocalAccessibilityElementsForTesting()
        var notifications: [NSAccessibility.Notification] = []
        c.canvas.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        let before = try presentation(for: c).1

        c.state.n1 = 2

        let after = try presentation(for: c).1
        XCTAssertNotEqual(after.center, before.center)
        XCTAssertNotEqual(after.inv, before.inv)
        XCTAssertEqual(notifications, [.layoutChanged])
    }

    func testRejectedOrNoOpSupercellDoesNotInvalidateReciprocalAccessibilityChildren() throws {
        let c = try controller()
        c.state.editKPathOnBZ = true
        _ = c.canvas.reciprocalAccessibilityElementsForTesting()
        var notifications: [NSAccessibility.Notification] = []
        c.canvas.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }

        c.state.n1 = 1
        XCTAssertTrue(notifications.isEmpty, "same supercell notified: \(notifications)")
        notifications.removeAll()
        c.state.n1 = 1_000_000

        XCTAssertEqual(c.scene.superCell, SuperCell())
        XCTAssertTrue(notifications.isEmpty, "unexpected notifications: \(notifications)")
    }

    func testAcceptedSlabPresentationChangeInvalidatesReciprocalAccessibilityChildren() throws {
        let c = try controller()
        c.state.slabA_dist = 0.25
        c.state.slabB_dist = -0.25
        c.state.editKPathOnBZ = true
        _ = c.canvas.reciprocalAccessibilityElementsForTesting()
        var notifications: [NSAccessibility.Notification] = []
        c.canvas.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        let before = try presentation(for: c).1

        c.state.slabEnabled = true

        let after = try presentation(for: c).1
        XCTAssertNotEqual(after.center, before.center)
        XCTAssertNotEqual(after.inv, before.inv)
        XCTAssertEqual(notifications, [.layoutChanged])

        _ = c.canvas.reciprocalAccessibilityElementsForTesting()
        notifications.removeAll()
        c.state.slabEnabled = true
        XCTAssertTrue(notifications.isEmpty,
                      "repeating an accepted slab state is a no-op: \(notifications)")
    }

    func testTooltipContainsLabelTypeFiniteFractionAndIsNotExported() throws {
        let c = try controller()
        let (bz, presentation) = try presentation(for: c)
        c.state.editKPathOnBZ = true
        let gamma = try XCTUnwrap(bz.candidates().first { $0.type == .center })
        let point = project(presentation.world(cartesian: gamma.cartesian),
                            camera: c.camera, viewport: SIMD2<Float>(400, 400))
        c.handleReciprocalPathHover(at: point, viewport: SIMD2<Float>(400, 400))

        let label = try XCTUnwrap(tooltip(c))
        let picked = try XCTUnwrap(MainWindowController.pickBZCandidate(
            candidates: bz.candidates(), presentation: presentation,
            camera: c.renderCamera(), viewport: SIMD2<Float>(400, 400), click: point))
        XCTAssertTrue(label.symbol.contains(picked.point.label))
        let type = switch picked.type {
        case .center: "Gamma"
        case .edge: "vertex"
        case .line: "edge midpoint"
        case .polyface: "face center"
        }
        XCTAssertTrue(label.symbol.contains(type))
        XCTAssertTrue(label.symbol.contains("."))
        XCTAssertFalse(label.symbol.localizedCaseInsensitiveContains("nan"))
        XCTAssertFalse(label.symbol.localizedCaseInsensitiveContains("inf"))
        XCTAssertFalse(c.currentRenderExportOptions.labels.contains { $0.style == .tooltip })
    }

    func testRouteLabelsAreIndependentOfAtomLabelFlagAndSelectedStyleWins() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.showLabels = false
        c.state.replaceKPath(points: [KPoint(.zero, "G"), KPoint(SIMD3(0.5, 0, 0), "X")],
                             breaks: [], provenance: .userEdited, signature: nil)
        c.setNeedsRender()

        XCTAssertFalse(c.scene.showLabels)
        XCTAssertFalse(routeLabels(c).isEmpty, "route labels must not depend on atom labels")
        XCTAssertTrue(routeLabels(c).allSatisfy { $0.style == .routeNode })

        c.selectKPathNode(1)
        let selected = routeLabels(c).filter { $0.style == .selectedRouteNode }
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.symbol, "X")
    }

    func testOverlappingRouteLabelsSuppressNormalsButKeepSelected() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.replaceKPath(points: [KPoint(.zero, "first"), KPoint(.zero, "second")],
                             breaks: [], provenance: .userEdited, signature: nil)
        c.setNeedsRender()
        XCTAssertEqual(routeLabels(c).map(\.symbol), ["first"])

        c.selectKPathNode(1)
        XCTAssertEqual(routeLabels(c).map(\.symbol), ["second"])
        XCTAssertEqual(routeLabels(c).first?.style, .selectedRouteNode)
    }

    func testOffscreenAndNonfiniteRouteNodesAreSkipped() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.replaceKPath(points: [
            KPoint(SIMD3(100, 100, 100), "offscreen"),
            KPoint(SIMD3(Float.nan, 0, 0), "nonfinite")
        ], breaks: [], provenance: .userEdited, signature: nil)
        c.setNeedsRender()
        XCTAssertTrue(routeLabels(c).isEmpty)
    }

    func testAutomaticEntryFitIsOneShotAndExitRestoresExactCamera() throws {
        let c = try controller()
        var original = c.camera
        original.center = SIMD3(7, -3, 2)
        original.distance = 73
        original.perspective = true
        original.rotation = simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3(1, 2, 3)))
        c.camera = original

        c.state.editKPathOnBZ = true
        let fitted = c.camera
        XCTAssertNotEqual(fitted.center, original.center)
        XCTAssertNotEqual(fitted.distance, original.distance)
        let buildCount = c.bzBuildCount
        c.state.atomScale += 0.01
        assertCameraEqual(c.camera, fitted)
        XCTAssertEqual(c.bzBuildCount, buildCount)

        c.state.editKPathOnBZ = false
        assertCameraEqual(c.camera, original)
    }

    func testReciprocalEditExitRestoresHiddenBrillouinZone() throws {
        let c = try controller()
        c.state.showBrillouinZone = false

        c.state.editKPathOnBZ = true
        XCTAssertTrue(c.state.showBrillouinZone)
        XCTAssertTrue(c.scene.showBrillouinZone)

        c.state.editKPathOnBZ = false

        XCTAssertFalse(c.state.showBrillouinZone)
        XCTAssertFalse(c.scene.showBrillouinZone)
    }

    func testReciprocalEditExitPreservesVisibleBrillouinZone() throws {
        let c = try controller()
        c.state.showBrillouinZone = true

        c.state.editKPathOnBZ = true
        c.state.editKPathOnBZ = false

        XCTAssertTrue(c.state.showBrillouinZone)
        XCTAssertTrue(c.scene.showBrillouinZone)
    }

    func testReciprocalEditRestoresExact2DModeAndCamera() throws {
        var scene = try crystal()
        scene.displayMode = .ballStick2D
        let c = try controller(scene)
        var original = c.camera
        original.center = SIMD3(-2, 4, 1)
        original.distance = 17
        original.perspective = true
        original.rotation = simd_quatf(angle: -0.3, axis: simd_normalize(SIMD3(1, 2, 1)))
        c.camera = original
        c.state.orthographic = false

        c.state.editKPathOnBZ = true

        XCTAssertEqual(c.scene.displayMode, .ballStick)
        XCTAssertEqual(c.state.displayMode, .ballStick)

        c.state.editKPathOnBZ = false

        XCTAssertEqual(c.scene.displayMode, .ballStick2D)
        XCTAssertEqual(c.state.displayMode, .ballStick2D)
        XCTAssertFalse(c.state.orthographic)
        assertCameraEqual(c.camera, original)
        XCTAssertTrue(c.canvas.delegate === c.renderer2D)
    }

    func testReciprocalEditRestoresExact3DModeAndCamera() throws {
        var scene = try crystal()
        scene.displayMode = .wireFrame
        let c = try controller(scene)
        var original = c.camera
        original.center = SIMD3(3, -1, 2)
        original.distance = 23
        original.perspective = true
        original.rotation = simd_quatf(angle: 0.2, axis: simd_normalize(SIMD3(2, 1, 3)))
        c.camera = original
        c.state.orthographic = false

        c.state.editKPathOnBZ = true
        c.state.editKPathOnBZ = false

        XCTAssertEqual(c.scene.displayMode, .wireFrame)
        XCTAssertEqual(c.state.displayMode, .wireFrame)
        assertCameraEqual(c.camera, original)
    }

    func testOrthographicToPerspectiveRefitsProjectedBZOnceAndPreservesRotation() throws {
        let c = try controller()
        var original = c.camera
        original.rotation = simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3(1, 2, 3)))
        c.camera = original
        c.state.editKPathOnBZ = true
        let rotationBeforeToggle = c.camera
        let framesBeforeToggle = c.reciprocalEditorFrameCount

        c.state.orthographic = false

        XCTAssertTrue(c.camera.perspective)
        XCTAssertEqual(c.reciprocalEditorFrameCount, framesBeforeToggle + 1)
        assertRotationEqual(c.camera, rotationBeforeToggle)
        try assertProjectedBZFits(c)

        let fitted = c.camera
        c.state.atomScale += 0.01
        XCTAssertEqual(c.reciprocalEditorFrameCount, framesBeforeToggle + 1,
                       "unrelated sidebar changes must not refit the reciprocal editor")
        assertCameraEqual(c.camera, fitted)
    }

    func testPerspectiveToOrthographicRefitsProjectedBZOnceAndPreservesRotation() throws {
        let c = try controller()
        c.state.orthographic = false
        var original = c.camera
        original.rotation = simd_quatf(angle: -0.35, axis: simd_normalize(SIMD3(2, 1, 3)))
        original.distance = 31
        c.camera = original
        c.state.editKPathOnBZ = true
        let rotationBeforeToggle = c.camera
        let framesBeforeToggle = c.reciprocalEditorFrameCount

        c.state.orthographic = true

        XCTAssertFalse(c.camera.perspective)
        XCTAssertEqual(c.reciprocalEditorFrameCount, framesBeforeToggle + 1)
        assertRotationEqual(c.camera, rotationBeforeToggle)
        try assertProjectedBZFits(c)

        let fitted = c.camera
        c.state.showLabels.toggle()
        XCTAssertEqual(c.reciprocalEditorFrameCount, framesBeforeToggle + 1,
                       "unrelated sidebar changes must not refit the reciprocal editor")
        assertCameraEqual(c.camera, fitted)
    }

    func testInvalidOrEmptyBZDoesNotChangeCamera() throws {
        var empty = Scene()
        empty.isCrystal = true
        empty.cell = Cell(a: .zero, b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        let c = try controller(empty)
        let original = c.camera
        c.state.showBrillouinZone = false
        c.state.editKPathOnBZ = true
        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertFalse(c.state.reciprocalEditorAvailable)
        XCTAssertEqual(c.state.reciprocalEditorStatusText,
                       "Brillouin zone unavailable for this cell.")
        XCTAssertFalse(c.state.showBrillouinZone)
        XCTAssertFalse(c.scene.showBrillouinZone)
        assertCameraEqual(c.camera, original)
        XCTAssertTrue(c.labelOverlay.labels.filter { $0.style == .tooltip }.isEmpty)

        c.handleReciprocalPathHover(at: SIMD2(200, 200), viewport: SIMD2(400, 400))
        XCTAssertNil(tooltip(c))
    }

    func testRendererFailureRejectsReciprocalEntryWithoutExposingEditor() throws {
        MainWindowController.forceRendererFailure = true
        defer { MainWindowController.forceRendererFailure = false }

        var scene = try crystal()
        scene.displayMode = .wireFrame
        let c = try controller(scene)
        c.state.orthographic = false
        var original = c.camera
        original.center = SIMD3(4, -2, 1)
        original.distance = 21
        original.perspective = true
        c.camera = original
        c.state.showBrillouinZone = false

        c.state.editKPathOnBZ = true

        XCTAssertNil(c.renderer)
        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertEqual(c.state.reciprocalEditorStatusText, "Metal renderer unavailable.")
        XCTAssertEqual(c.scene.displayMode, .wireFrame)
        XCTAssertEqual(c.state.displayMode, .wireFrame)
        XCTAssertFalse(c.state.showBrillouinZone)
        XCTAssertFalse(c.scene.showBrillouinZone)
        XCTAssertFalse(c.renderer?.showBZLandmarks ?? false)
        assertCameraEqual(c.camera, original)
        XCTAssertFalse(c.canvas.handleReciprocalKeyboard(.next))
        XCTAssertTrue(c.canvas.reciprocalAccessibilityElementsForTesting().isEmpty)

        c.handleReciprocalPathHover(at: SIMD2(200, 200), viewport: SIMD2(400, 400))
        XCTAssertNil(tooltip(c))

        c.state.showBrillouinZone = true
        XCTAssertTrue(c.state.showBrillouinZone)
        XCTAssertTrue(c.scene.showBrillouinZone)
    }

    func testPathologicalCellAutomaticallyLeavesEditModeWithUnavailableReason() throws {
        var scene = Scene()
        scene.isCrystal = true
        scene.cell = Cell(a: SIMD3<Float>(1e-8, 0, 0),
                          b: SIMD3<Float>(0, 1, 0),
                          c: SIMD3<Float>(0, 0, 1))
        let c = try controller(scene)

        c.state.editKPathOnBZ = true

        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertFalse(c.state.reciprocalEditorAvailable)
        XCTAssertEqual(c.state.reciprocalEditorStatusText,
                       "Brillouin zone unavailable for this cell.")
        XCTAssertFalse(c.renderer?.showBZLandmarks ?? false)
        c.state.showBrillouinZone = true
        XCTAssertTrue(c.scene.showBrillouinZone,
                      "normal BZ visibility must remain independently controllable")
    }

    func testViewResetAndLoadClearTransientReciprocalStateWithoutStaleRestore() throws {
        let c = try controller()
        let (bz, presentation) = try presentation(for: c)
        c.state.editKPathOnBZ = true
        let gamma = try XCTUnwrap(bz.candidates().first { $0.type == .center })
        let point = project(presentation.world(cartesian: gamma.cartesian),
                            camera: c.camera, viewport: SIMD2<Float>(400, 400))
        c.handleReciprocalPathHover(at: point, viewport: SIMD2<Float>(400, 400))
        XCTAssertNotNil(tooltip(c))
        c.resetView()
        XCTAssertNil(tooltip(c))

        var stale = c.camera
        stale.center = SIMD3(99, 99, 99)
        c.camera = stale
        c.loadFile(try crystal(), from: fixture("si110.xsf"), frameIndex: 0)
        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertNotEqual(c.camera.center, stale.center)
    }

    func testFrameReplacementDoesNotRestoreOldEditCamera() throws {
        let url = fixture("si.anim_grid.axsf")
        let c = try controller(Scene())
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, frameIndex: 0)
        c.canvas.setFrameSize(NSSize(width: 400, height: 400))
        c.state.editKPathOnBZ = true
        var frameCamera = c.camera
        frameCamera.distance += 4
        c.camera = frameCamera
        c.state.reciprocalEditorStatusText = "stale status"
        c.state.frameIndex = 1
        XCTAssertEqual(c.scene.currentFrame, 1)
        XCTAssertFalse(c.state.editKPathOnBZ, "accepted frame replacement exits reciprocal edit mode")
        XCTAssertTrue(c.state.reciprocalEditorAvailable)
        XCTAssertNil(c.state.reciprocalEditorStatusText)
        XCTAssertFalse(c.renderer?.showBZLandmarks ?? false)
        XCTAssertTrue(c.canvas.reciprocalAccessibilityElementsForTesting().isEmpty)
        let afterFrame = c.camera
        var expected = c.scene.defaultCamera()
        expected.perspective = !c.state.orthographic
        assertCameraEqual(afterFrame, expected)

        // A later edit toggle must capture only the new frame's normal camera.
        c.state.editKPathOnBZ = true
        c.state.editKPathOnBZ = false
        assertCameraEqual(c.camera, afterFrame)
    }

    func testFrameReplacementCarriesPreEditor2DHiddenBZPreferences() throws {
        let url = fixture("si.anim_grid.axsf")
        let c = try controller(Scene())
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, frameIndex: 0)
        c.canvas.setFrameSize(NSSize(width: 400, height: 400))
        c.state.displayMode = .ballStick2D
        c.state.showBrillouinZone = false
        c.state.orthographic = false

        c.state.editKPathOnBZ = true
        XCTAssertEqual(c.scene.displayMode, .ballStick)
        XCTAssertTrue(c.scene.showBrillouinZone)

        c.state.frameIndex = 1

        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertEqual(c.state.displayMode, .ballStick2D)
        XCTAssertEqual(c.scene.displayMode, .ballStick2D)
        XCTAssertFalse(c.state.showBrillouinZone)
        XCTAssertFalse(c.scene.showBrillouinZone)
        XCTAssertFalse(c.state.orthographic)
        XCTAssertTrue(c.camera.perspective)
        var expected = c.scene.defaultCamera()
        expected.perspective = true
        assertCameraEqual(c.camera, expected)
        XCTAssertTrue(c.canvas.delegate === c.renderer2D)
        XCTAssertNil(c.state.reciprocalEditorStatusText)
        XCTAssertTrue(c.canvas.reciprocalAccessibilityElementsForTesting().isEmpty)
    }

    func testFrameReplacementCarriesPreVisible3DPreferences() throws {
        let url = fixture("si.anim_grid.axsf")
        let c = try controller(Scene())
        c.loadFile(Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0)),
                   from: url, frameIndex: 0)
        c.canvas.setFrameSize(NSSize(width: 400, height: 400))
        c.state.displayMode = .wireFrame
        c.state.showBrillouinZone = true
        c.state.orthographic = true

        c.state.editKPathOnBZ = true
        XCTAssertEqual(c.scene.displayMode, .wireFrame)
        XCTAssertTrue(c.scene.showBrillouinZone)

        c.state.frameIndex = 1

        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertEqual(c.state.displayMode, .wireFrame)
        XCTAssertEqual(c.scene.displayMode, .wireFrame)
        XCTAssertTrue(c.state.showBrillouinZone)
        XCTAssertTrue(c.scene.showBrillouinZone)
        XCTAssertTrue(c.state.orthographic)
        XCTAssertFalse(c.camera.perspective)
        var expected = c.scene.defaultCamera()
        expected.perspective = false
        assertCameraEqual(c.camera, expected)
        XCTAssertNil(c.state.reciprocalEditorStatusText)
    }

    func testExportProjectsPersistentLabelsForRequestedAspectAndBounds() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.showLabels = false
        c.state.replaceKPath(points: [KPoint(.zero, "G")], breaks: [],
                             provenance: .userEdited, signature: nil)
        c.setNeedsRender()

        let live = try XCTUnwrap(routeLabels(c).first)
        let liveViewport = SIMD2<Float>(400, 400)
        let (_, presentation) = try presentation(for: c)
        let liveExpected = project(presentation.world(frac: .zero),
                                   camera: c.renderCamera(), viewport: liveViewport)
        let exportViewport = SIMD2<Float>(800, 300)
        let expected = project(presentation.world(frac: .zero),
                               camera: c.renderCamera(), viewport: exportViewport)

        let exported = try c.exportRenderOptions(for: CGSize(width: 800, height: 300))
        let label = try XCTUnwrap(exported.labels.first { $0.style == .routeNode })
        XCTAssertNotEqual(label.x, live.x, "export must not reuse live-canvas coordinates")
        XCTAssertEqual(live.x, CGFloat(liveExpected.x + 6), accuracy: 0.01)
        XCTAssertEqual(label.x, CGFloat(expected.x + 6), accuracy: 0.01)
        XCTAssertEqual(label.y, CGFloat(expected.y - 6), accuracy: 0.01)
        XCTAssertFalse(exported.labels.contains { $0.style == .tooltip })

        let drawingRect = LabelOverlayView.drawingRect(for: label)
        XCTAssertGreaterThanOrEqual(drawingRect.minX, 0)
        XCTAssertGreaterThanOrEqual(drawingRect.minY, 0)
        XCTAssertLessThanOrEqual(drawingRect.maxX, CGFloat(exportViewport.x))
        XCTAssertLessThanOrEqual(drawingRect.maxY, CGFloat(exportViewport.y))
        XCTAssertThrowsError(try c.exportRenderOptions(
            for: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 300)))
    }

    func testRouteLabelClampHandlesEdgesCornersAndOversizedLabels() {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 60)
        let centered = LabelOverlayView.Label(symbol: "center", x: 40, y: 20, style: .routeNode)
        XCTAssertEqual(MainWindowController.clampedRouteLabel(centered, in: bounds), centered,
                       "node-relative placement should remain unchanged when it fits")

        for label in [
            LabelOverlayView.Label(symbol: "top-left", x: -10, y: -8, style: .routeNode),
            LabelOverlayView.Label(symbol: "bottom-right", x: 96, y: 56, style: .selectedRouteNode)
        ] {
            let clamped = MainWindowController.clampedRouteLabel(label, in: bounds)
            let rect = LabelOverlayView.drawingRect(for: clamped)
            XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX)
            XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY)
            XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX)
            XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY)
        }

        let oversized = LabelOverlayView.Label(symbol: String(repeating: "x", count: 300),
                                                x: -100, y: -100, style: .routeNode)
        let safelyAnchored = MainWindowController.clampedRouteLabel(oversized, in: bounds)
        let oversizedRect = LabelOverlayView.drawingRect(for: safelyAnchored)
        XCTAssertEqual(oversizedRect.minX, bounds.minX)
        XCTAssertEqual(oversizedRect.minY, bounds.minY)
        XCTAssertTrue(oversizedRect.width.isFinite && oversizedRect.height.isFinite)
    }

    func testControllerExportCarriesOnlyAValidRenderedRouteSelection() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.replaceKPath(points: [KPoint(.zero, "G")], breaks: [],
                             provenance: .userEdited, signature: nil)
        c.selectKPathNode(0)
        XCTAssertEqual(c.currentRenderExportOptions.selectedKPathNode, 0)

        c.selectKPathNode(1024)
        XCTAssertNil(c.currentRenderExportOptions.selectedKPathNode)
        c.selectKPathNode(-1)
        XCTAssertNil(c.currentRenderExportOptions.selectedKPathNode)

        c.canvas.isHidden = true
        XCTAssertNil(c.currentRenderExportOptions.selectedKPathNode)
        XCTAssertNil(RenderExportOptions().selectedKPathNode)
    }

    func testHoverOnlyChangesTransientTooltipAndReusesPersistentLabels() throws {
        let c = try controller()
        let (bz, presentation) = try presentation(for: c)
        c.state.showBrillouinZone = true
        c.state.editKPathOnBZ = true
        c.setNeedsRender()
        let persistentBefore = c.labelOverlay.labels.filter { $0.style != .tooltip }
        let buildCount = c.bzBuildCount
        let gamma = try XCTUnwrap(bz.candidates().first { $0.type == .center })
        let point = project(presentation.world(cartesian: gamma.cartesian),
                            camera: c.camera, viewport: SIMD2<Float>(400, 400))

        for _ in 0..<4 {
            c.handleReciprocalPathHover(at: point, viewport: SIMD2<Float>(400, 400))
            XCTAssertEqual(c.labelOverlay.labels.filter { $0.style != .tooltip }, persistentBefore)
        }
        c.handleReciprocalPathHover(at: nil, viewport: SIMD2<Float>(400, 400))
        XCTAssertEqual(c.labelOverlay.labels.filter { $0.style != .tooltip }, persistentBefore)
        XCTAssertEqual(c.bzBuildCount, buildCount)
        XCTAssertNil(tooltip(c))
    }

    func testCanvasResizeReprojectsPersistentRouteLabelsWithoutStateMutation() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.showLabels = false
        c.state.replaceKPath(points: [KPoint(.zero, "G")], breaks: [],
                             provenance: .userEdited, signature: nil)
        let before = try XCTUnwrap(routeLabels(c).first)
        let beforeState = c.state.kPathPoints

        c.canvas.setFrameSize(NSSize(width: 800, height: 300))

        let after = try XCTUnwrap(routeLabels(c).first)
        XCTAssertEqual(c.state.kPathPoints, beforeState)
        XCTAssertNotEqual(after.x, before.x)
        XCTAssertNotEqual(after.y, before.y)
        XCTAssertEqual(after.x, 406, accuracy: 0.01)
        XCTAssertEqual(after.y, 144, accuracy: 0.01)
    }

    func testActiveCanvasResizeRefitsOncePreservesRotationAndRestoresSnapshot() throws {
        let c = try controller()
        var original = c.camera
        original.center = SIMD3(-3, 5, 2)
        original.distance = 29
        original.perspective = true
        original.rotation = simd_quatf(angle: 0.37, axis: simd_normalize(SIMD3(1, 3, 2)))
        c.camera = original

        c.state.editKPathOnBZ = true
        let entryRotation = c.camera.rotation
        let framesAtEntry = c.reciprocalEditorFrameCount
        let rendersBeforeResize = c.renderRequestCount

        c.canvas.setFrameSize(NSSize(width: 900, height: 300))

        XCTAssertTrue(c.state.editKPathOnBZ)
        XCTAssertEqual(c.reciprocalEditorFrameCount, framesAtEntry + 1)
        XCTAssertEqual(c.renderRequestCount, rendersBeforeResize + 1,
                       "one valid resize must request one render")
        XCTAssertEqual(c.camera.rotation.vector.x, entryRotation.vector.x, accuracy: 1e-6)
        XCTAssertEqual(c.camera.rotation.vector.y, entryRotation.vector.y, accuracy: 1e-6)
        XCTAssertEqual(c.camera.rotation.vector.z, entryRotation.vector.z, accuracy: 1e-6)
        XCTAssertEqual(c.camera.rotation.vector.w, entryRotation.vector.w, accuracy: 1e-6)

        c.canvas.setFrameSize(NSSize(width: 300, height: 900))
        XCTAssertEqual(c.reciprocalEditorFrameCount, framesAtEntry + 2)
        assertRotationEqual(c.camera, original)

        c.state.editKPathOnBZ = false
        assertCameraEqual(c.camera, original)
    }

    func testExtremeResizeDefersFitAndRecoversWithoutRejectingEditor() throws {
        let c = try controller()
        var original = c.camera
        original.center = SIMD3(4, -2, 1)
        original.distance = 21
        original.perspective = true
        original.rotation = simd_quatf(angle: -0.24, axis: simd_normalize(SIMD3(2, 1, 3)))
        c.camera = original
        c.state.editKPathOnBZ = true
        let entryCamera = c.camera
        let entryFrameCount = c.reciprocalEditorFrameCount
        let statusBeforeResize = c.state.reciprocalEditorStatusText
        _ = c.canvas.reciprocalAccessibilityElementsForTesting()
        XCTAssertTrue(c.canvas.handleReciprocalKeyboard(.next))
        XCTAssertNotNil(c.canvas.reciprocalKeyboardFocusIndexForTesting)

        c.canvas.setFrameSize(NSSize(width: 0.01, height: 1000))

        XCTAssertTrue(c.state.editKPathOnBZ)
        XCTAssertEqual(c.state.reciprocalEditorStatusText, statusBeforeResize)
        XCTAssertEqual(c.reciprocalEditorFrameCount, entryFrameCount)
        assertCameraEqual(c.camera, entryCamera)
        XCTAssertNil(c.canvas.reciprocalKeyboardFocusIndexForTesting)

        c.canvas.setFrameSize(NSSize(width: 400, height: 400))

        XCTAssertTrue(c.state.editKPathOnBZ)
        XCTAssertEqual(c.state.reciprocalEditorStatusText, statusBeforeResize)
        XCTAssertEqual(c.reciprocalEditorFrameCount, entryFrameCount + 1)
        assertRotationEqual(c.camera, original)

        c.state.editKPathOnBZ = false
        assertCameraEqual(c.camera, original)
    }

    func testFailedEntryRestores2DModeAndRendersUnavailableState() throws {
        var scene = Scene()
        scene.isCrystal = true
        scene.cell = Cell(a: .zero, b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        scene.displayMode = .ballStick2D
        let c = try controller(scene)
        let original = c.camera
        let rendersBeforeEntry = c.renderRequestCount

        c.state.editKPathOnBZ = true

        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertEqual(c.scene.displayMode, .ballStick2D)
        XCTAssertEqual(c.state.displayMode, .ballStick2D)
        XCTAssertTrue(c.canvas.delegate === c.renderer2D)
        XCTAssertEqual(c.state.reciprocalEditorStatusText,
                       "Brillouin zone unavailable for this cell.")
        XCTAssertEqual(c.renderRequestCount, rendersBeforeEntry + 1)
        assertCameraEqual(c.camera, original)
    }

    func testFailedProjectionRefitRestoresPreEditorCameraAndMode() throws {
        let c = try controller()
        let original = c.camera
        c.state.editKPathOnBZ = true
        var invalid = c.camera
        invalid.distance = .infinity
        c.camera = invalid
        let rendersBeforeProjection = c.renderRequestCount

        c.state.orthographic.toggle()

        XCTAssertFalse(c.state.editKPathOnBZ)
        XCTAssertEqual(c.scene.displayMode, .ballStick)
        XCTAssertEqual(c.state.displayMode, .ballStick)
        XCTAssertEqual(c.state.reciprocalEditorStatusText,
                       "Brillouin zone unavailable for this cell.")
        XCTAssertEqual(c.renderRequestCount, rendersBeforeProjection + 1)
        assertCameraEqual(c.camera, original)
    }

    func testControllerEditorCacheIsInstalledIntoLiveRenderer() throws {
        let c = try controller()
        c.state.editKPathOnBZ = true
        XCTAssertEqual(c.bzBuildCount, 1)
        XCTAssertEqual(c.renderer?.bzRebuildCount, 0,
                       "the live renderer must consume the controller-built cache")
        XCTAssertEqual(c.renderer2D?.renderer.bzRebuildCount, 0,
                       "the 2D renderer must receive the same installed cache")

        let changed = Cell(a: SIMD3(6, 0, 0), b: SIMD3(0, 6, 0), c: SIMD3(0, 0, 6))
        var changedScene = c.scene
        changedScene.cell = changed
        c.loadFile(changedScene)
        c.state.editKPathOnBZ = true
        XCTAssertEqual(c.bzBuildCount, 2)
        XCTAssertEqual(c.renderer?.bzRebuildCount, 0,
                       "a controller cache miss should still avoid a second live build")
    }

    func testRouteLabelMeasurementsReuseCameraRendersAndInvalidateEditedText() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.showLabels = false
        c.state.replaceKPath(points: [KPoint(.zero, "G")], breaks: [],
                             provenance: .userEdited, signature: nil)
        let initialCount = c.routeLabelMeasurementCount
        let initialLabel = try XCTUnwrap(routeLabels(c).first)

        var moved = c.camera
        moved.distance += 3
        c.camera = moved
        c.setNeedsRender()
        XCTAssertEqual(c.routeLabelMeasurementCount, initialCount,
                       "camera-only renders must reuse route text measurements")

        c.selectKPathNode(0)
        XCTAssertEqual(c.routeLabelMeasurementCount, initialCount + 1,
                       "selected and normal route styles need separate measurements")
        let selectedBeforeEdit = try XCTUnwrap(routeLabels(c).first)

        c.state.updateLabel(at: 0, to: String(repeating: "Q", count: 100))

        let edited = try XCTUnwrap(routeLabels(c).first)
        XCTAssertEqual(edited.symbol.count, 64, "route label text remains bounded")
        XCTAssertGreaterThan(LabelOverlayView.drawingRect(for: edited).width,
                             LabelOverlayView.drawingRect(for: selectedBeforeEdit).width)
        XCTAssertGreaterThan(c.routeLabelMeasurementCount, initialCount + 1)
        XCTAssertNotEqual(edited.symbol, initialLabel.symbol)
    }

    func testLargeRouteMeasurementWorkIsCappedAndStableAcrossCameraRenders() throws {
        let c = try controller()
        c.state.showBrillouinZone = true
        c.state.showLabels = false
        let baselineCount = c.routeLabelMeasurementCount
        let route = (0..<1100).map { index in
            KPoint(.zero, "node-\(index)")
        }
        c.state.replaceKPath(points: route, breaks: [], provenance: .userEdited, signature: nil)
        let firstPassCount = c.routeLabelMeasurementCount

        XCTAssertLessThanOrEqual(firstPassCount - baselineCount, 1024)
        var moved = c.camera
        moved.distance += 2
        c.camera = moved
        c.setNeedsRender()
        XCTAssertEqual(c.routeLabelMeasurementCount, firstPassCount,
                       "the bounded route must not remeasure unchanged labels after a camera render")
    }

    func testFrameCellMetricRefreshPreservesRouteWithoutOnChange() {
        let points = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0, 0), "X")]
        let firstCell = Cell(a: SIMD3(2, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        let secondCell = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 2, 0), c: SIMD3(0, 0, 2))
        var first = Scene()
        first.cell = firstCell
        first.isCrystal = true
        first.kPathPoints = points
        let state = SideBarState()
        state.syncFromScene(first)
        let firstDistance = state.kPathDistanceReadouts[1].incomingDistance
        var changes = 0
        state.onChange = { changes += 1 }

        state.refreshKPathMetrics(for: secondCell)

        XCTAssertEqual(state.kPathPoints, points)
        XCTAssertNotEqual(state.kPathDistanceReadouts[1].incomingDistance, firstDistance)
        XCTAssertEqual(state.kPathDistanceReadouts[1].incomingDistance!, Float.pi / 4, accuracy: 1e-5)
        XCTAssertEqual(changes, 0)
    }

    func testExitingReciprocalEditMirrorsRestoredProjection() throws {
        let c = try controller()
        var original = c.camera
        original.perspective = true
        c.camera = original

        c.state.editKPathOnBZ = true
        c.state.orthographic = false
        c.state.orthographic = true
        c.state.editKPathOnBZ = false

        XCTAssertTrue(c.camera.perspective)
        XCTAssertFalse(c.state.orthographic)
        c.state.atomScale += 0.01
        XCTAssertTrue(c.camera.perspective, "unrelated sync must not overwrite restored projection")
    }
}
