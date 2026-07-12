import simd
import XCTest
@testable import MolVisApp
final class SceneTests: XCTestCase {
    /// Element-wise SIMD equality (XCTAssertEqual/accuracy on SIMD3 is ambiguous).
    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool {
        abs(a.x-b.x) < eps && abs(a.y-b.y) < eps && abs(a.z-b.z) < eps
    }
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }
    func testXSFHappyPath() throws {
        let s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        XCTAssertEqual(s.atoms.count, 2)
        XCTAssertTrue(s.isCrystal)
        XCTAssertNotNil(s.cell)
        XCTAssertEqual(s.atoms[0].atomicNumber, 14)
    }
    func testPDBHappyPath() throws {
        let s = Scene(loaded: try Parser.load(fixture("ala.pdb")))
        XCTAssertEqual(s.atoms.count, 5)
        XCTAssertFalse(s.isCrystal)
    }
    func testAXSFFrameSelection() throws {
        let s0 = try Parser.load(fixture("si.latch.axsf"))
        XCTAssertEqual(s0.atoms.count, 2)
        let s1 = try Parser.load(fixture("si.latch.axsf"), as: nil, frameIndex: 1)
        XCTAssertEqual(s1.atoms.count, 2)
        XCTAssertNotEqual(s1.atoms[0].coord.x, s0.atoms[0].coord.x, accuracy: 0.0001)
    }
    // A DATAGRID_3D block now bridges into a ScalarField (the isosurface
    // engine's keystone), no longer a parse failure.
    func testDATAGRIDBridgesToScalarField() throws {
        let scene = Scene(loaded: try Parser.load(fixture("si.grid.xsf")))
        guard let field = scene.scalarField else { return XCTFail("expected a scalar field") }
        // 2x2x2 grid, origin at zero, axis vectors of length 5 along x/y/z.
        XCTAssertEqual(field.nx, 2)
        XCTAssertEqual(field.ny, 2)
        XCTAssertEqual(field.nz, 2)
        XCTAssertTrue(allComponentsEqual(field.origin, SIMD3<Float>(0, 0, 0)))
        XCTAssertTrue(allComponentsEqual(field.vec[0], SIMD3<Float>(5, 0, 0)))
        XCTAssertTrue(allComponentsEqual(field.vec[1], SIMD3<Float>(0, 5, 0)))
        XCTAssertTrue(allComponentsEqual(field.vec[2], SIMD3<Float>(0, 0, 5)))
        XCTAssertEqual(field.values.count, 8)
        let expected: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        for (a, b) in zip(field.values, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-5)
        }
        XCTAssertEqual(field.minValue, 0.1, accuracy: 1e-5)
        XCTAssertEqual(field.maxValue, 0.8, accuracy: 1e-5)
        // The structure is still parsed alongside the grid.
        XCTAssertEqual(scene.atoms.count, 2)
    }

    // Gaussian cube: a multi-orbital text format. Parse atoms (Bohr->Ang) and the
    // first orbital grid, then prove the same isosurface engine renders a surface.
    func testGaussianCubeLoadsFieldAndAtoms() throws {
        let url = fixture("N2O.cube")
        let scene = Scene(loaded: try Parser.load(url, as: .cube))
        // 3 atoms (N,N,O); the file writes natoms = -3 (multiple orbitals).
        XCTAssertEqual(scene.atoms.count, 3)
        XCTAssertEqual(scene.atoms[0].atomicNumber, 7)
        XCTAssertEqual(scene.atoms[2].atomicNumber, 8)
        guard let field = scene.scalarField else { return XCTFail("expected a scalar field") }
        // axes: 19 x 19 x 31 voxels.
        XCTAssertEqual(field.nx, 19)
        XCTAssertEqual(field.ny, 19)
        XCTAssertEqual(field.nz, 31)
        // grid is non-trivial: a spread of orbital values around 0.
        XCTAssertLessThan(field.minValue, 0.0)
        XCTAssertGreaterThan(field.maxValue, 0.0)
        // step is 0.377945 Bohr -> Ang; spanning vec.x = (19-1)*step.
        let stepAng: Float = 0.377945 * 0.52917721067
        XCTAssertEqual(field.vec[0].x, 18 * stepAng, accuracy: 0.01)
        // first orbital renders a surface at a mid iso level.
        let mesh = IsoMesh(field: field, isoLevel: 0.005, sign: 1)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
    }

    // WIEN2k .struct: parse lattice (Bohr->Ang) + fractional atoms into a crystal.
    // Verified on the real GaAs (2 atoms, fcc) and Pt (1 atom, fcc) fixtures.
    func testWIEN2kStructLoadsCrystal() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let gaas = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/gaas.struct"), as: .struct_))
        XCTAssertTrue(gaas.isCrystal)
        XCTAssertEqual(gaas.atoms.count, 2)
        XCTAssertEqual(gaas.atoms[0].atomicNumber, 31)  // Ga
        XCTAssertEqual(gaas.atoms[1].atomicNumber, 33)  // As
        XCTAssertNotNil(gaas.cell)
        // cubic fcc: a=b=c ~10.684 Bohr -> 5.654 Ang
        let a = simd_length(gaas.cell!.a)
        XCTAssertEqual(a, 10.684 * 0.52917721067, accuracy: 0.01)
        // As sits at (¼,¼,¼) fractional -> cartesian (a/4)(1,1,1)
        let asCart = gaas.atoms[1].coord
        XCTAssertEqual(asCart.x, a / 4, accuracy: 0.01)
        XCTAssertEqual(asCart.y, a / 4, accuracy: 0.01)
        XCTAssertEqual(asCart.z, a / 4, accuracy: 0.01)

        let pt = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/pt.struct"), as: .struct_))
        XCTAssertEqual(pt.atoms.count, 1)
        XCTAssertEqual(pt.atoms[0].atomicNumber, 78)  // Pt

        // MoS2: site Mo MULT=2 (2 pos) + site S MULT=4 (4 pos) => 6 atoms total.
        // The fixture has multiple position lines per site (the ATOM= line plus
        // m-1 follow-ups), carried on unmarked "<i>:" lines.
        let mos2 = Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/mos2.struct"), as: .struct_))
        XCTAssertTrue(mos2.isCrystal)
        XCTAssertEqual(mos2.atoms.count, 6)
        XCTAssertNotNil(mos2.cell)
        let mos2Mo = mos2.atoms.filter { $0.atomicNumber == 42 }.count
        let mos2S  = mos2.atoms.filter { $0.atomicNumber == 16 }.count
        XCTAssertEqual(mos2Mo, 2)
        XCTAssertEqual(mos2S, 4)
    }

    // Orca .out geometry-optimization log: multi-frame molecule. Each CARTESIAN
    // COORDINATES (ANGSTROEM) block is one optimization cycle; final geometry is
    // the last block.
    func testOrcaLogLoadsFrames() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/orca.orca")
        XCTAssertEqual(Parser.frameCount(url, as: .orca), 15, "orca log has 15 opt cycles")
        // final geometry (-1) is a molecule of 33 atoms.
        let final = try Scene(loaded: Parser.load(url, as: .orca))
        XCTAssertFalse(final.isCrystal)
        XCTAssertEqual(final.atoms.count, 33)
        // first frame also loads and differs atom positions (it's a relaxation).
        let first = try Scene(loaded: Parser.load(url, frameIndex: 0, as: .orca))
        XCTAssertEqual(first.atoms.count, 33)
        XCTAssertNotEqual(final.atoms[0].coord.x, first.atoms[0].coord.x, accuracy: 1e-4)
        // every frame parses.
        for i in 0..<15 {
            let s = try Scene(loaded: Parser.load(url, frameIndex: i, as: .orca))
            XCTAssertEqual(s.atoms.count, 33, "frame \(i) atom count")
        }
    }

    // CRYSCAL .r1: crystal input across crystal systems. The space group sets the
    // lattice-param count + cell angles; lattice constants are in Angstrom.
    func testCRYSCALr1LoadsCrystal() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        func load(_ name: String) throws -> Scene {
            try Scene(loaded: Parser.load(dir.appendingPathComponent("Fixtures/\(name)"), as: .crystal))
        }
        // ZnS: cubic (spg 216), 1 lattice const; 2 atoms. The file writes an extra
        // spurious 2.96 param that nLat=1 correctly ignores.
        let zns = try load("crystal_ZnS.r1")
        XCTAssertTrue(zns.isCrystal)
        XCTAssertEqual(zns.atoms.count, 2)
        XCTAssertNotNil(zns.cell)
        XCTAssertEqual(simd_length(zns.cell!.a), 5.42, accuracy: 0.01)

        // rutile: tetragonal (spg 136), a,c; 2 atoms.
        let rutile = try load("crystal_rutile.r1")
        XCTAssertEqual(rutile.atoms.count, 2)
        XCTAssertEqual(simd_length(rutile.cell!.a), 4.59, accuracy: 0.01)
        XCTAssertEqual(simd_length(rutile.cell!.c), 2.96, accuracy: 0.01)

        // graphite: hexagonal (spg 194), a,c gamma=120; 2 atoms.
        let graphite = try load("crystal_graphite.r1")
        XCTAssertEqual(graphite.atoms.count, 2)
        XCTAssertEqual(simd_length(graphite.cell!.a), 2.46, accuracy: 0.01)
        XCTAssertEqual(simd_length(graphite.cell!.c), 6.70, accuracy: 0.01)

        // corundum: trigonal R (spg 167, hexagonal setting) gamma=120; 2 atoms.
        let corundum = try load("crystal_corundum.r1")
        XCTAssertEqual(corundum.atoms.count, 2)
        XCTAssertEqual(simd_length(corundum.cell!.a), 4.7602, accuracy: 0.01)
        XCTAssertEqual(simd_length(corundum.cell!.c), 12.9933, accuracy: 0.01)

        // chabazite: trigonal (spg 166); 5 atoms.
        let chaba = try load("crystal_chabazite.r1")
        XCTAssertEqual(chaba.atoms.count, 5)

        // argonite: orthorhombic (Pmcn, spg 53), 3 lattice consts; 4 atoms.
        let argonite = try load("crystal_argonite.r1")
        XCTAssertEqual(argonite.atoms.count, 4)
        XCTAssertEqual(simd_length(argonite.cell!.a), 4.9616, accuracy: 0.01)
        XCTAssertEqual(simd_length(argonite.cell!.b), 7.9705, accuracy: 0.01)
        XCTAssertEqual(simd_length(argonite.cell!.c), 5.7394, accuracy: 0.01)
    }

    // Fermi-surface BXSF: parse the Fermi energy + per-band grids, then build a
    // surface at the Fermi level. Verified on the real MgB2 fixture.
    func testBXSFParsesBandsAndFermiEnergy() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fs = try BXSFLoader.load(from: dir.appendingPathComponent("Fixtures/MgB2.bxsf"))
        XCTAssertEqual(fs.fermiEnergy, 0.52304, accuracy: 1e-4)
        XCTAssertEqual(fs.bands.count, 3, "MgB2 has 3 bands")
        for b in fs.bands {
            XCTAssertEqual(b.nx, 13); XCTAssertEqual(b.ny, 13); XCTAssertEqual(b.nz, 10)
            XCTAssertEqual(b.values.count, 13*13*10)
        }
        // iso at the Fermi energy must emit a surface for each band.
        for b in fs.bands {
            let mesh = IsoMesh(field: b, isoLevel: fs.fermiEnergy, sign: 1)
            XCTAssertGreaterThan(mesh.triangleCount, 0, "every band surfaces at Fermi level")
        }
    }

    // Marching cubes over the bridged field must emit a closed-ish triangle
    // surface with in-range normals at a sensible iso level.
    func testMarchingCubesProducesSurface() throws {
        let scene = Scene(loaded: try Parser.load(fixture("si.grid.xsf")))
        guard let field = scene.scalarField else { return XCTFail("expected a scalar field") }
        let mesh = IsoMesh(field: field, isoLevel: 0.45, sign: 1)
        XCTAssertGreaterThan(mesh.triangleCount, 0, "isosurface must produce triangles")
        // Every normal must be unit length (lit correctly by the poly pipeline).
        var v: [Float] = []
        mesh.vertices.forEach { v.append($0) }
        for i in stride(from: 0, to: v.count, by: 9) {
            let n = SIMD3<Float>(v[i+3], v[i+4], v[i+5])
            XCTAssertEqual(length(n), 1.0, accuracy: 1e-4, "normal must be unit length")
        }
    }
    func testSupercellDoubles() throws {
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        s = s.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertEqual(s.atoms.count, 4)
    }
    func testSlabPreservesSubset() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        var s = Scene(loaded: try Parser.load(url))
        let before = s.atoms.count
        s = s.applySlab(Slab(planeA: Plane(h:0,k:1,l:0,distance:0), planeB: Plane(h:0,k:-1,l:0,distance:1e9)))
        XCTAssertLessThanOrEqual(s.atoms.count, before)
    }

    // A slab whose planes sit far outside the cell must keep every atom. This
    // exercises the same fractional-projection filter that syncFromState now
    // routes through via applySlab (final-review Important #2).
    func testSlabFarPlanePreservesAllAtoms() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/si110.xsf")
        var s = Scene(loaded: try Parser.load(url))
        let before = s.atoms.count
        XCTAssertGreaterThan(before, 0)
        // planeA distance very negative => projA >= dA always true;
        // planeB distance very positive => projB <= dB always true.
        s = s.applySlab(Slab(planeA: Plane(h: 0, k: 1, l: 0, distance: -1e9),
                             planeB: Plane(h: 0, k: -1, l: 0, distance: 1e9)))
        XCTAssertEqual(s.atoms.count, before)
        XCTAssertNotNil(s.slab)
    }
}
