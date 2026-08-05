import Foundation
import XCTest
@testable import MolVisApp

/// Parser-robustness regression coverage from the adversarial review: duplicate
/// DOS energy rows are dropped instead of rejecting the file, unrecognized
/// CRYSCAL space groups fail loudly instead of silently misparsing as cubic,
/// and FHI-aims COORD.OUT species names resolve through the full element table.
final class ParserRobustnessTests: XCTestCase {

    func testDOSParserDuplicateEnergyDropped() {
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
    }

    func testUnrecognizedCrystalSpaceGroupRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).r1")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        test
        CRYSTAL
        0 0 0
        NOT A GROUP
        5.0 4.0 3.0 90 90 90
        2
        6 0.0 0.0 0.0
        8 0.5 0.5 0.5
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(url)) { error in
            guard case ParseError.parse(_, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertTrue(reason.contains("space group"),
                          "reason should mention the space group, got: \(reason)")
        }
    }

    func testFHIaimsCoordOutSilverResolvesTo47() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: url) }
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
        """.write(to: url, atomically: true, encoding: .utf8)
        let scene = try Parser.load(url, as: .fhi)
        XCTAssertEqual(scene.atoms.count, 1)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 47)
        XCTAssertEqual(scene.atoms[0].label, "Ag")
    }
}
