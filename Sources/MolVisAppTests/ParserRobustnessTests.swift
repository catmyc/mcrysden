import Foundation
import XCTest
@testable import MolVisApp

/// Parser-robustness regression coverage from the adversarial review: duplicate
/// DOS energy rows are dropped instead of rejecting the file, unrecognized
/// CRYSCAL space groups fail loudly instead of silently misparsing as cubic,
/// and FHI-aims COORD.OUT species names resolve through the full element table.
final class ParserRobustnessTests: XCTestCase {

    func testParserRobustnessRejectionAndResolution() throws {
        let text = """
         # Fermi energy: -5.0000 eV
           -10.000  1.0  0.5
            -9.000  1.1  0.6
            -8.000  1.2  0.7
            -8.000  1.3  0.8
            -7.000  1.4  0.9
        """
        guard let dos = DOSParser.parse(text) else {
            return XCTFail("a DOS file with a duplicated energy row must parse")
        }
        XCTAssertEqual(dos.energies, [-10, -9, -8, -7])
        XCTAssertEqual(dos.series.count, 2)
        XCTAssertEqual(dos.series[0].values, [1.0, 1.1, 1.2, 1.4])
        XCTAssertEqual(dos.series[1].values, [0.5, 0.6, 0.7, 0.9])
        // Genuinely decreasing energies are still rejected.
        let decreasing = "1.0 2.0\n0.5 2.1\n"
        XCTAssertNil(DOSParser.parse(decreasing))

        // --- CRYSTAL space-group rejection ---
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).r1")
        defer { try? FileManager.default.removeItem(at: url1) }
        try """
        test
        CRYSTAL
        0 0 0
        NOT A GROUP
        5.0 4.0 3.0 90 90 90
        2
        6 0.0 0.0 0.0
        8 0.5 0.5 0.5
        """.write(to: url1, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(url1)) { error in
            guard case ParseError.parse(_, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertTrue(reason.contains("space group"),
                          "reason should mention the space group, got: \(reason)")
        }

        // --- FHI-aims COORD.OUT species resolution: "Silver" -> Ag (47) ---
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: url2) }
        // XCrySDen-style coord.out: 3 lattice rows (Bohr), species count, then
        // per-species count/name and Cartesian rows (Bohr). "Silver" must
        // resolve to Ag (47), not the 2-letter prefix "SI" (Silicon, 14).
        try """
        5.431  0.0    0.0
        0.0    5.431  0.0
        0.0    0.0    5.431
        1
        1
        Silver
        0.0 0.0 0.0 T
        """.write(to: url2, atomically: true, encoding: .utf8)
        let scene = try Parser.load(url2, as: .fhi)
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 47)
        XCTAssertEqual(scene.atoms[0].label, "Ag")
    }

    /// Adversarial review: the CRYSTAL DOS gate must accept the canonical
    /// "DENSITY OF STATES" / "... PER ATOM" / "... PERCELL" headers, accept a
    /// DOSS(INTEGRATED) table with its integrated column dropped, and must NOT
    /// accept a band file ("BAND STRUCTURE") as DOS.
    func testCrystalDosGateAndIntegratedColumn() throws {
        let dossTable = """
            -20.0  0.0  0.1
            -19.0  0.0  0.3
            -18.0  0.1  0.6
        """
        func dos(_ header: String) -> DensityOfStates? {
            CrystalDOSParser.parse(header + "\n" + dossTable)
        }
        XCTAssertNotNil(dos("DENSITY OF STATES"))
        XCTAssertNotNil(dos("DENSITY OF STATES PER ATOM"))
        XCTAssertNotNil(dos("DENSITY OF STATES PERCELL"))
        XCTAssertNil(dos("BAND STRUCTURE"))

        let integrated = """
            ENERGY  DOSS  DOSS(INTEGRATED)
            -20.0   0.0   0.0
            -19.0   0.1   0.1
            -18.0   0.3   0.4
        """
        guard let parsed = CrystalDOSParser.parse(integrated) else {
            return XCTFail("DOSS(INTEGRATED) table must parse")
        }
        XCTAssertEqual(parsed.series.count, 1, "integrated column must be dropped")
        XCTAssertEqual(parsed.series[0].values, [0.0, 0.1, 0.3])
    }

    /// Adversarial review: the CRYSTAL band gate has negative coverage only, so
    /// pin the positive path — a labelled BAND STRUCTURE header with explicit
    /// band/k-point counts, one k row and its wrapped energy row must yield a
    /// `BandStructure` with those counts and energies (eV, single spin).
    func testCrystalBandParsesMinimalFile() throws {
        let text = """
        BAND STRUCTURE - CRYSTAL PROPERTIES
        N. OF BANDS = 2
        N. OF K POINTS = 1
          0.000000  0.000000  0.000000
         -5.000000  3.000000

        """
        guard let bands = CrystalBandParser.parse(text) else {
            return XCTFail("a minimal CRYSTAL BAND file must parse")
        }
        XCTAssertEqual(bands.kPoints.count, 1)
        XCTAssertEqual(bands.nSpin, 1)
        XCTAssertEqual(bands.kPointsPerSpin, 1)
        XCTAssertTrue(bands.kPointsAreCrystal)
        XCTAssertEqual(bands.kPoints[0].k, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(bands.kPoints[0].energies, [-5.0, 3.0])
    }

    /// Finding 5: a malformed coordinate row must fail the whole file loudly
    /// (nil) rather than silently truncating later rows; the diagnostic must be
    /// surfaced through `GZMatrixError` / `ParseError`.
    func testGzmatrixMalformedRowFailsLoudly() throws {
        // Good O/H/H then a row with a non-numeric value.
        let broken = """
            O
            H  1  r2
            H  1  r3  2  badvalue

            r2= 0.96
            r3= 0.96
        """
        XCTAssertNil(GZMatrixParser.parse(broken))
        XCTAssertNotNil(GZMatrixError.get())

        // NaN/Inf in a numeric field must also fail (not silently truncate).
        let nanRow = """
            O
            H  1  NaN
            H  1  0.96  2  104.5
        """
        XCTAssertNil(GZMatrixParser.parse(nanRow))
    }

    /// Finding 6: XcrysdenScript.load must reject non-finite numeric fields
    /// (NaN, Inf) — they get skipped and reported, not applied.
    func testXcrysdenScriptRejectsNonFinite() {
        let base = XcrysdenViewState()
        let script = """
            set azimuth NaN
            set elevation Inf
            set zoom 2.0
        """
        guard let result = XcrysdenScript.load(script, base: base) else {
            return XCTFail("script with one valid field must map")
        }
        XCTAssertEqual(result.state.zoom, 2.0)
        XCTAssertEqual(result.state.azimuth, base.azimuth, "NaN must be skipped")
        XCTAssertEqual(result.state.elevation, base.elevation, "Inf must be skipped")
        XCTAssertEqual(result.skipped.count, 2)
    }
}
