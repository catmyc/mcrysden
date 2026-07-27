import XCTest
import simd
@testable import MolVisApp

final class StructureSummaryTests: XCTestCase {
    private func assertEqual(_ lhs: Double?, _ rhs: Double, _ accuracy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs else {
            XCTFail("expected non-nil value", file: file, line: line)
            return
        }
        XCTAssertEqual(lhs, rhs, accuracy: accuracy, file: file, line: line)
    }

    func testEmptySceneReturnsNil() {
        let scene = Scene()
        XCTAssertNil(StructureSummary(scene, symmetry: nil))
    }

    func testMolecularSceneNoCell() {
        var scene = Scene()
        scene.atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 8, label: "O"),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 1, 0), atomicNumber: 1, label: "H"),
        ]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        XCTAssertEqual(s.atomCount, 3)
        XCTAssertEqual(s.formula, "H2O")
        XCTAssertNil(s.latticeA)
        XCTAssertNil(s.alpha)
        XCTAssertNil(s.cellVolume)
        XCTAssertNil(s.density)
        XCTAssertNil(s.spaceGroupNumber)
        XCTAssertFalse(s.isCrystal)
    }

    func testCrystalSceneDensityAndLattice() {
        var scene = Scene()
        scene.cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 3, 0), c: SIMD3(0, 0, 7))
        scene.isCrystal = true
        scene.periodicDim = 3
        scene.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        assertEqual(s.latticeA, 5, 1e-6)
        assertEqual(s.latticeB, 3, 1e-6)
        assertEqual(s.latticeC, 7, 1e-6)
        assertEqual(s.alpha, 90, 1e-6)
        assertEqual(s.beta, 90, 1e-6)
        assertEqual(s.gamma, 90, 1e-6)
        assertEqual(s.cellVolume, 105, 1e-6)
        // ρ = (12.011) / (105 × 0.602214076)
        assertEqual(s.density, 12.011 / (105 * 0.602214076), 1e-6)
        XCTAssertTrue(s.isCrystal)
    }

    func testDensitySimpleCubicHydrogen() {
        var scene = Scene()
        scene.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        scene.isCrystal = true
        scene.periodicDim = 3
        scene.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 1, label: "H")]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        // ρ = 1.008 / (1 × 0.602214076) = 1.6739...
        assertEqual(s.density, 1.008 / 0.602214076, 1e-6)
    }

    func testHillFormulaWithCarbon() {
        var scene = Scene()
        // Methanol CH4O: C first, then H, then O alphabetically
        scene.atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 1, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 0, 1), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(1, 1, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(1, 0, 1), atomicNumber: 8, label: "O"),
        ]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        XCTAssertEqual(s.formula, "CH4O")
    }

    func testHillFormulaWithoutCarbon() {
        var scene = Scene()
        // NaCl: all alphabetical → ClNa
        scene.atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 11, label: "Na"),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 17, label: "Cl"),
        ]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        XCTAssertEqual(s.formula, "ClNa")
    }

    func testTriclinicAngles() {
        var scene = Scene()
        // Non-orthogonal cell: a=(1,0,0), b=(0,1,0), c=(1,1,1)
        // γ = angle(a,b) = 90°, β = angle(a,c) = acos(1/√3) ≈ 54.74°
        // α = angle(b,c) = acos(1/√3) ≈ 54.74°, vol = |a·(b×c)| = 1
        scene.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(1, 1, 1))
        scene.isCrystal = true
        scene.periodicDim = 3
        scene.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 1, label: "H")]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        let expectedAngle = acos(1.0 / sqrt(3.0)) * 180.0 / .pi
        assertEqual(s.gamma, 90, 1e-6)
        assertEqual(s.alpha, expectedAngle, 1e-4)
        assertEqual(s.beta, expectedAngle, 1e-4)
        assertEqual(s.cellVolume, 1, 1e-6)
    }

    func testSymmetryFieldsPopulated() {
        var scene = Scene()
        scene.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        scene.isCrystal = true
        scene.periodicDim = 3
        scene.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 13, label: "Al")]
        let symmetry = CrystalSymmetryAnalysis(
            symmetry: makeMinimalSymmetry(),
            unavailableReason: nil,
            tolerance: 1e-5
        )
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: symmetry))
        XCTAssertEqual(s.spaceGroupNumber, 225)
        XCTAssertEqual(s.spaceGroupSymbol, "Fm-3m")
        XCTAssertEqual(s.crystalSystem, "Cubic")
        XCTAssertEqual(s.bravaisLattice, "F Cubic")
        XCTAssertEqual(s.pointGroup, "m-3m")
        XCTAssertEqual(s.symmetryOperationCount, 1)
    }

    func testSymmetryUnavailableWhenNil() {
        var scene = Scene()
        scene.cell = Cell(a: SIMD3(1, 0, 0), b: SIMD3(0, 1, 0), c: SIMD3(0, 0, 1))
        scene.isCrystal = true
        scene.periodicDim = 3
        scene.atoms = [Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C")]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        XCTAssertNil(s.spaceGroupNumber)
        XCTAssertNil(s.spaceGroupSymbol)
        XCTAssertNil(s.crystalSystem)
        XCTAssertNil(s.bravaisLattice)
        XCTAssertNil(s.pointGroup)
        XCTAssertNil(s.symmetryOperationCount)
    }

    func testElementCounts() {
        var scene = Scene()
        scene.atoms = [
            Atom(coord: SIMD3(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3(1, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 1, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3(0, 0, 1), atomicNumber: 8, label: "O"),
            Atom(coord: SIMD3(1, 1, 0), atomicNumber: 8, label: "O"),
        ]
        let s = try! XCTUnwrap(StructureSummary(scene, symmetry: nil))
        XCTAssertEqual(s.elementCounts[6], 1)
        XCTAssertEqual(s.elementCounts[1], 2)
        XCTAssertEqual(s.elementCounts[8], 2)
    }

    func testElementTableMasses() {
        XCTAssertEqual(ElementTable.mass(1), 1.008, accuracy: 0.001)
        XCTAssertEqual(ElementTable.mass(6), 12.011, accuracy: 0.001)
        XCTAssertEqual(ElementTable.mass(26), 55.845, accuracy: 0.001)
        XCTAssertEqual(ElementTable.mass(79), 196.97, accuracy: 0.001)
        XCTAssertEqual(ElementTable.mass(118), 294.0, accuracy: 0.1)
        XCTAssertEqual(ElementTable.mass(0), 0.0, accuracy: 0.001)
    }

    func testMassClampsOutOfRange() {
        XCTAssertEqual(ElementTable.mass(-1), 0.0, accuracy: 0.001)
        // Z=9999 clamps to Og (118)
        XCTAssertEqual(ElementTable.mass(9999), 294.0, accuracy: 0.1)
    }
}

private func makeMinimalSymmetry() -> CrystalSymmetry {
    let identity = CrystalSymmetryMatrix([
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    ])
    let op = CrystalSymmetryOperation(
        rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1],
        translation: SIMD3(0, 0, 0)
    )
    let std = CrystalStandardizedStructure(
        latticeRows: identity,
        fractionalPositions: [SIMD3(0, 0, 0)],
        atomicTypes: [13],
        mappingToPrimitive: nil
    )
    return CrystalSymmetry(
        spaceGroupNumber: 225,
        internationalSymbol: "Fm-3m",
        hallNumber: nil,
        hallSymbol: nil,
        settingChoice: nil,
        pointGroupSymbol: "m-3m",
        crystalSystem: .cubic,
        bravaisLattice: CrystalBravaisLattice(system: .cubic, centering: .face),
        wyckoffLetters: ["a"],
        siteSymmetrySymbols: ["m-3m"],
        equivalentAtoms: [0],
        crystallographicOrbits: [0],
        inputToPrimitiveMapping: [0],
        symmetryOperations: [op],
        primitiveStructure: std,
        conventionalStructure: std,
        inputLattice: identity,
        preidealizedBravaisLattice: identity,
        detectedPrimitiveLattice: identity,
        standardizedLattice: identity,
        standardizedRotationMatrix: identity,
        inputToPreidealizedBravaisFractional: identity,
        preidealizedBravaisReciprocalToInput: identity,
        preidealizedBravaisToInputFractional: identity,
        inputReciprocalToPreidealizedBravais: identity,
        originShift: SIMD3(0, 0, 0),
        primitiveToConventionalFractional: identity,
        conventionalToPrimitiveFractional: identity,
        primitiveReciprocalToConventional: identity,
        conventionalReciprocalToPrimitive: identity,
        tolerance: 1e-5
    )
}
