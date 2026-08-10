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

    func testAdoptAppearanceCopiesAppearanceButNotGeometry() {
        var source = Scene()
        source.displayMode = .spaceFill
        source.atomScale = 0.7
        source.bondRadius = 0.2
        source.showCellFrame = false
        source.showAxes = false
        source.showLabels = true
        source.showBondDistances = true
        source.showScaleIndicator = true
        source.showBrillouinZone = true
        source.showStructure = false
        source.showIsoSurface = false
        source.isoLevel = 0.5
        source.isoSurfaces = [IsoSurfaceSpec(level: 0.1, colorHex: "#FF0000", sign: 1, enabled: true)]
        source.clipPlane = ClipPlane(enabled: true, h: 1, k: 0, l: 0, distance: 0.5)
        source.colorPlaneColormap = .inferno
        source.colorPlaneContourEnabled = false
        source.colorPlaneContourCount = 10
        source.volumeSlices = [VolumeSlice()]
        source.showFermiSurface = false
        source.showForces = true
        source.forceScale = 100
        source.showColorPlane = false
        source.msaaSampleCount = 4
        source.opacity = 0.8
        source.lineWidth = 2.5
        source.depthCueingStrength = 0.3
        source.aoStrength = 0.4
        source.shadowStrength = 0.5
        source.aoQuality = 3
        source.shadowQuality = 3
        source.lighting = Lighting(ambient: 0.1, diffuse: 0.9, specular: 0.5, shininess: 32, azimuth: 180, elevation: 30)
        source.lights = [SceneLightSource(azimuth: 90, elevation: 60, intensity: 2.0, colorHex: "#FF0000")]
        source.hbondSettings = HbondSettings(enabled: true, maxDistance: 3.0, minAngleDegrees: 150, colorHex: "#00FF00")
        source.molecularSurfaceSettings = MolecularSurfaceSettings(enabled: true, probeRadius: 2.0, opacity: 0.5, colorHex: "#0000FF")
        source.atomColorScheme = .coordination
        source.elementOverrides = [1: ElementOverride(colorHex: "#123456")]
        source.repetitionMode = .asymmetricUnit
        source.cellRodsEnabled = true
        source.cellRodFactor = 0.5
        source.unicolorBonds = true
        source.unicolorBondHex = "#ABCDEF"
        source.tessellationFactor = 3
        source.background = "#FFFFFF"
        source.backgroundBottom = "#808080"
        source.backgroundType = .gradient_top
        source.backgroundImagePath = "/tmp/img.png"
        source.anaglyphMode = .redCyan

        var target = Scene()
        target.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C"),
                        Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H")]
        target.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 5))
        target.selectedAtoms = [0]
        target.currentFrame = 7
        target.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")]
        target.kPathProvenance = .userEdited
        let originalAtoms = target.atoms
        let originalCell = target.cell
        let originalSelected = target.selectedAtoms
        let originalFrame = target.currentFrame
        let originalKPath = target.kPathPoints
        let originalProvenance = target.kPathProvenance

        target.adoptAppearance(from: source)

        XCTAssertEqual(target.displayMode, .spaceFill)
        XCTAssertEqual(target.atomScale, 0.7)
        XCTAssertEqual(target.bondRadius, 0.2)
        XCTAssertEqual(target.showCellFrame, false)
        XCTAssertEqual(target.showAxes, false)
        XCTAssertEqual(target.showLabels, true)
        XCTAssertEqual(target.showBondDistances, true)
        XCTAssertEqual(target.showScaleIndicator, true)
        XCTAssertEqual(target.showBrillouinZone, true)
        XCTAssertEqual(target.showStructure, false)
        XCTAssertEqual(target.showIsoSurface, false)
        XCTAssertEqual(target.isoLevel, 0.5)
        XCTAssertEqual(target.isoSurfaces.count, 1)
        XCTAssertNotNil(target.clipPlane)
        XCTAssertEqual(target.colorPlaneColormap, .inferno)
        XCTAssertEqual(target.colorPlaneContourEnabled, false)
        XCTAssertEqual(target.colorPlaneContourCount, 10)
        XCTAssertEqual(target.volumeSlices.count, 1)
        XCTAssertEqual(target.showFermiSurface, false)
        XCTAssertEqual(target.showForces, true)
        XCTAssertEqual(target.forceScale, 100)
        XCTAssertEqual(target.showColorPlane, false)
        XCTAssertEqual(target.msaaSampleCount, 4)
        XCTAssertEqual(target.opacity, 0.8)
        XCTAssertEqual(target.lineWidth, 2.5)
        XCTAssertEqual(target.depthCueingStrength, 0.3)
        XCTAssertEqual(target.aoStrength, 0.4)
        XCTAssertEqual(target.shadowStrength, 0.5)
        XCTAssertEqual(target.aoQuality, 3)
        XCTAssertEqual(target.shadowQuality, 3)
        XCTAssertEqual(target.lighting.ambient, 0.1)
        XCTAssertEqual(target.lights.count, 1)
        XCTAssertEqual(target.hbondSettings.enabled, true)
        XCTAssertEqual(target.molecularSurfaceSettings.enabled, true)
        XCTAssertEqual(target.atomColorScheme, .coordination)
        XCTAssertEqual(target.elementOverrides.count, 1)
        XCTAssertEqual(target.repetitionMode, .asymmetricUnit)
        XCTAssertEqual(target.cellRodsEnabled, true)
        XCTAssertEqual(target.cellRodFactor, 0.5)
        XCTAssertEqual(target.unicolorBonds, true)
        XCTAssertEqual(target.unicolorBondHex, "#ABCDEF")
        XCTAssertEqual(target.tessellationFactor, 3)
        XCTAssertEqual(target.background, "#FFFFFF")
        XCTAssertEqual(target.backgroundBottom, "#808080")
        XCTAssertEqual(target.backgroundType, .gradient_top)
        XCTAssertEqual(target.backgroundImagePath, "/tmp/img.png")
        XCTAssertEqual(target.anaglyphMode, .redCyan)

        XCTAssertEqual(target.atoms, originalAtoms)
        XCTAssertEqual(target.cell, originalCell)
        XCTAssertEqual(target.selectedAtoms, originalSelected)
        XCTAssertEqual(target.currentFrame, originalFrame)
        XCTAssertEqual(target.kPathPoints, originalKPath)
        XCTAssertEqual(target.kPathProvenance, originalProvenance)
    }

    func testWidenSuperCellRespectsPeriodicDim() {
        // 2D scene (periodicDim 2): a small orthorhombic cell with a couple of atoms.
        let a: Float = 3.0, b: Float = 4.0, c: Float = 15.0
        let cell = Cell(a: SIMD3(a, 0, 0), b: SIMD3(0, b, 0), c: SIMD3(0, 0, c))
        // Keep the base bond snapshot intentionally empty even though the
        // expanded geometry has a detectable C-H pair; shrink must restore []
        // rather than falling back to the widened bond list.
        let atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
                     Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H")]
        var scene = Scene()
        scene.cell = cell
        scene.atoms = atoms
        scene.isCrystal = true
        scene.periodicDim = 2
        scene.baseAtoms = atoms
        scene.baseBonds = []
        scene.preslabAtoms = atoms

        // n3 > 1 on a 2D structure must be refused (vacuum axis).
        let refused = scene.widenSuperCell(SuperCell(n1: 2, n2: 2, n3: 2))
        XCTAssertEqual(refused.atoms.count, scene.atoms.count,
                       "2D supercell with n3>1 must be refused, leaving atoms unchanged")

        // n1,n2 > 1 with n3 == 1 on a 2D structure must still expand.
        let expanded = scene.widenSuperCell(SuperCell(n1: 2, n2: 2, n3: 1))
        XCTAssertEqual(expanded.atoms.count, scene.atoms.count * 4,
                       "2D supercell along periodic axes must expand")
        XCTAssertFalse(expanded.bonds.isEmpty,
                       "expanded geometry should detect the C-H pair")
        let restored = expanded.widenSuperCell(SuperCell())
        XCTAssertTrue(restored.bonds.isEmpty,
                      "an explicitly empty base bond snapshot must survive a round trip")
    }
}
