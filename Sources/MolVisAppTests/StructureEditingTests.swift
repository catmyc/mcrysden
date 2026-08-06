import simd
import XCTest
@testable import MolVisApp

/// Focused coverage for the structure-editing Scene extensions: insert, remove,
/// substitute, displace, and lattice/cell-vector editing.
final class StructureEditingTests: XCTestCase {

    // MARK: - Fixtures

    /// Diamond-cubic Si conventional cell (a = 5.43 Å): fcc lattice with a 2-atom
    /// basis, 8 atoms total, analyzed as a complete 3D crystal.
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

    private func cellVolume(_ cell: Cell) -> Float {
        abs(simd_dot(cell.a, simd_cross(cell.b, cell.c)))
    }

    // MARK: - Insert / remove / substitute / displace

    func testInsertRemoveSubstituteDisplace() {
        let scene = makeDiamondSiScene()
        let a: Float = 5.43

        // Insert Cartesian: count +1, last atom at the requested coordinate.
        let ins = try! scene.insertingAtom(element: 14, label: nil,
                                           position: SIMD3(2, 2, 2), fractional: false).get()
        XCTAssertEqual(ins.atoms.count, 9)
        XCTAssertEqual(ins.atoms.last!.coord, SIMD3(2, 2, 2))
        XCTAssertEqual(ins.baseAtoms, ins.atoms)

        // Insert fractional: (0.5, 0.5, 0.5) → Cartesian (a/2, a/2, a/2).
        let insF = try! scene.insertingAtom(element: 8, label: nil,
                                            position: SIMD3(0.5, 0.5, 0.5), fractional: true).get()
        XCTAssertEqual(insF.atoms.count, 9)
        let half = SIMD3<Float>(a / 2, a / 2, a / 2)
        XCTAssertEqual(simd_distance(insF.atoms.last!.coord, half), 0, accuracy: 1e-3)

        // Invalid element (0 and 119) fails.
        switch scene.insertingAtom(element: 0, label: nil, position: SIMD3(0, 0, 0), fractional: false) {
        case .failure(let err): XCTAssertEqual(err, .invalidElement(0))
        case .success: XCTFail("element 0 should be rejected")
        }
        switch scene.insertingAtom(element: 119, label: nil, position: SIMD3(0, 0, 0), fractional: false) {
        case .failure(let err): XCTAssertEqual(err, .invalidElement(119))
        case .success: XCTFail("element 119 should be rejected")
        }
        // Non-finite position fails.
        switch scene.insertingAtom(element: 1, label: nil, position: SIMD3(.nan, 0, 0), fractional: false) {
        case .failure(let err): XCTAssertEqual(err, .nonFinitePosition)
        case .success: XCTFail("NaN position should be rejected")
        }

        // Remove two atoms: count -2, indices shift (new atoms[0] == old atoms[1]).
        let removed = try! scene.removingAtoms(at: [0, 2]).get()
        XCTAssertEqual(removed.atoms.count, 6)
        XCTAssertEqual(removed.atoms[0].coord, scene.atoms[1].coord)
        XCTAssertEqual(removed.atoms[1].coord, scene.atoms[3].coord)

        // Duplicate indices are deduped safely (removing [0,0,2] == removing [0,2]).
        let deduped = try! scene.removingAtoms(at: [0, 0, 2]).get()
        XCTAssertEqual(deduped.atoms.count, 6)
        XCTAssertEqual(deduped.atoms, removed.atoms)

        // Removing all atoms fails.
        let allIndices = Array(0..<scene.atoms.count)
        switch scene.removingAtoms(at: allIndices) {
        case .failure(let err): XCTAssertEqual(err, .wouldRemoveAllAtoms)
        case .success: XCTFail("removing every atom should be rejected")
        }
        // Empty selection fails.
        switch scene.removingAtoms(at: []) {
        case .failure(let err): XCTAssertEqual(err, .noSelection)
        case .success: XCTFail("empty selection should be rejected")
        }

        // Substitute species at two indices: those atoms become O (Z=8).
        let sub = try! scene.substitutingAtoms(at: [1, 3], element: 8, label: nil).get()
        XCTAssertEqual(sub.atoms.count, 8)
        XCTAssertEqual(sub.atoms[1].atomicNumber, 8)
        XCTAssertEqual(sub.atoms[1].label, "O")
        XCTAssertEqual(sub.atoms[3].atomicNumber, 8)
        XCTAssertEqual(sub.atoms[3].coord, scene.atoms[3].coord)  // coordinate unchanged
        // Invalid element fails.
        switch scene.substitutingAtoms(at: [0], element: 0, label: nil) {
        case .failure(let err): XCTAssertEqual(err, .invalidElement(0))
        case .success: XCTFail("element 0 should be rejected")
        }

        // Displace all atoms: every x + 0.5.
        let dispAll = try! scene.displacingAtoms(at: nil, by: SIMD3(0.5, 0, 0)).get()
        for (before, after) in zip(scene.atoms, dispAll.atoms) {
            XCTAssertEqual(after.coord.x, before.coord.x + 0.5, accuracy: 1e-4)
            XCTAssertEqual(after.coord.y, before.coord.y, accuracy: 1e-4)
            XCTAssertEqual(after.coord.z, before.coord.z, accuracy: 1e-4)
        }
        // Displace a selection: only those move.
        let dispSel = try! scene.displacingAtoms(at: [0, 1], by: SIMD3(0, 0, 0.5)).get()
        XCTAssertEqual(dispSel.atoms[0].coord.z, scene.atoms[0].coord.z + 0.5, accuracy: 1e-4)
        XCTAssertEqual(dispSel.atoms[2].coord.z, scene.atoms[2].coord.z, accuracy: 1e-4)
        // NaN delta fails.
        switch scene.displacingAtoms(at: nil, by: SIMD3(.nan, 0, 0)) {
        case .failure(let err): XCTAssertEqual(err, .nonFiniteDisplacement)
        case .success: XCTFail("NaN delta should be rejected")
        }
        // Huge delta fails.
        switch scene.displacingAtoms(at: nil, by: SIMD3(1e5, 0, 0)) {
        case .failure(let err): XCTAssertEqual(err, .excessiveDisplacement)
        case .success: XCTFail("huge delta should be rejected")
        }

        // Non-pristine (supercell) is not editable.
        let widened = scene.widenSuperCell(SuperCell(n1: 2, n2: 2, n3: 2))
        XCTAssertFalse(widened.isStructureEditable)
        switch widened.insertingAtom(element: 1, label: nil, position: SIMD3(0, 0, 0), fractional: false) {
        case .failure(let err):
            XCTAssertEqual(err, .notEditable("Editing disabled: supercell active. "
                + "Reset the supercell to 1×1×1 to edit atom coordinates."))
        case .success: XCTFail("supercell should not be editable")
        }
        switch widened.removingAtoms(at: [0]) {
        case .failure(let err):
            XCTAssertEqual(err, .notEditable("Editing disabled: supercell active. "
                + "Reset the supercell to 1×1×1 to edit atom coordinates."))
        case .success: XCTFail("supercell should not be editable")
        }
    }

