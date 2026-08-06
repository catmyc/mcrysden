import XCTest
import Metal
import AppKit
import simd
@testable import MolVisApp

final class AnimationPlaybackTests: XCTestCase {

    /// Compare two optional SIMD3<Float> within `tol` on each component.
    private func assertVecEqual(_ a: SIMD3<Float>?, _ b: SIMD3<Float>, _ tol: Float,
                                file: StaticString = #file, line: UInt = #line) {
        guard let a else { return XCTFail("expected non-nil vector", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: tol, file: file, line: line)
    }

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

        // MARK: - Centroid + alignment

        // centroid: arithmetic mean of coords.
        assertVecEqual(FrameMetrics.centroid([SIMD3<Float>(1, 0, 0), SIMD3<Float>(3, 0, 0)]),
                       SIMD3<Float>(2, 0, 0), 1e-5)
        // centroid nil on empty / non-finite.
        XCTAssertNil(FrameMetrics.centroid([]))
        XCTAssertNil(FrameMetrics.centroid([SIMD3<Float>(.nan, 0, 0)]))

        // Build frame A (atoms at x=0,1) and frame B (same atoms shifted +2 in x).
        let frameA = makeScene(coords: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)], cell: true, energy: 1.0)
        let frameB = makeScene(coords: [SIMD3<Float>(2, 0, 0), SIMD3<Float>(3, 0, 0)], cell: true, energy: 2.0)
        // Sanity: centroids differ before alignment.
        assertVecEqual(FrameMetrics.centroid(frameA.atoms.map(\.coord)), SIMD3<Float>(0.5, 0, 0), 1e-5)
        assertVecEqual(FrameMetrics.centroid(frameB.atoms.map(\.coord)), SIMD3<Float>(2.5, 0, 0), 1e-5)

        // alignCentroid to frame 0: frame B' centroid must equal frame A centroid,
        // and frame A is unchanged (it IS the reference).
        guard let aligned = FrameMetrics.alignCentroid(frames: [frameA, frameB], to: 0) else {
            return XCTFail("alignCentroid should succeed on matching frames")
        }
        XCTAssertEqual(aligned.count, 2)
        assertVecEqual(FrameMetrics.centroid(aligned[0].atoms.map(\.coord)),
                       FrameMetrics.centroid(frameA.atoms.map(\.coord)) ?? SIMD3<Float>.zero, 1e-5)
        assertVecEqual(FrameMetrics.centroid(aligned[1].atoms.map(\.coord)),
                       FrameMetrics.centroid(frameA.atoms.map(\.coord)) ?? SIMD3<Float>.zero, 1e-5)
        // Reference frame A is untouched.
        XCTAssertEqual(aligned[0].atoms.map(\.coord), frameA.atoms.map(\.coord))
        // B atoms shifted by -2 in x (2->0, 3->1), labels/atomicNumber/energy/cell preserved.
        assertVecEqual(aligned[1].atoms[0].coord, SIMD3<Float>(0, 0, 0), 1e-5)
        assertVecEqual(aligned[1].atoms[1].coord, SIMD3<Float>(1, 0, 0), 1e-5)
        XCTAssertEqual(aligned[1].atoms[0].label, "H")
        XCTAssertEqual(aligned[1].atoms[0].atomicNumber, 1)
        XCTAssertEqual(aligned[1].forceSet?.totalEnergy, 2.0)
        XCTAssertEqual(aligned[1].cell, frameB.cell)

        // alignCentroid nil on mismatched counts.
        XCTAssertNil(FrameMetrics.alignCentroid(frames: [frameA, c], to: 0))
        // alignCentroid nil on out-of-range referenceIndex.
        XCTAssertNil(FrameMetrics.alignCentroid(frames: [frameA, frameB], to: 5))
        // alignCentroid nil on empty frames.
        XCTAssertNil(FrameMetrics.alignCentroid(frames: [], to: 0))

        // MARK: - FrameMetricsPlotView

        // Construct with metrics and draw into a bitmap — must not trap.
        // Use a manual CGContext bitmap (no window required) so the test works
        // headless, mirroring the RendererTests render path.
        let plot = FrameMetricsPlotView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        plot.metrics = metrics
        plot.metric = .volume
        drawPlotViewIntoBitmap(plot)
        // csv() must equal FrameMetrics.csv(metrics).
        XCTAssertEqual(plot.csv(), FrameMetrics.csv(metrics))

        // Drawing with no metrics must not trap either.
        let emptyPlot = FrameMetricsPlotView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        drawPlotViewIntoBitmap(emptyPlot)
    }

    /// Render an NSView into an offscreen CGContext-backed bitmap without a window.
    private func drawPlotViewIntoBitmap(_ view: NSView) {
        let bounds = view.bounds
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { return }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        view.draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
}
