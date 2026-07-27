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

    func testExportVASPFormat() throws {
        // Gamma -> X -> M, three points, two edges. Endpoints repeat shared nodes
        // in pairs; a blank line separates each pair.
        let path = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                  KPoint(SIMD3(0.5,0,0), "X"),
                                  KPoint(SIMD3(0.5,0.5,0), "M")],
                          pointsPerSegment: 20)
        let out = try KPathExport.vaspKPoints(path)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        XCTAssertEqual(lines[0], "k-points for band structure")
        XCTAssertEqual(lines[1], "20", "pointsPerSegment in header")
        XCTAssertEqual(lines[2], "Line-mode")
        XCTAssertEqual(lines[3], "Reciprocal")
        // Pair 1: G, X
        XCTAssertEqual(lines[4], "0.000000 0.000000 0.000000 ! G")
        XCTAssertEqual(lines[5], "0.500000 0.000000 0.000000 ! X")
        // Blank separator
        XCTAssertEqual(lines[6], "")
        // Pair 2: X, M (shared X repeated)
        XCTAssertEqual(lines[7], "0.500000 0.000000 0.000000 ! X")
        XCTAssertEqual(lines[8], "0.500000 0.500000 0.000000 ! M")
        XCTAssertEqual(lines[9], "", "trailing blank")
        XCTAssertEqual(lines.count, 10)
    }

    func testExportVASPDisconnected() throws {
        // G -> X | M -> G (break at index 1). Two single-edge components.
        let path = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                  KPoint(SIMD3(0.5,0,0), "X"),
                                  KPoint(SIMD3(0.5,0.5,0), "M"),
                                  KPoint(SIMD3(0,0,0), "G")],
                          pointsPerSegment: 10, breaks: [1])
        let out = try KPathExport.vaspKPoints(path)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        XCTAssertEqual(lines[0], "k-points for band structure")
        XCTAssertEqual(lines[1], "10")
        // Pair 1: G, X — blank — Pair 2: M, G
        XCTAssertEqual(lines[4], "0.000000 0.000000 0.000000 ! G")
        XCTAssertEqual(lines[5], "0.500000 0.000000 0.000000 ! X")
        XCTAssertEqual(lines[6], "")
        XCTAssertEqual(lines[7], "0.500000 0.500000 0.000000 ! M")
        XCTAssertEqual(lines[8], "0.000000 0.000000 0.000000 ! G")
    }

    func testExportVASPAvailability() throws {
        // VASP line-mode needs at least one connected pair.
        let one = KPath(points: [KPoint(SIMD3(0,0,0), "G")])
        XCTAssertFalse(KPathExport.isEnabledInEditor(one, as: .vasp))
        // Two points connected — one pair.
        let two = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                  KPoint(SIMD3(0.5,0,0), "X")])
        XCTAssertTrue(KPathExport.isEnabledInEditor(two, as: .vasp))
        // Two points with a break = two singletons, no connected edge.
        let singletons = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                         KPoint(SIMD3(0.5,0,0), "X")], breaks: [0])
        XCTAssertFalse(KPathExport.isEnabledInEditor(singletons, as: .vasp))
        // Single-pair route with an orphan singleton (G-X|M) — rejected.
        let withSingleton = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                            KPoint(SIMD3(0.5,0,0), "X"),
                                            KPoint(SIMD3(0.5,0.5,0), "M")], breaks: [1])
        XCTAssertFalse(KPathExport.isEnabledInEditor(withSingleton, as: .vasp))
        XCTAssertThrowsError(try KPathExport.export(withSingleton, as: .vasp))
        // Four-point disconnected but fully paired: G-X | M-G (both edges).
        let paired = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                     KPoint(SIMD3(0.5,0,0), "X"),
                                     KPoint(SIMD3(0.5,0.5,0), "M"),
                                     KPoint(SIMD3(0,0,0), "G")], breaks: [1])
        XCTAssertTrue(KPathExport.isEnabledInEditor(paired, as: .vasp))
        // All-broken route throws from export().
        XCTAssertThrowsError(try KPathExport.export(singletons, as: .vasp))
        // Help text.
        XCTAssertTrue(KPathExport.editorHelp(one, as: .vasp).contains("at least two"))
        XCTAssertEqual(KPathExport.editorHelp(two, as: .vasp),
                       "Export VASP line-mode KPOINTS file")
    }

    func testExportVASPRoundTripThroughExportSwitch() throws {
        let path = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                  KPoint(SIMD3(0.5,0,0), "X")])
        let out = try KPathExport.export(path, as: .vasp)
        XCTAssertTrue(out.hasPrefix("k-points for band structure\n20\nLine-mode\nReciprocal\n"))
    }

    func testExportKPF() {
        // ISS multiplier clears the .5 denominators -> 2.
        let path = KPath(points: [KPoint(SIMD3(0,0,0), "G"),
                                  KPoint(SIMD3(0.5,0,0), "X"),
                                  KPoint(SIMD3(0.5,0.5,0), "M")])
        let kpf = try! KPathExport.xcrysdnenKPF(path)
        let lines = kpf.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "kpf: 1 multiplier line + 3 k-point lines")
        XCTAssertEqual(lines[0], "2", "ISS multiplier for .5 coords is 2")
        XCTAssertTrue(lines[2].hasPrefix("1 0 0"), "X point should be (1,0,0)*, got \(lines[2])")
    }
}
