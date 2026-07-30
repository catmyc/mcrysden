import AppKit
import simd
import XCTest
@testable import MolVisApp

private final class MetalViewWorldSpy: World {
    var camera = Camera()
    var scene = Scene()
    var hoverPoints: [SIMD2<Float>?] = []
    var cameraDistancesAtHover: [Float] = []
    var renderCount = 0
    var reciprocalFocusClearCount = 0
    var interactionLog: [String] = []
    var reciprocalEditing = false
    var reciprocalDescriptors: [ReciprocalAccessibilityDescriptor] = []

    var isReciprocalPathEditing: Bool { reciprocalEditing }

    func setNeedsRender() {
        renderCount += 1
    }

    func renderCamera() -> Camera { camera }

    func toggleSelection(_ index: Int) {}

    func adjustSlabPlaneA(by delta: Float) {}

    func handleReciprocalPathClick(at click: SIMD2<Float>, viewport: SIMD2<Float>) -> Bool {
        false
    }

    func handleReciprocalPathHover(at point: SIMD2<Float>?, viewport: SIMD2<Float>) {
        hoverPoints.append(point)
        cameraDistancesAtHover.append(camera.distance)
        interactionLog.append(point == nil ? "hover-clear" : "hover")
    }

    func clearReciprocalAccessibilityFocus() {
        reciprocalFocusClearCount += 1
        interactionLog.append("focus-clear")
    }

    func reciprocalAccessibilityDescriptors(viewport: SIMD2<Float>)
        -> [ReciprocalAccessibilityDescriptor] { reciprocalDescriptors }
}

@MainActor
final class MetalViewHoverTests: XCTestCase {
    func testHoverPayloadConvertsBottomOriginToTopOrigin() {
        let payload = MetalView.reciprocalHoverPayload(
            for: NSPoint(x: 18, y: 25),
            bounds: NSRect(x: 0, y: 0, width: 120, height: 80)
        )

        XCTAssertEqual(payload?.point, SIMD2<Float>(18, 55))
        XCTAssertEqual(payload?.viewport, SIMD2<Float>(120, 80))
    }

