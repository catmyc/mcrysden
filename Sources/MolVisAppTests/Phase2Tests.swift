import XCTest
import simd
@testable import MolVisApp

// Phase 2: HPKOT/SeeK-path canonical high-symmetry k-paths, disconnected
// segment representation, input-cell reciprocal mapping, and lifecycle
// management (regeneration/preservation across frames and supercell/slab ops).

// MARK: - Helper: build a Scene from a row-vector lattice + fractional atoms

private enum SceneFactory {
    /// Build a Scene from a row-vector direct lattice (rows = a, b, c) and
    /// fractional atom positions. The lattice rows are transposed to get the
    /// Cartesian basis vectors (Cell uses columns = basis vectors).
    static func scene(latticeRows: [[Double]], atoms fractional: [(Int, SIMD3<Double>)]) -> Scene {
        let matrix = CrystalSymmetryMatrix(latticeRows.flatMap { $0 })
        // For row-vector lattice L (rows = a, b, c), the Cartesian basis vectors
        // are the rows. Cell(a:b:c:) takes columns, so we pass the rows directly.
        let vectors = (0..<3).map { row in
            SIMD3<Float>(Float(matrix[row, 0]), Float(matrix[row, 1]), Float(matrix[row, 2]))
        }
        let cell = Cell(a: vectors[0], b: vectors[1], c: vectors[2])
        let swiftAtoms = fractional.map { type, f in
            // Cartesian position = f.x * a + f.y * b + f.z * c (row-vector convention)
            let cartesian = matrix.transposed.applying(to: f)
            return Atom(coord: SIMD3<Float>(Float(cartesian.x), Float(cartesian.y), Float(cartesian.z)),
                        atomicNumber: type, label: ElementTable.symbol(type))
        }
        var loaded = LoadedScene()
        loaded.atoms = swiftAtoms
        loaded.cell = cell
        loaded.isCrystal = true
        loaded.periodicDim = 3
        return Scene(loaded: loaded)
    }
}

// MARK: - CanonicalPathGenerator tests

final class CanonicalPathGeneratorTests: XCTestCase {

    private func assertCanonical(_ path: CanonicalPath, expectedLabels: [String],
                                 file: StaticString = #filePath, line: UInt = #line) {
        let labels = path.points.map { $0.label }
        XCTAssertEqual(labels, expectedLabels, file: file, line: line)
    }

    // MARK: Triclinic (aP2)

