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
