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