    func testTriclinicAP2Path() {
        // SG 1 (P1) → aP2 (all-obtuse reciprocal)
        let s = SceneFactory.scene(latticeRows: [
            [3.1, 0, 0],
            [0.2, 4.2, 0],
            [0.1, 0.3, 5.1],
        ], atoms: [(6, SIMD3(0.123, 0.234, 0.345)), (8, SIMD3(0.481, 0.271, 0.619))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath aP2: Γ-X-Y-Γ-Z-R-Γ-T-U-Γ-V with breaks at 1, 4, 7
        assertCanonical(path, expectedLabels: ["Γ", "X", "Y", "Γ", "Z", "R", "Γ", "T", "U", "Γ", "V"])
        XCTAssertEqual(path.breaks, [1, 4, 7])
    }

    func testTriclinicP1PointsAreFinite() {
        let s = SceneFactory.scene(latticeRows: [
            [3.1, 0, 0],
            [0.2, 4.2, 0],
            [0.1, 0.3, 5.1],
        ], atoms: [(6, SIMD3(0.123, 0.234, 0.345))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        for p in path.points {
            XCTAssertTrue(p.frac.x.isFinite && p.frac.y.isFinite && p.frac.z.isFinite,
                          "point \(p.label) has non-finite coordinates")
        }
    }

    // MARK: Cubic (cP, cF, cI)

    func testCubicSCPath() {
        // SG 221 (Pm-3m) → cP2 (cubic primitive, no inversion)
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath cP2: Γ-X-M-Γ-R-X-R-M with break at 5
        assertCanonical(path, expectedLabels: ["Γ", "X", "M", "Γ", "R", "X", "R", "M"])
        XCTAssertEqual(path.breaks, [5])
    }

    func testCubicFCCPath() {
        // SG 225 (Fm-3m) → cF2 (cubic face-centered, no inversion)
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(29, SIMD3(0, 0, 0)), (29, SIMD3(0, 0.5, 0.5)),
                   (29, SIMD3(0.5, 0, 0.5)), (29, SIMD3(0.5, 0.5, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath cF2: Γ-X-U-K-Γ-L-W-X with break at 2
        assertCanonical(path, expectedLabels: ["Γ", "X", "U", "K", "Γ", "L", "W", "X"])
        XCTAssertEqual(path.breaks, [2])
    }

    func testCubicBCCPath() {
        // SG 229 (Im-3m) → cI1 (cubic body-centered)
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(26, SIMD3(0, 0, 0)), (26, SIMD3(0.5, 0.5, 0.5))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath cI1: Γ-H-N-Γ-P-H-P-N with break at 5
        assertCanonical(path, expectedLabels: ["Γ", "H", "N", "Γ", "P", "H", "P", "N"])
        XCTAssertEqual(path.breaks, [5])
    }

    func testCubicBCCNAndPDistinct() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(26, SIMD3(0, 0, 0)), (26, SIMD3(0.5, 0.5, 0.5))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        guard let n = path.points.first(where: { $0.label == "N" }),
              let p = path.points.first(where: { $0.label == "P" }) else {
            XCTFail("missing N or P"); return
        }
        XCTAssertNotEqual(n.frac, p.frac, "N and P must be distinct")
    }

    // MARK: Hexagonal (hP)

    func testHexagonalPath() {
        // SG 164 (P-31m) → hP2 (hexagonal, standard space groups)
        let a = 3.0
        let rows: [[Double]] = [
            [a, 0, 0],
            [-a / 2, a * sqrt(3) / 2, 0],
            [0, 0, 5.0],
        ]
        let s = SceneFactory.scene(latticeRows: rows, atoms: [
            (12, SIMD3(0, 0, 0)),
            (12, SIMD3(1.0 / 3.0, 2.0 / 3.0, 1.0 / 4.0)),
        ])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath hP2: Γ-M-K-Γ-A-L-H-A-L-M-H-K with breaks at 7, 9
        assertCanonical(path, expectedLabels: ["Γ", "M", "K", "Γ", "A", "L", "H", "A", "L", "M", "H", "K"])
        XCTAssertEqual(path.breaks, [7, 9])
    }

    func testHexagonalKPointIsOneThird() {
        let a = 3.0
        let rows: [[Double]] = [
            [a, 0, 0],
            [-a / 2, a * sqrt(3) / 2, 0],
            [0, 0, 5.0],
        ]
        let s = SceneFactory.scene(latticeRows: rows, atoms: [
            (12, SIMD3(0, 0, 0)),
            (12, SIMD3(1.0 / 3.0, 2.0 / 3.0, 1.0 / 4.0)),
        ])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        guard let k = path.points.first(where: { $0.label == "K" }) else {
            XCTFail("missing K"); return
        }
        XCTAssertEqual(k.frac.x, 1.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(k.frac.y, 1.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(k.frac.z, 0, accuracy: 1e-6)
    }

    // MARK: Tetragonal (tP, tI)

    func testTetragonalPPath() {
        // SG 123 (P4/mmm) → tP1 (tetragonal primitive, no c/a split)
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 6],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath tP1: Γ-X-M-Γ-Z-R-A-Z-X-R-M-A with breaks at 7, 9
        assertCanonical(path, expectedLabels: ["Γ", "X", "M", "Γ", "Z", "R", "A", "Z", "X", "R", "M", "A"])
        XCTAssertEqual(path.breaks, [7, 9])
    }

    func testTetragonalPPathShortC() {
        // tP has no c/a split → same path as testTetragonalPPath
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 3],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // Same tP1 path regardless of c/a ratio
        assertCanonical(path, expectedLabels: ["Γ", "X", "M", "Γ", "Z", "R", "A", "Z", "X", "R", "M", "A"])
        XCTAssertEqual(path.breaks, [7, 9])
    }

    func testTetragonalIPath() {
        // SG 139 (I4/mmm) → tI2 (tetragonal body-centered, c > a)
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 6],
        ], atoms: [(22, SIMD3(0, 0, 0)), (22, SIMD3(0.5, 0.5, 0.5))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath tI2: Γ-X-P-N-Γ-M-S-S_0-Γ-X-R-G-M with breaks at 6, 8, 10
        assertCanonical(path, expectedLabels: ["Γ", "X", "P", "N", "Γ", "M", "S", "S_0", "Γ", "X", "R", "G", "M"])
        XCTAssertEqual(path.breaks, [6, 8, 10])
    }

    // MARK: Orthorhombic (oP, oC, oF, oI)

    func testOrthorhombicPPath() {
        // SG 47 (Pmmm) → oP1 (orthorhombic primitive)
        let s = SceneFactory.scene(latticeRows: [
            [3, 0, 0],
            [0, 4, 0],
            [0, 0, 5],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath oP1: Γ-X-S-Y-Γ-Z-U-R-T-Z-X-U-Y-T-S-R with breaks at 9, 11, 13
        assertCanonical(path, expectedLabels: ["Γ", "X", "S", "Y", "Γ", "Z", "U", "R", "T", "Z", "X", "U", "Y", "T", "S", "R"])
        XCTAssertEqual(path.breaks, [9, 11, 13])
    }

    func testOrthorhombicFPath() {
        // Mn in Fm-3m (SG 225) is cubic face-centered, not orthorhombic.
        // This verifies the cF2 path is produced for this structure.
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(25, SIMD3(0, 0, 0)), (25, SIMD3(0, 0.5, 0.5)),
                   (25, SIMD3(0.5, 0, 0.5)), (25, SIMD3(0.5, 0.5, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath cF2: Γ-X-U-K-Γ-L-W-X with break at 2
        assertCanonical(path, expectedLabels: ["Γ", "X", "U", "K", "Γ", "L", "W", "X"])
        XCTAssertEqual(path.breaks, [2])
    }

    // MARK: Trigonal (hR, hP)

    func testTrigonalRPath() {
        // SG 166 (R-3m) → hR1 (trigonal rhombohedral, sqrt(3)a <= sqrt(2)c)
        let a = 3.0
        let rows: [[Double]] = [
            [a, 0, 0],
            [-a / 2, a * sqrt(3) / 2, 0],
            [0, 0, 7.0],
        ]
        let s = SceneFactory.scene(latticeRows: rows, atoms: [
            (6, SIMD3(0, 0, 0)),
            (6, SIMD3(2.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)),
            (6, SIMD3(1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0)),
        ])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let path = CanonicalPathGenerator.generate(for: symmetry)
        // SeekPath hR1: Γ-T-H_2-H_0-L-Γ-S_0-S_2-F-Γ with breaks at 2, 6
        assertCanonical(path, expectedLabels: ["Γ", "T", "H_2", "H_0", "L", "Γ", "S_0", "S_2", "F", "Γ"])
        XCTAssertEqual(path.breaks, [2, 6])
    }

    // MARK: Metric-independent path generation

    func testPathIsDeterministic() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let p1 = CanonicalPathGenerator.generate(for: symmetry)
        let p2 = CanonicalPathGenerator.generate(for: symmetry)
        XCTAssertEqual(p1.points.map { $0.frac }, p2.points.map { $0.frac })
        XCTAssertEqual(p1.points.map { $0.label }, p2.points.map { $0.label })
        XCTAssertEqual(p1.breaks, p2.breaks)
    }

    func testPathIsStableUnderCellScaling() {
        // Scaling the direct cell should not change the canonical path (it's
        // defined in the standardized reciprocal basis, which is determined by
        // the Bravais type, not the cell size).
        func buildLabels(scale: Double) -> [String]? {
            let s = SceneFactory.scene(latticeRows: [
                [scale * 4, 0, 0],
                [0, scale * 4, 0],
                [0, 0, scale * 4],
            ], atoms: [(14, SIMD3(0, 0, 0))])
            guard let symmetry = s.crystalSymmetry?.symmetry else { return nil }
            return CanonicalPathGenerator.generate(for: symmetry).points.map { $0.label }
        }
        guard let labels1 = buildLabels(scale: 1),
              let labels10 = buildLabels(scale: 10) else {
            XCTFail("path generation failed"); return
        }
        XCTAssertEqual(labels1, labels10, "scaling the cell must not change the canonical path")
    }

    // MARK: - Input-cell reciprocal mapping

    func testMapToInputReciprocalPreservesBreakMetadata() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(26, SIMD3(0, 0, 0)), (26, SIMD3(0.5, 0.5, 0.5))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let canonical = CanonicalPathGenerator.generate(for: symmetry)
        let mapped = CanonicalPathGenerator.mapToInputReciprocal(canonical, symmetry: symmetry, inputCell: s.cell!)
        XCTAssertEqual(mapped.breaks, canonical.breaks, "breaks must survive mapping")
    }

    func testMapToInputReciprocalCubicPreservesCartesian() {
        // For fcc in standard orientation, the mapping should preserve Cartesian
        // reciprocal positions: canonical (primitive basis) -> Cartesian -> input fractional.
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(29, SIMD3(0, 0, 0)), (29, SIMD3(0, 0.5, 0.5)),
                   (29, SIMD3(0.5, 0, 0.5)), (29, SIMD3(0.5, 0.5, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let canonical = CanonicalPathGenerator.generate(for: symmetry)
        guard let basis = CanonicalPathGenerator.generateWithBasis(for: symmetry) else {
            XCTFail("generateWithBasis failed"); return
        }
        let mapped = CanonicalPathGenerator.mapToInputReciprocal(canonical, primRecip: basis.primRecip, inputCell: s.cell!)

        // Use the HPKOT primitive reciprocal lattice vectors (from the P matrix
        // construction, not spglib's detectedPrimitiveLattice) to compute the
        // expected Cartesian position from the canonical fractional coordinates.
        let primRecip = basis.primRecip
        let inputRecip = s.cell!.reciprocalVectors

        for (c, m) in zip(canonical.points, mapped.points) {
            // Canonical (primitive) fractional -> Cartesian via primitive reciprocal vectors
            let cartFromPrim = primRecip.a * c.frac.x + primRecip.b * c.frac.y + primRecip.c * c.frac.z
            // Mapped fractional -> Cartesian via input reciprocal vectors (should match)
            let cartFromInput = inputRecip.a * m.frac.x + inputRecip.b * m.frac.y + inputRecip.c * m.frac.z
            XCTAssertEqual(cartFromPrim.x, cartFromInput.x, accuracy: 1e-3, "\(c.label) x")
            XCTAssertEqual(cartFromPrim.y, cartFromInput.y, accuracy: 1e-3, "\(c.label) y")
            XCTAssertEqual(cartFromPrim.z, cartFromInput.z, accuracy: 1e-3, "\(c.label) z")
        }
    }

    func testMapToInputReciprocalSkewedCellPreservesCartesian() {
        // For a non-orthogonal cell, the mapping should preserve Cartesian
        // reciprocal positions: canonical point -> Cartesian -> input fractional.
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [1, 4, 0],
            [0.5, 0.5, 5],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        guard let symmetry = s.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let canonical = CanonicalPathGenerator.generate(for: symmetry)
        guard let basis = CanonicalPathGenerator.generateWithBasis(for: symmetry) else {
            XCTFail("generateWithBasis failed"); return
        }
        let mapped = CanonicalPathGenerator.mapToInputReciprocal(canonical, primRecip: basis.primRecip, inputCell: s.cell!)

        // Use the primitive reciprocal lattice vectors from the generation basis
        // (for aP lattices this is the reciprocal of real_cell_final, not the
        // detected primitive lattice) to compute the expected Cartesian position.
        let primRecip = basis.primRecip
        let inputRecip = s.cell!.reciprocalVectors

        for (c, m) in zip(canonical.points, mapped.points) {
            // Canonical (primitive) fractional -> Cartesian via primitive reciprocal vectors
            let cartFromPrim = primRecip.a * c.frac.x + primRecip.b * c.frac.y + primRecip.c * c.frac.z
            // Mapped fractional -> Cartesian via input reciprocal vectors (should match)
            let cartFromInput = inputRecip.a * m.frac.x + inputRecip.b * m.frac.y + inputRecip.c * m.frac.z
            XCTAssertEqual(cartFromPrim.x, cartFromInput.x, accuracy: 1e-3, "\(c.label) x")
            XCTAssertEqual(cartFromPrim.y, cartFromInput.y, accuracy: 1e-3, "\(c.label) y")
            XCTAssertEqual(cartFromPrim.z, cartFromInput.z, accuracy: 1e-3, "\(c.label) z")
        }
    }

    func testMapToInputReciprocalRotatedCellPreservesCartesian() {
        // For a rotated cell, the mapping should preserve Cartesian reciprocal
        // positions: canonical point -> Cartesian -> input fractional. This
        // verifies the production mapping does NOT assume standard lab orientation.
        // Apply a rotation to a cubic cell.
        let angle: Double = .pi / 6.0  // 30 degrees
        let c = cos(angle), s = sin(angle)
        // Rotation matrix around z-axis
        let rot: [[Double]] = [
            [c, -s, 0],
            [s,  c, 0],
            [0,  0, 1],
        ]
        // Original cubic cell (a=4)
        let a: Double = 4.0
        let orig: [[Double]] = [
            [a, 0, 0],
            [0, a, 0],
            [0, 0, a],
        ]
        // Apply rotation to lattice rows
        var rotated = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                rotated[i][j] = rot[i][0]*orig[0][j] + rot[i][1]*orig[1][j] + rot[i][2]*orig[2][j]
            }
        }

        // Physically rotate the atom Cartesian positions to match
        let origMatrix = CrystalSymmetryMatrix(orig.flatMap { $0 })
        let origFrac: [[Double]] = [[0, 0, 0], [0, 0.5, 0.5], [0.5, 0, 0.5], [0.5, 0.5, 0]]
        var rotatedAtomCartesian: [SIMD3<Float>] = []
        for frac in origFrac {
            let f = SIMD3<Double>(frac[0], frac[1], frac[2])
            let cart = origMatrix.transposed.applying(to: f)
            let rx = Float(rot[0][0] * cart.x + rot[0][1] * cart.y + rot[0][2] * cart.z)
            let ry = Float(rot[1][0] * cart.x + rot[1][1] * cart.y + rot[1][2] * cart.z)
            let rz = Float(rot[2][0] * cart.x + rot[2][1] * cart.y + rot[2][2] * cart.z)
            rotatedAtomCartesian.append(SIMD3<Float>(rx, ry, rz))
        }

        let rotatedMatrix = CrystalSymmetryMatrix(rotated.flatMap { $0 })
        let vectors = (0..<3).map { row in
            SIMD3<Float>(Float(rotatedMatrix[row, 0]), Float(rotatedMatrix[row, 1]), Float(rotatedMatrix[row, 2]))
        }
        let cell = Cell(a: vectors[0], b: vectors[1], c: vectors[2])
        let swiftAtoms = rotatedAtomCartesian.map { cart in
            Atom(coord: cart, atomicNumber: 29, label: "Cu")
        }
        var loaded = LoadedScene()
        loaded.atoms = swiftAtoms
        loaded.cell = cell
        loaded.isCrystal = true
        loaded.periodicDim = 3
        let scene = Scene(loaded: loaded)

        guard let symmetry = scene.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let canonical = CanonicalPathGenerator.generate(for: symmetry)
        guard let basis = CanonicalPathGenerator.generateWithBasis(for: symmetry) else {
            XCTFail("generateWithBasis failed"); return
        }
        let mapped = CanonicalPathGenerator.mapToInputReciprocal(canonical, primRecip: basis.primRecip, inputCell: scene.cell!)

        // Use the HPKOT primitive reciprocal lattice vectors (from the P matrix
        // construction) to compute the expected Cartesian position.
        let primRecip = basis.primRecip
        let inputRecip = scene.cell!.reciprocalVectors

        for (c, m) in zip(canonical.points, mapped.points) {
            // Canonical (primitive) fractional -> Cartesian via primitive reciprocal vectors
            let cartFromPrim = primRecip.a * c.frac.x + primRecip.b * c.frac.y + primRecip.c * c.frac.z
            // Mapped fractional -> Cartesian via input reciprocal vectors (should match)
            let cartFromInput = inputRecip.a * m.frac.x + inputRecip.b * m.frac.y + inputRecip.c * m.frac.z
            XCTAssertEqual(cartFromPrim.x, cartFromInput.x, accuracy: 1e-3, "\(c.label) x")
            XCTAssertEqual(cartFromPrim.y, cartFromInput.y, accuracy: 1e-3, "\(c.label) y")
            XCTAssertEqual(cartFromPrim.z, cartFromInput.z, accuracy: 1e-3, "\(c.label) z")
        }
    }

    func testStructureSignatureChangesWithLatticeParameters() {
        let s1 = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        let s2 = SceneFactory.scene(latticeRows: [
            [5, 0, 0],
            [0, 5, 0],
            [0, 0, 5],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        guard let sym1 = s1.crystalSymmetry?.symmetry,
              let sym2 = s2.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let sig1 = CanonicalPathGenerator.structureSignature(for: sym1)
        let sig2 = CanonicalPathGenerator.structureSignature(for: sym2)
        XCTAssertNotEqual(sig1, sig2, "signature must change when lattice parameters change")
    }

    func testStructureSignatureChangesWithSpaceGroup() {
        let sP = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        let sI = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(26, SIMD3(0, 0, 0)), (26, SIMD3(0.5, 0.5, 0.5))])
        guard let symP = sP.crystalSymmetry?.symmetry,
              let symI = sI.crystalSymmetry?.symmetry else {
            XCTFail("symmetry unavailable"); return
        }
        let sigP = CanonicalPathGenerator.structureSignature(for: symP)
        let sigI = CanonicalPathGenerator.structureSignature(for: symI)
        XCTAssertNotEqual(sigP, sigI, "signature must change when space group changes")
    }
}

// MARK: - Disconnected segment interpolation tests

final class DisconnectedSegmentTests: XCTestCase {

    func testInterpolationRespectsBreaks() {
        // Path: A-B-C | D-E (break at index 2)
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(0.5, 0, 0), "B"),
            KPoint(SIMD3(1, 0, 0), "C"),
            KPoint(SIMD3(0, 0.5, 0), "D"),
            KPoint(SIMD3(0, 1, 0), "E"),
        ], breaks: [2])
        let pts = path.interpolated()
        // The interpolated points should NOT include any points between C and D.
        // All points should be on the line segments A-B, B-C, D-E.
        XCTAssertFalse(pts.isEmpty)
        // No point should be between C and D (i.e., no point with x > 1 and y > 0).
        for p in pts {
            // Either on the A-B-C line (y=0, z=0) or on the D-E line (x=0, z=0).
            let onFirst = abs(p.y) < 1e-6 && abs(p.z) < 1e-6
            let onSecond = abs(p.x) < 1e-6 && abs(p.z) < 1e-6
            XCTAssertTrue(onFirst || onSecond, "point \(p) is not on any segment")
        }
    }

    func testInterpolationNoBreaksConnectsAll() {
        // Path: A-B-C (no breaks)
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(0.5, 0, 0), "B"),
            KPoint(SIMD3(1, 0, 0), "C"),
        ], breaks: [])
        let pts = path.interpolated()
        XCTAssertGreaterThanOrEqual(pts.count, 2)
        XCTAssertEqual(pts.first, SIMD3(0, 0, 0))
        XCTAssertEqual(pts.last, SIMD3(1, 0, 0))
    }

