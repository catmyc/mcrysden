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

    /// Consolidated: CRYSTAL DOS gate (accept/reject headers + integrated column),
    /// CRYSTAL BAND minimal-file positive path, and GZMatrix malformed-row loud failure.
    func testParserAuxiliaryFormatsAndGates() throws {
        // --- CRYSTAL DOS gate ---
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

        // --- CRYSTAL BAND minimal-file positive path ---
        let bandText = """
        BAND STRUCTURE - CRYSTAL PROPERTIES
        N. OF BANDS = 2
        N. OF K POINTS = 1
          0.000000  0.000000  0.000000
         -5.000000  3.000000

        """
        guard let bands = CrystalBandParser.parse(bandText) else {
            return XCTFail("a minimal CRYSTAL BAND file must parse")
        }
        XCTAssertEqual(bands.kPoints.count, 1)
        XCTAssertEqual(bands.nSpin, 1)
        XCTAssertEqual(bands.kPointsPerSpin, 1)
        XCTAssertTrue(bands.kPointsAreCrystal)
        XCTAssertEqual(bands.kPoints[0].k, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(bands.kPoints[0].energies, [-5.0, 3.0])

        // --- GZMatrix malformed-row loud failure ---
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

    /// Consolidated: XcrysdenScript non-finite rejection and heavy-element symbol resolution.
    func testXcrysdenScriptAndElementResolution() {
        // --- XcrysdenScript non-finite rejection ---
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

        // --- Heavy-element symbol resolution ---
        // Forward: Z -> symbol
        XCTAssertEqual(Table.id(79), "Au")
        XCTAssertEqual(Table.id(92), "U")
        XCTAssertEqual(Table.id(118), "Og")
        XCTAssertEqual(Table.id(1), "H")
        XCTAssertEqual(Table.id(36), "Kr")
        // Fallback: out-of-range Z -> "\(z)"
        XCTAssertEqual(Table.id(0), "0")
        XCTAssertEqual(Table.id(-1), "-1")
        XCTAssertEqual(Table.id(119), "119")
        // Reverse: symbol -> Z (case-insensitive via .capitalized)
        XCTAssertEqual(Table.z("Au"), 79)
        XCTAssertEqual(Table.z("U"), 92)
        XCTAssertEqual(Table.z("au"), 79)
        XCTAssertEqual(Table.z("AU"), 79)
        XCTAssertEqual(Table.z("og"), 118)
        // Unknown symbol -> 0
        XCTAssertEqual(Table.z("Xx"), 0)
    }

    /// Finding 1: NaN/Inf coordinates must be rejected at parse time — not
    /// silently accepted (Float("nan") parses as non-nil but isNaN, poisoning
    /// framingSphere/defaultCamera downstream). Covers Orca, FHI-aims
    /// geometry.in, FHI-aims coord.out, and WIEN2k .struct.
    func testNonFiniteCoordinatesRejected() throws {
        // --- Orca: a NaN x-coordinate must abort the block (no atoms produced) ---
        let orcaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: orcaURL) }
        try """
            some header
            CARTESIAN COORDINATES (ANGSTROEM)
            -------------------------------------------
            C   nan  0.0  0.0
            H   1.0  0.0  0.0
            """.write(to: orcaURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(orcaURL, as: .orca),
                            "NaN coord must abort the block")

        // --- FHI-aims geometry.in: NaN in lattice_vector must throw ---
        let geomURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: geomURL) }
        try """
            lattice_vector  nan  0.0  0.0
            lattice_vector  0.0  5.431  0.0
            lattice_vector  0.0  0.0  5.431
            atom_frac  0.0  0.0  0.0  Si
            """.write(to: geomURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(geomURL, as: .fhi),
                            "NaN lattice_vector must be rejected")

        // --- FHI-aims coord.out: NaN in a lattice column must throw ---
        let coordURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: coordURL) }
        try """
            nan  0.0  0.0
            0.0  5.431  0.0
            0.0  0.0  5.431
            1
            1
            Si
            0.0  0.0  0.0 T
            """.write(to: coordURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(coordURL, as: .fhi),
                            "NaN lattice column must be rejected")

        // --- WIEN2k .struct: non-finite in the lattice params must throw.
        // Use "1e39" (not "nan") — the scanFloats regex only matches numeric
        // forms, and 1e39 overflows Float to inf, which the isFinite guard
        // catches. A bare "nan" would be silently skipped by the regex.
        let wienURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).struct")
        defer { try? FileManager.default.removeItem(at: wienURL) }
        try """
            Si
            F   LATTICE,NONEQUIV. ATOMS  1
            MODE OF CALC=RELA
            1e39  5.431  5.431  90.0  90.0  90.0
            ATOM= 1: X=0.0 Y=0.0 Z=0.0
            MULT= 1  ISPLIT= 0
            Si   NPT= 79  R0= 0.0005  RMT= 2.0  Z: 28
            """.write(to: wienURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(wienURL, as: .struct_),
                            "non-finite lattice params must be rejected")
    }

    /// Finding 2/4: atom-count sanity caps must reject absurd values before
    /// they drive unbounded allocation. Covers WIEN2k natoms and FHI-aims
    /// coord.out nSpecies.
    func testAtomCountSanityCaps() throws {
        // --- WIEN2k: absurd natoms must throw ---
        let wienURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).struct")
        defer { try? FileManager.default.removeItem(at: wienURL) }
        try """
            Si
            F   LATTICE,NONEQUIV. ATOMS  99999999
            MODE OF CALC=RELA
            5.431  5.431  5.431  90.0  90.0  90.0
            """.write(to: wienURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(wienURL, as: .struct_),
                            "absurd WIEN2k natoms must be rejected")

        // --- FHI-aims coord.out: absurd nSpecies must throw ---
        let fhiURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: fhiURL) }
        try """
            5.431  0.0  0.0
            0.0  5.431  0.0
            0.0  0.0  5.431
            99999999
            """.write(to: fhiURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(fhiURL, as: .fhi),
                            "absurd FHI-aims nSpecies must be rejected")
    }
}
