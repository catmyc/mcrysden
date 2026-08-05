import Foundation
import simd
import XCTest
@testable import MolVisApp

final class SceneTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
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

        let geo = try Scene(loaded: Parser.load(geometryURL, as: .fhi))
        XCTAssertEqual(geo.isCrystal, true)
        XCTAssertEqual(geo.atoms.count, 3)
        XCTAssertNotNil(geo.cell)
        XCTAssertEqual(geo.atoms[0].atomicNumber, 14)
        XCTAssertEqual(geo.atoms[2].atomicNumber, 1)

        // A file with ONLY Cartesian atoms must parse as a non-crystal molecule.
        let cartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cart-\(UUID().uuidString).in")
        defer { try? FileManager.default.removeItem(at: cartURL) }
        try """
        atom   0.0   0.0   0.0   H
        atom   1.0   0.0   0.0   H
        """.write(to: cartURL, atomically: true, encoding: .utf8)
        let cart = try Scene(loaded: Parser.load(cartURL, as: .fhi))
        XCTAssertEqual(cart.isCrystal, false)
        XCTAssertEqual(cart.atoms.count, 2)

        // VASP POSCAR-style parsing.
        let poscarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("poscar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: poscarURL) }
        try """
        Si2
        1.0
        5.43 0.0 0.0
        0.0 5.43 0.0
        0.0 0.0 5.43
        Si
        2
        direct
        0.0 0.0 0.0
        0.25 0.25 0.25
        """.write(to: poscarURL, atomically: true, encoding: .utf8)
        let poscar = try Scene(loaded: Parser.load(poscarURL, as: .poscar))
        XCTAssertEqual(poscar.isCrystal, true)
        XCTAssertEqual(poscar.atoms.count, 2)
        XCTAssertEqual(poscar.atoms[0].atomicNumber, 14)

        // FHI-aims parsing.
        let aimsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aims-\(UUID().uuidString).in")
        defer { try? FileManager.default.removeItem(at: aimsURL) }
        try """
        lattice_vector 4.0 0.0 0.0
        lattice_vector 0.0 4.0 0.0
        lattice_vector 0.0 0.0 4.0
        atom_frac 0.0 0.0 0.0 Si
        atom_frac 0.5 0.5 0.5 Si
        """.write(to: aimsURL, atomically: true, encoding: .utf8)
        let aims = try Scene(loaded: Parser.load(aimsURL, as: .fhi))
        XCTAssertEqual(aims.isCrystal, true)
        XCTAssertEqual(aims.atoms.count, 2)
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
        // --- Supercell/slab/malformed-input safety (merged) ---
        do {

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
        XCTAssertEqual(overflow.atoms.count, base.atoms.count,
                       "overflowing supercell must be refused, leaving atoms unchanged")

        // Malformed input must not trap — a zero-length lattice vector.
        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).in")
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        try "atom 0 0 0 H\n".write(to: emptyURL, atomically: true, encoding: .utf8)
        XCTAssertNoThrow(try Parser.load(emptyURL, as: .fhi))
        }   // end merged block

    }
}