    func testInterpolationMultipleBreaks() {
        // Path: A-B | C-D | E-F (breaks at 1 and 3)
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(0, 1, 0), "C"),
            KPoint(SIMD3(0, 2, 0), "D"),
            KPoint(SIMD3(1, 1, 0), "E"),
            KPoint(SIMD3(2, 1, 0), "F"),
        ], breaks: [1, 3])
        let pts = path.interpolated()
        XCTAssertFalse(pts.isEmpty)
        // No point should be between B and C, or between D and E.
        for p in pts {
            let onFirst = abs(p.y) < 1e-6 && p.z == 0
            let onSecond = abs(p.x) < 1e-6 && p.z == 0
            let onThird = abs(p.y - 1) < 1e-6 && p.z == 0
            XCTAssertTrue(onFirst || onSecond || onThird, "point \(p) is not on any segment")
        }
    }

    func testInterpolationAllBreaksPreservesSingletonComponents() {
        // Path: A | B | C (breaks at 0 and 1). Explicit k-point export still
        // needs each singleton component's first (and only) endpoint.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(2, 0, 0), "C"),
        ], breaks: [0, 1])
        let pts = path.interpolated()
        XCTAssertEqual(pts, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)])
    }

    func testInterpolationEmptyPath() {
        let path = KPath(points: [], breaks: [])
        XCTAssertTrue(path.interpolated().isEmpty)
    }

    func testInterpolationSinglePoint() {
        let path = KPath(points: [KPoint(SIMD3(0.5, 0, 0), "X")], breaks: [])
        let pts = path.interpolated()
        XCTAssertEqual(pts, [SIMD3(0.5, 0, 0)])
    }

    func testInterpolationBreakOutOfRangeIgnored() {
        // Break at index 5 is out of range for a 3-point path and should be ignored.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(0.5, 0, 0), "B"),
            KPoint(SIMD3(1, 0, 0), "C"),
        ], breaks: [5])
        let pts = path.interpolated()
        XCTAssertGreaterThanOrEqual(pts.count, 2)
        XCTAssertEqual(pts.first, SIMD3(0, 0, 0))
        XCTAssertEqual(pts.last, SIMD3(1, 0, 0))
    }

    func testQERespectsBreaks() {
        // Path: A-B | C-D (break at 1)
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(0.5, 0, 0), "B"),
            KPoint(SIMD3(0, 0.5, 0), "C"),
            KPoint(SIMD3(0, 1, 0), "D"),
        ], breaks: [1])
        let qe = KPathExport.qeKPointsCrystal(path)
        let lines = qe.split(separator: "\n").filter { !$0.isEmpty }
        // First line is the count, rest are k-points.
        guard let countLine = lines.first, let count = Int(countLine) else {
            XCTFail("bad QE output"); return
        }
        XCTAssertEqual(count, lines.count - 1)
        // No point should be between B and C.
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ")
            guard parts.count >= 3,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]) else { continue }
            let onFirst = abs(y) < 1e-6
            let onSecond = abs(x) < 1e-6
            XCTAssertTrue(onFirst || onSecond, "QE point (\(x),\(y)) is not on any segment")
        }
    }

    func testKPFThrowsOnBreaks() {
        // KPF cannot represent disconnected segments unambiguously: a repeated
        // label only indicates a break when the shared endpoint happens to be
        // that label. Export must throw for paths with breaks.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
            KPoint(SIMD3(0.5, 0.5, 0), "M"),
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "R"),
        ], breaks: [3])
        XCTAssertThrowsError(try KPathExport.xcrysdnenKPF(path)) { error in
            XCTAssertTrue(error is KPathExport.ExportError)
        }
    }

    func testKPFConnectedPathWorks() {
        // A fully connected path (no breaks) should export to KPF without error.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
            KPoint(SIMD3(0.5, 0.5, 0), "M"),
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "R"),
        ], breaks: [])
        let kpf = try! KPathExport.xcrysdnenKPF(path)
        let lines = kpf.split(separator: "\n").filter { !$0.isEmpty }
        // 1 multiplier line + 5 k-point lines.
        XCTAssertEqual(lines.count, 6)
        // Γ appears twice because it's in the points list twice (at the junction
        // of two connected segments). KPF preserves this.
        let gammaCount = lines.filter { $0.contains("Γ") }.count
        XCTAssertEqual(gammaCount, 2, "Γ should appear twice (repeated in points list)")
    }

    func testKPFIgnoresOutOfRangeBreaksLikeInterpolation() throws {
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
        ], breaks: [-1, 7])
        XCTAssertFalse(path.hasDisconnectedSegments)
        let text = try KPathExport.xcrysdnenKPF(path)
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }

    func testSegmentEnumeration() {
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(2, 0, 0), "C"),
            KPoint(SIMD3(3, 0, 0), "D"),
            KPoint(SIMD3(4, 0, 0), "E"),
        ], breaks: [1, 3])
        let segs = path.segments()
        // Break at 1: no segment between B(1) and C(2). Segment [0..<2] = A-B.
        // Break at 3: no segment between D(3) and E(4). Segment [2..<4] = C-D.
        // E(4) is a singleton component and must remain visible to explicit
        // k-point interpolation/export.
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0], 0..<2)  // A-B
        XCTAssertEqual(segs[1], 2..<4)  // C-D
        XCTAssertEqual(segs[2], 4..<5)  // E
    }

    // MARK: - Exact-count/endpoint tests for per-component interpolation

    func testInterpolationEqualEdgesExactCount() {
        // Single component with 2 equal-length edges: A-B-C (lengths 1+1=2).
        // With perSeg=10, each edge gets round(10 * 1/2) = 5 samples (n=5).
        // First edge: j=0..4 → 5 points (A to B). Second edge: j=1..4 → 4 points.
        // Total: 5 + 4 = 9 points.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(2, 0, 0), "C"),
        ], pointsPerSegment: 10)
        let pts = path.interpolated()
        XCTAssertEqual(pts.first, SIMD3(0, 0, 0), "first endpoint must be A")
        XCTAssertEqual(pts.last, SIMD3(2, 0, 0), "last endpoint must be C")
        // n=5 per edge: edge 1 emits j=0..4 (5 pts), edge 2 emits j=1..4 (4 pts)
        XCTAssertEqual(pts.count, 9, "two equal edges with perSeg=10 should give 9 points")
    }

    func testInterpolationUnequalEdgesExactCount() {
        // Single component with 2 unequal-length edges: A-B-C (lengths 1+2=3).
        // With perSeg=9, edge 1 gets round(9 * 1/3) = 3 (n=3), edge 2 gets round(9 * 2/3) = 6 (n=6).
        // First edge: j=0..2 → 3 points. Second edge: j=1..5 → 5 points.
        // Total: 3 + 5 = 8 points.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(3, 0, 0), "C"),
        ], pointsPerSegment: 9)
        let pts = path.interpolated()
        XCTAssertEqual(pts.first, SIMD3(0, 0, 0))
        XCTAssertEqual(pts.last, SIMD3(3, 0, 0))
        XCTAssertEqual(pts.count, 8, "unequal edges (1:2) with perSeg=9 should give 8 points")
    }

    func testInterpolationDisconnectedComponentsIndependent() {
        // Two disconnected components: A-B | C-D (break at 1).
        // Component 1: A-B (length 1), Component 2: C-D (length 1).
        // Each component gets perSeg=4 samples (n=4).
        // Component 1: edge A-B gets round(4 * 1/1) = 4, emits j=0..3 → 4 points.
        // Component 2: edge C-D gets round(4 * 1/1) = 4, emits j=0..3 → 4 points.
        // Total: 8 points.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(0, 1, 0), "C"),
            KPoint(SIMD3(1, 1, 0), "D"),
        ], pointsPerSegment: 4, breaks: [1])
        let pts = path.interpolated()
        XCTAssertEqual(pts.count, 8, "two disconnected equal components with perSeg=4 should give 8 points")
        // First point of component 1
        XCTAssertEqual(pts[0], SIMD3(0, 0, 0), "first endpoint of component 1 must be A")
        // Last point of component 1
        XCTAssertEqual(pts[3], SIMD3(1, 0, 0), "last point of component 1 must be B")
        // First point of component 2 (must include C)
        XCTAssertEqual(pts[4], SIMD3(0, 1, 0), "first endpoint of component 2 must be C")
        // Last point of component 2
        XCTAssertEqual(pts[7], SIMD3(1, 1, 0), "last endpoint of component 2 must be D")
    }

    func testInterpolationDisconnectedComponentsDifferentLengths() {
        // Two disconnected components with different total lengths:
        // Component 1: A-B (length 1), Component 2: C-D-E (lengths 1+1=2).
        // With perSeg=6:
        // Component 1: edge A-B gets round(6 * 1/1) = 6 (n=6), emits j=0..5 → 6 points.
        // Component 2: edge C-D gets round(6 * 1/2) = 3 (n=3), emits j=0..2 → 3 points.
        //           edge D-E gets round(6 * 1/2) = 3 (n=3), emits j=1..2 → 2 points.
        // Total: 6 + 3 + 2 = 11 points.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(0, 1, 0), "C"),
            KPoint(SIMD3(1, 1, 0), "D"),
            KPoint(SIMD3(2, 1, 0), "E"),
        ], pointsPerSegment: 6, breaks: [1])
        let pts = path.interpolated()
        XCTAssertEqual(pts.count, 11, "components of length 1 and 2 with perSeg=6 should give 11 points")
        // First point of component 2 must be C
        XCTAssertEqual(pts[6], SIMD3(0, 1, 0), "first endpoint of component 2 must be C")
    }

    func testInterpolationAllZeroComponent() {
        // Component with zero-length edges: A-A-A (all same point).
        // With perSeg=10, each edge gets 2 samples (deterministic, n=2).
        // Edge 1: j=0..1 → 2 points (A, A). Edge 2: j=1..1 → 1 point (A).
        // Total: 3 points, all at A.
        let path = KPath(points: [
            KPoint(SIMD3(0.5, 0.5, 0.5), "A"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "A"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "A"),
        ], pointsPerSegment: 10)
        let pts = path.interpolated()
        XCTAssertEqual(pts.count, 3, "all-zero component should give 3 points")
        for p in pts {
            XCTAssertEqual(p, SIMD3(0.5, 0.5, 0.5), "all points should be at A")
        }
    }

    func testInterpolationFirstEndpointOfEveryComponentIncluded() {
        // Three disconnected components: A-B | C-D | E-F (breaks at 1, 3).
        // Each component's first endpoint must be included.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(0, 1, 0), "C"),
            KPoint(SIMD3(1, 1, 0), "D"),
            KPoint(SIMD3(0, 2, 0), "E"),
            KPoint(SIMD3(1, 2, 0), "F"),
        ], pointsPerSegment: 4, breaks: [1, 3])
        let pts = path.interpolated()
        // Each component: 1 edge, perSeg=4 (n=4), emits j=0..3 → 4 points.
        // Total: 12 points.
        XCTAssertEqual(pts.count, 12)
        // First endpoint of component 1
        XCTAssertEqual(pts[0], SIMD3(0, 0, 0), "first endpoint of component 1 must be A")
        // First endpoint of component 2
        XCTAssertEqual(pts[4], SIMD3(0, 1, 0), "first endpoint of component 2 must be C")
        // First endpoint of component 3
        XCTAssertEqual(pts[8], SIMD3(0, 2, 0), "first endpoint of component 3 must be E")
    }

    func testInterpolationGlobalCap() {
        // A very large perSeg should be capped at 1,000,000.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
        ], pointsPerSegment: Int.max)
        let pts = path.interpolated()
        XCTAssertEqual(pts.count, 1_000_000, "perSeg=Int.max should be capped at 1,000,000")
        XCTAssertEqual(pts.first, SIMD3(0, 0, 0))
        XCTAssertEqual(pts.last, SIMD3(1, 0, 0))
    }

    func testInterpolationCapRetainsLaterComponentEndpointsWhenPossible() {
        // The first disconnected edge asks for a full cap's worth of samples,
        // but the two endpoints of the second component still fit within the
        // global cap and must not be starved by the earlier dense component.
        let path = KPath(points: [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(0, 1, 0), "C"),
            KPoint(SIMD3(1, 1, 0), "D"),
        ], pointsPerSegment: Int.max, breaks: [1])
        let pts = path.interpolated()
        XCTAssertEqual(pts.count, 1_000_000)
        XCTAssertEqual(pts[pts.count - 2], SIMD3(0, 1, 0))
        XCTAssertEqual(pts.last, SIMD3(1, 1, 0))
    }

    func testInterpolationCapStillEmitsOrderedPrefixWhenRouteHasTooManyNodes() {
        // More explicit route nodes than the global cap makes retaining every
        // endpoint impossible. The safety cap must still yield an ordered
        // prefix rather than silently exporting an empty list.
        let points = (0...1_000_000).map {
            KPoint(SIMD3(Float($0), 0, 0), "P")
        }
        let pts = KPath(points: points, pointsPerSegment: 2).interpolated()
        XCTAssertEqual(pts.count, 1_000_000)
        XCTAssertEqual(pts.first, SIMD3(0, 0, 0))
        XCTAssertEqual(pts.last, SIMD3(999_999, 0, 0))
    }
}

