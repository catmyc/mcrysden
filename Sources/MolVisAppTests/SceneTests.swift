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
        XCTAssertEqual(scene.multiOrbitalFields.count, 2)
        XCTAssertEqual(scene.multiOrbitalFields[0].value(0, 0, 0), 1.41569e-4, accuracy: 1e-9)
        XCTAssertEqual(scene.multiOrbitalFields[1].value(0, 0, 0), -3.88836e-4, accuracy: 1e-9)
        XCTAssertEqual(scene.multiOrbitalFields[0].value(0, 0, 1), 2.31251e-4, accuracy: 1e-9)
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

    // .g98 extension must dispatch to the same cube parser.
    func testGaussianG98ExtensionDispatchesToCube() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mol.g98")
        try """
        Gaussian mock
        Test
         1   0.000000   0.000000   0.000000   0.000000
           2   1.000000   0.000000   0.000000
           2   0.000000   1.000000   0.000000
           2   0.000000   0.000000   1.000000
         1   0.000000   0.500000   0.500000   0.500000
           0.1   0.2   0.3   0.4   0.5   0.6   0.7   0.8
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let loaded = try Parser.load(tmp)
        XCTAssertNotNil(loaded.scalarField, ".g98 must parse as a cube")
        XCTAssertEqual(loaded.scalarField?.nx, 2)
    }

    // Multi-orbital cube files retain ALL orbitals so the user can switch between them.
    func testMultiOrbitalCubeRetainsAllOrbitals() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("multi.cube")
        // natoms = -1 → multi-orbital. MO record "2  1  2" → 2 orbitals.
        // Cube values are voxel-major with z fastest, and orbital values are
        // interleaved at each voxel: (orb1,orb2), (orb1,orb2), ...
        let values = (1...8).flatMap { [Float($0), Float(100 + $0)] }
            .map { String(format: "%.1f", $0) }.joined(separator: "   ")
        try """
        Multi-orbital test
        mock
        -1   0.000000   0.000000   0.000000
           2   1.000000   0.000000   0.000000
           2   0.000000   1.000000   0.000000
           2   0.000000   0.000000   1.000000
         1   0.000000   0.500000   0.500000   0.500000
        2  1  2
        \(values)
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let loaded = try Parser.load(tmp, as: .cube)
        XCTAssertEqual(loaded.multiOrbitalFields.count, 2, "both orbitals retained")
        // ScalarField stores x fastest, so transpose cube's z-fastest voxel order.
        XCTAssertEqual(loaded.multiOrbitalFields[0].values, [1, 5, 3, 7, 2, 6, 4, 8])
        XCTAssertEqual(loaded.multiOrbitalFields[1].values, [101, 105, 103, 107, 102, 106, 104, 108])
        // scalarField defaults to the first orbital
        XCTAssertEqual(loaded.scalarField?.values.first ?? -1, 1.0, accuracy: 0.01)
    }

    func testMultiOrbitalSelectionWiresThroughController() throws {
        let fields = [
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                        values: Array(repeating: -1, count: 8), minValue: -1, maxValue: 1),
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                        values: Array(repeating: 4, count: 8), minValue: 2, maxValue: 6),
        ]
        var scene = Scene()
        scene.scalarField = fields[0]
        scene.multiOrbitalFields = fields
        let wc = MainWindowController(scene: Scene())
        defer { wc.window.close() }
        wc.loadFile(scene)
        XCTAssertEqual(wc.state.orbitalCount, 2)
        wc.state.currentOrbital = 1
        XCTAssertEqual(wc.scene.currentOrbital, 1)
        XCTAssertEqual(wc.scene.scalarField?.values.first, 4)
        XCTAssertEqual(wc.state.isoRange, 2...6)
    }

    // The isosurface renderer draws both positive (sign>0) and negative (sign<0)
    // shells for an orbital field that spans both signs.
    func testInsideIsosurfaceShellNonEmpty() throws {
        let url = fixture("N2O.cube")
        let scene = Scene(loaded: try Parser.load(url, as: .cube))
        guard let field = scene.scalarField else { return XCTFail("expected a scalar field") }
        // outside shell at iso=0.005
        let outside = IsoMesh(field: field, isoLevel: 0.005, sign: 1)
        XCTAssertGreaterThan(outside.triangleCount, 0, "outside shell must render")
        // negative shell at field == -0.005.
        let inside = IsoMesh(field: field, isoLevel: 0.005, sign: -1)
        XCTAssertGreaterThan(inside.triangleCount, 0, "inside shell must render a surface too")
    }

    func testNegativeIsosurfaceInterpolatesAtNegativeThreshold() throws {
        // v=-2 at x=0 and v=0 at x=1. A sign=-1 shell at iso=0.5 crosses
        // v=-0.5 at x=0.75; interpolating at +0.5 would extrapolate to x=1.25.
        var values: [Float] = []
        for _ in 0..<4 { values += [-2, 0] }
        let field = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                vec: [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)],
                                values: values, minValue: -2, maxValue: 0)
        let mesh = IsoMesh(field: field, isoLevel: 0.5, sign: -1)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
            XCTAssertEqual(mesh.vertices[i], 0.75, accuracy: 1e-5)
            XCTAssertGreaterThan(mesh.vertices[i + 3], 0.99, "negative-lobe normal faces higher values")
        }
    }

    func testWorldGradientTransformsSkewedAnisotropicGrid() throws {
        let spans = [SIMD3<Float>(2, 0, 0), SIMD3<Float>(1, 3, 0), SIMD3<Float>(0.5, 0.25, 4)]
        let expected = SIMD3<Float>(1, 2, -0.5)
        var values: [Float] = []
        for iz in 0..<3 { for iy in 0..<3 { for ix in 0..<3 {
            let p = spans[0] * (Float(ix) / 2) + spans[1] * (Float(iy) / 2) + spans[2] * (Float(iz) / 2)
            values.append(simd_dot(expected, p))
        } } }
        let field = ScalarField(nx: 3, ny: 3, nz: 3, origin: .zero, vec: spans,
                                values: values, minValue: values.min()!, maxValue: values.max()!)
        let gradient = field.worldGradient(0.5, 0.5, 0.5)
        XCTAssertTrue(allComponentsEqual(gradient, expected, 1e-4), "got \(gradient)")
    }

    // Standard FHI-aims `geometry.in` (lattice_vector + atom_frac/atom) parses.
    func testFHIGeometryInParses() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("geometry.in")
        try """
        lattice_vector   5.430000   0.000000   0.000000
        lattice_vector   0.000000   5.430000   0.000000
        lattice_vector   0.000000   0.000000   5.430000
        atom_frac   0.000000   0.000000   0.000000   Si
        atom_frac   0.250000   0.250000   0.250000   Si
        atom            1.000000   2.000000   3.000000   H
        constrain_relaxation .true.
        """.write(to: tmp, atomically: true, encoding: .utf8)
        let loaded = try Parser.load(tmp)
        XCTAssertEqual(loaded.atoms.count, 3, "2 fractional + 1 Cartesian atom")
        XCTAssertEqual(loaded.atoms[0].atomicNumber, 14) // Si
        XCTAssertEqual(loaded.atoms[2].atomicNumber, 1)  // H
        XCTAssertNotNil(loaded.cell, "geometry.in has a cell")
        // fractional Si at (0,0,0) → origin
        XCTAssertEqual(loaded.atoms[0].coord.x, 0, accuracy: 1e-5)
        // fractional Si at (0.25,0.25,0.25) → (0.25*5.43, ...)
        XCTAssertEqual(loaded.atoms[1].coord.x, 0.25 * 5.43, accuracy: 0.01)
        // Cartesian H at (1,2,3) → unchanged
        XCTAssertEqual(loaded.atoms[2].coord.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(loaded.atoms[2].coord.y, 2.0, accuracy: 1e-5)
        XCTAssertEqual(loaded.atoms[2].coord.z, 3.0, accuracy: 1e-5)
    }

    func testCompressedXSFLoadsThroughNormalDispatch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", fixture("si.grid.xsf").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("si.grid.xsf.gz")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.atoms.count, 2)
        XCTAssertNotNil(loaded.scalarField)
    }

    func testOpenPanelIncludesTierAExtensions() throws {
        XCTAssertTrue(App.openPanelExtensions.contains("g98"))
        XCTAssertTrue(App.openPanelExtensions.contains("gz"))
    }

    // Regression for review P1#1: the isosurface must span the WHOLE grid, not
    // collapse into the first cell near the origin. Checking only that vertices lie
    // inside the global bounding box is NOT enough -- the old first-cell-only output
    // also passed that test (all its vertices sat near the origin, well inside the
    // box). The real invariant is that the mesh's own bounding box spans a large
    // fraction of the cell in every dimension: a collapsed mesh covers ~1 voxel; a
    // correct one covers most of the cell.
    func testMarchingCubesSpansWholeGrid() throws {
        let url = fixture("N2O.cube")
        let scene = Scene(loaded: try Parser.load(url, as: .cube))
        guard let field = scene.scalarField else { return XCTFail("expected a scalar field") }
        let mesh = IsoMesh(field: field, isoLevel: 0.005, sign: 1)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        let o = field.origin
        let maxCorner = o + field.vec[0] + field.vec[1] + field.vec[2]
        var loV = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var hiV = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
            let p = SIMD3<Float>(mesh.vertices[i], mesh.vertices[i+1], mesh.vertices[i+2])
            loV = min(loV, p); hiV = max(hiV, p)
        }
        for a in 0..<3 {
            let cellSpan = abs(maxCorner[a] - o[a])
            let meshSpan = hiV[a] - loV[a]
            // A correct surface spans a large fraction of the cell; a first-cell
            // collapse spans ~1 voxel (a few percent of the cell).
            XCTAssertGreaterThan(meshSpan, cellSpan * 0.4,
                "mesh must span the cell, not collapse into the first voxel (dim \(a): \(meshSpan) vs \(cellSpan))")
        }
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

    // FHI-aims coord.out structure: lattice vectors (Bohr->Ang) + species blocks
    // of [count name (x y z flag)*count]. Verified on the GaAs-surface slab:
    // 4 species (Ga x6, As x6, H x1, H x1) = 14 atoms. Reference converter
    // (XCrySDen F/fhi_coord2xcr.f) multiplies both lattice and coords by BOHR.
    func testFHIaimsLoadsStructure() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let scene = try Scene(loaded: Parser.load(dir.appendingPathComponent("Fixtures/fhi_gaas_surface.fhi"), as: .fhi))
        XCTAssertTrue(scene.isCrystal)
        XCTAssertEqual(scene.atoms.count, 14)
        XCTAssertNotNil(scene.cell)
        let ga = scene.atoms.filter { $0.atomicNumber == 31 }.count
        let ar = scene.atoms.filter { $0.atomicNumber == 33 }.count
        let h  = scene.atoms.filter { $0.atomicNumber == 1 }.count
        XCTAssertEqual(ga, 6)
        XCTAssertEqual(ar, 6)
        XCTAssertEqual(h, 2)
        // lattice vectors were in Bohr: 10.44 Bohr -> 5.52 Ang.
        XCTAssertEqual(simd_length(scene.cell!.a), 10.44 * 0.529177, accuracy: 0.01)
    }

    // Orca .out geometry-optimization log: multi-frame molecule. Each CARTESIAN
    // COORDINATES (ANGSTROEM) block is one optimization cycle; final geometry is
    // the last block.
    func testOrcaLogLoadsFrames() throws {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures/orca.orca")
        XCTAssertEqual(Parser.frameCount(url, as: .orca), 15, "orca log has 15 opt cycles")
        // Default-open (no frameIndex) now returns the FIRST cycle, like AXSF/pwo,
        // so the scrubber (which starts at frame 0) and the open view agree.
        let first = try Scene(loaded: Parser.load(url, as: .orca))
        XCTAssertFalse(first.isCrystal)
        XCTAssertEqual(first.atoms.count, 33)
        // An explicit --frame 0 is the SAME first cycle (the bug made it final).
        let explicitZero = try Scene(loaded: Parser.load(url, frameIndex: 0, as: .orca))
        XCTAssertEqual(explicitZero.atoms[0].coord.x, first.atoms[0].coord.x, accuracy: 1e-4,
                       "explicit --frame 0 must equal default-open (first cycle)")
        // an explicit late frame differs from the first cycle (it's a relaxation).
        let late = try Scene(loaded: Parser.load(url, frameIndex: 14, as: .orca))
        XCTAssertEqual(late.atoms.count, 33)
        XCTAssertNotEqual(late.atoms[0].coord.x, first.atoms[0].coord.x, accuracy: 1e-4)
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

    // supercell product overflow must be refused (returned unchanged), not wrap past
    // the cap. Int.max/2 cubed overflows Int; the safe product rejects it.
    func testSupercellOverflowIsRefused() throws {
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let before = s.atoms.count
        let huge = SuperCell(n1: Int.max / 2, n2: Int.max / 2, n3: Int.max / 2)
        let out = s.widenSuperCell(huge)
        // Refusal leaves the scene untouched: same atom count and a default supercell.
        XCTAssertEqual(out.atoms.count, before)
        XCTAssertEqual(out.superCell, SuperCell())
    }

    // A zero/negative supercell factor is nonsensical and must be refused rather
    // than produce a degenerate (zero-atom) expansion.
    func testSupercellNonPositiveFactorIsRefused() throws {
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let before = s.atoms.count
        let out = s.widenSuperCell(SuperCell(n1: 0, n2: 2, n3: 2))
        XCTAssertEqual(out.atoms.count, before)
    }

    // fractionalCoord must return nil for a singular (zero-volume) cell so callers
    // (applySlab) can refuse instead of fabricating an origin at (0,0,0).
    func testFractionalCoordNilForSingularCell() {
        var s = Scene()
        // Two collinear vectors => det == 0.
        s.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        XCTAssertNil(s.fractionalCoord(SIMD3(0.5, 0, 0.5)))
    }

    // applySlab against a singular cell must leave the scene unchanged (refuse),
    // not filter atoms against a fabricated origin.
    func testApplySlabRefusesSingularCell() throws {
        var s = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        s.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        let before = s.atoms.count
        let out = s.applySlab(Slab(planeA: Plane(h: 0, k: 1, l: 0, distance: 0),
                                    planeB: Plane(h: 0, k: -1, l: 0, distance: 1)))
        XCTAssertEqual(out.atoms.count, before)
        XCTAssertNil(out.slab)
    }
}
