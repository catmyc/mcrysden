import XCTest
import simd
@testable import MolVisApp

/// CIF parsing coverage. The CIF parser lives in the C target
/// `Sources/MolEnvParse/molenv_parse.c` and is dispatched from
/// `Parser.load(_:as:)` for `ParseFormat.cif`. This test loads a minimal
/// NaCl fixture (P 1, 2 fractional atoms) and asserts the loaded scene
/// carries the expected cell, atom count, atomic numbers, and crystal flag.
final class CIFParserTests: XCTestCase {

    /// Resolve the `nacl.cif` fixture. Prefer the SPM resource bundle
    /// (`resources: [.process("Fixtures")]` in Package.swift), then fall
    /// back to the source-tree path used by the other test files.
    private func naclFixtureURL() throws -> URL {
        if let bundled = Bundle.module.url(forResource: "nacl", withExtension: "cif") {
            return bundled
        }
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/nacl.cif")
    }

    func testCIFParsesNaCl() throws {
        let url = try naclFixtureURL()
        let loaded = try Parser.load(url, as: .cif)

        XCTAssertEqual(loaded.atoms.count, 2, "NaCl fixture defines 2 atoms (Na, Cl)")
        XCTAssertEqual(loaded.isCrystal, true, "CIF with cell parameters must be a crystal")
        XCTAssertNotNil(loaded.cell, "crystal CIF must carry a cell")

        // P 1 with alpha=beta=gamma=90 → axis-aligned cell vectors.
        let cell = try XCTUnwrap(loaded.cell)
        XCTAssertEqual(cell.a.x, 5.64, accuracy: 1e-4)
        XCTAssertEqual(cell.a.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(cell.a.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(cell.b.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(cell.b.y, 5.64, accuracy: 1e-4)
        XCTAssertEqual(cell.b.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(cell.c.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(cell.c.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(cell.c.z, 5.64, accuracy: 1e-4)

        // Na (Z=11) at origin; Cl (Z=17) at (1/2, 1/2, 1/2) → (2.82, 2.82, 2.82).
        let na = loaded.atoms[0]
        let cl = loaded.atoms[1]
        XCTAssertEqual(na.atomicNumber, 11)
        XCTAssertEqual(cl.atomicNumber, 17)
        XCTAssertEqual(na.coord.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(na.coord.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(na.coord.z, 0.0, accuracy: 1e-6)
        XCTAssertEqual(cl.coord.x, 2.82, accuracy: 1e-4)
        XCTAssertEqual(cl.coord.y, 2.82, accuracy: 1e-4)
        XCTAssertEqual(cl.coord.z, 2.82, accuracy: 1e-4)

        // Format auto-detection from the `.cif` extension must agree with the
        // explicit `.cif` request.
        let auto = try Parser.load(url)
        XCTAssertEqual(auto.atoms.count, 2)
        XCTAssertEqual(auto.isCrystal, true)
    }
}