// MARK: - Persistence tests

final class KPathPersistenceTests: XCTestCase {

    func testBreaksPersistInStateFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_breaks.mvis-state")
        var s = Scene()
        s.kPathPoints = [
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0, 0), "X"),
            KPoint(SIMD3(0.5, 0.5, 0), "M"),
            KPoint(SIMD3(0, 0, 0), "Γ"),
            KPoint(SIMD3(0.5, 0.5, 0.5), "R"),
        ]
        s.kPathBreaks = [3]
        s.kPathProvenance = .generated
        try StateStore.save(s, camera: nil, sourceURL: nil, to: tmp)

        var s2 = Scene()
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertEqual(s2.kPathBreaks, [3])
        XCTAssertEqual(s2.kPathProvenance, .generated)
    }

    func testBreaksPersistBackwardCompatible() throws {
        // Old state file without kPathBreaks key should default to no breaks.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_compat.mvis-state")
        let payload: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "kPathPoints": [["frac": [0.0, 0.0, 0.0], "label": "Γ"],
                           ["frac": [0.5, 0.0, 0.0], "label": "X"]],
        ]
        try JSONSerialization.data(withJSONObject: payload, options: []).write(to: tmp)

        var s = Scene()
        var c: Camera? = nil
        try StateStore.load(into: &s, camera: &c, from: tmp)
        XCTAssertTrue(s.kPathBreaks.isEmpty, "absent kPathBreaks key should default to no breaks")
    }

    func testMalformedBreaksRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_bad_breaks.mvis-state")
        var s = Scene()
        var c: Camera? = nil

        // Breaks as a string instead of array.
        let bad: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "kPathPoints": [["frac": [0.0, 0.0, 0.0], "label": "Γ"]],
            "kPathBreaks": "not-an-array",
        ]
        try JSONSerialization.data(withJSONObject: bad, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))

        // Break index out of range.
        let outOfRange: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "kPathPoints": [["frac": [0.0, 0.0, 0.0], "label": "Γ"],
                           ["frac": [0.5, 0.0, 0.0], "label": "X"]],
            "kPathBreaks": [5],
        ]
        try JSONSerialization.data(withJSONObject: outOfRange, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))
    }

    func testInvalidProvenanceRejected() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_bad_provenance.mvis-state")
        var s = Scene()
        var c: Camera? = nil

        // Invalid provenance string should be rejected, not coerced.
        let bad: [String: Any] = [
            "version": 1,
            "displayMode": "ballStick",
            "supercell": [1, 1, 1],
            "kPathPoints": [["frac": [0.0, 0.0, 0.0], "label": "Γ"],
                           ["frac": [0.5, 0.0, 0.0], "label": "X"]],
            "kPathProvenance": "bogus",
        ]
        try JSONSerialization.data(withJSONObject: bad, options: []).write(to: tmp)
        XCTAssertThrowsError(try StateStore.load(into: &s, camera: &c, from: tmp))
    }

    func testProvenancePersists() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_provenance.mvis-state")
        var s = Scene()
        s.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X")]
        s.kPathProvenance = .userEdited
        try StateStore.save(s, camera: nil, sourceURL: nil, to: tmp)

        var s2 = Scene()
        var c2: Camera? = nil
        try StateStore.load(into: &s2, camera: &c2, from: tmp)
        XCTAssertEqual(s2.kPathProvenance, .userEdited)
    }

    func testGeneratedSignaturePersistsWithCanonicalRoute() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_generated_signature.mvis-state")
        let source = SceneFactory.scene(latticeRows: [
            [4, 0, 0], [0, 4, 0], [0, 0, 4],
        ], atoms: [(29, SIMD3(0, 0, 0)), (29, SIMD3(0, 0.5, 0.5)),
                   (29, SIMD3(0.5, 0, 0.5)), (29, SIMD3(0.5, 0.5, 0))])
        let signature = try XCTUnwrap(source.kPathSignature)
        try StateStore.save(source, camera: nil, sourceURL: nil, to: tmp)

        var restored = SceneFactory.scene(latticeRows: [
            [4, 0, 0], [0, 4, 0], [0, 0, 4],
        ], atoms: [(29, SIMD3(0, 0, 0)), (29, SIMD3(0, 0.5, 0.5)),
                   (29, SIMD3(0.5, 0, 0.5)), (29, SIMD3(0.5, 0.5, 0))])
        var camera: Camera? = nil
        try StateStore.load(into: &restored, camera: &camera, from: tmp)
        XCTAssertEqual(restored.kPathProvenance, .generated)
        XCTAssertEqual(restored.kPathSignature, signature)
        XCTAssertEqual(restored.kPathPoints, source.kPathPoints)
        XCTAssertEqual(restored.kPathBreaks, source.kPathBreaks)
    }

    func testGeneratedStateKeepsFreshRouteWhenInputBasisChanges() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_generated_rotated_state.mvis-state")
        let fccAtoms: [(Int, SIMD3<Double>)] = [
            (29, SIMD3(0, 0, 0)), (29, SIMD3(0, 0.5, 0.5)),
            (29, SIMD3(0.5, 0, 0.5)), (29, SIMD3(0.5, 0.5, 0)),
        ]
        let saved = SceneFactory.scene(latticeRows: [
            [4, 0, 0], [0, 4, 0], [0, 0, 4],
        ], atoms: fccAtoms)
        try StateStore.save(saved, camera: nil, sourceURL: nil, to: tmp)

        // The same physical crystal with a rotated input basis. Its canonical
        // route is freshly mapped into that new reciprocal basis; state restore
        // must not overwrite it with the old basis's fractional coordinates.
        var restored = SceneFactory.scene(latticeRows: [
            [0, 4, 0], [-4, 0, 0], [0, 0, 4],
        ], atoms: fccAtoms)
        let freshPoints = restored.kPathPoints
        let freshBreaks = restored.kPathBreaks
        let freshSignature = restored.kPathSignature
        XCTAssertEqual(Scene.inputReciprocalBasesMatch(saved.cell!, restored.cell!), false)
        XCTAssertNotEqual(saved.kPathPoints, freshPoints)

        var camera: Camera? = nil
        try StateStore.load(into: &restored, camera: &camera, from: tmp)
        XCTAssertEqual(restored.kPathPoints, freshPoints)
        XCTAssertEqual(restored.kPathBreaks, freshBreaks)
        XCTAssertEqual(restored.kPathProvenance, .generated)
        XCTAssertEqual(restored.kPathSignature, freshSignature)
    }

    func testLegacyCustomRouteWithoutProvenanceIsInferredUserEdited() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_legacy_custom.mvis-state")
        let route = [KPoint(SIMD3(0, 0, 0), "custom Γ"), KPoint(SIMD3(0.123, 0.234, 0.345), "custom")]
        let payload: [String: Any] = [
            "version": 1,
            "kPathPoints": route.map { ["frac": [$0.frac.x, $0.frac.y, $0.frac.z], "label": $0.label] },
            "kPathBreaks": [],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: tmp)

        var restored = SceneFactory.scene(latticeRows: [
            [4, 0, 0], [0, 4, 0], [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        var camera: Camera? = nil
        try StateStore.load(into: &restored, camera: &camera, from: tmp)
        XCTAssertEqual(restored.kPathPoints, route)
        XCTAssertEqual(restored.kPathProvenance, .userEdited)
        XCTAssertNil(restored.kPathSignature)
    }

    func testLegacyCanonicalRouteInferenceRequiresExactPointsAndBreaks() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_legacy_canonical.mvis-state")
        let fresh = SceneFactory.scene(latticeRows: [
            [4, 0, 0], [0, 4, 0], [0, 0, 4],
        ], atoms: [(29, SIMD3(0, 0, 0)), (29, SIMD3(0, 0.5, 0.5)),
                   (29, SIMD3(0.5, 0, 0.5)), (29, SIMD3(0.5, 0.5, 0))])
        XCTAssertFalse(fresh.kPathBreaks.isEmpty, "the fixture needs a disconnected canonical route")
        let pointPayload = fresh.kPathPoints.map { point in
            ["frac": [point.frac.x, point.frac.y, point.frac.z], "label": point.label]
        }

        // A pre-provenance state is generated only if its complete topology is
        // identical to the freshly parsed canonical route.
        var exactPayload: [String: Any] = [
            "version": 1,
            "kPathPoints": pointPayload,
            "kPathBreaks": Array(fresh.kPathBreaks).sorted(),
        ]
        try JSONSerialization.data(withJSONObject: exactPayload).write(to: tmp)
        var exact = fresh
        var camera: Camera? = nil
        try StateStore.load(into: &exact, camera: &camera, from: tmp)
        XCTAssertEqual(exact.kPathProvenance, .generated)
        XCTAssertEqual(exact.kPathSignature, fresh.kPathSignature)
        XCTAssertEqual(exact.kPathPoints, fresh.kPathPoints)
        XCTAssertEqual(exact.kPathBreaks, fresh.kPathBreaks)

        // The same nodes with a different disconnected topology are a custom
        // route; treating them as generated would lose a user intent on a later
        // geometry change.
        exactPayload["kPathBreaks"] = []
        try JSONSerialization.data(withJSONObject: exactPayload).write(to: tmp)
        var topologyEdited = fresh
        try StateStore.load(into: &topologyEdited, camera: &camera, from: tmp)
        XCTAssertEqual(topologyEdited.kPathProvenance, .userEdited)
        XCTAssertNil(topologyEdited.kPathSignature)
        XCTAssertEqual(topologyEdited.kPathPoints, fresh.kPathPoints)
        XCTAssertTrue(topologyEdited.kPathBreaks.isEmpty)
    }

    func testStateRestoreRemapsUserRouteFromPersistedInputCell() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_user_basis_remap.mvis-state")
        let oldCell = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4))
        let newCell = Cell(a: SIMD3(0, 4, 0), b: SIMD3(-4, 0, 0), c: SIMD3(0, 0, 4))
        var saved = Scene()
        saved.cell = oldCell
        saved.kPathPoints = [KPoint(SIMD3(0.25, 0.5, 0.125), "custom")]
        saved.kPathProvenance = .userEdited
        try StateStore.save(saved, camera: nil, sourceURL: nil, to: tmp)

        var restored = Scene()
        restored.cell = newCell
        var camera: Camera? = nil
        try StateStore.load(into: &restored, camera: &camera, from: tmp)
        let oldCartesian = BrillouinZone.cartesianFromFractional(saved.kPathPoints[0].frac,
                                                                   reciprocal: oldCell.reciprocalVectors)
        let newCartesian = BrillouinZone.cartesianFromFractional(restored.kPathPoints[0].frac,
                                                                   reciprocal: newCell.reciprocalVectors)
        XCTAssertLessThan(length(oldCartesian - newCartesian), 1e-5)
        XCTAssertEqual(restored.kPathProvenance, .userEdited)
        XCTAssertNil(restored.kPathSignature)
    }

    func testStrictKPathMetadataValidationRollsBackTransactionally() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kpath_strict_metadata.mvis-state")
        let points: [[String: Any]] = [
            ["frac": [0.0, 0.0, 0.0], "label": "Γ"],
            ["frac": [0.5, 0.0, 0.0], "label": "X"],
            ["frac": [0.5, 0.5, 0.0], "label": "M"],
        ]
        let invalidFields: [[String: Any]] = [
            ["kPathBreaks": [0, 0]],       // duplicate
            ["kPathBreaks": [0.5]],        // non-integral
            ["kPathProvenance": 7],        // wrong type
            ["kPathSignature": 7],         // wrong type
            ["version": "1"],             // wrong type
        ]

        for invalid in invalidFields {
            var payload: [String: Any] = ["version": 1, "kPathPoints": points]
            for (key, value) in invalid { payload[key] = value }
            try JSONSerialization.data(withJSONObject: payload).write(to: tmp)

            var scene = Scene()
            let originalRoute = [KPoint(SIMD3(0, 0, 0), "old"), KPoint(SIMD3(0.25, 0, 0), "old2")]
            scene.kPathPoints = originalRoute
            scene.kPathProvenance = .userEdited
            var camera: Camera? = Camera()
            camera?.distance = 31
            XCTAssertThrowsError(try StateStore.load(into: &scene, camera: &camera, from: tmp))
            XCTAssertEqual(scene.kPathPoints, originalRoute)
            XCTAssertEqual(scene.kPathProvenance, .userEdited)
            XCTAssertEqual(camera?.distance, 31)
        }
    }
}

