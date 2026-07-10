import XCTest
import simd
@testable import MolVisApp

// k-path interpolation + export: pure SIMD-vector math, no matrix inverse.
// Validates the F/kPath.f contract that a band-structure run consumes.
final class KPathTests: XCTestCase {

    func testInterpolatorMidpoint() {
        let path = KPath(points: [KPoint(SIMD3(0,0,0), "Gamma"),
                                  KPoint(SIMD3(0.5,0,0), "X")], pointsPerSegment: 5)
        let seg0 = Array(path.interpolated().prefix(5))
        XCTAssertEqual(seg0.first!.x, 0.0, accuracy: 1e-3)
        XCTAssertEqual(seg0.last!.x, 0.5, accuracy: 1e-3)
        XCTAssertEqual(seg0[2].x, 0.25, accuracy: 1e-2)
    }

    func testExportQE() {
        let path = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                  KPoint(SIMD3(0.5,0,0), "X"),
                                  KPoint(SIMD3(0.5,0.5,0), "M")], pointsPerSegment: 10)
        let out = KPathExport.qeKPointsCrystal(path)
        let lines = out.split(separator: "\n").filter { !$0.isEmpty }
        // count line + interpolated points; with interior samples we expect many.
        XCTAssertGreaterThan(lines.dropFirst().count, 3, "expected several interpolated points")
        XCTAssertTrue(out.contains("0.500"), "export should contain the X coordinate")
        // The F5 fix: no adjacent duplicate k-points (shared segment endpoints
        // emitted once). Verify directly on the interpolated list.
        let pts = path.interpolated()
        for i in 1..<pts.count {
            XCTAssertNotEqual(pts[i], pts[i-1], "adjacent k-points must not duplicate (F5)")
        }
        // All special points are present in order.
        XCTAssertEqual(pts.first, SIMD3(0,0,0))
        XCTAssertEqual(pts.last, SIMD3(0.5,0.5,0))
    }

    func testExportKPF() {
        // ISS multiplier clears the .5 denominators -> 2.
        let path = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                  KPoint(SIMD3(0.5,0,0), "X"),
                                  KPoint(SIMD3(0.5,0.5,0), "M")])
        let kpf = KPathExport.xcrysdnenKPF(path)
        let lines = kpf.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "kpf: 1 multiplier line + 3 k-point lines")
        XCTAssertEqual(lines[0], "2", "ISS multiplier for .5 coords is 2")
        XCTAssertTrue(lines[2].hasPrefix("1 0 0"), "X point should be (1,0,0)*, got \(lines[2])")
    }
}
