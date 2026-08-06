import simd
import XCTest
@testable import MolVisApp

/// Coverage for the controller/UI wiring of structure editing + export: the
/// unified undo group, atom/defect workflows, lattice edit, gating, and export.
final class StructureEditingControllerTests: XCTestCase {

    // MARK: - Fixtures

    /// Diamond-cubic Si conventional cell (a = 5.43 Å): fcc lattice + 2-atom basis.
    private func makeDiamondSiScene() -> Scene {
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
        scene.bonds = Scene.rebond(atoms, cell: cell, isCrystal: true, periodicDim: 3)
        scene.baseAtoms = atoms
        scene.baseBonds = scene.bonds
        scene.preslabAtoms = atoms
        scene.crystalSymmetry = CrystalSymmetryAnalyzer.analyze(
            cell: cell, atoms: atoms, isCrystal: true, periodicDim: 3)
        scene.installCanonicalPath(cell: cell)
        return scene
    }

    private func fractionalCoords(_ scene: Scene) -> [SIMD3<Float>] {
        scene.atoms.map { scene.fractionalCoord($0.coord) ?? SIMD3(0, 0, 0) }
    }

    // MARK: - Atom editing, lattice, gating + export

    @MainActor
    func testAtomEditingLatticeGatingAndExport() {
        let scene = makeDiamondSiScene()
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(scene, from: nil, format: nil, frameIndex: 0)
        XCTAssertEqual(controller.scene.atoms.count, 8)

        // Insert O at fractional (0.5, 0.5, 0.5): count +1, last atom Z = 8.
        XCTAssertTrue(controller.insertAtom(element: 8, position: SIMD3(0.5, 0.5, 0.5), fractional: true))
        XCTAssertEqual(controller.scene.atoms.count, 9)
        XCTAssertEqual(controller.scene.atoms.last!.atomicNumber, 8)

        // Remove the first two atoms: count -2.
        controller.scene.selectedAtoms = [0, 1]
        XCTAssertTrue(controller.removeSelectedAtoms())
        XCTAssertEqual(controller.scene.atoms.count, 7)

        // Substitute a fresh selection to O.
        controller.scene.selectedAtoms = [0, 1]
        XCTAssertTrue(controller.substituteSelectedAtoms(element: 8))
        XCTAssertEqual(controller.scene.atoms[0].atomicNumber, 8)
        XCTAssertEqual(controller.scene.atoms[1].atomicNumber, 8)

        // Displace all atoms: every x + 0.5.
        let xsBefore = controller.scene.atoms.map { $0.coord.x }
        XCTAssertTrue(controller.displaceAtoms(indices: nil, by: SIMD3(0.5, 0, 0)))
        for (before, atom) in zip(xsBefore, controller.scene.atoms) {
            XCTAssertEqual(atom.coord.x, before + 0.5, accuracy: 1e-4)
        }

        // Lattice edit: a -> 6.0. Fractional coords preserved, cell a.x == 6.0.
        let fracBefore = fractionalCoords(controller.scene)
        controller.state.latticeA = 6.0
        XCTAssertTrue(controller.applyLatticeParameters())
        XCTAssertEqual(controller.scene.cell!.a.x, 6.0, accuracy: 1e-3)
        let fracAfter = fractionalCoords(controller.scene)
        for (before, after) in zip(fracBefore, fracAfter) {
            XCTAssertEqual(after.x, before.x, accuracy: 1e-3)
            XCTAssertEqual(after.y, before.y, accuracy: 1e-3)
            XCTAssertEqual(after.z, before.z, accuracy: 1e-3)
        }

        // Reset mirrors the (edited) cell back into the lattice fields.
        controller.state.latticeA = 1  // deliberately wrong
        controller.resetLatticeParameters()
        XCTAssertEqual(controller.state.latticeA, 6.0, accuracy: 1e-3)

        // A user-edited k-path survives a lattice edit: provenance is preserved
        // and the route is remapped through Cartesian reciprocal space (not
        // regenerated from the new cell).
        controller.scene.kPathProvenance = .userEdited
        controller.scene.kPathSignature = nil
        controller.scene.kPathPoints = [KPoint(SIMD3(0, 0, 0), "G"), KPoint(SIMD3(0.5, 0.5, 0.5), "X")]
        controller.scene.kPathBreaks = []
        controller.state.latticeA = 7.0
        XCTAssertTrue(controller.applyLatticeParameters())
        XCTAssertEqual(controller.scene.kPathProvenance, .userEdited)
        XCTAssertEqual(controller.scene.kPathPoints.count, 2)
        XCTAssertEqual(controller.scene.kPathPoints[0].label, "G")
        XCTAssertEqual(controller.scene.kPathPoints[1].label, "X")

        // Invalid element symbol is rejected with a clear status.
        controller.state.defectElementSymbol = "Xx"
        XCTAssertFalse(controller.insertInterstitialFromState())
        XCTAssertTrue(controller.state.structureEditStatusText.contains("Unknown"))

        // Non-pristine (supercell) geometry: editing is disabled and rejected.
        let widened = scene.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertFalse(widened.isStructureEditable)
        controller.loadFile(widened, from: nil, format: nil, frameIndex: 0)
        controller.scene.selectedAtoms = [0, 1]
        XCTAssertFalse(controller.removeSelectedAtoms())
        XCTAssertTrue(controller.state.structureEditStatusText.contains("supercell")
            || controller.state.structureEditStatusText.contains("Editing disabled"))

        // Export text round-trips per format.
        let fccController = MainWindowController(scene: Scene(), showWindow: false)
        fccController.loadFile(scene, from: nil, format: nil, frameIndex: 0)
        let xsf = try! fccController.structureExportText(.xsf)
        XCTAssertTrue(xsf.contains("CRYSTAL"))
        XCTAssertTrue(xsf.contains("PRIMVEC"))
        let qe = try! fccController.structureExportText(.qeInput)
        XCTAssertTrue(qe.contains("ibrav = 0"))

        // Molecule (no cell): CIF export throws.
        var mol = Scene()
        mol.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 8, label: "O"),
                     Atom(coord: SIMD3(0.96, 0, 0), atomicNumber: 1, label: "H")]
        let molController = MainWindowController(scene: Scene(), showWindow: false)
        molController.loadFile(mol, from: nil, format: nil, frameIndex: 0)
        XCTAssertThrowsError(try molController.structureExportText(.cif))
    }
}