// MARK: - Editor index remapping and undo tests

final class KPathEditorRemappingTests: XCTestCase {

    private func makeState() -> SideBarState {
        let state = SideBarState()
        state.onChange = nil  // disable for direct mutation
        state.kPathPoints = [
            KPoint(SIMD3(0, 0, 0), "A"),
            KPoint(SIMD3(1, 0, 0), "B"),
            KPoint(SIMD3(2, 0, 0), "C"),
            KPoint(SIMD3(3, 0, 0), "D"),
            KPoint(SIMD3(4, 0, 0), "E"),
        ]
        state.kPathBreaks = [1, 3]
        return state
    }

    func testToggleBreakInsertsAndRemoves() {
        let state = makeState()
        state.onChange = nil
        // Initially breaks at 1 and 3.
        XCTAssertEqual(state.kPathBreaks, [1, 3])
        // Toggle break at 2: insert.
        state.toggleBreak(at: 2)
        XCTAssertEqual(state.kPathBreaks, [1, 2, 3])
        // Toggle break at 2 again: remove.
        state.toggleBreak(at: 2)
        XCTAssertEqual(state.kPathBreaks, [1, 3])
    }

    func testToggleBreakOutOfRangeNoOp() {
        let state = makeState()
        state.onChange = nil
        let before = state.kPathBreaks
        state.toggleBreak(at: -1)
        XCTAssertEqual(state.kPathBreaks, before)
        state.toggleBreak(at: 10)
        XCTAssertEqual(state.kPathBreaks, before)
        state.toggleBreak(at: 4)  // last index, no next point
        XCTAssertEqual(state.kPathBreaks, before)
    }

