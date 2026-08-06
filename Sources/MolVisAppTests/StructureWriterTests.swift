import simd
import XCTest
@testable import MolVisApp

/// Coverage for `StructureWriter`: every format round-trips through its parser,
/// and the validation errors fire for the malformed cases.
final class StructureWriterTests: XCTestCase {

    // MARK: - Fixtures

    /// Diamond-cubic Si conventional cell (a = 5.43 Å, 8 atoms).
    private func makeSiScene() -> Scene {
        let a: Float = 5.43
        let cell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, a, 0), c: SIMD3(0, 0, a))
        let frac: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0.5, 0.5), SIMD3(0.5, 0, 0.5), SIMD3(0.5, 0.5, 0),
            SIMD3(0.25, 0.25, 0.25), SIMD3(0.25, 0.75, 0.75),
            SIMD3(0.75, 0.25, 0.75), SIMD3(0.75, 0.75, 0.25),
        ]
        let atoms = frac.map { f -> Atom in
            let c = SIMD3<Float>(Float(f.x) * a, Float(f.y) * a, Float(f.z) * a)
            return Atom(coord: c, atomicNumber: 14, label: "Si")
        }
        var scene = Scene()
        scene.cell = cell
        scene.atoms = atoms
        scene.isCrystal = true
        scene.periodicDim = 3
        scene.title = "Si"
        return scene
    }

    private func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-sw-\(UUID().uuidString).\(ext)")
    }

    private func cellParams(_ cell: Cell) -> (a: Float, b: Float, c: Float,
                                             alpha: Float, beta: Float, gamma: Float) {
        func ang(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> Float {
            let c = simd_dot(u, v) / (length(u) * length(v))
            return acos(max(-1, min(1, c))) * 180 / .pi
        }
        return (length(cell.a), length(cell.b), length(cell.c),
                ang(cell.b, cell.c), ang(cell.a, cell.c), ang(cell.a, cell.b))
    }

    // MARK: - Round-trip, validation, and molecule formats

    func testWritersRoundTripValidationAndMoleculeFormats() throws {
        // --- Round-trip ---
        let scene = makeSiScene()
        let cases: [(StructureExportFormat, ParseFormat)] = [
            (.xsf, .xsf),
            (.cif, .cif),
            (.poscar, .poscar),
            (.xyz, .xyz),
            (.qeInput, .pwi),
        ]
        for (format, parseAs) in cases {
            let text = try StructureWriter.write(scene, as: format)
            let url = tempURL(ext: format.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            try text.write(to: url, atomically: true, encoding: .utf8)
            let parsed = try Parser.load(url, as: parseAs)

            XCTAssertEqual(parsed.atoms.count, scene.atoms.count,
                           "\(format) atom count")
            let origZ = scene.atoms.map { $0.atomicNumber }.sorted()
            let backZ = parsed.atoms.map { $0.atomicNumber }.sorted()
            XCTAssertEqual(origZ, backZ, "\(format) atomic numbers")

            guard let origCell = scene.cell, let backCell = parsed.cell else {
                continue
            }
            let o = cellParams(origCell)
            let b = cellParams(backCell)
            XCTAssertEqual(o.a, b.a, accuracy: 1e-2, "\(format) length a")
            XCTAssertEqual(o.b, b.b, accuracy: 1e-2, "\(format) length b")
            XCTAssertEqual(o.c, b.c, accuracy: 1e-2, "\(format) length c")
            XCTAssertEqual(o.alpha, b.alpha, accuracy: 1e-2, "\(format) angle alpha")
            XCTAssertEqual(o.beta, b.beta, accuracy: 1e-2, "\(format) angle beta")
            XCTAssertEqual(o.gamma, b.gamma, accuracy: 1e-2, "\(format) angle gamma")
        }

        // --- Validation + molecule formats ---
        let h2o = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 8, label: "O"),
            Atom(coord: SIMD3(0.757, 0.586, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(-0.757, 0.586, 0), atomicNumber: 1, label: "H"),
        ]

        // Molecule: XYZ + XSF succeed; crystal formats require a cell.
        let xyz = try StructureWriter.write(atoms: h2o, cell: nil, title: "H2O",
                                            isCrystal: false, periodicDim: 0, as: .xyz)
        XCTAssertTrue(xyz.contains("O"))
        let xsf = try StructureWriter.write(atoms: h2o, cell: nil, title: "H2O",
                                            isCrystal: false, periodicDim: 0, as: .xsf)
        XCTAssertTrue(xsf.contains("ATOMS"))
        XCTAssertFalse(xsf.contains("CRYSTAL"))
        for crystal in [StructureExportFormat.cif, .poscar, .qeInput] {
            XCTAssertThrowsError(try StructureWriter.write(atoms: h2o, cell: nil, title: "H2O",
                                                           isCrystal: false, periodicDim: 0, as: crystal)) { e in
                guard case StructureWriteError.requiresCrystal = e else {
                    return XCTFail("expected requiresCrystal for \(crystal), got \(e)")
                }
            }
        }

        // Empty atoms -> .emptyAtoms for every format.
        for format in StructureExportFormat.allCases {
            XCTAssertThrowsError(try StructureWriter.write(atoms: [], cell: nil, title: "",
                                                           isCrystal: false, periodicDim: 0, as: format)) { e in
                guard case StructureWriteError.emptyAtoms = e else {
                    return XCTFail("expected emptyAtoms for \(format), got \(e)")
                }
            }
        }

        // NaN coordinate -> .nonFiniteGeometry.
        let nanAtom = [Atom(coord: SIMD3(Float.nan, 0, 0), atomicNumber: 1, label: "H")]
        for format in StructureExportFormat.allCases {
            XCTAssertThrowsError(try StructureWriter.write(atoms: nanAtom, cell: nil, title: "",
                                                           isCrystal: false, periodicDim: 0, as: format)) { e in
                guard case StructureWriteError.nonFiniteGeometry = e else {
                    return XCTFail("expected nonFiniteGeometry for \(format), got \(e)")
                }
            }
        }

        // Singular cell (zero volume) -> .singularCell for crystal formats.
        let singular = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        let oneSi = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 14, label: "Si")]
        for crystal in [StructureExportFormat.cif, .poscar, .qeInput] {
            XCTAssertThrowsError(try StructureWriter.write(atoms: oneSi, cell: singular, title: "",
                                                           isCrystal: true, periodicDim: 3, as: crystal)) { e in
                guard case StructureWriteError.singularCell = e else {
                    return XCTFail("expected singularCell for \(crystal), got \(e)")
                }
            }
        }

        // QE sanity: required keywords and ntyp == distinct species count.
        let si = makeSiScene()
        let qe = try StructureWriter.write(si, as: .qeInput)
        XCTAssertTrue(qe.contains("ibrav = 0"))
        XCTAssertTrue(qe.contains("ATOMIC_SPECIES"))
        XCTAssertTrue(qe.contains("CELL_PARAMETERS angstrom"))
        XCTAssertTrue(qe.contains("K_POINTS gamma"))
        let distinct = Set(si.atoms.map { $0.atomicNumber }).count
        XCTAssertTrue(qe.contains("ntyp = \(distinct)"))

        // label / fileExtension mappings.
        XCTAssertEqual(StructureExportFormat.xsf.label, "XSF")
        XCTAssertEqual(StructureExportFormat.xsf.fileExtension, "xsf")
        XCTAssertEqual(StructureExportFormat.cif.label, "CIF")
        XCTAssertEqual(StructureExportFormat.cif.fileExtension, "cif")
        XCTAssertEqual(StructureExportFormat.poscar.label, "POSCAR")
        XCTAssertEqual(StructureExportFormat.poscar.fileExtension, "poscar")
        XCTAssertEqual(StructureExportFormat.xyz.label, "XYZ")
        XCTAssertEqual(StructureExportFormat.xyz.fileExtension, "xyz")
        XCTAssertEqual(StructureExportFormat.qeInput.label, "QE PWscf input")
        XCTAssertEqual(StructureExportFormat.qeInput.fileExtension, "in")
    }
}
