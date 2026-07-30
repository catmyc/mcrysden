import AppKit
import XCTest
import simd

@testable import MolVisApp

@MainActor
final class ReciprocalAccessibilityTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func controller() throws -> MainWindowController {
        let scene = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let controller = MainWindowController(scene: scene, showWindow: false)
        controller.canvas.setFrameSize(NSSize(width: 400, height: 400))
        controller.canvas.isHidden = false
        return controller
    }

    private func edit(_ controller: MainWindowController) {
        controller.state.editKPathOnBZ = true
    }

    private func tooltip(_ controller: MainWindowController) -> LabelOverlayView.Label? {
        controller.labelOverlay.labels.first { $0.style == .tooltip }
    }

    private func project(_ world: SIMD3<Float>, camera: Camera,
                         viewport: SIMD2<Float>) -> SIMD2<Float>? {
        let clip = camera.projectionMatrix(aspect: viewport.x / viewport.y)
            * camera.viewMatrix() * SIMD4<Float>(world, 1)
        guard clip.w > 1e-10, clip.x.isFinite, clip.y.isFinite, clip.w.isFinite else { return nil }
        let ndc = clip / clip.w
        let point = SIMD2<Float>((ndc.x * 0.5 + 0.5) * viewport.x,
                                 (1 - (ndc.y * 0.5 + 0.5)) * viewport.y)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    func testAccessibilityChildrenDescribeVisibleLandmarksAndAppendAction() throws {
        let controller = try controller()
        edit(controller)

        let descriptors = controller.reciprocalAccessibilityDescriptors(viewport: SIMD2(400, 400))
        XCTAssertFalse(descriptors.isEmpty)
        XCTAssertLessThanOrEqual(descriptors.count,
                                 MainWindowController.maximumReciprocalAccessibilityChildren)

        let descriptor = try XCTUnwrap(descriptors.first)
        let text = [descriptor.label, descriptor.value, descriptor.help].joined(separator: " ")
        XCTAssertTrue(text.contains(descriptor.candidate.point.label))
        XCTAssertTrue(text.contains(MainWindowController.reciprocalCandidateTypeName(
            descriptor.candidate.type)))
        XCTAssertTrue(text.contains("fractional"))
        XCTAssertTrue(text.contains("Activate") || text.contains("append"))
        XCTAssertTrue(descriptor.candidate.point.frac.x.isFinite)
        XCTAssertTrue(descriptor.candidate.point.frac.y.isFinite)
        XCTAssertTrue(descriptor.candidate.point.frac.z.isFinite)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("nan"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("inf"))

        let child = try XCTUnwrap(controller.canvas.reciprocalAccessibilityElementsForTesting().first)
        XCTAssertEqual(child.accessibilityRole(), .button)
        XCTAssertEqual(child.accessibilityLabel(), descriptor.label)
        XCTAssertEqual(child.accessibilityValue() as? String, descriptor.value)
        XCTAssertEqual(child.accessibilityHelp(), descriptor.help)
    }

    func testDynamicLandmarkRadiusMatchesRenderedCrossAndAXFrame() throws {
        let controller = try controller()
        edit(controller)
        let cell = try XCTUnwrap(controller.scene.cell)
        let bz = try XCTUnwrap(BrillouinZone.build(cell: cell, atoms: controller.scene.baseAtoms))
        let candidate = try XCTUnwrap(bz.candidates().first { $0.type == .center })

        for (viewport, perspective) in [(SIMD2<Float>(400, 400), false),
                                         (SIMD2<Float>(800, 300), true),
                                         (SIMD2<Float>(300, 800), false)] {
            controller.canvas.setFrameSize(NSSize(width: CGFloat(viewport.x), height: CGFloat(viewport.y)))
            var camera = controller.camera
            camera.perspective = perspective
            controller.camera = camera
            let presentation = BZPresentation(bz: bz, scene: controller.scene)
            let projected = try XCTUnwrap(MainWindowController.projectVisibleBZCandidate(
                candidate, presentation: presentation, camera: controller.renderCamera(), viewport: viewport))
            let descriptor = try XCTUnwrap(controller.reciprocalAccessibilityDescriptors(viewport: viewport)
                .first { $0.candidate.point == candidate.point })

            XCTAssertGreaterThanOrEqual(projected.screenRadius,
                                        BZPresentation.landmarkPickMinimumRadius)
            XCTAssertEqual(descriptor.screenRadius, projected.screenRadius, accuracy: 1e-5)

            let endpoints = Renderer.crossLineSegments(
                presentation.world(cartesian: candidate.cartesian),
                half: presentation.landmarkHalfExtent)
            let endpointDistances = endpoints.compactMap { endpoint -> Float? in
                guard let point = project(endpoint, camera: controller.renderCamera(), viewport: viewport) else {
                    return nil
                }
                let delta = point - projected.point
                let distance = simd_length(delta)
                return distance.isFinite ? distance : nil
            }
            XCTAssertEqual(projected.screenRadius,
                           max(BZPresentation.landmarkPickMinimumRadius,
                               endpointDistances.max() ?? 0), accuracy: 1e-4)

            let child = try XCTUnwrap(controller.canvas.reciprocalAccessibilityElementsForTesting()
                .compactMap { $0 as? ReciprocalAccessibilityElement }
                .first { $0.descriptor.candidate.point == candidate.point })
            XCTAssertEqual(child.accessibilityFrame().width,
                           CGFloat(descriptor.screenRadius * 2), accuracy: 1)
            XCTAssertEqual(child.accessibilityFrame().height,
                           CGFloat(descriptor.screenRadius * 2), accuracy: 1)
        }
    }

    func testClickingRenderedCrossArmUsesDynamicRadius() throws {
        let controller = try controller()
        edit(controller)
        let cell = try XCTUnwrap(controller.scene.cell)
        let bz = try XCTUnwrap(BrillouinZone.build(cell: cell, atoms: controller.scene.baseAtoms))
        let candidate = try XCTUnwrap(bz.candidates().first { $0.type == .center })
        let viewport = SIMD2<Float>(2400, 2400)
        controller.canvas.setFrameSize(NSSize(width: CGFloat(viewport.x), height: CGFloat(viewport.y)))
        let presentation = BZPresentation(bz: bz, scene: controller.scene)
        let projection = try XCTUnwrap(MainWindowController.projectVisibleBZCandidate(
            candidate, presentation: presentation, camera: controller.renderCamera(), viewport: viewport))
        let endpoints = Renderer.crossLineSegments(
            presentation.world(cartesian: candidate.cartesian), half: presentation.landmarkHalfExtent)
        let arm = try XCTUnwrap(endpoints.first(where: {
            guard let point = project($0, camera: controller.renderCamera(), viewport: viewport) else { return false }
            return point.x >= 0 && point.x <= viewport.x && point.y >= 0 && point.y <= viewport.y
        }))
        let click = try XCTUnwrap(project(arm, camera: controller.renderCamera(), viewport: viewport))
        let distance = simd_distance(click, projection.point)
        XCTAssertGreaterThan(distance, 10, "the regression needs an arm beyond the old fixed pick radius")
        XCTAssertEqual(MainWindowController.pickBZCandidate(
            candidates: [candidate], presentation: presentation, camera: controller.renderCamera(),
            viewport: viewport, click: click)?.point, candidate.point)
    }

    func testAccessibilityActivationUsesRouteMutationAndSuppressesDuplicatesAndCap() throws {
        let controller = try controller()
        edit(controller)
        let descriptor = try XCTUnwrap(
            controller.reciprocalAccessibilityDescriptors(viewport: SIMD2(400, 400)).first)
        let child = try XCTUnwrap(controller.canvas.reciprocalAccessibilityElementsForTesting()
            .first(where: { ($0 as? ReciprocalAccessibilityElement)?.descriptor == descriptor }))

        let countBefore = controller.state.kPathPoints.count
        XCTAssertTrue(child.accessibilityPerformPress())
        XCTAssertEqual(controller.state.kPathPoints.count, countBefore + 1)
        XCTAssertEqual(controller.scene.kPathPoints, controller.state.kPathPoints)
        XCTAssertEqual(controller.state.kPathPoints.last?.frac, descriptor.candidate.point.frac)

        XCTAssertTrue(child.accessibilityPerformPress(), "a visible duplicate is still a handled action")
        XCTAssertEqual(controller.state.kPathPoints.count, countBefore + 1,
                       "SideBarState duplicate suppression must remain authoritative")

        let bounded = (0..<1024).map { index in
            KPoint(SIMD3(Float(index), Float(index) * 0.01, 0), "P\(index)")
        }
        controller.state.replaceKPath(points: bounded, breaks: [], provenance: .userEdited, signature: nil)
        let cappedCount = controller.state.kPathPoints.count
        XCTAssertEqual(cappedCount, 1024)
        XCTAssertTrue(controller.activateReciprocalAccessibilityCandidate(descriptor))
        XCTAssertEqual(controller.state.kPathPoints.count, cappedCount)
    }

    func testAccessibilityFiltersOffscreenAndBehindCandidatesUsingSharedProjection() throws {
        let controller = try controller()
        edit(controller)
        let cell = try XCTUnwrap(controller.scene.cell)
        let bz = try XCTUnwrap(BrillouinZone.build(cell: cell, atoms: controller.scene.baseAtoms))
        let presentation = BZPresentation(bz: bz, scene: controller.scene)
        let candidate = try XCTUnwrap(bz.candidates().first)
        let viewport = SIMD2<Float>(400, 400)
        XCTAssertNotNil(MainWindowController.projectVisibleBZCandidate(
            candidate, presentation: presentation, camera: controller.renderCamera(), viewport: viewport))

        var offscreen = candidate
        offscreen.cartesian = SIMD3(100_000, 100_000, 100_000)
        XCTAssertNil(MainWindowController.projectVisibleBZCandidate(
            offscreen, presentation: presentation, camera: controller.renderCamera(), viewport: viewport))

        var behind = candidate
        let rotation = float4x4(controller.renderCamera().rotation)
        let behindWorld = controller.renderCamera().center
            + (rotation * SIMD4<Float>(0, 0, controller.renderCamera().distance + 1, 0)).xyz
        behind.cartesian = (behindWorld - presentation.center) / presentation.inv
        XCTAssertNil(MainWindowController.projectVisibleBZCandidate(
            behind, presentation: presentation, camera: controller.renderCamera(), viewport: viewport))
    }

    func testKeyboardCyclesVisibleCandidatesUpdatesTooltipActivatesAndEscapes() throws {
        let controller = try controller()
        edit(controller)
        let descriptors = controller.reciprocalAccessibilityDescriptors(viewport: SIMD2(400, 400))
        XCTAssertGreaterThanOrEqual(descriptors.count, 2)

        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        XCTAssertEqual(controller.canvas.reciprocalKeyboardFocusIndexForTesting, 0)
        XCTAssertTrue(try XCTUnwrap(tooltip(controller)).symbol.contains(
            descriptors[0].candidate.point.label))

        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        XCTAssertEqual(controller.canvas.reciprocalKeyboardFocusIndexForTesting, 1)
        XCTAssertTrue(try XCTUnwrap(tooltip(controller)).symbol.contains(
            descriptors[1].candidate.point.label))

        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.previous))
        XCTAssertEqual(controller.canvas.reciprocalKeyboardFocusIndexForTesting, 0)
        let beforeActivation = controller.state.kPathPoints.count
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.activate))
        XCTAssertEqual(controller.state.kPathPoints.count, beforeActivation + 1)
        XCTAssertEqual(controller.state.kPathPoints.last?.frac, descriptors[0].candidate.point.frac)

        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.clear))
        XCTAssertNil(controller.canvas.reciprocalKeyboardFocusIndexForTesting)
        XCTAssertNil(tooltip(controller))
    }

    func testAccessibilityAndKeyboardAreInactiveOutsideEditMode() throws {
        let controller = try controller()
        let before = controller.state.kPathPoints
        XCTAssertTrue(controller.canvas.reciprocalAccessibilityElementsForTesting().isEmpty)
        XCTAssertFalse(controller.canvas.handleReciprocalKeyboard(.next))
        XCTAssertFalse(controller.canvas.handleReciprocalKeyboard(.activate))
        XCTAssertFalse(controller.canvas.handleReciprocalKeyboard(.clear))
        XCTAssertEqual(controller.state.kPathPoints, before)

        edit(controller)
        XCTAssertFalse(controller.canvas.reciprocalAccessibilityElementsForTesting().isEmpty)
        controller.state.editKPathOnBZ = false
        XCTAssertTrue(controller.canvas.reciprocalAccessibilityElementsForTesting().isEmpty)
        XCTAssertFalse(controller.canvas.handleReciprocalKeyboard(.next))
        XCTAssertEqual(controller.state.kPathPoints, before)
    }

    func testAccessibilityQueriesAndKeyboardReuseEditorBZCache() throws {
        let controller = try controller()
        edit(controller)
        let initialBuilds = controller.bzBuildCount
        XCTAssertGreaterThan(initialBuilds, 0)

        for _ in 0..<4 {
            _ = controller.reciprocalAccessibilityDescriptors(viewport: SIMD2(400, 400))
            _ = controller.canvas.reciprocalAccessibilityElementsForTesting()
            _ = controller.canvas.handleReciprocalKeyboard(.next)
        }
        XCTAssertEqual(controller.bzBuildCount, initialBuilds)
    }

    func testAccessibilityFrameTracksWindowOriginWithoutRebuildingChild() throws {
        let controller = try controller()
        edit(controller)
        let child = try XCTUnwrap(
            controller.canvas.reciprocalAccessibilityElementsForTesting().first
                as? ReciprocalAccessibilityElement)
        let window = controller.window
        let before = child.accessibilityFrame()
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x + 37, y: origin.y + 19))

        let after = child.accessibilityFrame()
        XCTAssertEqual(after.minX - before.minX, 37, accuracy: 0.5)
        XCTAssertEqual(after.minY - before.minY, 19, accuracy: 0.5)
        XCTAssertTrue((controller.canvas.reciprocalAccessibilityElementsForTesting().first
                       as? ReciprocalAccessibilityElement) === child)
    }

    func testAccessibilityLayoutNotificationsOnlyFollowInvalidationOrReplacement() throws {
        let controller = try controller()
        edit(controller)
        _ = controller.canvas.reciprocalAccessibilityElementsForTesting()

        var notifications: [NSAccessibility.Notification] = []
        controller.canvas.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }

        _ = controller.canvas.reciprocalAccessibilityElementsForTesting()
        XCTAssertTrue(notifications.isEmpty, "a no-op accessibility query must not notify")

        controller.canvas.setFrameSize(NSSize(width: 420, height: 400))
        XCTAssertEqual(notifications, [.layoutChanged])

        controller.canvas.setFrameSize(NSSize(width: 420, height: 400))
        XCTAssertEqual(notifications, [.layoutChanged], "a no-op resize must not notify again")

        _ = controller.canvas.reciprocalAccessibilityElementsForTesting()
        controller.canvas.invalidateReciprocalAccessibilityFocus()
        XCTAssertEqual(notifications, [.layoutChanged, .layoutChanged])
    }

    func testKeyboardFocusNotificationsTrackArrowMovementAndEscapeWithoutDuplicates() throws {
        let controller = try controller()
        edit(controller)
        let children = controller.canvas.reciprocalAccessibilityElementsForTesting()
            .compactMap { $0 as? ReciprocalAccessibilityElement }
        XCTAssertGreaterThanOrEqual(children.count, 2)

        var posted: [(NSAccessibility.Notification, Any)] = []
        controller.canvas.accessibilityNotificationPoster = { notification, element in
            posted.append((notification, element))
        }

        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        XCTAssertEqual(posted.map(\.0), [.focusedUIElementChanged])
        XCTAssertTrue((posted[0].1 as? ReciprocalAccessibilityElement) === children[0])
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        XCTAssertEqual(posted.map(\.0),
                       [.focusedUIElementChanged, .focusedUIElementChanged])
        XCTAssertTrue((posted[1].1 as? ReciprocalAccessibilityElement) === children[1])

        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.clear))
        XCTAssertEqual(posted.map(\.0),
                       [.focusedUIElementChanged, .focusedUIElementChanged,
                         .focusedUIElementChanged])
        XCTAssertTrue((posted[2].1 as? MetalView) === controller.canvas)
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.clear))
        XCTAssertEqual(posted.count, 3, "repeated escape must not notify")
    }

    func testNoOpFrameAndBoundsSettersPreserveReciprocalFocusAndTooltip() throws {
        let controller = try controller()
        edit(controller)
        let child = try XCTUnwrap(controller.canvas.reciprocalAccessibilityElementsForTesting()
            .first as? ReciprocalAccessibilityElement)
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        let tooltipBefore = try XCTUnwrap(tooltip(controller))
        XCTAssertEqual(controller.canvas.reciprocalKeyboardFocusIndexForTesting, 0)

        var notifications: [NSAccessibility.Notification] = []
        controller.canvas.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        controller.canvas.setFrameSize(controller.canvas.frame.size)
        controller.canvas.setBoundsSize(controller.canvas.bounds.size)

        XCTAssertEqual(controller.canvas.reciprocalKeyboardFocusIndexForTesting, 0)
        XCTAssertTrue((controller.canvas.reciprocalAccessibilityElementsForTesting().first
                       as? ReciprocalAccessibilityElement) === child)
        XCTAssertEqual(tooltip(controller)?.symbol, tooltipBefore.symbol)
        XCTAssertTrue(notifications.isEmpty, "no-op setters must not notify")
    }

    func testTrackingAreaRefreshPreservesKeyboardFocusChildWorldFocusAndNotifications() throws {
        let controller = try controller()
        edit(controller)
        let child = try XCTUnwrap(controller.canvas.reciprocalAccessibilityElementsForTesting()
            .first as? ReciprocalAccessibilityElement)
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        let tooltipBefore = try XCTUnwrap(tooltip(controller))
        XCTAssertEqual(controller.canvas.reciprocalKeyboardFocusIndexForTesting, 0)
        XCTAssertTrue(child.isAccessibilityFocused())

        var notifications: [NSAccessibility.Notification] = []
        controller.canvas.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        controller.canvas.updateTrackingAreas()
        controller.canvas.updateTrackingAreas()

        XCTAssertEqual(controller.canvas.trackingAreas.count, 1)
        XCTAssertEqual(controller.canvas.reciprocalKeyboardFocusIndexForTesting, 0)
        XCTAssertTrue((controller.canvas.reciprocalAccessibilityElementsForTesting().first
                       as? ReciprocalAccessibilityElement) === child)
        XCTAssertTrue(child.isAccessibilityFocused())
        XCTAssertEqual(tooltip(controller)?.symbol, tooltipBefore.symbol)
        XCTAssertTrue(notifications.isEmpty, "tracking refresh must not invalidate AX focus or layout")
    }

    func testRealResizeClearsLocalAndWorldReciprocalFocusOnce() throws {
        let controller = try controller()
        edit(controller)
        _ = controller.canvas.reciprocalAccessibilityElementsForTesting()
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        XCTAssertNotNil(tooltip(controller))

        var posted: [(NSAccessibility.Notification, Any)] = []
        controller.canvas.accessibilityNotificationPoster = { notification, element in
            posted.append((notification, element))
        }
        controller.canvas.setFrameSize(NSSize(width: 420, height: 400))

        XCTAssertNil(controller.canvas.reciprocalKeyboardFocusIndexForTesting)
        XCTAssertNil(tooltip(controller))
        XCTAssertEqual(posted.map(\.0), [.layoutChanged, .focusedUIElementChanged])
        XCTAssertTrue(posted.allSatisfy { ($0.1 as? MetalView) === controller.canvas })
    }

    func testAccessibilityElementDoesNotRetainOwnerAndClearsStaleFocusSafely() throws {
        let controller = try controller()
        edit(controller)
        let descriptor = try XCTUnwrap(
            controller.reciprocalAccessibilityDescriptors(viewport: SIMD2(400, 400)).first)

        var element: ReciprocalAccessibilityElement?
        weak var owner: MetalView?
        autoreleasepool {
            var view: MetalView? = MetalView(
                frame: NSRect(x: 0, y: 0, width: 400, height: 400), device: nil)
            owner = view
            element = ReciprocalAccessibilityElement(descriptor: descriptor, owner: view!)
            XCTAssertEqual(element?.accessibilityFrame(), .zero)
            view = nil
        }
        XCTAssertEqual(element?.accessibilityFrame(), .zero)
        element = nil
        XCTAssertNil(owner)

        let child = try XCTUnwrap(
            controller.canvas.reciprocalAccessibilityElementsForTesting().first
                as? ReciprocalAccessibilityElement)
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        controller.canvas.invalidateReciprocalAccessibilityFocus()
        XCTAssertNil(controller.canvas.reciprocalKeyboardFocusIndexForTesting)
        XCTAssertFalse(controller.canvas.reciprocalAccessibilityElementsForTesting().contains {
            $0 === child
        }, "invalidated children must not remain the focused accessibility target")
    }

    func testPointerHoverOwnsTooltipAndMouseExitLeavesReciprocalFocusClear() throws {
        let controller = try controller()
        edit(controller)
        let descriptors = controller.reciprocalAccessibilityDescriptors(viewport: SIMD2(400, 400))
        XCTAssertGreaterThanOrEqual(descriptors.count, 2)
        XCTAssertTrue(controller.canvas.handleReciprocalKeyboard(.next))
        let keyboardTooltip = try XCTUnwrap(tooltip(controller))
        let child = try XCTUnwrap(controller.canvas.reciprocalAccessibilityElementsForTesting()
            .first as? ReciprocalAccessibilityElement)
        XCTAssertTrue(child.isAccessibilityFocused())

        var posted: [(NSAccessibility.Notification, Any)] = []
        controller.canvas.accessibilityNotificationPoster = { notification, element in
            posted.append((notification, element))
        }
        let pointerDescriptor = descriptors[1]
        let localPoint = NSPoint(
            x: CGFloat(pointerDescriptor.screenPoint.x),
            y: controller.canvas.bounds.height - CGFloat(pointerDescriptor.screenPoint.y))
        let windowPoint = controller.canvas.convert(localPoint, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        controller.canvas.mouseMoved(with: event)

        XCTAssertNil(controller.canvas.reciprocalKeyboardFocusIndexForTesting)
        XCTAssertFalse(child.isAccessibilityFocused())
        XCTAssertEqual(posted.map(\.0), [.focusedUIElementChanged])
        let pointerTooltip = try XCTUnwrap(tooltip(controller))
        XCTAssertNotEqual(pointerTooltip.symbol, keyboardTooltip.symbol)
        XCTAssertTrue(pointerTooltip.symbol.contains(pointerDescriptor.candidate.point.label))

        controller.canvas.mouseExited(with: event)

        XCTAssertNil(tooltip(controller))
        XCTAssertNil(controller.canvas.reciprocalKeyboardFocusIndexForTesting)
        XCTAssertFalse(child.isAccessibilityFocused())
    }

    func testPointerHoverWithoutKeyboardFocusDoesNotPostAccessibilityFocus() throws {
        let controller = try controller()
        edit(controller)
        let descriptor = try XCTUnwrap(
            controller.reciprocalAccessibilityDescriptors(viewport: SIMD2(400, 400)).first)
        var posted: [NSAccessibility.Notification] = []
        controller.canvas.accessibilityNotificationPoster = { notification, _ in
            posted.append(notification)
        }
        let localPoint = NSPoint(
            x: CGFloat(descriptor.screenPoint.x),
            y: controller.canvas.bounds.height - CGFloat(descriptor.screenPoint.y))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: controller.canvas.convert(localPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        controller.canvas.mouseMoved(with: event)

        XCTAssertTrue(posted.isEmpty)
        XCTAssertNotNil(tooltip(controller))
    }
}