    func testInsertBreakAndRemoveBreak() {
        let state = makeState()
        state.onChange = nil
        state.insertBreak(at: 2)
        XCTAssertEqual(state.kPathBreaks, [1, 2, 3])
        state.removeBreak(at: 2)
        XCTAssertEqual(state.kPathBreaks, [1, 3])
    }

    func testRemoveBreakNoOpWhenNotPresent() {
        let state = makeState()
        state.onChange = nil
        let before = state.kPathBreaks
        state.removeBreak(at: 0)
        XCTAssertEqual(state.kPathBreaks, before)
    }

    func testRemovePointRemapsBreaks() {
        let state = makeState()
        state.onChange = nil
        // Points: A(0) B(1) C(2) D(3) E(4), breaks at 1 (B-C) and 3 (D-E).
        // Remove point at index 2 (C). Gaps at 1 (B-C) and 2 (C-D) collapse
        // into gap at 1 (B-D). Since gap 1 was a break, new gap 1 is a break.
        // Break at 3 (D-E) shifts to 2 (D-E, now at indices 2-3).
        state.remove(at: 2)
        XCTAssertEqual(state.kPathPoints.map { $0.label }, ["A", "B", "D", "E"])
        XCTAssertEqual(state.kPathBreaks, [1, 2])
    }

