import XCTest
import simd
import Darwin
@testable import MolVisApp

// Export interoperability for the two pair-based k-path formats: QE K_POINTS
// crystal_b (band-path card body) and Wannier90 kpoint_path. Covers exact
// syntax, distance-weighted sampling, disconnected-path encoding, label
// policy, failure modes, locale independence, default filenames, editor
// availability/help, and dispatch through KPathExport.export.
final class KPathExportInteropTests: XCTestCase {

    private let g = KPoint(SIMD3(0, 0, 0), "G")
    private let x = KPoint(SIMD3(0.5, 0, 0), "X")
    private let m = KPoint(SIMD3(0.5, 0.5, 0), "M")
    private let l = KPoint(SIMD3(0.5, 0.5, 0.5), "L")

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kpath-export-\(UUID().uuidString)-\(name)")
    }

    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    // MARK: - Wannier90 kpoint_path

    func testWannier90ExactSyntax() throws {
        let route = KPath(points: [g, x, m], pointsPerSegment: 20)
        let out = try KPathExport.wannier90KPointPath(route)
        let expected = """
        begin kpoint_path
        G 0.000000 0.000000 0.000000 X 0.500000 0.000000 0.000000
        X 0.500000 0.000000 0.000000 M 0.500000 0.500000 0.000000
        end kpoint_path
        """
        XCTAssertEqual(out, expected + "\n")
    }

    func testWannier90DisconnectedRoundTrip() throws {
        // G-X | M-L: two independent edges. The exported rows must re-parse
        // into the identical break topology through KPathImport.
        let route = KPath(points: [g, x, m, l], pointsPerSegment: 20, breaks: [1])
        let text = try KPathExport.export(route, as: .wannier90)
        let url = tempURL("route.win")
        try! text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try KPathImport.parse(text: text, url: url)
        XCTAssertEqual(parsed.points.count, 4)
        XCTAssertEqual(parsed.breaks, [1], "non-sharing rows must reconstruct the break")
        XCTAssertEqual(parsed.points.map(\.label), ["G", "X", "M", "L"])
        XCTAssertTrue(allComponentsEqual(parsed.points[3].frac, l.frac))
    }

    func testWannier90GeneratedAndSanitizedLabels() throws {
        // Blank/whitespace labels get deterministic K<routeIndex+1> labels; a
        // shared endpoint carries the same sanitized label in adjacent rows.
        let route = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "  "),
            KPoint(SIMD3(0.5, 0, 0), "X prime"),
            KPoint(SIMD3(0.5, 0.5, 0), ""),
        ])
        let out = try KPathExport.export(route, as: .wannier90)
        XCTAssertTrue(out.contains("\nK1 0.000000 0.000000 0.000000 Xprime 0.500000 0.000000 0.000000\n"))
        XCTAssertTrue(out.contains("\nXprime 0.500000 0.000000 0.000000 K3 0.500000 0.500000 0.000000\n"))
    }

    func testWannier90LabelHelper() {
        XCTAssertEqual(KPathExport.wannier90Label("", routeIndex: 0), "K1")
        XCTAssertEqual(KPathExport.wannier90Label("  \n\t", routeIndex: 2), "K3")
        XCTAssertEqual(KPathExport.wannier90Label("Gamma point", routeIndex: 0), "Gammapoint")
        XCTAssertEqual(KPathExport.wannier90Label(" G ", routeIndex: 1), "G")
        XCTAssertEqual(KPathExport.wannier90Label(String(repeating: "Z", count: 80), routeIndex: 0).count, 64)
        // Wannier90 comment characters must never survive sanitization.
        XCTAssertEqual(KPathExport.wannier90Label("X!", routeIndex: 0), "X_")
        XCTAssertEqual(KPathExport.wannier90Label("#Y", routeIndex: 0), "_Y")
        XCTAssertEqual(KPathExport.wannier90Label("a !b #c", routeIndex: 0), "a_b_c")
    }

    func testWannier90CommentCharLabelsRoundTrip() throws {
        // Labels containing whitespace and Wannier90 comment characters (!, #)
        // sanitize to a parseable file; the sanitized labels round-trip
        // through KPathImport.
        let route = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "Gamma point"),
            KPoint(SIMD3(0.5, 0, 0), "X!"),
            KPoint(SIMD3(0.5, 0.5, 0), "#Y"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "  "),
        ])
        let text = try KPathExport.export(route, as: .wannier90)
        XCTAssertFalse(text.contains("!"), "exported file must not contain comment characters")
        XCTAssertFalse(text.contains("#"), "exported file must not contain comment characters")
        let url = tempURL("route.win")
        try! text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try KPathImport.parse(text: text, url: url)
        XCTAssertEqual(parsed.points.map(\.label), ["Gammapoint", "X_", "_Y", "K4"])
    }

    func testWannier90Failures() throws {
        let singleton = KPath(points: [g])
        XCTAssertThrowsError(try KPathExport.export(singleton, as: .wannier90)) { err in
            guard case KPathExport.ExportError.tooFewPoints = err else {
                return XCTFail("expected tooFewPoints, got \(err)")
            }
        }
        let noEdge = KPath(points: [g, x], breaks: [0])
        XCTAssertThrowsError(try KPathExport.export(noEdge, as: .wannier90)) { err in
            guard case KPathExport.ExportError.noConnectedEdge = err else {
                return XCTFail("expected noConnectedEdge, got \(err)")
            }
        }
        let orphan = KPath(points: [g, x, m, l], breaks: [2])
        XCTAssertThrowsError(try KPathExport.export(orphan, as: .wannier90)) { err in
            guard case KPathExport.ExportError.orphanSingleton = err else {
                return XCTFail("expected orphanSingleton, got \(err)")
            }
        }
        let nan = KPath(points: [g, KPoint(SIMD3<Float>(Float.nan, 0, 0), "N")])
        XCTAssertThrowsError(try KPathExport.export(nan, as: .wannier90)) { err in
            guard case KPathExport.ExportError.nonFiniteRoute = err else {
                return XCTFail("expected nonFiniteRoute, got \(err)")
            }
        }
    }

    // MARK: - QE K_POINTS crystal_b

    func testQECrystalBExactSyntaxAndSampling() throws {
        // Two equal edges: a 40-sample budget gives 20 desired samples per
        // edge, exported as 19 subdivisions (QE emits the line start
        // separately). The final row's weight is QE-ignored and written as 0.
        let route = KPath(points: [g, x, m], pointsPerSegment: 40)
        let out = try KPathExport.export(route, as: .qeCrystalB)
        let expected = """
        3
        0.000000 0.000000 0.000000 19
        0.500000 0.000000 0.000000 19
        0.500000 0.500000 0.000000 0
        """
        XCTAssertEqual(out, expected + "\n")
    }

    func testQECrystalBDistanceWeightedSampling() throws {
        // Edges of length 0.5 and 0.25 in a 0.75 component: 27 and 13 desired
        // samples -> exported subdivisions 26 and 12.
        let a = KPoint(SIMD3(0, 0, 0), "G")
        let b = KPoint(SIMD3(0.5, 0, 0), "X")
        let c = KPoint(SIMD3(0.5, 0.25, 0), "M")
        let route = KPath(points: [a, b, c], pointsPerSegment: 40)
        let out = try KPathExport.export(route, as: .qeCrystalB)
        XCTAssertTrue(out.contains("\n0.000000 0.000000 0.000000 26\n"),
                      "longer edge must get the larger line weight, got:\n\(out)")
        XCTAssertTrue(out.contains("\n0.500000 0.000000 0.000000 12\n"),
                      "shorter edge must get the smaller line weight, got:\n\(out)")
    }

    func testQECrystalBSamplingClamped() throws {
        let high = KPath(points: [g, x], pointsPerSegment: 5000)
        let outHigh = try KPathExport.export(high, as: .qeCrystalB)
        XCTAssertTrue(outHigh.contains("\n0.000000 0.000000 0.000000 199\n"))
        let low = KPath(points: [g, x], pointsPerSegment: 1)
        let outLow = try KPathExport.export(low, as: .qeCrystalB)
        XCTAssertTrue(outLow.contains("\n0.000000 0.000000 0.000000 1\n"))
    }

    func testQECrystalBDisconnectedEncodedWithZeroWeights() throws {
        // G-X | M-L: each row carries the weight of the line leaving it; the
        // break edge (X->M) gets weight 0 (QE's official jump), so
        // disconnected components are not silently connected; the final row's
        // ignored weight is 0.
        let route = KPath(points: [g, x, m, l], pointsPerSegment: 20, breaks: [1])
        let out = try KPathExport.export(route, as: .qeCrystalB)
        let expected = """
        4
        0.000000 0.000000 0.000000 19
        0.500000 0.000000 0.000000 0
        0.500000 0.500000 0.000000 19
        0.500000 0.500000 0.500000 0
        """
        XCTAssertEqual(out, expected + "\n")
    }

    func testQECrystalBCountMatchesInterpolated() throws {
        // QE's own count formula (read_cards.f90:822-825) is nkstot = 1 + sum
        // of positive weights + number of zero-weight lines, all rows before
        // the final one. For every nondegenerate route this must equal the
        // editor's interpolation point count, proving the n-1 subdivision
        // mapping reproduces the editor's sampling exactly.
        let connected = KPath(points: [g, x, m, l], pointsPerSegment: 40)
        let disconnected = KPath(points: [g, x, m, l], pointsPerSegment: 40, breaks: [1])
        for route in [connected, disconnected] {
            let out = try KPathExport.export(route, as: .qeCrystalB)
            XCTAssertEqual(qeCountFormula(out), route.interpolated().count,
                           "QE count formula must match interpolated() for breaks \(route.breaks):\n\(out)")
        }
    }

    /// Reimplement QE's nkstot computation for a crystal_b card body: 1 + sum
    /// of positive weights + number of zero-weight lines over all rows except
    /// the final one (whose weight QE ignores).
    private func qeCountFormula(_ card: String) -> Int {
        let rows = card.split(separator: "\n").dropFirst().map(String.init)
        var total = 1
        for row in rows.dropLast() {
            let tokens = row.split(whereSeparator: { $0 == " " }).map(String.init)
            let w = Int(tokens[3]) ?? 0
            total += max(w, 1)   // positive w: w points; zero w: 1 endpoint
        }
        return total
    }

    func testQECrystalBFailures() throws {
        let singleton = KPath(points: [g])
        XCTAssertThrowsError(try KPathExport.export(singleton, as: .qeCrystalB)) { err in
            guard case KPathExport.ExportError.tooFewPoints = err else {
                return XCTFail("expected tooFewPoints, got \(err)")
            }
        }
        let empty = KPath(points: [])
        XCTAssertThrowsError(try KPathExport.export(empty, as: .qeCrystalB)) { err in
            guard case KPathExport.ExportError.tooFewPoints = err else {
                return XCTFail("expected tooFewPoints, got \(err)")
            }
        }
        let nan = KPath(points: [g, KPoint(SIMD3<Float>(Float.nan, 0, 0), "N")])
        XCTAssertThrowsError(try KPathExport.export(nan, as: .qeCrystalB)) { err in
            guard case KPathExport.ExportError.nonFiniteRoute = err else {
                return XCTFail("expected nonFiniteRoute, got \(err)")
            }
        }
    }

    // MARK: - Locale independence

    func testWritersLocaleIndependent() throws {
        // A comma-locale must not change the '.' decimal separator the writers
        // produce (they format with the POSIX locale explicitly). The exact
        // prior locale is restored afterwards.
        let prior = setlocale(LC_NUMERIC, nil).map { String(cString: $0) }
        guard setlocale(LC_NUMERIC, "de_DE.UTF-8") != nil else {
            throw XCTSkip("comma decimal locale unavailable on this system")
        }
        defer {
            if let prior = prior {
                prior.withCString { setlocale(LC_NUMERIC, $0) }
            }
        }
        let route = KPath(points: [g, x], pointsPerSegment: 20)
        let qeOut = try KPathExport.export(route, as: .qeCrystalB)
        XCTAssertTrue(qeOut.contains("0.000000 0.000000 0.000000 19"))
        XCTAssertFalse(qeOut.contains(","))
        let w90Out = try KPathExport.export(route, as: .wannier90)
        XCTAssertTrue(w90Out.contains("G 0.000000 0.000000 0.000000 X 0.500000 0.000000 0.000000"))
        XCTAssertFalse(w90Out.contains(","))
    }

    // MARK: - Route-node cap

    func testRouteNodeCapBoundaryAccepted() throws {
        // The 1024-node editor/import cap is the export cap; exactly 1024
        // connected nodes must export for both pair-based formats.
        let points = (0..<1024).map { KPoint(SIMD3(Float($0) / 1023.0, 0, 0), "") }
        let route = KPath(points: points, pointsPerSegment: 20)

        let qeOut = try KPathExport.export(route, as: .qeCrystalB)
        let qeLines = qeOut.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(qeLines.count, 1025, "count line + 1024 rows")
        XCTAssertEqual(qeLines[0], "1024")

        let w90Out = try KPathExport.export(route, as: .wannier90)
        let w90Lines = w90Out.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(w90Lines.count, 1025, "begin + 1023 edge rows + end")
        XCTAssertEqual(w90Lines.first, "begin kpoint_path")
        XCTAssertEqual(w90Lines.last, "end kpoint_path")
    }

    func testRouteNodeCapRejected() throws {
        // One node over the cap is rejected up front for both formats, before
        // any output is constructed.
        let points = (0..<1025).map { KPoint(SIMD3(Float($0) / 1024.0, 0, 0), "") }
        let route = KPath(points: points, pointsPerSegment: 20)
        for format in [KPathExportFormat.qeCrystalB, .wannier90] {
            XCTAssertThrowsError(try KPathExport.export(route, as: format)) { err in
                guard case KPathExport.ExportError.tooManyPoints(let count) = err else {
                    return XCTFail("expected tooManyPoints, got \(err)")
                }
                XCTAssertEqual(count, 1025)
            }
        }
        // The LocalizedError text reports both the cap and the offending count.
        let error = KPathExport.ExportError.tooManyPoints(1025)
        XCTAssertEqual(error.errorDescription, "Export requires at most 1024 route points; got 1025.")
    }

    // MARK: - Filenames, editor policy, dispatch

    func testDefaultFilenames() {
        XCTAssertEqual(KPathExportFormat.qe.defaultFilename, "kpath.qe")
        XCTAssertEqual(KPathExportFormat.qeCrystalB.defaultFilename, "kpath.crystal_b")
        XCTAssertEqual(KPathExportFormat.kpf.defaultFilename, "kpath.kpf")
        XCTAssertEqual(KPathExportFormat.vasp.defaultFilename, "KPOINTS")
        XCTAssertEqual(KPathExportFormat.wannier90.defaultFilename, "kpath.win")
    }

    func testEditorAvailabilityMatrix() {
        let empty = KPath(points: [])
        let one = KPath(points: [g])
        let two = KPath(points: [g, x])
        let connected = KPath(points: [g, x, m])
        let disconnected = KPath(points: [g, x, m, l], breaks: [1])
        let orphan = KPath(points: [g, x, m, l], breaks: [2])
        let noEdge = KPath(points: [g, x], breaks: [0])

        for format in [KPathExportFormat.qeCrystalB, .wannier90] {
            XCTAssertFalse(KPathExport.isEnabledInEditor(empty, as: format))
            XCTAssertFalse(KPathExport.isEnabledInEditor(one, as: format))
            XCTAssertTrue(KPathExport.isEnabledInEditor(two, as: format))
            XCTAssertTrue(KPathExport.isEnabledInEditor(connected, as: format))
            XCTAssertTrue(KPathExport.isEnabledInEditor(disconnected, as: format))
            XCTAssertFalse(KPathExport.editorHelp(one, as: format).isEmpty,
                           "disabled format \(format) must explain why")
        }
        // crystal_b encodes orphan singletons and fully broken routes via
        // weight-0 lines; Wannier90 rejects both.
        XCTAssertTrue(KPathExport.isEnabledInEditor(orphan, as: .qeCrystalB))
        XCTAssertTrue(KPathExport.isEnabledInEditor(noEdge, as: .qeCrystalB))
        XCTAssertFalse(KPathExport.isEnabledInEditor(orphan, as: .wannier90))
        XCTAssertFalse(KPathExport.isEnabledInEditor(noEdge, as: .wannier90))
        // Wannier90 help explains each disabled reason.
        XCTAssertTrue(KPathExport.editorHelp(orphan, as: .wannier90).contains("singleton"))
        XCTAssertTrue(KPathExport.editorHelp(noEdge, as: .wannier90).contains("connected pair"))
        // Enabled formats still carry a tooltip.
        XCTAssertEqual(KPathExport.editorHelp(connected, as: .qeCrystalB),
                       "Export explicit QE K_POINTS crystal_b card data")
        XCTAssertEqual(KPathExport.editorHelp(connected, as: .wannier90),
                       "Export Wannier90 kpoint_path block")
    }

    func testExportDispatchRoutesNewFormats() throws {
        let route = KPath(points: [g, x, m], pointsPerSegment: 30)
        XCTAssertEqual(try KPathExport.export(route, as: .qeCrystalB),
                       try KPathExport.qeKPointsCrystalB(route))
        XCTAssertEqual(try KPathExport.export(route, as: .wannier90),
                       try KPathExport.wannier90KPointPath(route))
    }
}
