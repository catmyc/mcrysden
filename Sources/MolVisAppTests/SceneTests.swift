import Foundation
import simd
import XCTest
@testable import MolVisApp

final class SceneTests: XCTestCase {
    private func allComponentsEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    func testXSFLoadsCrystalAndBundledSlab() throws {
        let silicon = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        XCTAssertEqual(silicon.atoms.count, 2)
        XCTAssertTrue(silicon.isCrystal)
        XCTAssertNotNil(silicon.cell)
        XCTAssertEqual(silicon.atoms[0].atomicNumber, 14)

        // The bundled XCrySDen slab separates PRIMVEC records with blank lines.
        // Keep this permissive input covered: whitespace must not create a bogus row.
        let slabURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/fcc-410-1x1.xsf")
        let slab = Scene(loaded: try Parser.load(slabURL))
        XCTAssertEqual(slab.atoms.count, 8)
        XCTAssertEqual(slab.periodicDim, 2)
        XCTAssertNotNil(slab.cell)
    }

    func testParserFamilyMatrixLoadsStructures() throws {
        let geometryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("geometry-\(UUID().uuidString).in")
        defer { try? FileManager.default.removeItem(at: geometryURL) }
        try """
        lattice_vector   5.430000   0.000000   0.000000
        lattice_vector   0.000000   5.430000   0.000000
        lattice_vector   0.000000   0.000000   5.430000
        atom_frac   0.000000   0.000000   0.000000   Si
        atom_frac   0.250000   0.250000   0.250000   Si
        atom            1.000000   2.000000   3.000000   H
        constrain_relaxation .true.
        """.write(to: geometryURL, atomically: true, encoding: .utf8)

        let cases: [(label: String, url: URL, format: ParseFormat, atoms: Int, crystal: Bool)] = [
            ("XYZ", fixture("si.xyz"), .xyz, 2, false),
            ("PDB", fixture("ala.pdb"), .pdb, 5, false),
            ("QE input", fixture("si.pwi"), .pwi, 2, true),
            ("QE output", fixture("si_relax.out"), .pwo, 2, true),
            ("WIEN2k", fixture("gaas.struct"), .struct_, 2, true),
            ("FHI-aims coord", fixture("fhi_gaas_surface.fhi"), .fhi, 14, true),
            ("FHI-aims geometry.in", geometryURL, .fhi, 3, true),
        ]
        for item in cases {
            let loaded = try Parser.load(item.url, as: item.format)
            XCTAssertEqual(loaded.atoms.count, item.atoms, item.label)
            XCTAssertEqual(loaded.isCrystal, item.crystal, item.label)
            if item.crystal { XCTAssertNotNil(loaded.cell, item.label) }
        }

        let geometry = try Parser.load(geometryURL, as: .fhi)
        XCTAssertEqual(geometry.atoms[0].coord.x, 0, accuracy: 1e-5)
        XCTAssertEqual(geometry.atoms[1].coord.x, 0.25 * 5.43, accuracy: 0.01)
        XCTAssertEqual(geometry.atoms[2].coord, SIMD3<Float>(1, 2, 3))

        // Format dispatch: extension sniffing, standard projected-DOS names,
        // open-panel advertisement, and extension-renamed content loading.
        XCTAssertEqual(ParseFormat.from(url: fixture("si110.xsf")), .xsf)
        XCTAssertEqual(ParseFormat.from(url: fixture("N2O.cube")), .cube)
        XCTAssertEqual(ParseFormat.from(url: fixture("si_relax.out")), .pwo)
        XCTAssertEqual(ParseFormat.from(url: URL(fileURLWithPath: "/tmp/prefix.pdos_atm#1(Fe)_wfc#2(p)")), .dos)
        XCTAssertTrue(App.openPanelExtensions.contains("g98"))
        XCTAssertTrue(App.openPanelExtensions.contains("gz"))

        let qe = try Parser.load(fixture("si_relax.out"))
        XCTAssertEqual(qe.atoms.count, 2)
        XCTAssertNotNil(qe.cell)

        let g98URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-\(UUID().uuidString).g98")
        defer { try? FileManager.default.removeItem(at: g98URL) }
        try Data(contentsOf: fixture("N2O.cube")).write(to: g98URL)
        let g98 = try Parser.load(g98URL)
        XCTAssertEqual(g98.scalarField?.nx, 19)
        XCTAssertEqual(g98.atoms.count, 3)

        let gzipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-\(UUID().uuidString).xsf.gz")
        defer { try? FileManager.default.removeItem(at: gzipURL) }
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c", fixture("si.grid.xsf").path]
        let output = Pipe()
        gzip.standardOutput = output
        try gzip.run()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        gzip.waitUntilExit()
        XCTAssertEqual(gzip.terminationStatus, 0)
        try compressed.write(to: gzipURL)
        let gzipped = try Parser.load(gzipURL)
        XCTAssertEqual(gzipped.atoms.count, 2)
        XCTAssertNotNil(gzipped.scalarField)

        // Extension-renamed content is sniffed by content, not extension.
        let orcaOutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: orcaOutURL) }
        try Data(contentsOf: fixture("orca.orca")).write(to: orcaOutURL)
        XCTAssertEqual(ParseFormat.from(url: orcaOutURL), .orca)

        let fhiOutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: fhiOutURL) }
        try Data(contentsOf: fixture("fhi_gaas_surface.fhi")).write(to: fhiOutURL)
        XCTAssertEqual(ParseFormat.from(url: fhiOutURL), .fhi)

        // --msaa CLI parsing: accepts 1/2/4/8 (1 = explicit Off override); rejects the rest.
        XCTAssertEqual(try App.parseArguments(["file.xsf", "--msaa", "1"]).msaaSampleCount, 1)
        XCTAssertEqual(try App.parseArguments(["file.xsf", "--msaa", "2"]).msaaSampleCount, 2)
        XCTAssertEqual(try App.parseArguments(["file.xsf", "--msaa", "4"]).msaaSampleCount, 4)
        XCTAssertEqual(try App.parseArguments(["file.xsf", "--msaa", "8"]).msaaSampleCount, 8)
        XCTAssertNil(try App.parseArguments(["file.xsf"]).msaaSampleCount)
        XCTAssertThrowsError(try App.parseArguments(["file.xsf", "--msaa", "3"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("1, 2, 4, or 8"), "unexpected error: \(error)")
        }
        XCTAssertThrowsError(try App.parseArguments(["file.xsf", "--msaa"]))
        XCTAssertThrowsError(try App.parseArguments(["file.xsf", "--msaa", "2", "--msaa", "4"]))
        // Duplicate detection must fire even when the first value is 1 (explicit Off):
        // a separate seen flag must track the repeat regardless of the stored value.
        XCTAssertThrowsError(try App.parseArguments(["file.xsf", "--msaa", "1", "--msaa", "4"]))
        XCTAssertThrowsError(try App.parseArguments(["file.xsf", "--msaa", "1", "--msaa", "1"]))
    }

    func testCRYSCALExpansionSymbolsAndPolymer() throws {
        let counts = { (atoms: [Atom]) -> [Int: Int] in
            Dictionary(grouping: atoms, by: { $0.atomicNumber }).mapValues { $0.count }
        }
        let crystalNames = [
            ("crystal_ZnS.r1", 8), ("crystal_mgo.r1", 8),
            ("crystal_rutile.r1", 6), ("crystal_graphite.r1", 4),
            ("crystal_corundum.r1", 30), ("crystal_chabazite.r1", 144),
            ("crystal_argonite.r1", 20),
        ]
        for (name, atomCount) in crystalNames {
            let scene = Scene(loaded: try Parser.load(fixture(name), as: .crystal))
            XCTAssertTrue(scene.isCrystal, name)
            XCTAssertEqual(scene.atoms.count, atomCount, name)
            XCTAssertNotNil(scene.cell, name)
        }

        let zns = Scene(loaded: try Parser.load(fixture("crystal_ZnS.r1"), as: .crystal))
        XCTAssertEqual(zns.crystalSymmetry?.symmetry?.spaceGroupNumber, 216)
        XCTAssertEqual(counts(zns.atoms)[16], 4)
        XCTAssertEqual(counts(zns.atoms)[30], 4)
        let mgo = Scene(loaded: try Parser.load(fixture("crystal_mgo.r1"), as: .crystal))
        XCTAssertEqual(mgo.crystalSymmetry?.symmetry?.spaceGroupNumber, 225)
        XCTAssertEqual(counts(mgo.atoms)[12], 4)
        XCTAssertEqual(counts(mgo.atoms)[8], 4)

        // Non-cubic CRYSCAL expansion: verify completeness, symmetry
        // availability, and per-species counts for representative systems.
        let rutileLoaded = try Parser.load(fixture("crystal_rutile.r1"), as: .crystal)
        XCTAssertEqual(rutileLoaded.symmetryInputCompleteness, .complete)
        let rutile = Scene(loaded: rutileLoaded)
        XCTAssertEqual(rutile.crystalSymmetry?.symmetry?.spaceGroupNumber, 136)
        XCTAssertEqual(counts(rutile.atoms)[22], 2)
        XCTAssertEqual(counts(rutile.atoms)[8], 4)
        let graphiteLoaded = try Parser.load(fixture("crystal_graphite.r1"), as: .crystal)
        XCTAssertEqual(graphiteLoaded.symmetryInputCompleteness, .complete)
        let graphite = Scene(loaded: graphiteLoaded)
        XCTAssertEqual(graphite.crystalSymmetry?.symmetry?.spaceGroupNumber, 194)
        XCTAssertEqual(counts(graphite.atoms)[6], 4)
        let corundumLoaded = try Parser.load(fixture("crystal_corundum.r1"), as: .crystal)
        XCTAssertEqual(corundumLoaded.symmetryInputCompleteness, .complete)
        let corundum = Scene(loaded: corundumLoaded)
        XCTAssertEqual(corundum.crystalSymmetry?.symmetry?.spaceGroupNumber, 167)
        XCTAssertEqual(counts(corundum.atoms)[13], 12)
        XCTAssertEqual(counts(corundum.atoms)[8], 18)
        let chabaziteLoaded = try Parser.load(fixture("crystal_chabazite.r1"), as: .crystal)
        XCTAssertEqual(chabaziteLoaded.symmetryInputCompleteness, .complete)
        let chabazite = Scene(loaded: chabaziteLoaded)
        XCTAssertEqual(chabazite.crystalSymmetry?.symmetry?.spaceGroupNumber, 166)
        XCTAssertEqual(counts(chabazite.atoms)[14], 36)
        XCTAssertEqual(counts(chabazite.atoms)[8], 108)
        let aragoniteLoaded = try Parser.load(fixture("crystal_argonite.r1"), as: .crystal)
        XCTAssertEqual(aragoniteLoaded.symmetryInputCompleteness, .complete)
        let aragonite = Scene(loaded: aragoniteLoaded)
        XCTAssertEqual(aragonite.crystalSymmetry?.symmetry?.spaceGroupNumber, 62)
        XCTAssertEqual(counts(aragonite.atoms)[20], 4)
        XCTAssertEqual(counts(aragonite.atoms)[6], 4)
        XCTAssertEqual(counts(aragonite.atoms)[8], 12)

        // Remaining lattice-system Hall conventions: triclinic P1,
        // monoclinic unique-b P2, and primitive trigonal P3.
        for (group, lattice, expected) in [
            (1, "4 5 6 80 90 70", 1),
            (3, "4 5 6 100", 2),
            (143, "4 6", 3),
        ] {
            let text = "synthetic-\(group)\nCRYSTAL\n0 0 0\n\(group)\n\(lattice)\n1\n6 0.123 0.234 0.345\nSTOP\n"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcrysden-sg-\(group)-\(UUID().uuidString).r1")
            try text.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let loaded = try Parser.load(url, as: .crystal)
            XCTAssertEqual(loaded.atoms.count, expected, "space group \(group)")
            XCTAssertEqual(loaded.symmetryInputCompleteness, .complete, "space group \(group)")
        }

        let ptURL = fixture("crystal_Pt_fcc.r1")
        let ptLoaded = try Parser.load(ptURL, as: .crystal)
        XCTAssertEqual(ptLoaded.atoms.count, 4)
        XCTAssertEqual(ptLoaded.symmetryInputCompleteness, .complete)
        let pt = Scene(loaded: ptLoaded)
        XCTAssertEqual(pt.crystalSymmetry?.symmetry?.spaceGroupNumber, 225)
        let expectedFCC = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0.5, 0.5),
            SIMD3<Float>(0.5, 0, 0.5), SIMD3<Float>(0.5, 0.5, 0),
        ]
        let fractional = pt.atoms.compactMap { pt.fractionalCoord($0.coord) }
        XCTAssertEqual(fractional.count, 4)
        for position in expectedFCC {
            XCTAssertEqual(fractional.filter { allComponentsEqual($0, position, 1e-4) }.count, 1,
                           "missing or duplicated FCC position \(position)")
        }

        let source = try String(contentsOf: ptURL, encoding: .utf8)
        func temporary(symbol: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcrysden-cryscal-\(UUID().uuidString).r1")
            try source.replacingOccurrences(of: "F M 3 M", with: symbol)
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let dashedURL = try temporary(symbol: "fm-3m")
        defer { try? FileManager.default.removeItem(at: dashedURL) }
        let dashed = try Parser.load(dashedURL, as: .crystal)
        XCTAssertEqual(dashed.atoms.count, 4)
        XCTAssertTrue(dashed.atoms.allSatisfy { $0.atomicNumber == 78 })
        XCTAssertEqual(dashed.symmetryInputCompleteness, .complete)

        let unknownURL = try temporary(symbol: "xm-3m")
        defer { try? FileManager.default.removeItem(at: unknownURL) }
        let unknown = try Parser.load(unknownURL, as: .crystal)
        XCTAssertEqual(unknown.atoms.count, 1)
        XCTAssertEqual(unknown.symmetryInputCompleteness, .asymmetricUnit)

        // POLYMER is a 1D periodic crystal: isCrystal=true, periodicDim=1.
        let polymer = try Parser.load(fixture("crystal_polymer.r1"), as: .crystal)
        XCTAssertTrue(polymer.isCrystal)
        XCTAssertEqual(polymer.atoms.count, 6)
        let polymerCell = try XCTUnwrap(polymer.cell)
        XCTAssertEqual(polymerCell.a.x, 2.4402, accuracy: 1e-4)
        XCTAssertEqual(polymerCell.a.y, 0, accuracy: 1e-5)
        XCTAssertEqual(polymerCell.b.x, 0, accuracy: 1e-5)
        XCTAssertNotEqual(polymerCell.b.y, 0)
        XCTAssertNotEqual(polymerCell.c.z, 0)
        XCTAssertEqual(polymer.periodicDim, 1)
        XCTAssertEqual(polymer.symmetryInputCompleteness, .asymmetricUnit)
        XCTAssertEqual(polymer.atoms[0].coord.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(polymer.atoms[0].coord.y, 0.7219, accuracy: 1e-5)

        // SLAB record (CRYSCAL/YCrySDen semantics): after an expanded CRYSTAL,
        // SLAB / h k l / NSLAB VACUUM cuts a 2D periodic surface.
        let slab = try Parser.load(fixture("crystal_Pt322.r1"), as: .crystal)
        XCTAssertTrue(slab.isCrystal)
        XCTAssertGreaterThan(slab.atoms.count, 0)
        XCTAssertEqual(slab.periodicDim, 2)
        XCTAssertEqual(slab.symmetryInputCompleteness, .complete)
        let slabCell = try XCTUnwrap(slab.cell)
        XCTAssertEqual(slabCell.c.x, 0, accuracy: 1e-5)
        XCTAssertEqual(slabCell.c.y, 0, accuracy: 1e-5)
        XCTAssertNotEqual(slabCell.c.z, 0, accuracy: 1e-5)
        XCTAssertNotEqual(slabCell.a.x, 0, accuracy: 1e-5)
        let cZ = slabCell.c.z
        XCTAssertGreaterThanOrEqual(cZ, 10.0, "c.z must include the 10 Å user vacuum")
        for atom in slab.atoms {
            XCTAssertGreaterThanOrEqual(atom.coord.z, -1e-3,
                                        "slab atom z must be nonnegative")
            XCTAssertLessThan(atom.coord.z, cZ,
                              "slab atom z must be below c.z")
        }

        // Malformed SLAB records must throw useful ParseError with path.
        let ptBase = try String(contentsOf: fixture("crystal_Pt322.r1"), encoding: .utf8)
        // Degenerate Miller indices (0 0 0).
        let degSource = ptBase.replacingOccurrences(of: "3 2 2", with: "0 0 0")
        let degURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-deg-\(UUID().uuidString).r1")
        try degSource.write(to: degURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: degURL) }
        XCTAssertThrowsError(try Parser.load(degURL, as: .crystal)) { error in
            guard case ParseError.parse(let path, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertEqual(path, degURL.path, "ParseError must carry the file path")
            XCTAssertTrue(reason.contains("degenerate") || reason.contains("0 0 0"),
                          "expected degenerate-Miller error, got: \(reason)")
        }
        // NSLAB = 0 (must be positive).
        let zeroLayer = ptBase.replacingOccurrences(of: "1 10", with: "0 10")
        let zlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-zl-\(UUID().uuidString).r1")
        try zeroLayer.write(to: zlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: zlURL) }
        XCTAssertThrowsError(try Parser.load(zlURL, as: .crystal)) { error in
            guard case ParseError.parse(let path, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertEqual(path, zlURL.path)
            XCTAssertTrue(reason.contains("positive") || reason.contains("layer"),
                          "expected positive-layer error, got: \(reason)")
        }
        // Negative vacuum.
        let negVac = ptBase.replacingOccurrences(of: "1 10", with: "1 -5")
        let nvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-nv-\(UUID().uuidString).r1")
        try negVac.write(to: nvURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: nvURL) }
        XCTAssertThrowsError(try Parser.load(nvURL, as: .crystal)) { error in
            guard case ParseError.parse(let path, _, let reason) = error else {
                return XCTFail("expected ParseError.parse, got \(error)")
            }
            XCTAssertEqual(path, nvURL.path)
            XCTAssertTrue(reason.contains("vacuum") || reason.contains("non-negative"),
                          "expected vacuum error, got: \(reason)")
        }

        // NSLAB > 1 regression: Pt(322) with 3 layers.
        let nSlab3Base = """
        Pt-3layer-slab
        CRYSTAL
        1 0 0
        F M 3 M
        3.92
        1
        78 0.0 0.0 0.0
        SLAB
        3 2 2
        3 8.0
        EXTPRT
        STOP
        """
        let nSlab3URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-nslab3-\(UUID().uuidString).r1")
        try nSlab3Base.write(to: nSlab3URL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: nSlab3URL) }
        let slab3 = try Parser.load(nSlab3URL, as: .crystal)
        XCTAssertTrue(slab3.isCrystal)
        XCTAssertGreaterThan(slab3.atoms.count, 0)
        XCTAssertEqual(slab3.periodicDim, 2)
        XCTAssertEqual(slab3.symmetryInputCompleteness, .complete)
        let slab3Cell = try XCTUnwrap(slab3.cell)
        XCTAssertGreaterThanOrEqual(slab3Cell.c.z, 8.0,
                                    "c.z must include the 8 Å user vacuum")
        XCTAssertGreaterThan(slab3Cell.c.z, 8.0,
                             "c.z must exceed vacuum alone (slab has thickness)")
        for atom in slab3.atoms {
            XCTAssertGreaterThanOrEqual(atom.coord.z, -1e-3)
            XCTAssertLessThan(atom.coord.z, slab3Cell.c.z)
        }
        XCTAssertGreaterThan(slab3.atoms.count, slab.atoms.count,
                             "3-layer slab should have more atoms than 1-layer")
    }

    func testScalarFieldsMarchingCubesAndMultiOrbitalIntegration() throws {
        let xsf = Scene(loaded: try Parser.load(fixture("si.grid.xsf")))
        guard let xsfField = xsf.scalarField else { return XCTFail("expected XSF scalar field") }
        XCTAssertEqual(xsfField.nx, 2)
        XCTAssertEqual(xsfField.ny, 2)
        XCTAssertEqual(xsfField.nz, 2)
        XCTAssertEqual(xsfField.values, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
        XCTAssertEqual(xsfField.minValue, 0.1, accuracy: 1e-5)
        XCTAssertEqual(xsfField.maxValue, 0.8, accuracy: 1e-5)
        let xsfMesh = IsoMesh(field: xsfField, isoLevel: 0.45, sign: 1)
        XCTAssertGreaterThan(xsfMesh.triangleCount, 0)

        let cube = Scene(loaded: try Parser.load(fixture("N2O.cube"), as: .cube))
        XCTAssertEqual(cube.atoms.count, 3)
        XCTAssertEqual(cube.atoms.map(\.atomicNumber), [7, 7, 8])
        guard let cubeField = cube.scalarField else { return XCTFail("expected cube scalar field") }
        XCTAssertEqual(cubeField.nx, 19)
        XCTAssertEqual(cubeField.ny, 19)
        XCTAssertEqual(cubeField.nz, 31)
        XCTAssertEqual(cube.multiOrbitalFields.count, 2)
        XCTAssertEqual(cube.multiOrbitalFields[0].value(0, 0, 0), 1.41569e-4, accuracy: 1e-9)
        XCTAssertEqual(cube.multiOrbitalFields[1].value(0, 0, 0), -3.88836e-4, accuracy: 1e-9)
        XCTAssertGreaterThan(IsoMesh(field: cubeField, isoLevel: 0.005, sign: 1).triangleCount, 0)
        XCTAssertGreaterThan(IsoMesh(field: cubeField, isoLevel: 0.005, sign: -1).triangleCount, 0)

        let bxsf = try Parser.load(fixture("MgB2.bxsf"), as: .bxsf)
        guard let fermiSurface = bxsf.fermiSurface else { return XCTFail("expected BXSF surface") }
        XCTAssertEqual(fermiSurface.fermiEnergy, 0.52304, accuracy: 1e-4)
        XCTAssertEqual(fermiSurface.bands.count, 3)
        for band in fermiSurface.bands {
            XCTAssertGreaterThan(IsoMesh(field: band, isoLevel: fermiSurface.fermiEnergy, sign: 1).triangleCount, 0)
        }

        let fields = [
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
                        values: Array(repeating: -1, count: 8), minValue: -1, maxValue: 1),
            ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                        vec: [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
                        values: Array(repeating: 4, count: 8), minValue: 2, maxValue: 6),
        ]
        var orbitalScene = Scene()
        orbitalScene.scalarField = fields[0]
        orbitalScene.multiOrbitalFields = fields
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(orbitalScene)
        XCTAssertEqual(controller.state.orbitalCount, 2)
        controller.state.currentOrbital = 1
        XCTAssertEqual(controller.scene.currentOrbital, 1)
        XCTAssertEqual(controller.scene.scalarField?.values.first, 4)
        XCTAssertEqual(controller.state.isoRange, 2...6)
    }

    func testAnimationAndFrameParsing() throws {
        let axsfURL = fixture("si.latch.axsf")
        XCTAssertEqual(Parser.frameCount(axsfURL), 2)
        let axsf0 = try Scene(loaded: Parser.load(axsfURL, as: nil, frameIndex: 0))
        let axsf1 = try Scene(loaded: Parser.load(axsfURL, as: nil, frameIndex: 1))
        XCTAssertEqual(axsf0.atoms.count, 2)
        XCTAssertEqual(axsf1.atoms.count, 2)
        XCTAssertNotEqual(axsf0.atoms[0].coord.x, axsf1.atoms[0].coord.x, accuracy: 1e-4)

        let qeURL = fixture("si_relax.out")
        XCTAssertEqual(Parser.frameCount(qeURL, as: .pwo), 2)
        let qe0 = try Parser.load(qeURL, frameIndex: 0, as: .pwo)
        let qe1 = try Parser.load(qeURL, frameIndex: 1, as: .pwo)
        XCTAssertEqual(qe0.atoms.count, 2)
        XCTAssertEqual(qe1.atoms.count, 2)
        XCTAssertNotNil(qe0.cell)
        XCTAssertNotNil(qe1.cell)

        let orcaURL = fixture("orca.orca")
        XCTAssertEqual(Parser.frameCount(orcaURL, as: .orca), 15)
        let orca0 = try Scene(loaded: Parser.load(orcaURL, frameIndex: 0, as: .orca))
        let orcaLast = try Scene(loaded: Parser.load(orcaURL, frameIndex: 14, as: .orca))
        XCTAssertFalse(orca0.isCrystal)
        XCTAssertEqual(orca0.atoms.count, 33)
        XCTAssertEqual(orcaLast.atoms.count, 33)
        XCTAssertNotEqual(orca0.atoms[0].coord.x, orcaLast.atoms[0].coord.x, accuracy: 1e-4)
    }

    func testSupercellSlabAndMalformedInputSafety() throws {
        let base = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let doubled = base.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertEqual(doubled.atoms.count, 4)

        let clipped = base.applySlab(Slab(
            planeA: Plane(h: 0, k: 1, l: 0, distance: 0),
            planeB: Plane(h: 0, k: -1, l: 0, distance: 1e9)))
        XCTAssertLessThanOrEqual(clipped.atoms.count, base.atoms.count)

        let far = base.applySlab(Slab(
            planeA: Plane(h: 0, k: 1, l: 0, distance: -1e9),
            planeB: Plane(h: 0, k: -1, l: 0, distance: 1e9)))
        XCTAssertEqual(far.atoms.count, base.atoms.count)
        XCTAssertNotNil(far.slab)

        let overflow = base.widenSuperCell(SuperCell(n1: Int.max / 2, n2: Int.max / 2, n3: Int.max / 2))
        XCTAssertEqual(overflow.atoms.count, base.atoms.count)
        XCTAssertEqual(overflow.superCell, SuperCell())
        let nonPositive = base.widenSuperCell(SuperCell(n1: 0, n2: 2, n3: 2))
        XCTAssertEqual(nonPositive.atoms.count, base.atoms.count)

        // Malformed input must fail with a useful ParseError, never trap.
        XCTAssertThrowsError(try Parser.load(fixture("bad.xyz"), as: .xyz)) { error in
            guard case ParseError.parse(_, _, let reason) = error else {
                return XCTFail("malformed input should produce ParseError.parse, got \(error)")
            }
            XCTAssertTrue(reason.contains("malformed") || reason.contains("unexpected"))
        }

        var singular = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        singular.cell = Cell(a: SIMD3<Float>(1, 0, 0), b: SIMD3<Float>(2, 0, 0), c: SIMD3<Float>(0, 0, 1))
        XCTAssertNil(singular.fractionalCoord(SIMD3<Float>(0.5, 0, 0.5)))
        let unchanged = singular.applySlab(Slab(
            planeA: Plane(h: 0, k: 1, l: 0, distance: 0),
            planeB: Plane(h: 0, k: -1, l: 0, distance: 1)))
        XCTAssertEqual(unchanged.atoms.count, singular.atoms.count)
        XCTAssertNil(unchanged.slab)
    }
}