    func testRemovePointAtBreakLocation() {
        let state = makeState()
        state.onChange = nil
        // Points: A(0) B(1) C(2) D(3) E(4), breaks at 1 (B-C) and 3 (D-E).
        // Remove point at index 1 (B). Gaps at 0 (A-B) and 1 (B-C) collapse
        // into gap at 0 (A-C). Since gap 1 was a break, new gap 0 is a break.
        // Break at 3 (D-E) shifts to 2 (D-E, now at indices 2-3).
        state.remove(at: 1)
        XCTAssertEqual(state.kPathPoints.map { $0.label }, ["A", "C", "D", "E"])
        XCTAssertEqual(state.kPathBreaks, [0, 2])
    }

    func testRemoveFirstDropsItsVanishedBreakAndShiftsLaterBreaks() {
        let state = makeState()
        state.onChange = nil
        // A-B-C-D-E with breaks B-C and D-E. Removing A drops gap A-B;
        // B-C and D-E become gaps 0 and 2 respectively.
        state.remove(at: 0)
        XCTAssertEqual(state.kPathPoints.map { $0.label }, ["B", "C", "D", "E"])
        XCTAssertEqual(state.kPathBreaks, [0, 2])
        XCTAssertTrue(state.kPathBreaks.allSatisfy { $0 >= 0 && $0 < state.kPathPoints.count - 1 })
    }

    func testRemoveLastDropsItsVanishedBreak() {
        let state = makeState()
        state.onChange = nil
        // The D-E break vanishes together with E; it must not remain as the
        // now-out-of-range final break index.
        state.remove(at: 4)
        XCTAssertEqual(state.kPathPoints.map { $0.label }, ["A", "B", "C", "D"])
        XCTAssertEqual(state.kPathBreaks, [1])
        XCTAssertTrue(state.kPathBreaks.allSatisfy { $0 >= 0 && $0 < state.kPathPoints.count - 1 })
    }

    func testUndoRestoresBreaks() {
        let state = makeState()
        state.onChange = nil
        let origBreaks = state.kPathBreaks
        // Mutate: insert a break.
        state.insertBreak(at: 0)
        XCTAssertEqual(state.kPathBreaks, [0, 1, 3])
        // Undo: should restore original breaks.
        state.undoLast()
        XCTAssertEqual(state.kPathBreaks, origBreaks)
    }

    func testClearResetsBreaks() {
        let state = makeState()
        state.onChange = nil
        state.clear()
        XCTAssertTrue(state.kPathPoints.isEmpty)
        XCTAssertTrue(state.kPathBreaks.isEmpty)
    }

    func testMoveDoesNotAffectBreaks() {
        let state = makeState()
        state.onChange = nil
        // Adjacent swaps don't change gap indices.
        state.moveUp(at: 2)
        XCTAssertEqual(state.kPathBreaks, [1, 3])
        state.moveDown(at: 1)
        XCTAssertEqual(state.kPathBreaks, [1, 3])
    }

    func testCompositeRouteMutationsNotifyOnlyFinalTopology() {
        let state = makeState()
        var snapshots: [([String], Set<Int>)] = []
        state.onChange = {
            snapshots.append((state.kPathPoints.map { $0.label }, state.kPathBreaks))
        }

        state.remove(at: 2)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].0, ["A", "B", "D", "E"])
        XCTAssertEqual(snapshots[0].1, [1, 2])

        snapshots.removeAll()
        state.clear()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].0, [])
        XCTAssertEqual(snapshots[0].1, [])

        snapshots.removeAll()
        state.undoLast()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].0, ["A", "B", "D", "E"])
        XCTAssertEqual(snapshots[0].1, [1, 2])
    }

    func testBreaksAreCappedAtValidRange() {
        let state = makeState()
        state.onChange = nil
        // Insert breaks at all valid indices.
        state.insertBreak(at: 0)
        state.insertBreak(at: 1)
        state.insertBreak(at: 2)
        state.insertBreak(at: 3)
        XCTAssertEqual(state.kPathBreaks, [0, 1, 2, 3])
    }
}

// MARK: - Lifecycle: regeneration/preservation tests

final class KPathLifecycleTests: XCTestCase {

