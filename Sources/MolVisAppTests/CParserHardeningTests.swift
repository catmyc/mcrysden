import Foundation
import XCTest
@testable import MolVisApp

/// Adversarial-review hardening coverage for the C parser (molenv_parse.c):
/// unbounded atom counts fail loudly, QE unit tokens are case-insensitive and
/// unknown units are hard errors, and non-finite numeric values are rejected.
final class CParserHardeningTests: XCTestCase {

    // Finding 1: an XYZ file with an overflowed atom-count header must fail with
    // a clear ParseError instead of loading a wrong (wrapped) atom count.
    func testXyzOverflowAtomCountRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).xyz")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        9999999999999999999
        overflow test
        Si 0.0 0.0 0.0
        """.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(url)) { error in
            guard case ParseError.parse(_, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertTrue(reason.contains("atom count") || reason.contains("XYZ"),
                          "reason should mention the atom count, got: \(reason)")
        }
    }

    // Finding 4: valid uppercase QE unit tokens (BOHR), (CRYSTAL), {Alat} must
    // resolve correctly instead of silently falling through to angstrom.
    func testPwiUppercaseUnitTokens() throws {
        // A minimal QE input with uppercase (BOHR) for CELL_PARAMETERS and
        // {Alat} for ATOMIC_POSITIONS. With the old strcmp-based dispatch these
        // would silently default to angstrom and mis-scale the structure.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).pwi")
        defer { try? FileManager.default.removeItem(at: url) }
        // bohr=0.529177 A. A 5.431 bohr cell edge = 2.874 A (Si). If the unit
        // were ignored and treated as angstrom, the cell would be 5.431 A.
        try """
        &SYSTEM
         ibrav=0
         nat=1
         ntyp=1
        /
        ATOMIC_SPECIES
         Si 28.085 Si.pbe-n-kjpaw_psl.1.0.0.UPF
        CELL_PARAMETERS {BOHR}
         5.431 0.0   0.0
         0.0   5.431 0.0
         0.0   0.0   5.431
        ATOMIC_POSITIONS angstrom
         Si 0.0 0.0 0.0
        K_POINTS gamma
        """.write(to: url, atomically: true, encoding: .utf8)
        let scene = try Parser.load(url)
        // With correct unit handling: cell = 5.431 bohr * 0.529177 = 2.874 A.
        // With the bug (treated as angstrom): cell = 5.431 A.
        guard let cell = scene.cell else {
            return XCTFail("scene must have a cell")
        }
        let cellA = cell.a.x
        XCTAssertEqual(cellA, 5.431 * 0.529177, accuracy: 0.01,
                       "CELL_PARAMETERS {BOHR} must scale by bohr->angstrom, got \(cellA)")
    }

    // Finding 4: an unknown QE unit token must be a hard parse error, not a
    // silent default to angstrom. Also covers Finding 5: a non-finite celldm
    // value must be rejected.
    func testPwiUnknownUnitAndNonFiniteCelldmRejected() throws {
        // --- Unknown unit token ---
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).pwi")
        defer { try? FileManager.default.removeItem(at: url1) }
        try """
        &SYSTEM
         ibrav=0
         nat=1
         ntyp=1
        /
        ATOMIC_SPECIES
         Si 28.085 Si.pbe-n-kjpaw_psl.1.0.0.UPF
        CELL_PARAMETERS fathoms
         5.431 0.0   0.0
         0.0   5.431 0.0
         0.0   0.0   5.431
        ATOMIC_POSITIONS angstrom
         Si 0.0 0.0 0.0
        K_POINTS gamma
        """.write(to: url1, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(url1)) { error in
            guard case ParseError.parse(_, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertTrue(reason.contains("unit") || reason.contains("CELL_PARAMETERS"),
                          "reason should mention the unknown unit, got: \(reason)")
        }

        // --- Non-finite celldm ---
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-test-\(UUID().uuidString).pwi")
        defer { try? FileManager.default.removeItem(at: url2) }
        try """
        &SYSTEM
         ibrav=1
         celldm(1)=1e999
         nat=1
         ntyp=1
        /
        ATOMIC_SPECIES
         Si 28.085 Si.pbe-n-kjpaw_psl.1.0.0.UPF
        ATOMIC_POSITIONS angstrom
         Si 0.0 0.0 0.0
        K_POINTS gamma
        """.write(to: url2, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(url2)) { error in
            guard case ParseError.parse(_, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertTrue(reason.contains("celldm") || reason.contains("non-finite"),
                          "reason should mention the non-finite celldm, got: \(reason)")
        }
    }

    /// Periodic bonding must honor the active dimensionality. Slab and polymer
    /// cells intentionally have rank-two/rank-one embeddings, so requiring a
    /// full 3D determinant would silently drop boundary-crossing bonds.
    func testPeriodicBondingForSlabAndPolymerCells() throws {
        func parse(_ contents: String, suffix: String) throws -> LoadedScene {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcrysden-test-\(UUID().uuidString).\(suffix)")
            defer { try? FileManager.default.removeItem(at: url) }
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return try Parser.load(url, as: .xsf)
        }

        let slab = try parse("""
        SLAB
        PRIMVEC
        10 0 0
        0 10 0
        0 0 0
        PRIMCOORD
        2 1
        C 0 0 0
        C 9 0 0
        """, suffix: "xsf")
        XCTAssertEqual(slab.periodicDim, 2)
        XCTAssertTrue(slab.bonds.contains { Set([$0.i, $0.j]) == Set([0, 1]) })

        let polymer = try parse("""
        POLYMER
        PRIMVEC
        10 0 0
        0 0 0
        0 0 0
        PRIMCOORD
        2 1
        C 0 0 0
        C 9 0 0
        """, suffix: "xsf")
        XCTAssertEqual(polymer.periodicDim, 1)
        XCTAssertTrue(polymer.bonds.contains { Set([$0.i, $0.j]) == Set([0, 1]) })
    }
}
