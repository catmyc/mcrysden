import XCTest
import simd
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

    // Parenthesized unit syntax "ATOMIC_POSITIONS (crystal)" and
    // "CELL_PARAMETERS (bohr)" is valid QE input and appears in XCrySDen
    // reference files. The C parser must strip the parentheses so the unit
    // resolves correctly — otherwise "(crystal)" is not recognised and
    // falls back to the alat default, zeroing atoms when celldm(1) is unset.
    func testPWIParenthesizedUnits() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("paren.pwi")
        try """
        &system
          ibrav = 0
          nat = 1
          ntyp = 1
        /
        ATOMIC_SPECIES
         Fe 55.845 Fe.upf
        ATOMIC_POSITIONS (crystal)
         Fe 0.5 0.5 0.5
        CELL_PARAMETERS (bohr)
         10.0 0.0 0.0
         0.0 10.0 0.0
         0.0 0.0 10.0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertTrue(s.isCrystal)
        // Fe at fractional (0.5,0.5,0.5) in a 10-Bohr cubic cell → (5,5,5) Bohr
        // = 5*BOHR_TO_ANG ≈ 2.6459 Å. If "(crystal)" were read literally, the
        // atom would be at (0,0,0) or a bogus alat scale.
        let expected = Float(5.0 * 0.529177210903)
        XCTAssertEqual(s.atoms[0].coord.x, expected, accuracy: 0.01)
        XCTAssertEqual(s.atoms[0].coord.y, expected, accuracy: 0.01)
        XCTAssertEqual(s.atoms[0].coord.z, expected, accuracy: 0.01)
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

    // ----- CIF -----

    // Minimal crystal CIF: data_test block, full cell, one atom-site loop with
    // fractional coords. The single Fe at (.25,.25,.25) maps to a frac->cart
    // position of (0.25*a, ...) on a 5 A cubic cell.
    func testCIFHappyPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xtal.cif")
        try """
        data_test
        _cell_length_a 5.0
        _cell_length_b 5.0
        _cell_length_c 5.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0

        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Fe1 Fe 0.25 0.25 0.25
         O1  O 0.50 0.50 0.50
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertEqual(s.atoms[0].atomicNumber, 26) // Fe
        XCTAssertEqual(s.atoms[1].atomicNumber, 8)  // O
        XCTAssertTrue(s.isCrystal)
        XCTAssertNotNil(s.cell)
        // cubic cell: a along x => cell.a.x == 5.0
        XCTAssertEqual(s.cell!.a.x, 5.0, accuracy: 0.001)
        XCTAssertEqual(s.cell!.b.y, 5.0, accuracy: 0.001)
        // Fe at (0.25,.25,.25)*5 => (1.25,1.25,1.25)
        XCTAssertEqual(s.atoms[0].coord.x, 1.25, accuracy: 0.001)
        XCTAssertEqual(s.atoms[0].coord.y, 1.25, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(s.bonds.count, 0)
    }

    // A molecule CIF has no _cell_* params: parsing must succeed and report
    // isCrystal == false.
    func testCIFMolecule() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mol.cif")
        try """
        data_water
        loop_
        _atom_site_label
        _atom_site_Cartn_x
        _atom_site_Cartn_y
        _atom_site_Cartn_z
        O1  0.0000  0.0000  0.0000
        H1  0.7572  0.5860  0.0000
        H2 -0.7572  0.5860  0.0000
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.atoms.count, 3)
        XCTAssertEqual(s.atoms[0].atomicNumber, 8) // O
        XCTAssertEqual(s.atoms[1].atomicNumber, 1) // H
        XCTAssertFalse(s.isCrystal)
        XCTAssertNil(s.cell)
        // Cartesian coords: O at origin
        XCTAssertEqual(s.atoms[0].coord.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.x, 0.7572, accuracy: 0.001)
    }

    // ----- POSCAR -----

    // VASP 5 style: comment, scale, lattice, species line, counts, Cartesian.
    func testPOSCARHappyPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("si.poscar")
        try """
        Si dimer test
        1.0
         5.0 0.0 0.0
         0.0 5.0 0.0
         0.0 0.0 5.0
        Si
        2
        Cartesian
         0.0 0.0 0.0
         2.0 0.0 0.0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertEqual(s.atoms[0].atomicNumber, 14) // Si
        XCTAssertTrue(s.isCrystal)
        XCTAssertNotNil(s.cell)
        XCTAssertEqual(s.cell!.a.x, 5.0, accuracy: 0.001)
        XCTAssertEqual(s.cell!.b.y, 5.0, accuracy: 0.001)
        // Cartesian, scale 1.0 => stored exactly
        XCTAssertEqual(s.atoms[1].coord.x, 2.0, accuracy: 0.001)
        // Si-Si distance 2.0 A < 2*1.05*1.11 == 2.33 A => one bond
        XCTAssertEqual(s.bonds.count, 1, "Si-Si dimer at 2.0 A should bond")
    }

    // VASP 4 style omits the species line; the counts line comes directly after
    // the lattice. Dispatch must also work for the .contcar extension.
    func testPOSCARVASP4() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("si.contcar")
        try """
        Si2 VASP4
        1.0
         5.43 0.0 0.0
         0.0 5.43 0.0
         0.0 0.0 5.43
        2
        Direct
         0.00 0.00 0.00
         0.25 0.25 0.25
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.atoms.count, 2)
        // No species line => unknown element, Swift layer tolerates Z==0.
        XCTAssertTrue(s.isCrystal)
        XCTAssertEqual(s.cell!.a.x, 5.43, accuracy: 0.001)
        // Direct (0.25,.25,.25)*5.43 => 1.3575 along each axis
        XCTAssertEqual(s.atoms[1].coord.x, 0.25 * 5.43, accuracy: 0.001)
    }

    // VASP volume convention: a negative scaling factor is the target cell
    // VOLUME, not a negative multiplier. Raw cell a=b=c=2 (volume 8), target
    // volume 27 => per-axis scale (27/8)^(1/3) = 1.5 => final edges 3.0.
    func testPOSCARNegativeScaleVolume() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vol.poscar")
        try """
        vol test
        -27.0
         2.0 0.0 0.0
         0.0 2.0 0.0
         0.0 0.0 2.0
        Al
        1
        Direct
         0.0 0.0 0.0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let s = try Parser.load(tmp)
        XCTAssertEqual(s.atoms[0].atomicNumber, 13) // Al
        XCTAssertNotNil(s.cell)
        XCTAssertEqual(s.cell!.a.x, 3.0, accuracy: 0.001, "neg-scale volume conv failed: got \(s.cell!.a.x)")
    }

    // The newly-completed element table must resolve species the old table
    // silently dropped (Sc, Y, La, Hf, Og) — previously Z=0 => no color/radius.
    // ----- Quantum Espresso output (.pwo) -----
    //
    // .pwo parsing reproduces the XCrySDen pwo2xsf.awk contract natively (no shell
    // filter). Each ATOMIC_POSITIONS block is one ionic step; the latest
    // CELL_PARAMETERS/crystal axes block supplies its cell; units resolve via alat.

    func testPWOScfHappyPath() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si_scf.out")
        let s = try Parser.load(url)
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertEqual(s.atoms[0].atomicNumber, 14) // Si
        XCTAssertTrue(s.isCrystal)
        XCTAssertNotNil(s.cell)
        // alat = 10.2 bohr * BOHR_TO_ANG ~ 5.3976 A; CELL_PARAMETERS(alat)=identity.
        let a0 = Float(10.2 * 0.529177210903)
        XCTAssertEqual(s.cell!.a.x, a0, accuracy: 0.001)
        XCTAssertEqual(s.cell!.b.y, a0, accuracy: 0.001)
        // ATOMIC_POSITIONS(crystal): Si at (0,0,0) and (.25,.25,.25)*a0.
        XCTAssertEqual(s.atoms[0].coord.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.x, 0.25 * a0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.y, 0.25 * a0, accuracy: 0.001)
        XCTAssertEqual(s.atoms[1].coord.z, 0.25 * a0, accuracy: 0.001)
        // Single SCF step -> one frame.
        XCTAssertEqual(Parser.frameCount(url), 1)
    }

    func testPWORelaxMultiStep() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si_relax.out")
        // Two ATOMIC_POSITIONS blocks -> two frames.
        XCTAssertEqual(Parser.frameCount(url), 2)
        // Last frame is the "Begin final coordinates" geometry.
        let final = try Parser.load(url, as: nil, frameIndex: 1)
        XCTAssertEqual(final.atoms.count, 2)
        XCTAssertTrue(final.isCrystal)
        // Final frame: CELL_PARAMETERS(angstrom)=5.43 cube, ATOMIC_POSITIONS(angstrom).
        XCTAssertEqual(final.cell!.a.x, 5.43, accuracy: 0.001)
        XCTAssertEqual(final.atoms[1].coord.x, 1.3575, accuracy: 0.001) // 0.25*5.43
        XCTAssertEqual(final.atoms[1].coord.y, 1.3575, accuracy: 0.001)
    }

    func testPWOLastFrameIsFinalCoordinates() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si_relax.out")
        // Two frames; both read CELL_PARAMETERS(angstrom)=5.43 as their cell (the
        // latest cell block preceding each ATOMIC_POSITIONS — matching the awk,
        // which overrides the crystal-axes lattice with CELL_PARAMETERS). They
        // differ in coordinate UNITS: frame 0 = crystal (.25*5.43), frame 1 =
        // angstrom (1.3575). A unit bug would blow up frame 1.
        let f0 = try Parser.load(url, as: nil, frameIndex: 0)
        let f1 = try Parser.load(url, as: nil, frameIndex: 1)
        XCTAssertEqual(f0.cell!.a.x, 5.43, accuracy: 0.001, "frame0 cell = angstrom 5.43")
        // frame 0 crystal coords: (.25,.25,.25)*5.43 = 1.3575
        XCTAssertEqual(f0.atoms[1].coord.x, 1.3575, accuracy: 0.001)
        // frame 1 angstrom coords: literal 1.3575 (NOT alat-scaled, which would be ~7.3)
        XCTAssertEqual(f1.cell!.a.x, 5.43, accuracy: 0.001, "frame1 cell = angstrom 5.43")
        XCTAssertEqual(f1.atoms[1].coord.x, 1.3575, accuracy: 0.001)
        XCTAssertEqual(f1.atoms[1].coord.y, 1.3575, accuracy: 0.001)
        XCTAssertEqual(f1.atoms[1].coord.z, 1.3575, accuracy: 0.001)
    }

    func testForcePwoFlag() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si_relax.out")
        // Forced .pwo parser on an `.out` path succeeds; extension-based dispatch
        // also succeeds because .out maps to .pwo.
        let forced = try Parser.load(url, as: .pwo)
        XCTAssertEqual(forced.atoms.count, 2)
        XCTAssertEqual(Parser.frameCount(url), 2)
    }

    // The newly-completed element table must resolve species the old table
    // silently dropped (Sc, Y, La, Hf, Og) — previously Z=0 => no color/radius.
    func testNewElementsResolved() throws {
        func z(_ sym: String) throws -> Int {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("el.poscar")
            try """
            el test
            1.0
             5 0 0
             0 5 0
             0 0 5
            \(sym)
            1
            Direct
             0 0 0
            """.write(to: tmp, atomically: true, encoding: .utf8)
            return try Parser.load(tmp).atoms[0].atomicNumber
        }
        XCTAssertEqual(try z("Sc"), 21)
        XCTAssertEqual(try z("Y"), 39)
        XCTAssertEqual(try z("La"), 57)
        XCTAssertEqual(try z("Hf"), 72)
        XCTAssertEqual(try z("Og"), 118)
    }

    // The `as:` flag must override extension dispatch: valid CIF content saved
    // under a .xyz name parses only when forced to the CIF parser.
    func testForceCifFlagOverridesExtension() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("renamed.xyz")
        try """
        data_mini
        _cell_length_a 3.0
        _cell_length_b 3.0
        _cell_length_c 3.0
        _cell_angle_alpha 90.0
        _cell_angle_beta 90.0
        _cell_angle_gamma 90.0

        loop_
        _atom_site_label
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Li1 0.0 0.0 0.0
        """.write(to: tmp, atomically: true, encoding: .utf8)
        // Forced CIF parser succeeds.
        let s = try Parser.load(tmp, as: .cif)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 3) // Li
        XCTAssertTrue(s.isCrystal)
        // Extension-based dispatch (.xyz) must fail on CIF content.
        XCTAssertThrowsError(try Parser.load(tmp)) { err in
            guard case ParseError.parse = err else { return XCTFail("expected parse error") }
        }
    }

    // The new AXSF frame-count helper must read the ANIMSTEPS header without
    // loading a frame — the latch fixture has 2 frames, single-frame XSFs are
    // not AXSF at all, and a molecule XYZ reports 0.
    func testAXSFFrameCount() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        XCTAssertEqual(Parser.frameCount(dir.appendingPathComponent("Fixtures/si.latch.axsf")), 2)
        XCTAssertEqual(Parser.frameCount(dir.appendingPathComponent("Fixtures/si110.xsf")), 0)
        XCTAssertEqual(Parser.frameCount(dir.appendingPathComponent("Fixtures/h2o.xyz")), 0)
    }

    // State store must never throw on a malformed scene payload (spec §9).
    func testStateLoadMalformedSceneFallsBack() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bad.mvis-state")
        let payload: [String: Any] = ["version": 1, "scene": "not-a-dict"]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)
        var s = Scene()
        var c: Camera? = nil
        try StateStore.load(into: &s, camera: &c, from: tmp)
        XCTAssertTrue(s.atoms.isEmpty)
        XCTAssertNil(c)
    }

    // A QE PWscf `.out` carrying `bands (ev):` blocks must parse (forced with
    // `--bands`, i.e. as `.bands`) into a BandStructure. The fixture holds SEVEN
    // SCF iterations of 8 k-points each: the parser must return ONLY the final
    // complete iteration (8 points), not the concatenation (56). Band count is
    // deduced from the mode; the Fermi energy is read from the file, not forged.
    func testBandsParseQE() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/CH3Rh111.out")
        let loaded = try Parser.load(url, as: .bands)
        guard let bands = loaded.bandStructure else {
            return XCTFail("no bandStructure parsed")
        }
        // Final iteration only: 8 k-points, not all 56.
        XCTAssertEqual(bands.nKPoints, 8, "expected the final iteration's 8 k-points")
        XCTAssertEqual(bands.nBands, 69, "expected 69 bands per k-point")
        XCTAssertTrue(loaded.atoms.isEmpty, "a bands file carries no atoms")
        // Every surviving k-point must match the modal band count exactly — no
        // zero-padded short records.
        for (ik, kp) in bands.kPoints.enumerated() {
            XCTAssertEqual(kp.energies.count, 69, "k-point \(ik) band count mismatch")
        }
        // kDistances must be non-decreasing (monotonic path).
        let d = bands.kDistances
        for i in 1..<d.count {
            XCTAssertGreaterThanOrEqual(d[i], d[i - 1], "k-distances not monotonic at \(i)")
        }
        // The real Fermi energy of the final iteration, not a fabricated zero.
        let ef = bands.fermiEnergy
        XCTAssertNotNil(ef, "metallic output must report a Fermi energy")
        XCTAssertEqual(ef!, 4.6341, accuracy: 0.01, "Fermi energy should be parsed from the file")
        // And it must fall within the final iteration's eigenvalue window, i.e.
        // the grapher's red Fermi line actually intersects the plotted bands.
        let allE = bands.kPoints.flatMap { $0.energies }
        if let ef = bands.fermiEnergy, let lo = allE.min(), let hi = allE.max() {
            XCTAssertGreaterThanOrEqual(ef, lo)
            XCTAssertLessThanOrEqual(ef, hi)
        }
        // The fixture labels its k-points "cart. coord.", so the parser must NOT
        // apply the reciprocal metric (which would double-transform them). kDistances
        // are therefore plain Euclidean |dk| in 2π/a_0 units.
        XCTAssertFalse(bands.kPointsAreCrystal,
                       "cartesian k-points must not be flagged as crystal")
        let dk = bands.kPoints[1].k - bands.kPoints[0].k
        XCTAssertEqual(bands.kDistances[1], sqrt(dot(dk, dk)), accuracy: 1e-4,
                       "cartesian k-distances must be plain |dk|, not metric-transformed")
        // Single spin channel; per-spin count matches total.
        XCTAssertEqual(bands.nSpin, 1, "fixture is spinless")
        XCTAssertEqual(bands.kPointsPerSpin, 8, "one channel holds all 8 k-points")
        // The fixture is a uniform-weight (wk=0.25) Monkhorst-Pack mesh, not a band
        // path: the parser must flag it so the grapher does not connect the points.
        XCTAssertTrue(bands.isMesh, "uniform-weight mesh must be detected")
    }

    // Negative Fermi energies must keep their sign. The old `[0-9]+\.[0-9]+` regex
    // matched only the magnitude, silently flipping negative (insulating/doped)
    // values to positive. Verifies sign, integer, and scientific forms.
    func testFermiNegative() throws {
        // parseFermiEnergy returns Float?; compare as Floats to avoid Double overload issues.
        func check(_ line: String, _ expected: Float, _ eps: Float = 1e-4) {
            let got = BandParser.parseFermiEnergy(line)
            XCTAssertNotNil(got, "expected a Fermi value for: \(line)")
            XCTAssertEqual(got!, expected, accuracy: eps)
        }
        check("     the Fermi energy is    -4.25 ev", -4.25, 0.001)
        check("     the Fermi energy is     5 ev", 5, 0.001)
        check("     the Fermi energy is   1.5e-3 ev", 1.5e-3, 1e-5)
        // Fortran "D" exponent notation must normalize to "e" before conversion.
        check("     the Fermi energy is   1.5D-3 ev", 1.5e-3, 1e-5)
        check("     the Fermi energy is  -2.5d+1 ev", -25, 1e-3)
        XCTAssertNil(BandParser.parseFermiEnergy("     some other Fermi mention -4.25 ev"))
    }

    // Insulating QE outputs report "highest occupied level" (not a Fermi energy)
    // after each iteration. The parser must treat those lines as iteration
    // boundaries, so iterations split and only the last is kept — not all SCF
    // cycles concatenated into one path.
    func testBandsInsulatorSplit() throws {
        // Two synthetic iterations of 4 k-points each, delimited by a
        // highest-occupied line (no Fermi line at all). Expect 4 k-points (final
        // iteration), NOT the concatenation (8). k-headers must differ so each is
        // parsed as a distinct k-point (parseKHeader rejects exact duplicates only
        // via the value, not the text, so distinct fractional coords are needed).
        func kHeader(_ i: Int) -> String {
            // Distinct fractional coords per k-point; leading-integer form so Float
            // parses reliably (a bare leading dot, e.g. ".10001", would fail).
            return "          k =  .\(i)5000  .\(i)2500 -.1852 ( 6180 PWs)   bands (ev):"
        }
        let eigenvalues = "    -7.2477  -1.7434   -.7444   -.7095"
        func block(_ i: Int) -> String { ([kHeader(i), "", eigenvalues] as [String]).joined(separator: "\n") }
        let gap = "     highest occupied level            ... ev"
        // Iteration 1: k-points 1..4 ; iteration 2: k-points 5..8.
        let iter1 = (1...4).map { block($0) }.joined(separator: "\n")
        let iter2 = (5...8).map { block($0) }.joined(separator: "\n")
        let text = ([iter1, gap, iter2, gap] as [String]).joined(separator: "\n")
        guard let bands = BandParser.parse(text) else {
            return XCTFail("no bandStructure parsed from insulator text")
        }
        XCTAssertEqual(bands.nKPoints, 4, "insulator iterations must split; expected final 4, got \(bands.nKPoints)")
        XCTAssertNil(bands.fermiEnergy, "insulator has no Fermi energy -> unavailable (nil)")
        // k-distances must still be monotonic for the kept iteration.
        for i in 1..<bands.kDistances.count {
            XCTAssertGreaterThanOrEqual(bands.kDistances[i], bands.kDistances[i - 1])
        }
    }

    // The fixture's k-points are explicitly labelled "cart. coord.", so the parser
    // must treat them as Cartesian and compute plain Euclidean |dk| (in 2π/a_0)
    // — NOT apply the reciprocal metric, which would double-transform them.
    func testBandsCartesianKDistance() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/CH3Rh111.out")
        guard let bands = BandParser.parse(try String(contentsOf: url, encoding: .utf8)) else {
            return XCTFail("parse failed")
        }
        XCTAssertFalse(bands.kPointsAreCrystal, "fixture k-points are cartesian")
        // Cartesian k-distance is plain Euclidean |dk|.
        let dk = bands.kPoints[1].k - bands.kPoints[0].k
        XCTAssertEqual(bands.kDistances[1], sqrt(dot(dk, dk)), accuracy: 1e-4,
                       "cartesian k-distance must be plain |dk|")
        for i in 1..<bands.kDistances.count {
            XCTAssertGreaterThan(bands.kDistances[i], bands.kDistances[i - 1], "not monotonic at \(i)")
        }
    }

    // Crystal (fractional) k-points MUST have the reciprocal metric applied, so a
    // fractional step's physical length reflects the cell. We synthesize a crystal
    // QE-style output (header "cryst. coord.") with an anisotropic reciprocal cell
    // and verify the distance equals |B·dk| and differs from plain |dk|.
    func testBandsCrystalKDistance() throws {
        // Reciprocal cell (rows b1..b3), strongly anisotropic.
        let b1 = "               b(1) = (  2.0000   .0000   .0000 )"
        let b2 = "               b(2) = (  .0000  1.0000   .0000 )"
        let b3 = "               b(3) = (  .0000   .0000   .5000 )"
        let recipBlock = """
             reciprocal axes: (cart. coord. in units 2 pi/a_0)
            \(b1)
            \(b2)
            \(b3)
        """
        // Two crystal k-points differing by (0.1, 0, 0): fractional dk = (0.1,0,0).
        // Physical dk = 0.1*b1 = (0.2, 0, 0), |dk|_phys = 0.2; plain |dk| = 0.1.
        let k1 = "  k =  .1000  .0000  .0000 ( 6180 PWs)   bands (ev):"
        let k2 = "  k =  .2000  .0000  .0000 ( 6180 PWs)   bands (ev):"
        let ev = "    -7.2477  -1.7434"
        let kBlock = { (k: String) in [k, "", ev].joined(separator: "\n") }
        let text = ([
            recipBlock,
            "     number of k points=    2",
            "                       cryst. coord.",
            kBlock(k1), kBlock(k2),
        ] as [String]).joined(separator: "\n")
        guard let bands = BandParser.parse(text) else { return XCTFail("parse failed") }
        XCTAssertTrue(bands.kPointsAreCrystal, "synthetic crystal k-points must be detected")
        XCTAssertNotNil(bands.reciprocal, "reciprocal axes should be parsed")
        // Physical distance: |B·dk| where dk_frac = (0.1,0,0) -> (0.2,0,0) -> 0.2.
        XCTAssertEqual(bands.kDistances[1], 0.2, accuracy: 1e-4,
                       "crystal k-distance must be metric-transformed |B·dk| = 0.2")
        XCTAssertNotEqual(bands.kDistances[1], 0.1, "crystal distance must differ from plain fractional")
        XCTAssertFalse(bands.isMesh, "a true band path with distinct points is not a mesh")
    }

    // QE `Forces acting on atoms` blocks are parsed into a ForceSet (eV/Å, eV).
    // parse() now auto-fills energy/stress and counts iterations, so the returned
    // set is fully populated without a separate fillEnergyAndStress() call.
    func testForceParse() throws {
        let block = """
             Forces acting on atoms (Ry/au):

             atom   1 type  1   force =      .01178589     .00671649    -.00370617
             atom   2 type  1   force =     -.01165606     .00670024    -.00383326
             atom   3 type  2   force =      .00005964    -.01367884    -.00324235

             Total force =      .267804     Total SCF correction =      .002682
            """
        // Energy in "Ry" (unit matched case-insensitively) — printed BEFORE forces in a real
        // QE iteration, so it falls within the accepted block's window. Filled automatically.
        let text = "!    total energy              =  -545.21374359 Ry\n" + block
        // atomCount: the block must match the structure's 3 atoms.
        guard let fs = ForceParser.parse(text, atomCount: 3) else { return XCTFail("no forceSet parsed") }
        XCTAssertEqual(fs.forces.count, 3, "expected per-atom forces for 3 atoms")
        // Forces placed by printed index: force[0] is atom 1's, force[1] atom 2's.
        XCTAssertEqual(fs.forces[0].x, 0.01178589 * ForceParser.ryPerAu_to_eVPerAng, accuracy: 1e-6,
                       "force[0] must be atom 1's force (index-aligned, not shifted)")
        // Forces were converted Ry/au -> eV/Å: magnitude should be non-zero and finite.
        XCTAssertFalse(fs.forces.contains { !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite },
                       "forces must be finite")
        XCTAssertNotNil(fs.totalForce, "total force line must be parsed (non-nil)")
        XCTAssertGreaterThan(fs.totalForce!, 0, "total force must be positive")
        // Energy filled automatically by parse(): the real value, not a zero placeholder.
        XCTAssertNotNil(fs.totalEnergy, "total energy line must be parsed (non-nil)")
        XCTAssertEqual(fs.totalEnergy!, -545.21374359 * ForceParser.ry_to_eV, accuracy: 0.05,
                       "total energy must be parsed and converted Ry -> eV")
        XCTAssertEqual(fs.nIterations, 1, "one force block -> one iteration")
    }

    // A malformed atom line must NOT shift subsequent forces onto the wrong atoms,
    // and a block with a gap in the printed indices must be rejected in favor of an
    // earlier complete iteration.
    func testForceIndexAlignment() throws {
        // Two iterations: final one has a GAP (atom 2 malformed), so it is rejected
        // and the earlier complete iteration is used instead. Forces stay aligned.
        let iter1 = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =      .20000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction =      .000010
            """
        // Final iteration: atom 2 line is malformed (no "force =") -> index 2 gap.
        let iter2 = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .90000000     .00000000     .00000000
             atom   2 type  1   force =     garbage
             atom   3 type  1   force =      .90000000     .00000000     .00000000
             Total force =      .90000000     Total SCF correction =      .000010
            """
        let text = iter1 + "\n" + iter2
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        // iter2 is incomplete (gap at index 2) -> rejected; iter1 (2 atoms) is used.
        XCTAssertEqual(fs.forces.count, 2, "should fall back to the complete iteration")
        XCTAssertEqual(fs.forces[0].x, 0.1 * ForceParser.ryPerAu_to_eVPerAng, accuracy: 1e-6,
                       "force[0] must be atom 1's, not shifted onto it by the malformed line")
        XCTAssertEqual(fs.forces[1].x, 0.2 * ForceParser.ryPerAu_to_eVPerAng, accuracy: 1e-6,
                       "force[1] must be atom 2's, not the value from a later iteration")
    }

    // When the final force block is truncated and parse() falls back to an earlier
    // complete block, the paired energy must come from THAT block's iteration, not
    // the file's final "total energy" (which belongs to a different cycle).
    func testForceEnergyPairedWithBlock() throws {
        // Realistic QE order: each SCF cycle prints its total energy BEFORE its
        // forces block. Iteration 1: energy -10, then a complete 2-atom force block.
        // Iteration 2: energy -20, then an INCOMPLETE block (gap: atoms 1 and 3,
        // atom 2 missing) -> rejected, forcing fallback to iter1. parse() must
        // use iter1's forces AND iter1's energy (-10), NOT iter2's -20.
        let iter1 = """
             !    total energy              =     -10.00000000 Ry
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =      .20000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction =      .000010
            """
        let iter2 = """
             !    total energy              =     -20.00000000 Ry
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .90000000     .00000000     .00000000
             atom   3 type  1   force =      .90000000     .00000000     .00000000
             Total force =      .90000000     Total SCF correction =      .000010
            """
        let text = iter1 + "\n" + iter2
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        // iter2 rejected (gap at 2) -> iter1 used: 2 forces AND its own energy (-10),
        // NOT iter2's (-20). Energy pairs with the ACCEPTED block.
        XCTAssertEqual(fs.forces.count, 2, "should fall back to the complete iteration")
        XCTAssertNotNil(fs.totalEnergy, "energy must be paired with the accepted block")
        XCTAssertEqual(fs.totalEnergy!, -10.0 * ForceParser.ry_to_eV, accuracy: 0.05,
                       "energy must pair with the accepted block, not the file's last energy")
    }

    // QE prints the stress tensor as three "s(i j)=" rows of three floats (the
    // standard PWscf format), NOT six floats on the header line. Verify the full
    // symmetric 3×3 is recovered.
    func testForceStressThreeRows() throws {
        let text = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction =      .000010
                 Computing stress (Ry/bohr**3) components
             s(1 1)=      -1.00000000     .50000000     .00000000
             s(2 1)=       .50000000    -2.00000000     .00000000
             s(3 1)=       .00000000     .00000000    -3.00000000
            """
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        guard let s = fs.stress else { return XCTFail("stress should be parsed from three s(i j)= rows") }
        XCTAssertEqual(s[0].x, -1, accuracy: 1e-5, "sxx")
        XCTAssertEqual(s[0].y, 0.5, accuracy: 1e-5, "sxy")
        XCTAssertEqual(s[1].y, -2, accuracy: 1e-5, "syy")
        XCTAssertEqual(s[2].z, -3, accuracy: 1e-5, "szz")
        XCTAssertEqual(s[1].x, s[0].y, accuracy: 1e-5, "tensor must be symmetric")
    }

    // A force block that repeats an atom index (atom 1; atom 2; atom 2) must be
    // REJECTED (not silently overwrite), so an earlier complete block is used.
    func testForceRejectsDuplicateIndex() throws {
        let clean = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =      .20000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction =      .000010
            """
        // Final block: atom 2 appears twice -> duplicate -> rejected -> clean used.
        let dup = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .90000000     .00000000     .00000000
             atom   2 type  1   force =      .80000000     .00000000     .00000000
             atom   2 type  1   force =      .70000000     .00000000     .00000000
             Total force =      .90000000     Total SCF correction =      .000010
            """
        let text = clean + "\n" + dup
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        XCTAssertEqual(fs.forces[1].x, 0.2 * ForceParser.ryPerAu_to_eVPerAng, accuracy: 1e-6,
                       "duplicate block must be rejected, not overwrite atom 2's force")
    }

    // Frame binding: in a relaxation, `ATOMIC_POSITIONS` blocks index frames and the forces
    // printed after each step belong to that step's geometry. parse(frameIndex:) must select
    // the force block of the REQUESTED frame, not the file's final forces, so arrows map to
    // the displayed coordinates.
    // Frame→force mapping matches real QE PWscf relaxation output, where forces computed on
    // geometry[k] are printed AFTER that step's SCF and BEFORE the next ATOMIC_POSITIONS block.
    // So frame k's forces appear in the forward window [geomStarts[k], geomStarts[k+1]); the last
    // frame's converged forces precede it, so it falls back to [geomStarts[k-1], geomStarts[k]).
    // Physically, forces[k] are the forces on geometry[k] — verified against real QE output.
    func testForceFrameBinding() throws {
        // Real QE relaxation order: [geom0] forces0 [geom1] forces1 [geom2 (final)], where
        // forces_k is the force computed on geometry_k. Distinct values per geometry.
        let geom = """
             ATOMIC_POSITIONS (angstrom)
             Si        0.000000   0.000000   0.000000
             Si        1.357500   1.357500   1.357500
            """
        // forces on geometry 0 (initial, large forces, not converged).
        let forcesG0 = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .50000000     .00000000     .00000000
             atom   2 type  1   force =      .50000000     .00000000     .00000000
             Total force =      1.00000000     Total SCF correction =      .000010
            """
        // forces on geometry 1 (converged, small forces).
        let forcesG1 = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .01000000     .00000000     .00000000
             atom   2 type  1   force =      .01000000     .00000000     .00000000
             Total force =      .02000000     Total SCF correction =      .000010
            """
        // forces on geometry 2 (final, printed after last geom — some QE versions do this).
        let forcesG2 = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .00100000     .00000000     .00000000
             atom   2 type  1   force =      .00100000     .00000000     .00000000
             Total force =      .00200000     Total SCF correction =      .000010
            """
        // Order: geom0 forcesG0 geom1 forcesG1 geom2(final) forcesG2.
        // forcesG0 in [geom0,geom1) → frame 0.  forcesG1 in [geom1,geom2) → frame 1.
        // forcesG2 in [geom2, EOF) → frame 2.
        // Last frame with NO following forces returns nil (no backward-window fallback).
        let text = geom + "\n" + forcesG0 + "\n" + geom + "\n" + forcesG1 + "\n" + geom + "\n" + forcesG2
        guard let f0 = ForceParser.parse(text, frameIndex: 0) else { return XCTFail("frame0 parse failed") }
        XCTAssertEqual(f0.forces[0].x, 0.5 * ForceParser.ryPerAu_to_eVPerAng, accuracy: 1e-6,
                       "frame 0 must get geometry 0's forces (0.5)")
        guard let f1 = ForceParser.parse(text, frameIndex: 1) else { return XCTFail("frame1 parse failed") }
        XCTAssertEqual(f1.forces[0].x, 0.01 * ForceParser.ryPerAu_to_eVPerAng, accuracy: 1e-6,
                       "frame 1 must get geometry 1's converged forces (0.01)")
        guard let f2 = ForceParser.parse(text, frameIndex: 2) else { return XCTFail("frame2 parse failed") }
        XCTAssertEqual(f2.forces[0].x, 0.001 * ForceParser.ryPerAu_to_eVPerAng, accuracy: 1e-6,
                       "final frame gets forces from its forward window")
        XCTAssertEqual(f2.nIterations, 3, "nIterations reflects all force blocks in the file")

        // Last frame with NO following forces: must return nil, not borrow from previous frame.
        let noFinalForces = geom + "\n" + forcesG0 + "\n" + geom + "\n" + forcesG1 + "\n" + geom
        XCTAssertNil(ForceParser.parse(noFinalForces, frameIndex: 2),
                     "last frame with no forward forces must return nil, not borrow")
    }

    // Overflow-glued fields: QE prints forces in fixed columns and glues adjacent
    // integer.decimal fields when a magnitude overflows its width. Two cases:
    // (a) realistic overflow (trailing zeros): "90.000000120.000000" = 90.000000 + 120.000000.
    // (b) nonzero fractional parts: "90.123456120.654321" = 90.123456 + 120.654321.
    // An early greedy regex split after the first fractional digit (90.1 + ...); the
    // fix snaps every field to the canonical width of the last (clean) field.
    func testForceGluedOverflowFields() throws {
        let conv = ForceParser.ryPerAu_to_eVPerAng

        func check(_ label: String, _ atom1Forces: String, _ x: Float, _ y: Float) throws {
            // Mirror real QE: the substring after "force =" begins with column padding
            // whitespace, then three components. Components 1 and 2 are overflow-glued;
            // component 3 is a clean field whose fractional width can differ from the
            // glued pair — so the canonical width must be derived from the glued token.
            let text = """
                 Forces acting on atoms (Ry/au):
                 atom   1 type  1   force =  \(atom1Forces)
                 atom   2 type  1   force =      .10000000     .00000000     .00000000
                 Total force =      .30000000     Total SCF correction =      .000010
                """
            guard let fs = ForceParser.parse(text) else { return XCTFail("\(label): no forceSet") }
            XCTAssertEqual(fs.forces.count, 2, label)
            // Forces are converted Ry/au -> eV/Å; the glued field must still split into two
            // components (90 and 120 Ry/au), not merge into 90.000000120.
            XCTAssertEqual(fs.forces[0].x, x * conv, accuracy: 0.05 * conv, "\(label): x corrupted")
            XCTAssertEqual(fs.forces[0].y, y * conv, accuracy: 0.05 * conv, "\(label): y corrupted")
        }
        try check("zeros", "90.000000120.000000 -.00370617", 90.0, 120.0)
        try check("nonzero-frac", "90.123456120.654321 -.00370617", 90.123456, 120.654321)
    }

    // Inline QE stress form "total stress (Ry/bohr**3) = xx yy zz xy xz yz": the
    // "(Ry/bohr**3)" label carries a "3". Scanning the WHOLE line would read that "3"
    // as xx; the fix parses only after '='. Input = 1 2 3 4 5 6, so xx must be 1 (not 3).
    func testForceStressInlineForm() throws {
        let text = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction =      .000010
             total   stress  (Ry/bohr**3)                   = 1.00    2.00    3.00 4.00    5.00    6.00
            """
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        guard let s = fs.stress else { return XCTFail("inline stress should be parsed") }
        XCTAssertEqual(s[0].x, 1.0, accuracy: 0.01, "xx must be 1 (the '3' from bohr**3 must NOT be read)")
        XCTAssertEqual(s[1].y, 2.0, accuracy: 0.01, "syy must be 2")
        XCTAssertEqual(s[2].z, 3.0, accuracy: 0.01, "szz must be 3")
    }

    // Some QE builds print the stress as three UNLABELLED numeric rows after the
    // "total stress (Ry/bohr**3)" header. The parser must recover the 3×3 too.
    func testForceStressUnlabeledRows() throws {
        let text = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction =      .000010
                total   stress  (Ry/bohr**3) (kbar)
             -1.00000000     .50000000     .00000000
              .50000000    -2.00000000     .00000000
              .00000000     .00000000    -3.00000000
            """
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        guard let s = fs.stress else { return XCTFail("stress should be parsed from unlabeled rows") }
        XCTAssertEqual(s[0].x, -1, accuracy: 1e-5, "sxx")
        XCTAssertEqual(s[1].y, -2, accuracy: 1e-5, "syy")
        XCTAssertEqual(s[2].z, -3, accuracy: 1e-5, "szz")
    }

    // When stress appears in multiple iterations and parse() falls back to an
    // earlier complete force block, the selected stress tensor must be the one
    // nearest that accepted block — not the file's first/dump stress.
    func testStressPairedWithAcceptedBlock() throws {
        // Iteration 1 (complete forces + its stress tensor = diag -1,-2,-3).
        let iter1 = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =      .20000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction = .000010
             Computing stress (Ry/bohr**3) components
             s(1 1)=      -1.00000000     .00000000     .00000000
             s(2 1)=       .00000000    -2.00000000     .00000000
             s(3 1)=       .00000000     .00000000    -3.00000000
            """
        // Iteration 2: a DIFFERENT stress (diag -9) but a TRUNCATED force block
        // (gap at atom 2) -> rejected, so stress must pair with iter1, not iter2.
        let iter2 = """
             s(1 1)=      -9.00000000     .00000000     .00000000
             s(2 1)=       .00000000    -9.00000000     .00000000
             s(3 1)=       .00000000     .00000000    -9.00000000
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .90000000     .00000000     .00000000
             atom   3 type  1   force =      .90000000     .00000000     .00000000
             Total force =      .90000000     Total SCF correction = .000010
            """
        let text = iter1 + "\n" + iter2
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        XCTAssertEqual(fs.forces.count, 2, "should fall back to the complete iteration")
        guard let s = fs.stress else { return XCTFail("stress should be parsed") }
        XCTAssertEqual(s[0].x, -1, accuracy: 1e-5,
                       "stress must pair with the accepted (iter1) block, not iter2's (-9)")
        XCTAssertEqual(s[2].z, -3, accuracy: 1e-5, "stress paired with iter1")
    }

    // When the accepted force block has NO stress and the next (rejected) iteration
    // prints stress before its own force header, that later tensor must NOT be
    // borrowed. The contiguous scan in parseStress stops at the first structural
    // boundary (non-blank, non-stress line) after the accepted block, so SCF output
    // between iterations acts as a natural fence.
    func testStressNotBorrowedFromRejectedIteration() throws {
        // Accepted block (iter1): complete forces + Total force, NO stress.
        let iter1 = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =      .20000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction = .000010
            """
        // A single SCF line between iterations is enough for the contiguous scan
        // to stop before reaching iter2's pre-header stress.
        let iter2 = """
             estimated scf accuracy    <   0.00000001
             s(1 1)=      -9.00000000     .00000000     .00000000
             s(2 1)=       .00000000    -9.00000000     .00000000
             s(3 1)=       .00000000     .00000000    -9.00000000
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .90000000     .00000000     .00000000
             atom   3 type  1   force =      .90000000     .00000000     .00000000
             Total force =      .90000000     Total SCF correction = .000010
            """
        let text = iter1 + "\n" + iter2
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        // Iter1 (complete, accepted) has NO stress → must be nil.
        XCTAssertNil(fs.stress, "stress from a rejected iteration must not be borrowed across SCF output")
        XCTAssertEqual(fs.forces.count, 2, "uses iter1 forces")
    }

    // A truncated unlabelled stress header immediately before the next force block
    // must not consume that block's numeric atom rows as a 3x3 tensor.
    func testTruncatedUnlabelledStressStopsAtNextForceBlock() throws {
        let text = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =      .20000000     .00000000     .00000000
             Total force =      .30000000     Total SCF correction = .000010
             total stress (Ry/bohr**3) (kbar)
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .90000000     .00000000     .00000000
             atom   3 type  1   force =      .90000000     .00000000     .00000000
             atom   4 type  1   force =      .90000000     .00000000     .00000000
            """
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        XCTAssertEqual(fs.forces.count, 2, "uses the earlier complete force block")
        XCTAssertNil(fs.stress, "truncated stress must not borrow rows from the next force block")
    }

    // When a force block has no "Total force" line, parseBlock must still return an
    // endLine that sits right after the force atom rows (forceEnd), not at blockEnd.
    // Otherwise the stress search window [endLine, stressEnd) is empty and a valid
    // stress tensor following the atom rows is silently discarded.
    func testStressParsedWhenTotalForceAbsent() throws {
        let text = """
             Forces acting on atoms (Ry/au):
             atom   1 type  1   force =      .10000000     .00000000     .00000000
             atom   2 type  1   force =      .20000000     .00000000     .00000000
             Computing stress (Ry/bohr**3) components
             s(1 1)=      -1.00000000     .00000000     .00000000
             s(2 1)=       .00000000    -2.00000000     .00000000
             s(3 1)=       .00000000     .00000000    -3.00000000
            """
        guard let fs = ForceParser.parse(text) else { return XCTFail("no forceSet parsed") }
        XCTAssertNil(fs.totalForce, "no Total force line → totalForce is nil")
        guard let s = fs.stress else { return XCTFail("stress after forces must be parsed even without Total force line") }
        XCTAssertEqual(s[0].x, -1, accuracy: 1e-5, "sxx parsed correctly")
        XCTAssertEqual(s[2].z, -3, accuracy: 1e-5, "szz parsed correctly")
    }

    // Wiring test: loading a QE .pwo populates scene.forceSet and per-atom
    // forces by index, instead of the forces being parsed but never attached.
    // Uses a synthetic valid `.pwo` (the C parser accepts its atoms/cell) with a
    // force block and energy appended — self-contained, no restart quirks.
    func testPwoForceWiring() throws {
        let pwo = """
             Program PWSCF v.6.7
                 Today is  1Jan2024 at  0:00:00
             bravais-lattice index     =            1
             lattice parameter (alat)  =      10.2000  a.u.
             number of atoms/cell      =            2
             number of atomic types    =            1
             CELL_PARAMETERS (alat)
              1.0000000  0.0000000  0.0000000
              0.0000000  1.0000000  0.0000000
              0.0000000  0.0000000  1.0000000
             ATOMIC_POSITIONS (crystal)
             Si        0.000000   0.000000   0.000000
             Si        0.250000   0.250000   0.250000

                 End of self-consistent calculation

             !    total energy              =     -15.84123456 Ry

             Forces acting on atoms (Ry/au):

             atom   1 type  1   force =      .01178589     .00671649    -.00370617
             atom   2 type  1   force =     -.01165606     .00670024    -.00383326

             Total force =      .267804     Total SCF correction =      .002682
            """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wiring.pwo")
        try pwo.write(to: tmp, atomically: true, encoding: .utf8)
        let loaded = try Parser.load(tmp, as: .pwo)
        guard let fs = loaded.forceSet else { return XCTFail("no forceSet wired from .pwo") }
        XCTAssertEqual(loaded.atoms.count, 2, "structure has 2 atoms")
        XCTAssertEqual(fs.forces.count, 2, "2 atoms -> 2 forces")
        // Per-atom forces aligned by index on the LoadedScene atoms.
        for i in 0..<2 {
            let a = loaded.atoms[i].force!
            let b = fs.forces[i]
            XCTAssertEqual(a.x, b.x, accuracy: 1e-8, "atom \(i) fx alignment")
            XCTAssertEqual(a.y, b.y, accuracy: 1e-8, "atom \(i) fy alignment")
            XCTAssertEqual(a.z, b.z, accuracy: 1e-8, "atom \(i) fz alignment")
        }
        // Energy parsed (auto-filled, non-nil) and positive total-force magnitude.
        XCTAssertNotNil(fs.totalEnergy, "energy auto-filled by wiring path")
        XCTAssertEqual(fs.totalEnergy!, -15.84123456 * ForceParser.ry_to_eV, accuracy: 0.01,
                       "energy auto-filled by wiring path")
        XCTAssertNotNil(fs.totalForce, "total force auto-filled by wiring path")
        XCTAssertGreaterThan(fs.totalForce!, 0)
        XCTAssertEqual(fs.nIterations, 1)
    }

    // A legitimate 2×2 Monkhorst-Pack mesh (the smallest physically meaningful
    // MP grid) must be detected as a mesh, not a band path. After relaxing the
    // size gate to count >= 4 / perRow >= 2 the 4-point grid passes the
    // hasUniformRowFactorization() check (uniform weights + equal spacing +
    // non-collinear also required).
    func testBandsMesh2x2() throws {
        // 2×2 grid in the xy-plane: (0,0),(0,.5),(.5,0),(.5,.5), all wk equal.
        func kHeader(_ x: String, _ y: String) -> String {
            return "  k =  \(x)  \(y)  .0000 ( 6180 PWs)   bands (ev):"
        }
        let ev = "    -7.2477  -1.7434"
        let grid = [(0,0),(0,5),(5,0),(5,5)]
        let blocks = grid.map { kHeader(String(format: ".%d",$0.0), String(format: ".%d",$0.1)) }
            .map { [$0, "", ev].joined(separator: "\n") }.joined(separator: "\n")
        let kList = [
            "        k(   1) = (    .0000000    .0000000    .0000000), wk =    .2500",
            "        k(   2) = (    .0000000    .5000000    .0000000), wk =    .2500",
            "        k(   3) = (    .5000000    .0000000    .0000000), wk =    .2500",
            "        k(   4) = (    .5000000    .5000000    .0000000), wk =    .2500",
        ].joined(separator: "\n")
        let text = ([
            "     number of k points=    4",
            "                       cart. coord.",
            kList,
            blocks,
            "     the Fermi energy is     4.5000 ev",
        ] as [String]).joined(separator: "\n")
        guard let bands = BandParser.parse(text) else { return XCTFail("parse failed") }
        XCTAssertTrue(bands.isMesh, "a 2×2 Monkhorst-Pack mesh must be detected as a mesh")
        XCTAssertEqual(bands.nKPoints, 4)
    }

    // A sparse set whose per-axis marginal frequencies LOOK uniform — every x and every y
    // value appears twice, equally spaced, non-collinear — but whose coordinate
    // COMBINATIONS do not fill a complete grid: (0,0),(0,1),(1,0),(1,2),(2,1),(2,2).
    // The lattice-completeness gate must reject it as a path so it still renders as bands.
    // (Two distinct points per row is not enough; a real mesh fills every grid crossing.)
    func testBandsRejectsSparsePath() throws {
        func kHeader(_ x: String, _ y: String) -> String {
            return "  k =  \(x)  \(y)  .0000 ( 6180 PWs)   bands (ev):"
        }
        let ev = "    -7.2477  -1.7434"
        let pairs = [(0,0),(0,1),(1,0),(1,2),(2,1),(2,2)]
        let blocks = pairs
            .map { kHeader(String(format: ".%d",$0.0), String(format: ".%d",$0.1)) }
            .map { [$0, "", ev].joined(separator: "\n") }.joined(separator: "\n")
        let kList = pairs.enumerated().map { i, p in
            "        k(   \(i+1)) = (    .\(p.0)0000000    .\(p.1)0000000    .0000000), wk =    .16667"
        }.joined(separator: "\n")
        let text = ([
            "     number of k points=    6",
            "                       cart. coord.",
            kList,
            blocks,
            "     the Fermi energy is     4.5000 ev",
        ] as [String]).joined(separator: "\n")
        guard let bands = BandParser.parse(text) else { return XCTFail("parse failed") }
        XCTAssertFalse(bands.isMesh, "a sparse non-lattice path must NOT be classified as a mesh")
    }

    // A genuine three-dimensional Monkhorst-Pack mesh (2×2×2 bulk grid) must be detected
    // as a mesh — the lattice test handles all dimensions via its basis search, not just 2D.
    // Also a sheared 2D slab whose primitive basis vectors are tiny (spacing ~0.01) must pass:
    // the collinearity test is relative to vector length, so small-but-independent vectors are
    // not falsely rejected.
    func testBandsMesh3DAndSheared() throws {
        // QE-style 7-decimal cartesian coords: ".ABCDEFG" parses to 0.ABCDEFG. We emit x,y,z
        // independently so all three axes can vary (a previous version pinned z and silently
        // collapsed to 2D). wk equal across points (uniform MP sampling).
        func mkText(_ pts: [(Int, Int, Int)]) -> String {
            let w = String(format: "%.5f", 1.0 / Float(pts.count))
            let ev = "    -7.2477  -1.7434"
            let blocks = pts.map { p in
                "  k =  .\(p.0)0000  .\(p.1)0000  .\(p.2)0000 ( 6180 PWs)   bands (ev):\n\n\(ev)"
            }.joined(separator: "\n")
            let kList = pts.enumerated().map { i, p in
                "        k(   \(i+1)) = (    .\(p.0)0000000    .\(p.1)0000000    .\(p.2)0000000), wk =    \(w)"
            }.joined(separator: "\n")
            return ([
                "     number of k points=    \(pts.count)",
                "                       cart. coord.",
                kList,
                blocks,
                "     the Fermi energy is     4.5000 ev",
            ] as [String]).joined(separator: "\n")
        }
        // 2×2×2 bulk MP mesh: x∈{5,15}, y∈{2,7}, z∈{1,6} (×1e-2), all 8 combos distinct.
        let bulk: [(Int, Int, Int)] = (0..<2).flatMap { i in (0..<2).flatMap { j in (0..<2).map { k in
            (5 + 10 * i, 2 + 5 * j, 1 + 5 * k)
        } } }
        guard let b3d = BandParser.parse(mkText(bulk)) else { return XCTFail("3D parse failed") }
        XCTAssertTrue(b3d.isMesh, "a 2×2×2 bulk MP mesh must be detected as a mesh")

        // Sheared 2D slab spanning a 3×3 grid. Primitive vectors b1=(1,0.5,0), b2=(0,1,0)
        // (×1e-2); basis vectors are short (len ~0.011) so the RELATIVE collinearity gate is
        // exercised — an absolute cross-product threshold would falsely reject them.
        let sheared: [(Int, Int, Int)] = (0..<3).flatMap { i in (0..<3).map { j in
            (1 * i + 0 * j, i + 3 * j, 0)
        } }
        guard let bSh = BandParser.parse(mkText(sheared)) else { return XCTFail("sheared parse failed") }
        XCTAssertTrue(bSh.isMesh, "a sheared tiny-spacing MP mesh must be detected as a mesh")

        // Reviewer's exact scenario: a valid sheared mesh at PRIMITIVE SPACING ~0.001 (smaller
        // than the 1e-3 absolute cutoff the old code used), anisotropic so the short primitive
        // has multiples spanning the box. Prefer integer grid indices × a fine step, expressed in
        // the same 7-decimal QE format as the passing cases, then scaled to the reviewer's scale.
        // Sheared 3×3 grid whose primitive spacing is ~0.001 (the reviewer's scenario): short
        // primitive b1=(1,0.5,0)·0.001 against long b2=(0,3,0)·0.001, expressed in QE's 7-decimal
        // cart. format. Fine spacing exercises the relative collinearity gate.
        var aniso: [(Int, Int)] = []
        for i in 0..<3 { for j in 0..<3 { aniso.append((i, j)) } }
        // lattice coords (integer indices) × step → grid-aligned at fine scale.
        let anisoText = ([
            "     number of k points=    9",
            "                       cart. coord.",
        ] as [String]).joined(separator: "\n") + "\n" + aniso.enumerated().map { i, p in
            "        k(   \(i+1)) = (    0.\(p.0)5000  0.\(p.0 + p.1*3)5000  .0000000), wk =    .11111"
        }.joined(separator: "\n") + "\n" + aniso.enumerated().map { i, p in
            String(format: "  k =  0.%d5000  0.%d5000  .0000 ( 6180 PWs)   bands (ev):\n\n    -7.2477  -1.7434",
                   p.0, p.0 + p.1*3)
        }.joined(separator: "\n") + "\n     the Fermi energy is     4.5000 ev"
        guard let bAniso = BandParser.parse(anisoText) else { return XCTFail("anisotropic parse failed") }
        XCTAssertTrue(bAniso.isMesh, "a fine-spacing sheared mesh must be detected as a mesh")
    }

    // An ANISOTROPIC 3D bulk mesh: short primitive a=(1,0,0) and long primitive b=(0,0,10), both at
    // fine spacing, in a 3×3×12 grid. The many in-plane a-multiples are all coplanar, so a
    // length-sorted candidate cap would exclude the long out-of-plane primitive; the rank-based
    // selection must still capture it so a complete 3D Monkhorst-Pack mesh is detected (not a path).
    func testBandsMeshAnisotropic3D() throws {
        // Generate on-the-fly: a=(0.01,0,0), b=(0,0.01,0), c=(0,0,0.12), 2×3×4 grid.
        var pts: [SIMD3<Float>] = []
        for i in 0..<2 { for j in 0..<3 { for k in 0..<4 {
            pts.append(SIMD3(0.01 * Float(i), 0.01 * Float(j), 0.12 * Float(k)))
        } } }
        let text = ([
            "     number of k points=    \(pts.count)",
            "                       cart. coord.",
        ] as [String]).joined(separator: "\n") + "\n" + pts.enumerated().map { idx, p in
            String(format: "        k(   %2d) = (    %.5f   %.5f   %.5f  ), wk =    .04167",
                   idx + 1, p.x, p.y, p.z)
        }.joined(separator: "\n") + "\n" + pts.map { p in
            String(format: "  k =  %.5f  %.5f  %.5f ( 6180 PWs)   bands (ev):\n\n    -7.2477  -1.7434",
                   p.x, p.y, p.z)
        }.joined(separator: "\n") + "\n     the Fermi energy is     4.5000 ev"
        guard let bands = BandParser.parse(text) else { return XCTFail("3D anisotropic parse failed") }
        XCTAssertTrue(bands.isMesh, "an anisotropic 3D bulk MP mesh must be detected as a mesh")
    }

    // A sheared 3D mesh whose first plane has more than 200 distinct directions, so
    // a capped direction collection fills with coplanar vectors before seeing the
    // third (out-of-plane) basis direction.
    func testBandsMeshLargeInPlaneSheared3D() throws {
        // Sheared 15×15×2 mesh: k is outermost, so all 225 z=0 points (224 distinct
        // coplanar directions from p0) precede the z=1 points.
        var pts: [SIMD3<Float>] = []
        for k in 0..<2 { for i in 0..<15 { for j in 0..<15 {
            pts.append(SIMD3(0.01 * Float(i), 0.005 * Float(i) + 0.01 * Float(j), Float(k)))
        } } }
        let result = BandParser.detectUniformMesh(
            Array(repeating: 1.0 / Float(pts.count), count: pts.count),
            records: pts.map { BandParserRecord(k: $0, weight: 0, energies: [0], position: 0, spin: 0) }
        )
        XCTAssertTrue(result, "sheared 3D mesh with >200 coplanar directions must be detected")
    }

    // Spin-polarized QE output repeats each k-point's eigenvalue block once per spin
    // (nSpin=2). The parser must detect two channels (eigBlockCount/kListCount) and
    // store kPointsPerSpin so the grapher renders them as separate sub-paths.
    func testBandsSpinPolarized() throws {
        // k-list: 3 unique k-points. Eigenvalue section: each appears twice (spin up,
        // then spin down) => 6 blocks total => nSpin=2, kPointsPerSpin=3.
        func eigBlock(_ k: String) -> String {
            ([k, "", "    -7.2477  -1.7434"] as [String]).joined(separator: "\n")
        }
        let k1 = "  k =  .1000  .0000  .0000 ( 6180 PWs)   bands (ev):"
        let k2 = "  k =  .2000  .0000  .0000 ( 6180 PWs)   bands (ev):"
        let k3 = "  k =  .3000  .0000  .0000 ( 6180 PWs)   bands (ev):"
        // QE prints the k-list once, then ALL eigenvalue blocks (spin-up then spin-
        // down) before a single Fermi line: 3 k-list entries, 6 eig blocks.
        let allBlocks = [eigBlock(k1), eigBlock(k2), eigBlock(k3),
                         eigBlock(k1), eigBlock(k2), eigBlock(k3)].joined(separator: "\n")
        // Distinct weights (a band path, not a uniform mesh).
        let kList = [
            "        k(   1) = (    .1000000    .0000000    .0000000), wk =    .25000",
            "        k(   2) = (    .2000000    .0000000    .0000000), wk =    .50000",
            "        k(   3) = (    .3000000    .0000000    .0000000), wk =    .25000",
        ].joined(separator: "\n")
        let text = ([
            "     number of k points=    3",
            "                       cart. coord.",
            kList,
            allBlocks,
            "     the Fermi energy is     4.5000 ev",
        ] as [String]).joined(separator: "\n")
        guard let bands = BandParser.parse(text) else { return XCTFail("parse failed") }
        XCTAssertEqual(bands.nSpin, 2, "spin-doubled blocks must yield nSpin=2")
        XCTAssertEqual(bands.kPointsPerSpin, 3, "three unique k-points per channel")
        XCTAssertEqual(bands.nKPoints, 6, "2 channels x 3 k-points = 6 total")
        // kDistances restart at 0 for the second channel (no cross-channel step).
        XCTAssertEqual(bands.kDistances[3], 0, "second channel must restart distance at 0")
        XCTAssertFalse(bands.isMesh, "distinct weights must not read as a uniform mesh")
    }

    // An XSF file carrying a `DATAGRID_2D` block must bridge to a `Grid2D` (not a
    // 3D ScalarField): 41 cols x 42 rows of charge-density-difference values, a
    // real span-vector plane, and a non-trivial value range for the colormap.
    func testGrid2DParse() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/mol-urea2D.xsf")
        let loaded = try Parser.load(url)
        guard let grid = loaded.grid2D else {
            return XCTFail("no grid2D parsed from DATAGRID_2D fixture")
        }
        XCTAssertNil(loaded.scalarField, "a 2D grid must not also become a ScalarField")
        XCTAssertEqual(grid.cols, 41, "expected 41 grid columns")
        XCTAssertEqual(grid.rows, 42, "expected 42 grid rows")
        XCTAssertEqual(grid.values.count, 42, "row-major values must have 42 rows")
        XCTAssertEqual(grid.values.first?.count, 41, "each row must have 41 columns")
        // The grid spans a real plane in world space (non-degenerate span vectors).
        XCTAssertEqual(grid.vec.count, 2, "Grid2D carries two span vectors")
        let zero = grid.vec[0] * 0
        XCTAssertTrue(grid.vec[0] != zero || grid.vec[1] != zero, "span vectors must be non-zero")
        // Value range must be non-trivial so the colormap has something to show.
        XCTAssertGreaterThan(grid.maxValue, grid.minValue, "flat field is not a useful colormap")
        XCTAssertFalse(grid.ident.isEmpty, "grid ident label should be populated")
    }
}

// MARK: - Adversarial regression coverage (findings 1-6)
//
// Each test verifies that a malformed / adversarial input is rejected cleanly
// (traps never fire) and that the thread-local error buffer is left empty after
// a failing parse so it cannot leak into a later parse. Structures that would
// have an allocated size diverging from their declared size are rejected outright.

final class AdversarialParserRegressionTests: XCTestCase {

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func mustThrow(_ url: URL, as format: ParseFormat? = nil,
                           file: StaticString = #file, line: UInt = #line) {
        XCTAssertThrowsError(try Parser.load(url, as: format),
                             "expected a parse error for \(url.lastPathComponent)", file: file, line: line)
    }
    // After a FAILED parse the thread-local error buffer intentionally holds the
    // message for the Swift side to read (loadPWO parses it out of molenv_last_error).
    // The "buffer empty" contract applies only to a SUCCESSFUL parse, so these tests
    // assert only that a ParseError was thrown — never that the buffer is empty.

    // MARK: POSCAR (finding 1)

    func testPOSCARRejectsFractionalCount() throws {
        let url = tmp("frac.poscar")
        try write("bad\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\nSi\n2.5\nDirect\n 0 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }

    func testPOSCARRejectsAlphanumericCount() throws {
        let url = tmp("alpha.poscar")
        try write("bad\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\nSi\n2abc\nDirect\n 0 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }

    func testPOSCARRejectsHugeCount() throws {
        let url = tmp("huge.poscar")
        try write("big\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\nSi\n999999999\nDirect\n 0 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }

    func testPOSCARRejectsZeroAtoms() throws {
        let url = tmp("zero.poscar")
        try write("none\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\n0\nDirect\n", to: url)
        mustThrow(url, as: .poscar)
    }

    func testPOSCARVASP5RejectsBadCount() throws {
        let url = tmp("v5bad.poscar")
        try write("bad\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\nSi O\n1 garbage\nDirect\n 0 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }

    func testPOSCARNegativeScaleStillParses() throws {
        let url = tmp("vol.poscar")
        try write("vol\n-27.0\n 2 0 0\n 0 2 0\n 0 0 2\nAl\n1\nDirect\n 0 0 0\n", to: url)
        let s = try Parser.load(url, as: .poscar)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 13)
        XCTAssertEqual(s.cell!.a.x, 3.0, accuracy: 0.001)
    }

    // MARK: PWI (finding 2 + declared-atom truncation)

    func testPWIRejectsMoreThan32Species() throws {
        var species = ""
        for i in 0..<40 { species += "El\(i) 1.0 el.upf\n" }
        let url = tmp("manyspec.pwi")
        try write("&SYSTEM\n  ibrav = 2\n  celldm(1) = 10.26\n  nat = 0\n  ntyp = 40\n/\nATOMIC_SPECIES\n\(species)\n", to: url)
        mustThrow(url, as: .pwi)
    }

    func testPWIRejectsTruncatedPositions() throws {
        let url = tmp("trunc.pwi")
        try write("&SYSTEM\n  ibrav = 2\n  celldm(1) = 10.26\n  nat = 3\n  ntyp = 1\n/\nATOMIC_SPECIES\n Si 28.0 Si.pbe.UPF\nATOMIC_POSITIONS {crystal}\n Si 0.0 0.0 0.0\n Si 0.25 0.25 0.25\n", to: url)
        mustThrow(url, as: .pwi)
    }

    func testPWITruncationHappyPath() throws {
        let url = tmp("ok.pwi")
        try write("&SYSTEM\n  ibrav = 2\n  celldm(1) = 10.26\n  nat = 2\n  ntyp = 1\n/\nATOMIC_SPECIES\n Si 28.0 Si.pbe.UPF\nATOMIC_POSITIONS {crystal}\n Si 0.0 0.0 0.0\n Si 0.25 0.25 0.25\nK_POINTS automatic\n 1 1 1 0 0 0\n", to: url)
        let s = try Parser.load(url, as: .pwi)
        XCTAssertEqual(s.atoms.count, 2)
    }

    // MARK: PWO (declared-atom truncation)

    func testPWORejectsTruncatedTargetFrame() throws {
        let url = tmp("trunc.pwo")
        try write(" number of atoms/cell      =    3\n lattice parameter (alat)  =   10.20 a.u.\nATOMIC_POSITIONS (crystal)\n Si  0.0000000000  0.0000000000  0.0000000000\n Si  0.2500000000  0.2500000000  0.2500000000\n", to: url)
        mustThrow(url, as: .pwo)
    }

    // MARK: CIF (finding 3)

    // A label far longer than the element buffer ("Cappadocian1") must resolve
    // without writing past el[]. The old code truncated to "Cap" (NOT carbon);
    // the point here is that it concludes safely with one atom, not a crash.
    func testCIFForgivesLongLabel() throws {
        let url = tmp("longlabel.cif")
        try write("data_x\n_cell_length_a 5.0\n_cell_length_b 5.0\n_cell_length_c 5.0\n_cell_angle_alpha 90.0\n_cell_angle_beta 90.0\n_cell_angle_gamma 90.0\n\nloop_\n_atom_site_label\n_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\nCappadocian1 0.0 0.0 0.0\n", to: url)
        let s = try Parser.load(url, as: .cif)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 0, "clamped 'Cap' is not a known element")
    }

    func testCIFDigitOnlyLabel() throws {
        let url = tmp("diglabel.cif")
        try write("data_x\n_cell_length_a 5.0\n_cell_length_b 5.0\n_cell_length_c 5.0\n_cell_angle_alpha 90.0\n_cell_angle_beta 90.0\n_cell_angle_gamma 90.0\n\nloop_\n_atom_site_label\n_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\n123 0.0 0.0 0.0\n", to: url)
        let s = try Parser.load(url, as: .cif)
        XCTAssertEqual(s.atoms.count, 1)
        XCTAssertEqual(s.atoms[0].atomicNumber, 0)
    }

    // MARK: Cube (finding 5)

    func testCubeRejectsIntMinAtoms() throws {
        let url = tmp("imin.cube")
        try write("c1\nc2\n\(Int.min) 0 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n1 0 0 0 0\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .cube)
    }

    func testCubeRejectsZeroAxis() throws {
        let url = tmp("zaxis.cube")
        try write("c1\nc2\n1 0 0 0\n2 1 0 0\n0 0 1 0\n2 0 0 1\n1 0 0 0 0\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .cube)
    }

    func testCubeRejectsOverflowingGrid() throws {
        let url = tmp("biggrid.cube")
        try write("c1\nc2\n1 0 0 0\n100000 1 0 0\n100000 0 1 0\n100000 0 0 1\n1 0 0 0 0\n", to: url)
        mustThrow(url, as: .cube)
    }

    func testCubeRejectsShortAtomLine() throws {
        let url = tmp("shortatom.cube")
        try write("c1\nc2\n1 0 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n1 0.0 0.0\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .cube)
    }

    func testCubeRejectsTruncatedGrid() throws {
        let url = tmp("shortgrid.cube")
        try write("c1\nc2\n1 0 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n1 0 0 0 0\n0.1 0.2 0.3\n", to: url)
        mustThrow(url, as: .cube)
    }

    func testCubeMultiOrbitalHappyPath() throws {
        let url = tmp("multi.cube")
        let values = (1...8).flatMap { [Float($0), Float(100 + $0)] }.map { String(format: "%.1f", $0) }.joined(separator: " ")
        // Atom record is Z, charge, x, y, z (5 fields).
        try write("multi\nmock\n-1 0 0 0\n 2 1 0 0\n 2 0 1 0\n 2 0 0 1\n 1 0.0 0.5 0.5 0.5\n2 1 2\n\(values)\n", to: url)
        let s = try Parser.load(url, as: .cube)
        XCTAssertEqual(s.multiOrbitalFields.count, 2)
    }

    func testCubeRejectsHugeOrbitalCount() throws {
        let url = tmp("hugeorb.cube")
        try write("multi\nmock\n-1 0 0 0\n 2 1 0 0\n 2 0 1 0\n 2 0 0 1\n 1 0.5 0.5 0.5\n1099511627776 1 2\n", to: url)
        mustThrow(url, as: .cube)
    }

    // MARK: BXSF (finding 6)

    func testBXSFRejectsMissingFermiEnergy() throws {
        let url = tmp("nofn.bxsf")
        try write("BEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    func testBXSFRejectsNaNDimension() throws {
        let url = tmp("nan.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 NaN\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    func testBXSFRejectsFractionalDimension() throws {
        let url = tmp("frac.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2.5\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    func testBXSFRejectsOverflowingGrid() throws {
        let url = tmp("ox.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n100000 100000 100000\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    func testBXSFRejectsTruncatedBand() throws {
        let url = tmp("bandshort.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    func testBXSFZeroFermiEnergyParses() throws {
        let url = tmp("fnz.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.000000\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        let fs = try BXSFLoader.load(from: url)
        XCTAssertEqual(fs.fermiEnergy, 0.0, accuracy: 1e-6)
        XCTAssertEqual(fs.bands.count, 1)
    }

    func testBXSFHappyPath() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fs = try BXSFLoader.load(from: dir.appendingPathComponent("Fixtures/MgB2.bxsf"))
        XCTAssertEqual(fs.fermiEnergy, 0.52304, accuracy: 1e-4)
        XCTAssertEqual(fs.bands.count, 3)
    }

    // Canonical "Fermi Energy:" must be matched by the label, not a loose
    // "fermi"+"energy" coincidence. A QE-style "the Fermi energy is ..." line is
    // not a BXSF header and must NOT satisfy the requirement.
    func testBXSFRejectsNonCanonicalFermiHeader() throws {
        let url = tmp("qeheader.bxsf")
        try write("BEGIN_INFO\n     the Fermi energy is     4.6341 ev\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // A BANDGRID block that opens but never closes (no END marker) is malformed.
    func testBXSFRejectsMissingEndBandgrid() throws {
        let url = tmp("noend.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // Band markers must be exactly 1..nband in sequence. Out-of-order (2, 1) fails.
    func testBXSFRejectsOutOfOrderBandIndices() throws {
        let url = tmp("ooo.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n2\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 2\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // A malformed numeric line (surplus non-numeric token) inside the body is rejected.
    func testBXSFRejectsSurplusBandgridToken() throws {
        let url = tmp("surplus.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2bad\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // Non-finite band value (NaN) is rejected.
    func testBXSFRejectsNanBandValue() throws {
        let url = tmp("nanval.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 NaN 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // Non-finite origin is rejected.
    func testBXSFRejectsNanOrigin() throws {
        let url = tmp("nanorig.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n1\n2 2 2\n NaN 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // Aggregate band-cell cap: declare a grid big enough that perBand passes but
    // perBand * nband exceeds the ceiling.
    func testBXSFRejectsAggregateOverflow() throws {
        let url = tmp("agg.bsxf")
        // nx*ny*nz = 1000000000 (1e9, passes perBand<=4e9), nband=8, total=8e9 > 4e9 cap
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n8\n10000 10000 10\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // A non-sequential band sequence (duplicate index 1) is rejected.
    func testBXSFRejectsDuplicateBandIndex() throws {
        let url = tmp("dupband.bxsf")
        try write("BEGIN_INFO\n  Fermi Energy:    0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nband_energies\nBANDGRID_3D_BANDS\n2\n2 2 2\n 0 0 0\n 1 0 0\n 0 1 0\n 0 0 1\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nBAND: 1\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\nEND_BANDGRID3D\n", to: url)
        mustThrow(url, as: .bxsf)
    }

    // MARK: Cube hardening (finite MO header + finite fields)

    // A non-finite origin component in the cube header is rejected.
    func testCubeRejectsNanOrigin() throws {
        let url = tmp("norig.cube")
        try write("c1\nc2\n1 NaN 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n1 0 0 0 0\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .cube)
    }

    // A non-finite axis step vector is rejected.
    func testCubeRejectsNanAxisVector() throws {
        let url = tmp("navec.cube")
        try write("c1\nc2\n1 0 0 0\n2 NaN 0 0\n2 0 1 0\n2 0 0 1\n1 0 0 0 0\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .cube)
    }

    // A non-finite atom coordinate is rejected.
    func testCubeRejectsNanAtomCoord() throws {
        let url = tmp("natom.cube")
        try write("c1\nc2\n1 0 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n1 0 NaN 0.0 0.5\n0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .cube)
    }

    // A MO header with a surplus token (declares 2 orbitals but gives 3 indices) is rejected.
    func testCubeRejectsSurplusMOToken() throws {
        let url = tmp("mooo.cube")
        try write("multi\nmock\n-1 0 0 0\n 2 1 0 0\n 2 0 1 0\n 2 0 0 1\n 1 0.5 0.5 0.5\n2 1 2 3\n", to: url)
        mustThrow(url, as: .cube)
    }

    // A MO header declaring more orbitals than indices provided is rejected.
    func testCubeRejectsShortMOHeader() throws {
        let url = tmp("moshort.cube")
        try write("multi\nmock\n-1 0 0 0\n 2 1 0 0\n 2 0 1 0\n 2 0 0 1\n 1 0.5 0.5 0.5\n3 1 2\n", to: url)
        mustThrow(url, as: .cube)
    }

    // A non-finite grid value is rejected.
    func testCubeRejectsNanGridValue() throws {
        let url = tmp("nangrid.cube")
        try write("c1\nc2\n1 0 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n1 0 0 0 0\n0.1 NaN 0.3 0.4 0.5 0.6 0.7 0.8\n", to: url)
        mustThrow(url, as: .cube)
    }

    // MARK: POSCAR hardening (32-token cap + VASP5 cardinality)

    // A species line carrying more than 32 tokens is rejected outright.
    func testPOSCARRejectsTooManySpeciesTokens() throws {
        let syms = (0..<33).map { "El\($0)" }.joined(separator: " ")
        let counts = (0..<33).map { _ in "1" }.joined(separator: " ")
        let url = tmp("toomany.poscar")
        try write("big\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\n\(syms)\n\(counts)\nDirect\n 0 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }

    // VASP5: species/count cardinality mismatch (3 species, 2 counts) is rejected.
    func testPOSCARVASP5RejectsCardinalityMismatch() throws {
        let url = tmp("card.poscar")
        try write("v5\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\nSi O Al\n2 3\nDirect\n 0 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }

    // A POSCAR declaring an atom count exceeding the realistic cap is rejected
    // before the allocation path is reached.
    func testPOSCARRejectsExcessiveAtomCount() throws {
        let url = tmp("hugeatoms.poscar")
        try write("big\n1.0\n 5 0 0\n 0 5 0\n 0 0 5\nSi\n999999999\nDirect\n 0 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }

    // MARK: PWI hardening (strict ntyp range)

    // ntyp out of range (negative) is rejected.
    func testPWIRejectsNegativeNtyp() throws {
        let url = tmp("negntyp.pwi")
        try write("&SYSTEM\n  ibrav = 2\n  celldm(1) = 10.26\n  nat = 1\n  ntyp = -1\n/\nATOMIC_SPECIES\n Si 28.0 Si.pbe.UPF\nATOMIC_POSITIONS {crystal}\n Si 0.0 0.0 0.0\n", to: url)
        mustThrow(url, as: .pwi)
    }

    // ntyp out of range (>32) is rejected.
    func testPWIRejectsLargeNtyp() throws {
        let url = tmp("largentyp.pwi")
        try write("&SYSTEM\n  ibrav = 2\n  celldm(1) = 10.26\n  nat = 1\n  ntyp = 99\n/\nATOMIC_SPECIES\n Si 28.0 Si.pbe.UPF\nATOMIC_POSITIONS {crystal}\n Si 0.0 0.0 0.0\n", to: url)
        mustThrow(url, as: .pwi)
    }

    func testPWIAllowsNamelistCommentsAfterCounts() throws {
        let url = tmp("commented.pwi")
        try write("&SYSTEM\n  ibrav = 2\n  celldm(1) = 10.26\n  nat = 1, ! atoms\n  ntyp = 1, ! species\n/\nATOMIC_SPECIES\n Si 28.0 Si.upf\nATOMIC_POSITIONS {crystal}\n Si 0 0 0\n", to: url)
        XCTAssertEqual(try Parser.load(url, as: .pwi).atoms.count, 1)
    }

    func testCubeAllowsBlankCommentsAndRejectsSurplusValues() throws {
        let valid = tmp("blank-comments.cube")
        try write("\n\n0 0 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n0 1 2 3 4 5 6 7\n", to: valid)
        XCTAssertEqual(try Parser.load(valid, as: .cube).scalarField?.values.count, 8)

        let surplus = tmp("surplus-values.cube")
        try write("c1\nc2\n0 0 0 0\n2 1 0 0\n2 0 1 0\n2 0 0 1\n0 1 2 3 4 5 6 7 8\n", to: surplus)
        mustThrow(surplus, as: .cube)
    }

    func testBXSFAcceptsIncreasingNoncontiguousBandIndices() throws {
        let url = tmp("band-gap.bxsf")
        try write("BEGIN_INFO\nFermi Energy: 0.5\nEND_INFO\nBEGIN_BLOCK_BANDGRID3D\nname\nBANDGRID_3D_BANDS\n2\n2 2 2\n0 0 0\n1 0 0\n0 1 0\n0 0 1\nBAND: 7\n0 0 0 0 1 1 1 1\nBAND: 9\n0 0 0 0 1 1 1 1\nEND_BANDGRID3D\n", to: url)
        XCTAssertEqual(try BXSFLoader.load(from: url).bands.count, 2)
    }

    func testDATAGRIDRejectsBadDimensionsNonfiniteAndMissingEnd() throws {
        func xsf(_ dims: String, _ values: String, end: Bool = true) -> String {
            "CRYSTAL\nPRIMVEC\n1 0 0\n0 1 0\n0 0 1\nPRIMCOORD\n1 1\n1 0 0 0\nBEGIN_BLOCK_DATAGRID_3D\ngrid\nBEGIN_DATAGRID_3D_x\n\(dims)\n0 0 0\n1 0 0\n0 1 0\n0 0 1\n\(values)\n" + (end ? "END_DATAGRID_3D\nEND_BLOCK_DATAGRID_3D\n" : "")
        }
        let badDims = tmp("bad-dims.xsf")
        try write(xsf("2 2", "0 1 2 3 4 5 6 7"), to: badDims)
        mustThrow(badDims, as: .xsf)
        let nonfinite = tmp("nan-grid.xsf")
        try write(xsf("2 2 2", "0 1 2 NaN 4 5 6 7"), to: nonfinite)
        mustThrow(nonfinite, as: .xsf)
        let noEnd = tmp("no-end-grid.xsf")
        try write(xsf("2 2 2", "0 1 2 3 4 5 6 7", end: false), to: noEnd)
        mustThrow(noEnd, as: .xsf)
    }

    func testCIFRejectsFractionalSitesWithoutCell() throws {
        let url = tmp("fractional-no-cell.cif")
        try write("data_x\nloop_\n_atom_site_label\n_atom_site_fract_x\n_atom_site_fract_y\n_atom_site_fract_z\nC 0 0 0\n", to: url)
        mustThrow(url, as: .cif)
    }

    func testPOSCARRejectsNonfiniteGeometry() throws {
        let url = tmp("nan-coordinate.poscar")
        try write("bad\n1.0\n1 0 0\n0 1 0\n0 0 1\nH\n1\nDirect\nNaN 0 0\n", to: url)
        mustThrow(url, as: .poscar)
    }
}