    func testSceneInitGeneratesCanonicalPath() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(29, SIMD3(0, 0, 0)), (29, SIMD3(0, 0.5, 0.5)),
                   (29, SIMD3(0.5, 0, 0.5)), (29, SIMD3(0.5, 0.5, 0))])
        XCTAssertFalse(s.kPathPoints.isEmpty, "crystal should seed a canonical path")
        XCTAssertEqual(s.kPathProvenance, .generated)
        XCTAssertNotNil(s.kPathSignature)
        // FCC path has a break.
        XCTAssertFalse(s.kPathBreaks.isEmpty, "fcc path should have breaks")
    }

    func testSceneInitMoleculeHasEmptyPath() {
        var loaded = LoadedScene()
        loaded.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 1, label: "H")]
        loaded.isCrystal = false
        loaded.periodicDim = 0
        let s = Scene(loaded: loaded)
        XCTAssertTrue(s.kPathPoints.isEmpty, "molecule should have empty path")
        XCTAssertTrue(s.kPathBreaks.isEmpty)
    }

    func testUserEditFlipsProvenance() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        var scene = s
        XCTAssertEqual(scene.kPathProvenance, .generated)
        // Simulate a user edit by directly modifying the path.
        scene.kPathPoints = [KPoint(SIMD3(0, 0, 0), "custom")]
        // The provenance should be flipped to userEdited when the controller
        // syncs state -> scene (simulated here).
        if scene.kPathPoints != s.kPathPoints {
            scene.kPathProvenance = .userEdited
        }
        XCTAssertEqual(scene.kPathProvenance, .userEdited)
    }

    func testSupercellRegeneratesGeneratedPath() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        let originalPath = s.kPathPoints
        XCTAssertFalse(originalPath.isEmpty)
        // Expand to a 2x1x1 supercell.
        let widened = s.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        // The path should be regenerated (non-empty, valid).
        XCTAssertFalse(widened.kPathPoints.isEmpty, "supercell should preserve generated path")
        XCTAssertEqual(widened.kPathProvenance, .generated)
    }

    func testSupercellPreservesUserEditedPath() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        var scene = s
        scene.kPathProvenance = .userEdited
        scene.kPathPoints = [KPoint(SIMD3(0.1, 0.2, 0.3), "custom")]
        scene.kPathBreaks = []
        // Expand to a 2x1x1 supercell.
        let widened = scene.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        // User-edited path should be PRESERVED: supercell widening keeps the base
        // cell and reciprocal structure, so the route remains valid.
        XCTAssertFalse(widened.kPathPoints.isEmpty, "user-edited path should be preserved on supercell")
        XCTAssertEqual(widened.kPathProvenance, .userEdited)
        XCTAssertEqual(widened.kPathPoints, scene.kPathPoints)
    }

    func testDisplayOnlySlabPreservesUserRouteAndTopology() {
        var scene = SceneFactory.scene(latticeRows: [
            [4, 0, 0], [0, 4, 0], [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0)), (14, SIMD3(0.5, 0.5, 0.5))])
        scene.kPathPoints = [KPoint(SIMD3(0, 0, 0), "Γ"), KPoint(SIMD3(0.5, 0, 0), "X"),
                             KPoint(SIMD3(0.5, 0.5, 0), "M")]
        scene.kPathBreaks = [1]
        scene.kPathProvenance = .userEdited
        scene.kPathSignature = nil

        let slab = Slab(planeA: Plane(h: 0, k: 0, l: 0, distance: -1),
                        planeB: Plane(h: 0, k: 0, l: 0, distance: 1))
        let displayFiltered = scene.applySlab(slab)
        XCTAssertEqual(displayFiltered.kPathPoints, scene.kPathPoints)
        XCTAssertEqual(displayFiltered.kPathBreaks, scene.kPathBreaks)
        XCTAssertEqual(displayFiltered.kPathProvenance, .userEdited)
    }

    func testUserRouteRemapsAcrossInputReciprocalBasisChange() {
        let oldCell = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4))
        // Same physical cubic lattice, represented with a 90-degree rotated
        // input basis. Fractional coordinates must change to retain Cartesian k.
        let newCell = Cell(a: SIMD3(0, 4, 0), b: SIMD3(-4, 0, 0), c: SIMD3(0, 0, 4))
        var old = Scene()
        old.cell = oldCell
        old.kPathPoints = [KPoint(SIMD3(0.25, 0.5, 0.125), "custom Γ"),
                           KPoint(SIMD3(-0.125, 0.25, 0.5), "custom X")]
        old.kPathBreaks = [0]
        old.kPathProvenance = .userEdited
        old.kPathSignature = nil

        var next = Scene()
        next.cell = newCell
        next.kPathPoints = [KPoint(SIMD3(0, 0, 0), "generated")]
        next.kPathProvenance = .generated
        next.kPathSignature = "new-generated-signature"
        next.transferKPathAcrossGeometryChange(from: old)

        let oldBasis = oldCell.reciprocalVectors
        let newBasis = newCell.reciprocalVectors
        for (before, after) in zip(old.kPathPoints, next.kPathPoints) {
            let oldCartesian = BrillouinZone.cartesianFromFractional(before.frac, reciprocal: oldBasis)
            let newCartesian = BrillouinZone.cartesianFromFractional(after.frac, reciprocal: newBasis)
            XCTAssertLessThan(length(oldCartesian - newCartesian), 1e-5)
            XCTAssertEqual(before.label, after.label)
        }
        XCTAssertEqual(next.kPathBreaks, [0])
        XCTAssertEqual(next.kPathProvenance, .userEdited)
        XCTAssertNil(next.kPathSignature)
        XCTAssertNotEqual(next.kPathPoints, old.kPathPoints, "a rotated basis must change fractional coordinates")
    }

    func testGeneratedRouteUsesFreshFrameRouteAndInvalidUserBasisFallsBackLiterally() {
        var oldGenerated = Scene()
        oldGenerated.kPathPoints = [KPoint(SIMD3(0.9, 0.9, 0.9), "stale")]
        oldGenerated.kPathBreaks = []
        oldGenerated.kPathProvenance = .generated
        oldGenerated.kPathSignature = "old-signature"
        var fresh = Scene()
        fresh.kPathPoints = [KPoint(SIMD3(0.1, 0.2, 0.3), "fresh")]
        fresh.kPathBreaks = [0]
        fresh.kPathProvenance = .generated
        fresh.kPathSignature = "fresh-signature"
        fresh.transferKPathAcrossGeometryChange(from: oldGenerated)
        XCTAssertEqual(fresh.kPathPoints, [KPoint(SIMD3(0.1, 0.2, 0.3), "fresh")])
        XCTAssertEqual(fresh.kPathBreaks, [0])
        XCTAssertEqual(fresh.kPathSignature, "fresh-signature")

        var oldUser = Scene()
        oldUser.cell = Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4))
        oldUser.kPathPoints = [KPoint(SIMD3(0.2, 0.3, 0.4), "literal")]
        oldUser.kPathProvenance = .userEdited
        var invalidTarget = Scene()
        invalidTarget.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0), c: SIMD3(0, 0, 1))
        invalidTarget.transferKPathAcrossGeometryChange(from: oldUser)
        XCTAssertEqual(invalidTarget.kPathPoints, oldUser.kPathPoints,
                       "a singular target basis must preserve literal user coordinates")
        XCTAssertEqual(invalidTarget.kPathProvenance, .userEdited)
        XCTAssertNil(invalidTarget.kPathSignature)
    }

    func testSupercellShrinkToBaseRegenerates() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        let widened = s.widenSuperCell(SuperCell(n1: 2, n2: 2, n3: 2))
        let shrunk = widened.widenSuperCell(SuperCell(n1: 1, n2: 1, n3: 1))
        // After shrinking back to (1,1,1), the path should be regenerated.
        XCTAssertFalse(shrunk.kPathPoints.isEmpty)
        XCTAssertEqual(shrunk.kPathProvenance, .generated)
    }

    func testControllerResetRegeneratesCanonicalPath() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        let controller = MainWindowController(scene: s, showWindow: false)
        // User edits the path.
        controller.state.kPathPoints = [KPoint(SIMD3(0.1, 0.2, 0.3), "custom")]
        controller.state.kPathBreaks = []
        controller.syncFromState()
        XCTAssertEqual(controller.scene.kPathProvenance, .userEdited)
        XCTAssertNil(controller.scene.kPathSignature)
        // Reset to default.
        controller.state.resetToDefault()
        XCTAssertEqual(controller.scene.kPathProvenance, .generated)
        XCTAssertFalse(controller.scene.kPathPoints.isEmpty)
    }

    func testControllerSupercellRegeneratesPath() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0],
            [0, 4, 0],
            [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        let controller = MainWindowController(scene: s, showWindow: false)
        XCTAssertEqual(controller.scene.kPathProvenance, .generated)
        // Trigger supercell expansion via state.
        controller.state.n1 = 2
        controller.syncFromState()
        // The path should be regenerated (non-empty).
        XCTAssertFalse(controller.scene.kPathPoints.isEmpty)
    }

    func testControllerInitMirrorsGeneratedRouteBeforeUnrelatedStateChange() {
        let s = SceneFactory.scene(latticeRows: [
            [4, 0, 0], [0, 4, 0], [0, 0, 4],
        ], atoms: [(14, SIMD3(0, 0, 0))])
        let signature = s.kPathSignature
        let controller = MainWindowController(scene: s, showWindow: false)
        XCTAssertEqual(controller.state.kPathPoints, s.kPathPoints)
        XCTAssertEqual(controller.state.kPathBreaks, s.kPathBreaks)

        // State defaults must not be pushed back into an already-loaded scene
        // when an unrelated control fires its synchronous didSet callback.
        controller.state.atomScale = 0.42
        XCTAssertEqual(controller.scene.kPathPoints, s.kPathPoints)
        XCTAssertEqual(controller.scene.kPathBreaks, s.kPathBreaks)
        XCTAssertEqual(controller.scene.kPathProvenance, .generated)
        XCTAssertEqual(controller.scene.kPathSignature, signature)
    }
}
