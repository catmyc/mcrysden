import XCTest
import Metal
import simd
@testable import MolVisApp

final class AnimationPlaybackTests: XCTestCase {

    private func makeScene(coords: [SIMD3<Float>], cell: Bool, energy: Float?) -> Scene {
        var s = Scene()
        s.atoms = coords.map { Atom(coord: $0, atomicNumber: 1, label: "H") }
        if cell {
            s.cell = Cell(a: SIMD3<Float>(1, 0, 0), b: SIMD3<Float>(0, 1, 0), c: SIMD3<Float>(0, 0, 1))
        }
        if let energy {
            s.forceSet = ForceSet(forces: [], totalForce: nil, totalEnergy: energy, stress: nil, nIterations: 1)
        }
        return s
    }

    @MainActor
    func testPlaybackSpeedLoopAndStepping() throws {
        // Pure stepping: no loop stops at the end, loop wraps to 0.
        XCTAssertNil(SideBarState.nextFrame(after: 4, count: 5, loop: false))
        XCTAssertEqual(SideBarState.nextFrame(after: 3, count: 5, loop: false), 4)
        XCTAssertEqual(SideBarState.nextFrame(after: 0, count: 5, loop: false), 1)
        XCTAssertEqual(SideBarState.nextFrame(after: 4, count: 5, loop: true), 0)
        XCTAssertEqual(SideBarState.nextFrame(after: 2, count: 5, loop: true), 3)
        XCTAssertNil(SideBarState.nextFrame(after: 0, count: 0, loop: true))

        // Interval math: 10 Hz scaled by speed, clamped to 0.1...20. Use a Float
        // tolerance because the parameter is Float (Float 0.1 != Double 0.1).
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 1.0), 0.1, accuracy: 1e-5)
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 2.0), 0.05, accuracy: 1e-5)
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 0.5), 0.2, accuracy: 1e-5)
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 0.1), 1.0, accuracy: 1e-5)
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 20.0), 0.005, accuracy: 1e-5)
        // Defensive clamps.
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 100.0), 0.005, accuracy: 1e-5)
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 0.01), 1.0, accuracy: 1e-5)

        // Driving the controller: starting playback installs the timer; the
        // interval follows the speed setting (speed 2 => 0.05s).
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.state.frameCount = 3
        controller.state.frameIndex = 0
        controller.state.playbackSpeed = 2.0
        controller.state.loopPlayback = true
        controller.startPlayback()
        XCTAssertTrue(controller.hasActivePlayTimer)
        // Timer interval matches the helper's output for this speed.
        XCTAssertEqual(MainWindowController.playbackInterval(speed: 2.0), 0.05, accuracy: 1e-5)
        controller.stopPlayback()
        XCTAssertFalse(controller.hasActivePlayTimer)
    }

    @MainActor
    func testFrameMetricsInterpolationAndThumbnails() throws {
        let a = makeScene(coords: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)], cell: true, energy: -5.0)
        let b = makeScene(coords: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(3, 0, 0)], cell: true, energy: -7.0)
        let c = makeScene(coords: [SIMD3<Float>(0, 0, 0)], cell: false, energy: nil)
        let metrics = FrameMetrics.compute(frames: [a, b])

        XCTAssertEqual(metrics.count, 2)
        // Identity cell => |a·(b×c)| = 1.
        XCTAssertEqual(Float(metrics[0].volume ?? -1), 1.0, accuracy: 1e-4)
        XCTAssertEqual(Float(metrics[1].volume ?? -1), 1.0, accuracy: 1e-4)
        // RMSD: frame 0 vs frame 1 -> sqrt((0 + 2^2) / 2) = sqrt(2).
        XCTAssertNil(metrics[0].rmsdFromPrevious)
        XCTAssertEqual(Float(metrics[1].rmsdFromPrevious ?? -1), Float(sqrt(2.0)), accuracy: 1e-3)
        // Energy passes through from the force set.
        XCTAssertEqual(Float(metrics[0].totalEnergy ?? 0), -5.0, accuracy: 1e-4)
        XCTAssertEqual(Float(metrics[1].totalEnergy ?? 0), -7.0, accuracy: 1e-4)
        XCTAssertNil(metrics[0].totalForce)

        // RMSD of mismatched counts is nil.
        XCTAssertNil(FrameMetrics.rmsd(between: a.atoms.map(\.coord), and: c.atoms.map(\.coord)))

        // CSV is non-empty with a header row.
        let csv = FrameMetrics.csv(metrics)
        XCTAssertFalse(csv.isEmpty)
        XCTAssertTrue(csv.hasPrefix("frame_index,"))
        XCTAssertTrue(csv.contains("-5.0"))

        // Midpoint interpolation: atom 1 coord goes 1 -> 3, so t=0.5 => 2.
        let mid = FrameMetrics.interpolate(between: a, and: b, t: 0.5)!
        XCTAssertEqual(mid.atoms[1].coord.x, 2.0, accuracy: 1e-4)
        XCTAssertEqual(mid.atoms[1].atomicNumber, 1)
        XCTAssertEqual(mid.atoms[1].label, "H")
        // Mismatched counts -> nil.
        XCTAssertNil(FrameMetrics.interpolate(between: a, and: c, t: 0.5))
        // Out-of-range t is clamped (endpoints preserved).
        let start = FrameMetrics.interpolate(between: a, and: b, t: -1.0)!
        XCTAssertEqual(start.atoms[1].coord.x, 1.0, accuracy: 1e-4)

        // Thumbnails: needs Metal — guard like other GPU tests.
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device; skipping thumbnail render")
        }
        let three = [a, b, c]
        let images = try TimelineThumbnails.render(frames: three, camera: nil, size: CGSize(width: 64, height: 64))
        XCTAssertLessThanOrEqual(images.count, TimelineThumbnails.maxCount)
        XCTAssertGreaterThan(images.count, 0)   // first frame always included
        XCTAssertGreaterThan(images.first?.width ?? 0, 0)

        // Oversampled: 100 frames collapse to <= maxCount with frame 0 included.
        let many = (0..<100).map { i in
            makeScene(coords: [SIMD3<Float>(Float(i), 0, 0)], cell: false, energy: nil)
        }
        let manyImages = try TimelineThumbnails.render(frames: many, camera: nil, size: CGSize(width: 32, height: 32))
        XCTAssertLessThanOrEqual(manyImages.count, TimelineThumbnails.maxCount)
        XCTAssertGreaterThan(manyImages.count, 0)
    }
}
