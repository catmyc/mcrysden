import XCTest
import simd
@testable import MolVisApp

// Integration tests for the k-path export UI wiring: sidebar format actions
// (QE crystal_b and Wannier90 added alongside the existing QE/KPF/VASP rows),
// controller save-panel defaults, sampling stamping through kPathForExport, and
// availability/help policy surfaced through the production KPathExport APIs.
// Exact export text is covered by the core KPath tests; nothing here asserts
// writer text.
@MainActor
final class KPathExportIntegrationTests: XCTestCase {

    private let g = KPoint(SIMD3(0, 0, 0), "G")
    private let x = KPoint(SIMD3(0.5, 0, 0), "X")
    private let m = KPoint(SIMD3(0.5, 0.5, 0), "M")
    private let l = KPoint(SIMD3(0.5, 0.5, 0.5), "L")

    // MARK: - Format action availability/help (production KPathExport APIs)

    func testNewFormatsRejectSingletonWithHelp() {
        let one = KPath(points: [g])
        for format in [KPathExportFormat.qeCrystalB, .wannier90] {
            XCTAssertFalse(KPathExport.isEnabledInEditor(one, as: format),
                           "pair-based format \(format) cannot encode a singleton")
            XCTAssertFalse(KPathExport.editorHelp(one, as: format).isEmpty,
                           "disabled format \(format) must explain why")
        }
    }

    func testNewFormatsAcceptConnectedRoute() {
        let two = KPath(points: [g, x])
        let three = KPath(points: [g, x, m])
        for format in [KPathExportFormat.qeCrystalB, .wannier90] {
            XCTAssertTrue(KPathExport.isEnabledInEditor(two, as: format),
                          "single connected segment must be exportable as \(format)")
            XCTAssertTrue(KPathExport.isEnabledInEditor(three, as: format),
                          "connected multi-segment route must be exportable as \(format)")
            XCTAssertFalse(KPathExport.editorHelp(three, as: format).isEmpty,
                           "enabled format \(format) must still provide a tooltip")
        }
    }

    func testNewFormatsEncodeDisconnectedSegments() {
        // G-X | M-L: the break at index 1 separates two independent segments,
        // which both QE crystal_b and Wannier90 kpoint_path encode per-line.
        let disconnected = KPath(points: [g, x, m, l], breaks: [1])
        for format in [KPathExportFormat.qeCrystalB, .wannier90, .vasp] {
            XCTAssertTrue(KPathExport.isEnabledInEditor(disconnected, as: format),
                          "pair-based format \(format) must encode each segment independently")
        }
    }

    // MARK: - Save-panel default filenames

    func testDefaultFilenamesPerFormat() {
        let formats: [KPathExportFormat] = [.qe, .qeCrystalB, .wannier90, .kpf, .vasp]
        for format in formats {
            XCTAssertFalse(format.defaultFilename.isEmpty, "\(format) must have a default filename")
        }
        XCTAssertEqual(Set(formats.map(\.defaultFilename)).count, formats.count,
                       "each format needs a distinct default filename")
        XCTAssertFalse(KPathExportFormat.vasp.defaultFilename.contains("."),
                       "VASP KPOINTS default filename must be extensionless")
    }

    // MARK: - Sampling stamping

    func testKPathForExportStampsSamplingUnchangedGeometry() {
        let c = MainWindowController(scene: Scene(), showWindow: false)
        c.state.kPathSampling = 60

        let route = KPath(points: [g, x, m], pointsPerSegment: 20, breaks: [1])
        let stamped = c.kPathForExport(route)

        XCTAssertEqual(stamped.pointsPerSegment, 60, "export route must carry the UI sampling")
        XCTAssertEqual(stamped.points.count, route.points.count, "stamping must not change geometry")
        XCTAssertEqual(stamped.breaks, route.breaks, "stamping must not change break topology")
        XCTAssertTrue(allComponentsEqual(stamped.points[0].frac, g.frac, 1e-6))
    }

    // MARK: - SideBar construction

    func testSideBarBuildsWithCrystalRoute() {
        // Construct the sidebar for a crystal with a route so the k-path section
        // (including the export rows) materializes without crashing.
        let s = SideBarState()
        s.isCrystal = true
        s.kPathPoints = [g, x, m]
        s.kPathBreaks = []
        _ = SideBar(state: s).body
    }

    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }
}
