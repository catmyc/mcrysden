import XCTest
import simd
@testable import MolVisApp

// Unit tests for the k-path import parser (KPathImport). Exercises format
// detection, the QE/VASP/Wannier90/KPF parsers, error paths, limits, and the
// export -> import round trip that guarantees exported routes re-parse.
final class KPathImportTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kpath-import-\(UUID().uuidString)-\(name)")
    }

    private func writeTemp(_ text: String, _ name: String) -> URL {
        let url = tempURL(name)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-4) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    // MARK: - Format detection

    func testDetectFormatKPFExtension() throws {
        let url = writeTemp("2\n0 0 0  G\n1 1 1  X\n", "route.kpf")
        XCTAssertEqual(try KPathImport.format(of: url), .kpf)
    }

    func testDetectFormatKPOINTSFilename() throws {
        // VASP KPOINTS file with standard line-mode layout.
        let content = """
        k-points for band structure
        40
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        XCTAssertEqual(try KPathImport.format(of: url), .vasp)
    }

    func testDetectFormatKPOINTSLowercaseExtension() throws {
        let content = """
        k-points
        10
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "kpath.kpoints")
        XCTAssertEqual(try KPathImport.format(of: url), .vasp)
    }

    func testDetectFormatQESniff() throws {
        let content = """
        some header
        K_POINTS crystal
        2
        0.0 0.0 0.0 1.0
        0.5 0.0 0.0 1.0
        """
        let url = writeTemp(content, "scf.in")
        XCTAssertEqual(try KPathImport.format(of: url), .qe)
    }

    func testDetectFormatWannier90Sniff() throws {
        let content = """
        some header
        kpoint_path
        G  X  0.0 0.0 0.0 0.5 0.0 0.0
        """
        let url = writeTemp(content, "win")
        XCTAssertEqual(try KPathImport.format(of: url), .wannier90)
    }

    func testDetectFormatVASPSniff() throws {
        // Third significant line is "Line-mode" — the VASP fallback rule.
        let content = """
        title
        40
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        """
        let url = writeTemp(content, "dat")
        XCTAssertEqual(try KPathImport.format(of: url), .vasp)
    }

    func testDetectFormatUnknownUnsupported() {
        let content = "this is not a k-path file at all\njust random text\nand more\n"
        let url = writeTemp(content, "txt")
        XCTAssertThrowsError(try KPathImport.format(of: url)) { err in
            guard case KPathImportError.unsupportedFile(let path, _) = err else {
                return XCTFail("expected unsupportedFile, got \(err)")
            }
            XCTAssertTrue(path.contains("txt"), "error should mention path, got \(path)")
        }
    }

    // MARK: - QE K_POINTS crystal happy path

    func testQECrystalHappyPath() throws {
        let content = """
        K_POINTS crystal
        4

        # comment line
        0.000000 0.000000 0.000000 1.0
        0.500000 0.000000 0.000000 1.0
        0.500000 0.500000 0.500000 1.0
        0.000000 0.000000 0.000000 1.0
        """
        let url = writeTemp(content, "scf.in")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 4)
        XCTAssertEqual(path.pointsPerSegment, 20)
        XCTAssertTrue(path.breaks.isEmpty)
        // All labels empty.
        XCTAssertTrue(path.points.allSatisfy { $0.label.isEmpty })
        // Exact coordinates.
        XCTAssertTrue(allComponentsEqual(path.points[0].frac, SIMD3(0, 0, 0)))
        XCTAssertTrue(allComponentsEqual(path.points[1].frac, SIMD3(0.5, 0, 0)))
        XCTAssertTrue(allComponentsEqual(path.points[2].frac, SIMD3(0.5, 0.5, 0.5)))
        XCTAssertTrue(allComponentsEqual(path.points[3].frac, SIMD3(0, 0, 0)))
    }

    func testQEEmptyQualifierForm() throws {
        // Bare K_POINTS card (no qualifier) parses like crystal.
        let content = """
        K_POINTS
        2
        0.0 0.0 0.0 1.0
        0.5 0.0 0.0 1.0
        """
        let url = writeTemp(content, "in")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertEqual(path.pointsPerSegment, 20)
        XCTAssertTrue(path.breaks.isEmpty)
    }

    func testQEThreeCoordinatesNoWeight() throws {
        // 3-token data lines (no weight) parse fine — weight is optional.
        let content = """
        K_POINTS crystal
        2
        0.0 0.0 0.0
        0.25 0.25 0.25
        """
        let url = writeTemp(content, "in")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertTrue(allComponentsEqual(path.points[1].frac, SIMD3(0.25, 0.25, 0.25)))
    }

    // MARK: - QE not-a-path modes

    func testQEAutomaticNotAPath() {
        let content = "K_POINTS automatic\n2 2 2 0 0 0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    func testQETpibaBNotAPath() {
        let content = "K_POINTS tpiba_b\n2\n0.0 0.0 0.0\n0.5 0.0 0.0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    func testQECartesNotAPath() {
        let content = "K_POINTS cartes\n2\n0.0 0.0 0.0\n0.5 0.0 0.0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    func testQEGammaNotAPath() {
        let content = "K_POINTS gamma\n2\n0.0 0.0 0.0\n0.5 0.0 0.0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    // MARK: - QE malformed

    func testQEMalformedMissingCount() {
        let content = "K_POINTS crystal\n0.0 0.0 0.0 1.0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testQEMalformedNonIntegerCount() {
        let content = "K_POINTS crystal\nabc\n0.0 0.0 0.0 1.0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testQEMalformedCountMismatch() {
        let content = "K_POINTS crystal\n5\n0.0 0.0 0.0 1.0\n0.5 0.0 0.0 1.0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed (count mismatch), got \(err)")
            }
        }
    }

    func testQEMalformedNonFiniteCoord() {
        let content = "K_POINTS crystal\n2\n0.0 0.0 0.0 1.0\nnan 0.0 0.0 1.0\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testQEMalformedNonFiniteWeight() {
        let content = "K_POINTS crystal\n1\n0.0 0.0 0.0 inf\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testQETooManyPoints() {
        let content = "K_POINTS crystal\n1025\n" + (0..<1025).map { _ in "0.0 0.0 0.0 1.0" }.joined(separator: "\n") + "\n"
        let url = writeTemp(content, "in")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.tooManyPoints(_, let count) = err else {
                return XCTFail("expected tooManyPoints, got \(err)")
            }
            XCTAssertEqual(count, 1025)
        }
    }

    // MARK: - VASP line-mode happy path

    func testVASPHappyPathContinuousAndBreak() throws {
        // N=40 (clamped to 40). Pair 1: G-X, Pair 2: X-M (shares X → coalesced),
        // Pair 3: L-G (no share → break inserted at index 2).
        let content = """
        k-points for band structure
        40
        Line-mode
        Reciprocal
        0.000000 0.000000 0.000000 ! G
        0.500000 0.000000 0.000000 ! X
        0.500000 0.000000 0.000000 ! X
        0.500000 0.500000 0.000000 ! M
        0.500000 0.500000 0.500000 ! L
        0.000000 0.000000 0.000000 ! G
        """
        let url = writeTemp(content, "KPOINTS")
        let path = try KPathImport.parse(text: content, url: url)
        // Coalesced: G-X + M (X shared) → [G,X,M], break, then L-G → [G,X,M,L,G].
        XCTAssertEqual(path.points.count, 5)
        XCTAssertEqual(path.pointsPerSegment, 40)
        XCTAssertEqual(path.breaks, [2])
        XCTAssertTrue(allComponentsEqual(path.points[0].frac, SIMD3(0, 0, 0)))
        XCTAssertTrue(allComponentsEqual(path.points[2].frac, SIMD3(0.5, 0.5, 0)))
        XCTAssertTrue(allComponentsEqual(path.points[3].frac, SIMD3(0.5, 0.5, 0.5)))
        // Labels empty (stripped as comments).
        XCTAssertTrue(path.points.allSatisfy { $0.label.isEmpty })
    }

    func testVASPPointsPerSegmentClampLow() throws {
        let content = """
        title
        1
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.pointsPerSegment, 2, "N=1 must clamp up to 2")
    }

    func testVASPPointsPerSegmentClampHigh() throws {
        let content = """
        title
        5000
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.pointsPerSegment, 200, "N=5000 must clamp down to 200")
    }

    func testVASPTrailingCommentsStripped() throws {
        let content = """
        title
        10
        Line-mode
        Reciprocal
        0.0 0.0 0.0  !  G
        0.5 0.0 0.0  !  X
        """
        let url = writeTemp(content, "KPOINTS")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertTrue(allComponentsEqual(path.points[0].frac, SIMD3(0, 0, 0)))
    }

    func testVASPCanonicalWikiTemplate() throws {
        // Verified VASP wiki template: "line mode" + "fractional" + commented N line.
        let content = """
        k points along high symmetry lines
         40              ! number of points per line
        line mode
        fractional
          0    0    0    Γ
          0.5  0.5  0    X
        """
        let url = writeTemp(content, "KPOINTS")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertEqual(path.pointsPerSegment, 40)
        XCTAssertTrue(path.breaks.isEmpty)
        // Γ (as a 4th-column label) normalizes to "G".
        XCTAssertEqual(path.points[0].label, "G")
        XCTAssertEqual(path.points[1].label, "X")
    }

    func testVASPNumberOfPointsLineWithComment() throws {
        // The VASP wiki template itself uses "40 ! number of points per line".
        let content = """
        k-points for band structure
        40 ! number of points per line
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.pointsPerSegment, 40)
        XCTAssertEqual(path.points.count, 2)
    }

    // MARK: - VASP errors

    func testVASPAutomaticNotAPath() {
        let content = """
        title
        G
        Line-mode
        Reciprocal
        """
        let url = writeTemp(content, "KPOINTS")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    func testVASPAutomaticGenerationNotAPath() {
        // Standard VASP automatic-grid header ("Automatic generation" in the
        // points-per-segment position) must classify as grid mode, not fail
        // with a misleading integer-parse error.
        let content = """
        Automatic mesh
        Automatic generation
        0.25
        Gamma
        0 0 0
        """
        // Detection needs the exact "KPOINTS" filename (no extension-based rule
        // or line-mode sniff applies to an automatic-grid file).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("KPOINTS")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    func testVASPCartesianNotAPath() {
        let content = """
        title
        10
        Line-mode
        Cartesian
        0.0 0.0 0.0 ! G
        """
        let url = writeTemp(content, "KPOINTS")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.notAPath = err else {
                return XCTFail("expected notAPath, got \(err)")
            }
        }
    }

    func testVASPOddPointCountMalformed() {
        let content = """
        title
        10
        Line-mode
        Reciprocal
        0.0 0.0 0.0 ! G
        0.5 0.0 0.0 ! X
        0.5 0.5 0.0 ! M
        """
        let url = writeTemp(content, "KPOINTS")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed (odd), got \(err)")
            }
        }
    }

    func testVASPNonFiniteCoordMalformed() {
        let content = """
        title
        10
        Line-mode
        Reciprocal
        0.0 inf 0.0 ! G
        0.5 0.0 0.0 ! X
        """
        let url = writeTemp(content, "KPOINTS")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testVASPEmptyFileMalformed() {
        // The content sniffer cannot classify an empty file, so the filename must
        // match exactly ("KPOINTS" without a random prefix) for detection to work.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("KPOINTS")
        try! Data().write(to: url)
        XCTAssertThrowsError(try KPathImport.parse(text: "", url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    // MARK: - Wannier90 kpoint_path happy path

    func testWannier90HappyPath() throws {
        // Three interleaved lines, each sharing its endpoint with the next → continuous.
        let content = """
        some header
        begin kpoint_path
        G 0.0 0.0 0.0 X 0.5 0.0 0.0
        X 0.5 0.0 0.0 M 0.5 0.5 0.0
        M 0.5 0.5 0.0 L 0.5 0.5 0.5
        end kpoint_path
        """
        let url = writeTemp(content, "win")
        let path = try KPathImport.parse(text: content, url: url)
        // Shared endpoints coalesce: [G,X,M,L] → 4 points, no breaks.
        XCTAssertEqual(path.points.count, 4)
        XCTAssertEqual(path.pointsPerSegment, 20)
        XCTAssertTrue(path.breaks.isEmpty, "all shared endpoints → no breaks, got \(path.breaks)")
        XCTAssertEqual(path.points[0].label, "G")
        XCTAssertEqual(path.points[1].label, "X")
        XCTAssertEqual(path.points[2].label, "M")
        XCTAssertEqual(path.points[3].label, "L")
    }

    func testWannier90LegacyTwoLabelsFirst() throws {
        // Legacy two-labels-first form: label1 label2 x1 y1 z1 x2 y2 z2.
        let content = """
        some header
        kpoint_path
        G  X  0.0 0.0 0.0 0.5 0.0 0.0
        X  M  0.5 0.0 0.0 0.5 0.5 0.0
        """
        let url = writeTemp(content, "win")
        let path = try KPathImport.parse(text: content, url: url)
        // Shared X coalesces: [G,X,M] → 3 points, no breaks.
        XCTAssertEqual(path.points.count, 3)
        XCTAssertTrue(path.breaks.isEmpty)
        XCTAssertEqual(path.points[0].label, "G")
        XCTAssertEqual(path.points[1].label, "X")
        XCTAssertEqual(path.points[2].label, "M")
    }

    func testWannier90EndTerminatesBlock() throws {
        // Data after "end kpoint_path" must be ignored.
        let content = """
        begin kpoint_path
        G 0.0 0.0 0.0 X 0.5 0.0 0.0
        X 0.5 0.0 0.0 M 0.5 0.5 0.0
        end kpoint_path
        M 0.5 0.5 0.0 L 0.5 0.5 0.5
        """
        let url = writeTemp(content, "win")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 3)   // G,X,M coalesced; L line ignored
        XCTAssertTrue(path.breaks.isEmpty)
    }

    func testWannier90GammaNormalization() {
        // "GM" → "G", "gamma" → "G", "Γ" → "G".
        let content = """
        begin kpoint_path
        GM 0.0 0.0 0.0 X 0.5 0.0 0.0
        gamma 0.0 0.0 0.0 M 0.5 0.5 0.0
        end kpoint_path
        """
        let url = writeTemp(content, "win")
        let path = try! KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points[0].label, "G")
        XCTAssertEqual(path.points[2].label, "G")
    }

    func testWannier90ConnectivityBreak() throws {
        // Two segments NOT sharing an endpoint → break at index 1.
        let content = """
        begin kpoint_path
        G 0.0 0.0 0.0 X 0.5 0.0 0.0
        M 0.5 0.5 0.0 L 0.5 0.5 0.5
        end kpoint_path
        """
        let url = writeTemp(content, "win")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 4)
        XCTAssertEqual(path.breaks, [1], "non-sharing segments must insert a break")
    }

    func testWannier90MalformedEmptyBlock() {
        let content = """
        some header
        kpoint_path
        ! just a comment
        """
        let url = writeTemp(content, "win")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testWannier90MalformedTokenCountsSkipped() {
        // Known behavior: malformed token counts are silently skipped. A block with
        // ONLY malformed lines → no valid segments → malformed.
        let content = """
        kpoint_path
        G  X  0.0 0.0
        too few tokens here
        """
        let url = writeTemp(content, "win")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testWannier90MalformedGarbageInBlock() throws {
        // A garbage line (wrong token count) inside the block is silently skipped;
        // valid lines before and after it still parse.
        let content = """
        begin kpoint_path
        G 0.0 0.0 0.0 X 0.5 0.0 0.0
        this is garbage
        X 0.5 0.0 0.0 M 0.5 0.5 0.0
        end kpoint_path
        """
        let url = writeTemp(content, "win")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 3)   // G,X,M coalesced
        XCTAssertTrue(path.breaks.isEmpty)
    }

    // MARK: - KPF happy path

    func testKPFHappyPathRoundTrip() throws {
        // Export a connected route then re-parse it: coords equal within 1e-4,
        // labels preserved.
        let original = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "G"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "L"),
        ], pointsPerSegment: 20)
        let text = try KPathExport.export(original, as: .kpf)
        let url = writeTemp(text, "route.kpf")
        let parsed = try KPathImport.parse(text: text, url: url)
        XCTAssertEqual(parsed.points.count, original.points.count)
        for (a, b) in zip(parsed.points, original.points) {
            XCTAssertTrue(allComponentsEqual(a.frac, b.frac, 1e-4), "\(a.frac) vs \(b.frac)")
            XCTAssertEqual(a.label, b.label)
        }
        XCTAssertTrue(parsed.breaks.isEmpty)
        XCTAssertEqual(parsed.pointsPerSegment, 20)
    }

    func testKPFNegativeIntegerCoordinates() throws {
        let content = """
        2
        -1 0 0  X-
        1 0 0  X
        """
        let url = writeTemp(content, "route.kpf")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertTrue(allComponentsEqual(path.points[0].frac, SIMD3(-0.5, 0, 0)))
        XCTAssertTrue(allComponentsEqual(path.points[1].frac, SIMD3(0.5, 0, 0)))
    }

    func testKPFSinglePointValid() throws {
        let content = """
        10
        5 5 5  M
        """
        let url = writeTemp(content, "route.kpf")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 1)
        XCTAssertTrue(allComponentsEqual(path.points[0].frac, SIMD3(0.5, 0.5, 0.5)))
        XCTAssertEqual(path.points[0].label, "M")
    }

    func testKPFBOMHandled() throws {
        // A UTF-8 BOM must not poison the ISS multiplier line or format detection.
        let content = "\u{FEFF}2\n0 0 0  G\n1 1 1  X\n"
        let url = writeTemp(content, "route.kpf")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertTrue(allComponentsEqual(path.points[0].frac, SIMD3(0, 0, 0)))
        XCTAssertEqual(path.points[0].label, "G")
    }

    // MARK: - KPF errors

    func testKPFZeroMultiplierMalformed() {
        let content = "0\n0 0 0  G\n"
        let url = writeTemp(content, "route.kpf")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testKPFNegativeMultiplierMalformed() {
        let content = "-3\n0 0 0  G\n"
        let url = writeTemp(content, "route.kpf")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testKPFNonIntegerMultiplierMalformed() {
        let content = "2.5\n0 0 0  G\n"
        let url = writeTemp(content, "route.kpf")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testKPFNonIntegerCoordinateMalformed() {
        let content = "2\n0.5 0 0  G\n"
        let url = writeTemp(content, "route.kpf")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    func testKPFZeroPointsMalformed() {
        let content = "2\n"
        let url = writeTemp(content, "route.kpf")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    // MARK: - Limits

    func testVASPTooManyPointsAtLimit() {
        // 513 pairs = 1026 k-points → exceeds 1024.
        var lines = ["title", "10", "Line-mode", "Reciprocal"]
        for i in 0..<513 {
            let x = Float(i % 10) * 0.1
            lines.append("\(x) 0.0 0.0 ! A")
            lines.append("\(x + 0.05) 0.0 0.0 ! B")
        }
        let content = lines.joined(separator: "\n") + "\n"
        let url = writeTemp(content, "KPOINTS")
        XCTAssertThrowsError(try KPathImport.parse(text: content, url: url)) { err in
            guard case KPathImportError.tooManyPoints = err else {
                return XCTFail("expected tooManyPoints, got \(err)")
            }
        }
    }

    func testQECrystalCRLF() throws {
        // \r\n line endings must parse once trims use whitespacesAndNewlines.
        let content = "K_POINTS crystal\r\n2\r\n0.0 0.0 0.0 1.0\r\n0.5 0.0 0.0 1.0\r\n"
        let url = writeTemp(content, "scf.in")
        let path = try KPathImport.parse(text: content, url: url)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertTrue(allComponentsEqual(path.points[0].frac, SIMD3(0, 0, 0)))
        XCTAssertTrue(allComponentsEqual(path.points[1].frac, SIMD3(0.5, 0, 0)))
    }

    func testImportFileTooLargeMalformed() throws {
        let url = tempURL("huge.kpf")
        let data = Data(count: Int(KPathImport.maxFileBytes) + 1)
        try! data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try KPathImport.importKPath(from: url)) { err in
            guard case KPathImportError.malformed(let path, let reason) = err else {
                return XCTFail("expected malformed, got \(err)")
            }
            XCTAssertTrue(reason.contains("too large"), "reason should mention size, got \(reason)")
            XCTAssertTrue(path.contains("huge.kpf"))
        }
    }

    // MARK: - Round-trip property

    func testRoundTripExportThenImport() throws {
        // A multi-segment connected route survives KPF export → parse intact.
        let original = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "G"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
            KPoint(SIMD3(0.5, 0.25, 0.75), "W"),
            KPoint(SIMD3(0, 0, 0), "G"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "L"),
        ], pointsPerSegment: 20)
        let text = try KPathExport.export(original, as: .kpf)
        let url = writeTemp(text, "route.kpf")
        let parsed = try KPathImport.parse(text: text, url: url)
        XCTAssertEqual(parsed.points.count, original.points.count)
        for (a, b) in zip(parsed.points, original.points) {
            XCTAssertTrue(allComponentsEqual(a.frac, b.frac, 1e-4), "\(a.frac) vs \(b.frac)")
            XCTAssertEqual(a.label, b.label)
        }
        XCTAssertEqual(parsed.breaks, original.breaks)
    }
}
