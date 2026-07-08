import XCTest
@testable import MolVisApp
import MolEnvParse

final class ParserTests: XCTestCase {
    // After a successful parse the thread-local error buffer must be empty: a
    // leftover error from a prior (possibly failing) call must never leak into
    // the next parse's result (this is order-independent across tests).
    func testLastErrorEmptyByDefault() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        _ = try Parser.load(dir.appendingPathComponent("Fixtures/si110.xsf"))
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
    // Real-world QE input: lowercase &system, digit-suffixed species (Fe1/Fe2),
    // ibrav=0 with a brace-less `CELL_PARAMETERS bohr`, and fractional positions.
    func testQEBiFeO3Like() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bfo.pwi")
        try """
        &control
          calculation = 'scf'
        /
        &system
          ibrav = 0
          nat = 5
          ntyp = 3
        /
        ATOMIC_SPECIES
         Bi 208.9804  Bi.upf
         Fe1  55.8450  Fe.upf
         Fe2  55.8450  Fe.upf
           O  15.9990   O.upf
        ATOMIC_POSITIONS { crystal }
         Fe1 0.0 0.0 0.0
         Fe2 0.5 0.5 0.5
          Bi 0.25 0.25 0.25
           O 0.1 0.2 0.3
           O 0.9 0.8 0.7
        CELL_PARAMETERS bohr
         10.0 0.0 0.0
         0.0 10.0 0.0
         0.0 0.0 10.0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.atoms.count, 5)
        XCTAssertTrue(s.isCrystal)
        // Fe1 and Fe2 must both resolve to iron (Z==26)
        XCTAssertEqual(s.atoms[0].atomicNumber, 26)
        XCTAssertEqual(s.atoms[1].atomicNumber, 26)
        XCTAssertEqual(s.atoms[2].atomicNumber, 83) // Bi
        XCTAssertEqual(s.atoms[3].atomicNumber, 8)  // O
        // CELL_PARAMETERS bohr -> 10 Bohr == 5.29177 Ang along each axis
        XCTAssertEqual(s.cell!.a.x, 10.0 * 0.529177210903, accuracy: 0.01)
        XCTAssertEqual(s.cell!.b.y, 10.0 * 0.529177210903, accuracy: 0.01)
        // fractional pos Fe2 (0.5,0.5,0.5) -> half the cell diagonal
        XCTAssertEqual(s.atoms[1].coord.x, 5.0 * 0.529177210903, accuracy: 0.01)
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

    // ----- Quantum Espresso (.pwi) -----

    // Si fcc: ibrav=2, celldm(1)=10.26 Bohr. a1 = a/2(-1,0,1) in Bohr; in Ang
    // that is -5.13*BOHR_TO_ANG == -2.7147 for the x (and z) component.
    func testPWIHappyPath() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let s = try Parser.load(dir.appendingPathComponent("Fixtures/si.pwi"))
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertEqual(s.atoms[0].atomicNumber, 14)
        XCTAssertTrue(s.isCrystal)
        XCTAssertNotNil(s.cell)
        let expected = -5.13 * Float(0.529177210903)
        XCTAssertEqual(s.cell!.a.x, expected, accuracy: 0.01)
        XCTAssertEqual(s.cell!.a.y, 0, accuracy: 0.001)
    }

    // ibrav=0 with an explicit CELL_PARAMETERS {angstrom} block must reproduce
    // the literal vectors (no latgen path).
    func testPWIIbrav0() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cell.pwi")
        try """
        &SYSTEM
          ibrav = 0
          nat = 1
          ntyp = 1
        /
        ATOMIC_SPECIES
         Si  28.0855  Si.pbe.UPF
        ATOMIC_POSITIONS {angstrom}
         Si  0 0 0
        CELL_PARAMETERS {angstrom}
         2.0 0.0 0.0
         0.0 3.0 0.0
         0.0 0.0 4.0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.cell!.a.x, 2.0, accuracy: 0.001)
        XCTAssertEqual(s.cell!.b.y, 3.0, accuracy: 0.001)
        XCTAssertEqual(s.cell!.c.z, 4.0, accuracy: 0.001)
    }

    // The `as:` flag must override extension-based dispatch: valid XSF content
    // saved under a .xyz name parses only when forced to the XSF parser.
    func testForceFlagOverridesExtension() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("renamed.xyz")
        try """
        CRYSTAL
        PRIMVEC
         1 0 0
         0 1 0
         0 0 1
        PRIMCOORD
         1 1
         6 0 0 0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        // Forced XSF parser succeeds.
        let s = try Parser.load(tmp, as: .xsf)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 6)
        // Extension-based dispatch (.xyz) must fail on XSF content.
        XCTAssertThrowsError(try Parser.load(tmp)) { err in
            guard case ParseError.parse = err else { return XCTFail("expected parse error") }
        }
    }

    // A .pwi with no ATOMIC_POSITIONS must be rejected cleanly.
    func testPWIRejectsNoAtoms() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("empty.pwi")
        try """
        &SYSTEM
          ibrav = 2
          celldm(1) = 10.26
          nat = 0
          ntyp = 0
        /
        """.write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Parser.load(tmp)) { err in
            guard case ParseError.parse = err else { return XCTFail("expected parse error") }
        }
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