    // MARK: - Lattice parameter editing

    func testLatticeParameterEditing() {
        let scene = makeDiamondSiScene()
        let a: Float = 5.43
        let oldVolume = cellVolume(scene.cell!)

        // Edit a only: new a = 6.0, b/c unchanged, fractional coords preserved.
        let editedA = try! scene.editingLattice(a: 6.0, b: nil, c: nil,
                                                alpha: nil, beta: nil, gamma: nil).get()
        XCTAssertEqual(simd_length(editedA.cell!.a), 6.0, accuracy: 1e-3)
        XCTAssertEqual(simd_length(editedA.cell!.b), a, accuracy: 1e-3)
        XCTAssertEqual(simd_length(editedA.cell!.c), a, accuracy: 1e-3)
        for (before, after) in zip(scene.atoms, editedA.atoms) {
            let fBefore = scene.fractionalCoord(before.coord)!
            let fAfter = editedA.fractionalCoord(after.coord)!
            XCTAssertEqual(fAfter.x, fBefore.x, accuracy: 1e-3)
            XCTAssertEqual(fAfter.y, fBefore.y, accuracy: 1e-3)
            XCTAssertEqual(fAfter.z, fBefore.z, accuracy: 1e-3)
        }
        XCTAssertEqual(cellVolume(editedA.cell!), oldVolume * (6.0 / a), accuracy: 1e-2)

        // Rhombohedral: a = b = c = 5, alpha = beta = gamma = 60.
        let rhom = try! scene.editingLattice(a: 5, b: 5, c: 5,
                                             alpha: 60, beta: 60, gamma: 60).get()
        let p = rhom.cellParameters!
        XCTAssertEqual(p.alpha, 60, accuracy: 1e-2)
        XCTAssertEqual(p.beta, 60, accuracy: 1e-2)
        XCTAssertEqual(p.gamma, 60, accuracy: 1e-2)
        let cos60 = cos(60 * Float.pi / 180)
        let expectedVol = 125 * sqrt(1 - 3 * cos60 * cos60 + 2 * cos60 * cos60 * cos60)
        XCTAssertEqual(cellVolume(rhom.cell!), expectedVol, accuracy: 1e-2)
        for (before, after) in zip(scene.atoms, rhom.atoms) {
            let fBefore = scene.fractionalCoord(before.coord)!
            let fAfter = rhom.fractionalCoord(after.coord)!
            XCTAssertEqual(fAfter.x, fBefore.x, accuracy: 1e-3)
            XCTAssertEqual(fAfter.y, fBefore.y, accuracy: 1e-3)
            XCTAssertEqual(fAfter.z, fBefore.z, accuracy: 1e-3)
        }

        // Invalid lattice parameters fail.
        switch scene.editingLattice(a: 0, b: nil, c: nil, alpha: nil, beta: nil, gamma: nil) {
        case .failure(let err): XCTAssertEqual(err, .invalidLattice("lattice constants must be positive and at most 10000 Å"))
        case .success: XCTFail("a = 0 should be rejected")
        }
        switch scene.editingLattice(a: 5, b: 5, c: 5, alpha: 180, beta: 60, gamma: 60) {
        case .failure(let err): XCTAssertEqual(err, .invalidLattice("lattice angles must be between 0 and 180 degrees"))
        case .success: XCTFail("alpha = 180 should be rejected")
        }
        switch scene.editingLattice(a: .nan, b: nil, c: nil, alpha: nil, beta: nil, gamma: nil) {
        case .failure(let err): XCTAssertEqual(err, .invalidLattice("lattice parameters must be finite"))
        case .success: XCTFail("NaN should be rejected")
        }

        // Degenerate cell vectors fail.
        switch scene.editingCellVectors(SIMD3(0, 0, 0), SIMD3(0, 6, 0), SIMD3(0, 0, 6)) {
        case .failure(let err): XCTAssertEqual(err, .invalidLattice("cell vectors are linearly dependent"))
        case .success: XCTFail("zero vector should be rejected")
        }
        // Valid cell-vector edit: a = (6,0,0), fractional coords preserved.
        let cv = try! scene.editingCellVectors(SIMD3(6, 0, 0), SIMD3(0, 6, 0), SIMD3(0, 0, 6)).get()
        XCTAssertEqual(cv.cell!.a, SIMD3(6, 0, 0))
        for (before, after) in zip(scene.atoms, cv.atoms) {
            let fBefore = scene.fractionalCoord(before.coord)!
            let fAfter = cv.fractionalCoord(after.coord)!
            XCTAssertEqual(fAfter.x, fBefore.x, accuracy: 1e-3)
            XCTAssertEqual(fAfter.y, fBefore.y, accuracy: 1e-3)
            XCTAssertEqual(fAfter.z, fBefore.z, accuracy: 1e-3)
        }

        // cellParameters: cubic cell.
        let cubic = scene.cellParameters!
        XCTAssertEqual(cubic.a, a, accuracy: 1e-3)
        XCTAssertEqual(cubic.b, a, accuracy: 1e-3)
        XCTAssertEqual(cubic.c, a, accuracy: 1e-3)
        XCTAssertEqual(cubic.alpha, 90, accuracy: 1e-2)
        XCTAssertEqual(cubic.beta, 90, accuracy: 1e-2)
        XCTAssertEqual(cubic.gamma, 90, accuracy: 1e-2)

        // cellParameters: monoclinic cell (a along x, b in xy-plane, c tilted).
        let mono = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(1, 0, 6))
        var monoScene = Scene()
        monoScene.cell = mono
        let mp = monoScene.cellParameters!
        XCTAssertEqual(mp.a, 4, accuracy: 1e-3)
        XCTAssertEqual(mp.b, 5, accuracy: 1e-3)
        XCTAssertEqual(mp.c, sqrt(37), accuracy: 1e-3)
        XCTAssertEqual(mp.gamma, 90, accuracy: 1e-2)  // a along x, b along y
    }
}