    func testHoverPayloadRejectsZeroAndNonFiniteBounds() {
        XCTAssertNil(MetalView.reciprocalHoverPayload(
            for: NSPoint(x: 1, y: 1),
            bounds: NSRect(x: 0, y: 0, width: 0, height: 80)
        ))
        XCTAssertNil(MetalView.reciprocalHoverPayload(
            for: NSPoint(x: 1, y: 1),
            bounds: NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 80)
        ))
        XCTAssertNil(MetalView.reciprocalHoverPayload(
            for: NSPoint(x: CGFloat.nan, y: 1),
            bounds: NSRect(x: 0, y: 0, width: 120, height: 80)
        ))
        XCTAssertNil(MetalView.reciprocalHoverPayload(
            for: NSPoint(x: -1, y: 25),
            bounds: NSRect(x: 0, y: 0, width: 120, height: 80)
        ))
        XCTAssertNil(MetalView.reciprocalHoverPayload(
            for: NSPoint(x: 18, y: 81),
            bounds: NSRect(x: 0, y: 0, width: 120, height: 80)
        ))
    }

    func testTrackingAreaIsReplacedAndUsesVisibleBounds() {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)

        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        guard let first = view.trackingAreas.first else {
            return XCTFail("tracking area was not installed")
        }
        XCTAssertTrue(first.options.contains(.inVisibleRect))
        XCTAssertTrue(first.options.contains(.mouseMoved))
        XCTAssertTrue(first.options.contains(.mouseEnteredAndExited))

        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertFalse(view.trackingAreas.first === first)

        view.setFrameSize(NSSize(width: 0, height: 0))
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.isEmpty)
    }

    func testMouseExitClearsHoverAfterTrackingAreaRefresh() throws {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        view.world = world
        view.updateTrackingAreas()
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 18, y: 25),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseMoved(with: event)
        view.updateTrackingAreas()
        view.mouseExited(with: event)

        XCTAssertEqual(world.hoverPoints.count, 2)
        XCTAssertNotNil(world.hoverPoints[0])
        XCTAssertNil(world.hoverPoints[1])
        XCTAssertEqual(view.trackingAreas.count, 1)
    }

    func testLogicalSizeChangesRequestOneRenderAndIgnoreNoOps() {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        view.world = world

        view.setFrameSize(NSSize(width: 120, height: 80))
        view.setBoundsSize(NSSize(width: 120, height: 80))
        XCTAssertEqual(world.renderCount, 0, "unchanged logical size must not redraw")
        XCTAssertEqual(world.reciprocalFocusClearCount, 0,
                       "unchanged logical size must preserve reciprocal focus")

        view.setFrameSize(NSSize(width: 200, height: 80))
        XCTAssertEqual(world.renderCount, 1)
        XCTAssertEqual(world.reciprocalFocusClearCount, 1)
        view.setBoundsSize(NSSize(width: 200, height: 80))
        view.setFrameSize(NSSize(width: 200, height: 80))
        XCTAssertEqual(world.renderCount, 1, "frame/bounds callbacks must be coalesced")
        XCTAssertEqual(world.reciprocalFocusClearCount, 1,
                       "frame/bounds callbacks must clear focus once")

        view.setFrameSize(NSSize(width: 0, height: 0))
        XCTAssertEqual(world.renderCount, 1, "invalid logical sizes must not redraw")
        XCTAssertEqual(world.reciprocalFocusClearCount, 2)
        view.setFrameSize(NSSize(width: 200, height: 80))
        XCTAssertEqual(world.renderCount, 2, "returning to a valid size must redraw once")
        XCTAssertEqual(world.reciprocalFocusClearCount, 3)
    }

    func testValidZoomClearsHoverBeforeCameraMutation() throws {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        view.world = world
        let hover = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 18, y: 25),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: hover)
        XCTAssertEqual(world.hoverPoints.count, 1)

        view.applyZoom(factor: 0.8)

        XCTAssertEqual(world.hoverPoints.count, 2)
        XCTAssertNotNil(world.hoverPoints[0])
        XCTAssertNil(world.hoverPoints[1])
        XCTAssertEqual(world.cameraDistancesAtHover, [20, 20])
        XCTAssertEqual(world.camera.distance, 16, accuracy: 1e-6)
        XCTAssertEqual(world.renderCount, 1)
    }

    func testRejectedNonFiniteScrollPreservesHoverAndCamera() throws {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        view.world = world
        let hover = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 18, y: 25),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: hover)
        let cameraBefore = world.camera

        view.applyScrollZoom(delta: .nan)

        XCTAssertEqual(world.hoverPoints.count, 1)
        XCTAssertEqual(world.camera.distance, cameraBefore.distance, accuracy: 1e-6)
        XCTAssertEqual(world.camera.center, cameraBefore.center)
        XCTAssertEqual(world.renderCount, 0)
    }

    func testAccessibilityLayoutNotificationCoversDescriptorReplacement() {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        world.reciprocalEditing = true
        let candidate = BZCandidate(
            point: KPoint(SIMD3<Float>(0, 0, 0), "G"),
            cartesian: SIMD3<Float>(0, 0, 0),
            type: .center)
        world.reciprocalDescriptors = [ReciprocalAccessibilityDescriptor(
            candidate: candidate,
            screenPoint: SIMD2<Float>(20, 20),
            label: "G",
            value: "center",
            help: "Activate")]
        view.world = world
        _ = view.reciprocalAccessibilityElementsForTesting()

        var notifications: [NSAccessibility.Notification] = []
        view.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        _ = view.reciprocalAccessibilityElementsForTesting()
        XCTAssertTrue(notifications.isEmpty)

        world.reciprocalDescriptors[0] = ReciprocalAccessibilityDescriptor(
            candidate: candidate,
            screenPoint: SIMD2<Float>(30, 20),
            label: "G",
            value: "center",
            help: "Activate")
        _ = view.reciprocalAccessibilityElementsForTesting()
        XCTAssertEqual(notifications, [.layoutChanged])
    }

    func testPointerHoverClearsKeyboardAndAccessibilityFocusBeforeDelivery() throws {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        world.reciprocalEditing = true
        let candidate = BZCandidate(
            point: KPoint(SIMD3<Float>(0, 0, 0), "G"),
            cartesian: SIMD3<Float>(0, 0, 0),
            type: .center)
        world.reciprocalDescriptors = [ReciprocalAccessibilityDescriptor(
            candidate: candidate,
            screenPoint: SIMD2<Float>(18, 25),
            label: "G",
            value: "center",
            help: "Activate")]
        view.world = world
        XCTAssertTrue(view.handleReciprocalKeyboard(.next))
        let child = try XCTUnwrap(
            view.reciprocalAccessibilityElementsForTesting().first as? ReciprocalAccessibilityElement)
        XCTAssertTrue(child.isAccessibilityFocused())

        var notifications: [NSAccessibility.Notification] = []
        view.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 18, y: 55),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseMoved(with: event)

        XCTAssertNil(view.reciprocalKeyboardFocusIndexForTesting)
        XCTAssertFalse(child.isAccessibilityFocused())
        XCTAssertEqual(world.interactionLog, ["focus-clear", "hover"])
        XCTAssertEqual(notifications, [.focusedUIElementChanged])
    }

    func testPointerHoverWithoutAccessibilityFocusDoesNotNotify() throws {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        world.reciprocalEditing = true
        view.world = world
        var notifications: [NSAccessibility.Notification] = []
        view.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 18, y: 55),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseMoved(with: event)

        XCTAssertEqual(world.hoverPoints.count, 1)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(world.reciprocalFocusClearCount, 0)
    }

    func testOffViewPointerMovementPreservesAccessibilityFocus() throws {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80), device: nil)
        let world = MetalViewWorldSpy()
        world.reciprocalEditing = true
        let candidate = BZCandidate(
            point: KPoint(SIMD3<Float>(0, 0, 0), "G"),
            cartesian: SIMD3<Float>(0, 0, 0),
            type: .center)
        world.reciprocalDescriptors = [ReciprocalAccessibilityDescriptor(
            candidate: candidate,
            screenPoint: SIMD2<Float>(18, 25),
            label: "G",
            value: "center",
            help: "Activate")]
        view.world = world
        XCTAssertTrue(view.handleReciprocalKeyboard(.next))
        let child = try XCTUnwrap(
            view.reciprocalAccessibilityElementsForTesting().first as? ReciprocalAccessibilityElement)

        var notifications: [NSAccessibility.Notification] = []
        view.accessibilityNotificationPoster = { notification, _ in
            notifications.append(notification)
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: -1, y: 55),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseMoved(with: event)

        XCTAssertEqual(view.reciprocalKeyboardFocusIndexForTesting, 0)
        XCTAssertTrue(child.isAccessibilityFocused())
        XCTAssertTrue(world.hoverPoints.isEmpty)
        XCTAssertEqual(world.reciprocalFocusClearCount, 0)
        XCTAssertTrue(notifications.isEmpty)
    }
}
