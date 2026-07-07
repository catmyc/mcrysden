import XCTest
@testable import MolVisApp
import MolEnvParse

final class ParserTests: XCTestCase {
    func testLastErrorEmptyByDefault() {
        XCTAssertEqual(String(cString: molenv_last_error()), "")
    }
    func testUnknownExtThrows() {
        let url = URL(fileURLWithPath: "/tmp/foo.weird")
        XCTAssertThrowsError(try Parser.load(url)) { err in
            guard case ParseError.io = err else { return XCTFail("wrong error") }
        }
    }
    func testBadPathThrows() {
        let url = URL(fileURLWithPath: "/no/such/file.xyz")
        XCTAssertThrowsError(try Parser.load(url)) { err in
            guard case ParseError.io = err else { return XCTFail("wrong error") }
        }
    }
    func testXYZHappyPath() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si.xyz")
        let s = try Parser.load(url)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertFalse(s.isCrystal)
        XCTAssertEqual(s.atoms[0].atomicNumber, 14)
        XCTAssertEqual(s.atoms[1].coord.x, 1.35, accuracy: 0.001)
        XCTAssertEqual(s.title.trimmingCharacters(in:.whitespacesAndNewlines), "Silicon dimer test")
    }
    func testXYZHappyPathWater() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/h2o.xyz")
        let s = try Parser.load(url)
        XCTAssertEqual(s.atoms.count, 3)
        XCTAssertEqual(s.atoms[0].atomicNumber, 8)
        XCTAssertEqual(s.atoms[1].atomicNumber, 1)
    }
    func testXYZMalformed() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/bad.xyz")
        XCTAssertThrowsError(try Parser.load(url)) { err in
            if case ParseError.parse(_, let line, _) = err {
                XCTAssertGreaterThan(line, 0, "expected a non-zero error line")
            } else {
                XCTFail("expected parse error")
            }
        }
    }

    // Locks the Critical ATOMS-block fix: an XSF file whose structure is given as
    // an ATOMS block (no PRIMCOORD) must parse — real XCrySDen files do this.
    func testXSFAtomsBlock() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atoms.xsf")
        try """
        ATOMS
         6   -2.567869    0.032045   -0.221028
         8   -1.382513   -0.640867   -0.040075
         1   -2.530354    0.718822   -1.046630
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let sc = try Parser.load(tmp)
        XCTAssertEqual(sc.atoms.count, 3)
        XCTAssertEqual(sc.atoms[0].atomicNumber, 6)
        XCTAssertFalse(sc.isCrystal)
    }

    // Bond heuristic must never crash on an out-of-range atomic number: such an
    // atom is simply skipped (no bond), per spec §9 "never crash on malformed input".
    func testBondSkipsOutOfRangeAtomicNumber() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oob.xsf")
        try """
        CRYSTAL
        PRIMVEC
         1 0 0
         0 1 0
         0 0 1
        PRIMCOORD
         2 1
         999 0 0 0
         6 0.5 0 0 0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let sc = try Parser.load(tmp)
        XCTAssertEqual(sc.atoms.count, 2)
        XCTAssertEqual(sc.bonds.count, 0)
    }

    // State store must never throw on a malformed scene payload (spec §9).
    func testStateLoadMalformedSceneFallsBack() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bad.mvis-state")
        let payload: [String: Any] = ["version": 1, "scene": "not-a-dict"]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = nil
        try StateStore.load(&s, camera: &c, from: tmp)
        XCTAssertTrue(s.atoms.isEmpty)
        XCTAssertNil(c)
    }
}
