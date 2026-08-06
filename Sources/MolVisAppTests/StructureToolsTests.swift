import simd
import XCTest
@testable import MolVisApp

/// Focused coverage for the structure-tool Scene extensions: primitive/conventional
/// transformation, elastic deformation, cluster cutting, and slab vacuum control.
final class StructureToolsTests: XCTestCase {

    // MARK: - Fixtures

    /// Diamond-cubic Si conventional cell (a = 5.43 Å): an fcc lattice with a 2-atom
    /// basis, so the conventional cell holds 8 atoms and the primitive cell holds 2.
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
        return scene
    }

    private func cellVolume(_ cell: Cell) -> Float {
        abs(dot(cell.a, cross(cell.b, cell.c)))
    }

    private func sortedCoords(_ atoms: [Atom]) -> [SIMD3<Float>] {
        atoms.map { $0.coord }.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.z < $1.z
        }
    }

    private func assertCoordsEqual(_ lhs: [SIMD3<Float>], _ rhs: [SIMD3<Float>],
                                   tolerance: Float, file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (a, b) in zip(lhs, rhs) {
            XCTAssertEqual(simd_distance(a, b), 0, accuracy: tolerance, file: file, line: line)
        }
    }

    /// Wrap a coordinate into [0, len) along each axis.
    private func wrap(_ v: SIMD3<Float>, _ cell: Cell) -> SIMD3<Float> {
        func w(_ x: Float, _ len: Float) -> Float {
            var r = x.truncatingRemainder(dividingBy: len)
            if r < 0 { r += len }
            return r
        }
        return SIMD3(w(v.x, cell.a.x), w(v.y, cell.b.y), w(v.z, cell.c.z))
    }

    /// Two coordinate sets match if one is a lattice translation of the other.
    /// spglib's standardized conventional cell may use a different origin than the
    /// input, so a direct comparison is too strict; the sets must agree modulo a
    /// single global translation.
    private func assertPeriodicCoordsEqual(_ input: [SIMD3<Float>], _ output: [SIMD3<Float>],
                                           cell: Cell, tolerance: Float,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let aSorted = input.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.z < $1.z
        }
        let bSorted = output.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.z < $1.z
        }
        XCTAssertEqual(aSorted.count, bSorted.count, file: file, line: line)
        guard let ref = aSorted.first, !aSorted.isEmpty else {
            XCTAssertTrue(bSorted.isEmpty, file: file, line: line)
            return
        }
        var matched = false
        for candidate in bSorted {
            let shift = ref - candidate
            let shifted = bSorted.map { wrap($0 + shift, cell) }.sorted {
                if $0.x != $1.x { return $0.x < $1.x }
                if $0.y != $1.y { return $0.y < $1.y }
                return $0.z < $1.z
            }
            if zip(aSorted, shifted).allSatisfy({ simd_distance($0, $1) <= tolerance }) {
                matched = true
                break
            }
        }
        XCTAssertTrue(matched, "output coords do not match input coords modulo a lattice translation",
                      file: file, line: line)
    }

    // MARK: - Primitive / conventional transforms

    func testPrimitiveConventionalTransforms() {
        let scene = makeDiamondSiScene()
        let inputVolume = cellVolume(scene.cell!)
        let inputCoords = sortedCoords(scene.atoms)

        // Primitive: 2 atoms, volume = input / 4.
        let prim = try! scene.transformed(to: .primitive).get()
        XCTAssertEqual(prim.atoms.count, 2)
        XCTAssertEqual(cellVolume(prim.cell!), inputVolume / 4, accuracy: 1e-2)
        XCTAssertTrue(prim.isCrystal)
        XCTAssertEqual(prim.periodicDim, 3)

        // Conventional from the primitive: 8 atoms, volume restored.
        let conv = try! prim.transformed(to: .conventional).get()
        XCTAssertEqual(conv.atoms.count, 8)
        XCTAssertEqual(cellVolume(conv.cell!), inputVolume, accuracy: 1e-2)

        // Cartesian positions round-trip back to the input set (modulo a lattice
        // translation, since spglib's standardized conventional origin may differ).
        assertPeriodicCoordsEqual(inputCoords, sortedCoords(conv.atoms), cell: scene.cell!, tolerance: 1e-3)

        // .input returns the same scene.
        let asInput = try! scene.transformed(to: .input).get()
        XCTAssertEqual(asInput.atoms, scene.atoms)
        XCTAssertEqual(asInput.cell, scene.cell)

        // A non-crystal (molecule) is rejected.
        var molecule = Scene()
        molecule.atoms = [Atom(coord: .zero, atomicNumber: 1, label: "H")]
        molecule.isCrystal = false
        molecule.periodicDim = 0
        switch molecule.transformed(to: .primitive) {
        case .failure(let err): XCTAssertEqual(err, .notThreeDimensionalCrystal)
        case .success: XCTFail("molecule should be rejected")
        }
    }

    // MARK: - Elastic deformation and cluster cut

    func testElasticDeformationAndClusterCut() {
        let scene = makeDiamondSiScene()
        let a: Float = 5.43

        // Uniaxial +10% along x.
        let rows: [SIMD3<Float>] = [SIMD3(1.1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let def = try! scene.deformed(byRows: rows).get()
        XCTAssertEqual(def.cell!.a.x, scene.cell!.a.x * 1.1, accuracy: 1e-3)
        XCTAssertEqual(def.cell!.b, scene.cell!.b)
        XCTAssertEqual(def.cell!.c, scene.cell!.c)
        for (before, after) in zip(scene.atoms, def.atoms) {
            XCTAssertEqual(after.coord.x, before.coord.x * 1.1, accuracy: 1e-3)
            XCTAssertEqual(after.coord.y, before.coord.y, accuracy: 1e-4)
            XCTAssertEqual(after.coord.z, before.coord.z, accuracy: 1e-4)
        }

        // Singular matrix (zero row) is rejected.
        switch scene.deformed(byRows: [SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]) {
        case .failure(let err): XCTAssertEqual(err, .singularDeformation)
        case .success: XCTFail("singular matrix should be rejected")
        }
        // NaN entry is rejected.
        switch scene.deformed(byRows: [SIMD3(.nan, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]) {
        case .failure(let err): XCTAssertEqual(err, .nonFiniteDeformation)
        case .success: XCTFail("NaN matrix should be rejected")
        }

        // Cluster cut from a 2x2x2 supercell (64 atoms).
        let superScene = scene.widenSuperCell(SuperCell(n1: 2, n2: 2, n3: 2))
        XCTAssertEqual(superScene.atoms.count, 64)
        // Off-lattice center near the middle of the 2a-wide supercell.
        let center = SIMD3<Float>(a, a, a * 0.5)
        let cluster = try! superScene.cutCluster(center: center, radius: a).get()
        XCTAssertFalse(cluster.isCrystal)
        XCTAssertNil(cluster.cell)
        XCTAssertGreaterThan(cluster.atoms.count, 0)
        XCTAssertLessThanOrEqual(cluster.atoms.count, 64)
        for atom in cluster.atoms {
            XCTAssertLessThanOrEqual(simd_distance(atom.coord, center), a + 1e-3)
        }

        // Too-small radius yields an empty cluster.
        switch superScene.cutCluster(center: center, radius: 0.01) {
        case .failure(let err): XCTAssertEqual(err, .emptyCluster)
        case .success: XCTFail("tiny radius should yield an empty cluster")
        }
    }
}
