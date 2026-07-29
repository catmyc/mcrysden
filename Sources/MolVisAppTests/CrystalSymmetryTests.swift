import XCTest
import simd
@testable import MolVisApp

final class CrystalSymmetryTests: XCTestCase {
    private let cubicRows: [[Double]] = [
        [4, 0, 0],
        [0, 4, 0],
        [0, 0, 4],
    ]

    private func scene(rows: [[Double]], atoms fractional: [(Int, SIMD3<Double>)]) -> Scene {
        scene(matrix: CrystalSymmetryMatrix(rows.flatMap { $0 }), atoms: fractional)
    }

    private func scene(matrix rows: CrystalSymmetryMatrix,
                       atoms fractional: [(Int, SIMD3<Double>)]) -> Scene {
        let vectors = (0..<3).map { row in
            SIMD3<Float>(Float(rows[row, 0]), Float(rows[row, 1]), Float(rows[row, 2]))
        }
        let cell = Cell(a: vectors[0], b: vectors[1], c: vectors[2])
        let swiftAtoms = fractional.map { type, f in
            let cartesian = rows.transposed.applying(to: f)
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

    private func cartesian(_ fractional: SIMD3<Double>, in rows: CrystalSymmetryMatrix) -> SIMD3<Double> {
        rows.transposed.applying(to: fractional)
    }

    private func assertCartesianEqual(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>, accuracy: Double = 1e-8,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }

    private func assertEqualModuloLattice(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>,
                                          latticeRows: CrystalSymmetryMatrix,
                                          accuracy: Double = 1e-7,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard let inverse = latticeRows.transposed.inverted() else {
            XCTFail("expected an invertible lattice", file: file, line: line)
            return
        }
        let difference = inverse.applying(to: lhs - rhs)
        XCTAssertEqual(difference.x, difference.x.rounded(), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(difference.y, difference.y.rounded(), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(difference.z, difference.z.rounded(), accuracy: accuracy, file: file, line: line)
    }

    private func changedBasis(_ rows: CrystalSymmetryMatrix,
                              by change: CrystalSymmetryMatrix) -> CrystalSymmetryMatrix {
        change.multiplied(by: rows)
    }

    private func changedFractionalCoordinates(_ points: [(Int, SIMD3<Double>)],
                                              by change: CrystalSymmetryMatrix) -> [(Int, SIMD3<Double>)] {
        guard let inverse = change.inverted() else { return points }
        return points.map { type, point in (type, inverse.transposed.applying(to: point)) }
    }

    private func symmetry(_ scene: Scene, file: StaticString = #filePath,
                          line: UInt = #line) -> CrystalSymmetry {
        guard let analysis = scene.crystalSymmetry, let symmetry = analysis.symmetry else {
            XCTFail("symmetry unavailable: \(scene.crystalSymmetry?.reasonDescription ?? "missing analysis")",
                    file: file, line: line)
            return CrystalSymmetryTests.placeholderSymmetry
        }
        return symmetry
    }

    private static let placeholderSymmetry = CrystalSymmetry(
        spaceGroupNumber: 0, internationalSymbol: "", hallNumber: nil, hallSymbol: nil,
        settingChoice: nil, pointGroupSymbol: "", crystalSystem: .unknown,
        bravaisLattice: CrystalBravaisLattice(system: .unknown, centering: .unknown),
        wyckoffLetters: [], siteSymmetrySymbols: [], equivalentAtoms: [],
        crystallographicOrbits: [], inputToPrimitiveMapping: [], symmetryOperations: [],
        primitiveStructure: CrystalStandardizedStructure(latticeRows: .identity,
                                                          fractionalPositions: [], atomicTypes: [],
                                                          mappingToPrimitive: nil),
        conventionalStructure: CrystalStandardizedStructure(latticeRows: .identity,
                                                             fractionalPositions: [], atomicTypes: [],
                                                             mappingToPrimitive: nil),
         inputLattice: .identity, preidealizedBravaisLattice: .identity,
         detectedPrimitiveLattice: .identity, standardizedLattice: .identity,
         standardizedRotationMatrix: .identity,
         inputToPreidealizedBravaisFractional: .identity,
         preidealizedBravaisReciprocalToInput: .identity,
         preidealizedBravaisToInputFractional: .identity,
         inputReciprocalToPreidealizedBravais: .identity,
         originShift: .zero,
         primitiveToConventionalFractional: .identity,
         conventionalToPrimitiveFractional: .identity,
         primitiveReciprocalToConventional: .identity,
         conventionalReciprocalToPrimitive: .identity, tolerance: 1e-5
    )

    func testPm3mSimpleCubic() {
        let s = scene(rows: cubicRows, atoms: [(14, SIMD3(0, 0, 0))])
        let result = symmetry(s)
        XCTAssertEqual(result.spaceGroupNumber, 221)
        XCTAssertEqual(result.internationalSymbol, "Pm-3m")
        XCTAssertEqual(result.pointGroupSymbol, "m-3m")
        XCTAssertEqual(result.crystalSystem, .cubic)
        XCTAssertEqual(result.bravaisLattice.centering, .primitive)
        XCTAssertEqual(result.symmetryOperations.count, 48)
        XCTAssertEqual(result.primitiveStructure.atomCount, 1)
        XCTAssertEqual(result.conventionalStructure.atomCount, 1)
        XCTAssertEqual(result.conventionalStructure.latticeRows.values,
                       [4, 0, 0, 0, 4, 0, 0, 0, 4])
        XCTAssertEqual(result.primitiveStructure.volume, result.conventionalStructure.volume,
                       accuracy: 1e-8)
    }

    func testIm3mBodyCenteredCubic() {
        let s = scene(rows: cubicRows, atoms: [
            (26, SIMD3(0, 0, 0)),
            (26, SIMD3(0.5, 0.5, 0.5)),
        ])
        let result = symmetry(s)
        XCTAssertEqual(result.spaceGroupNumber, 229)
        XCTAssertEqual(result.internationalSymbol, "Im-3m")
        XCTAssertEqual(result.bravaisLattice.centering, .body)
        XCTAssertEqual(result.primitiveStructure.atomCount, 1)
        XCTAssertEqual(result.conventionalStructure.atomCount, 2)
        XCTAssertEqual(result.conventionalStructure.volume / result.primitiveStructure.volume,
                       2, accuracy: 1e-8)
    }

    func testFm3mFaceCenteredCubic() {
        let s = scene(rows: cubicRows, atoms: [
            (29, SIMD3(0, 0, 0)),
            (29, SIMD3(0, 0.5, 0.5)),
            (29, SIMD3(0.5, 0, 0.5)),
            (29, SIMD3(0.5, 0.5, 0)),
        ])
        let result = symmetry(s)
        XCTAssertEqual(result.spaceGroupNumber, 225)
        XCTAssertEqual(result.internationalSymbol, "Fm-3m")
        XCTAssertEqual(result.bravaisLattice.centering, .face)
        XCTAssertEqual(result.primitiveStructure.atomCount, 1)
        XCTAssertEqual(result.conventionalStructure.atomCount, 4)
        XCTAssertEqual(result.conventionalStructure.volume / result.primitiveStructure.volume,
                       4, accuracy: 1e-8)
    }

    private func assertDatasetPrimitiveRepresentatives(
        _ scene: Scene,
        input fractional: [(Int, SIMD3<Double>)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CrystalSymmetry {
        let result = symmetry(scene, file: file, line: line)
        XCTAssertEqual(result.inputToPrimitiveMapping.count, fractional.count, file: file, line: line)
        XCTAssertEqual(Set(result.inputToPrimitiveMapping).count,
                       result.primitiveStructure.atomCount, file: file, line: line)
        XCTAssertEqual(result.primitiveStructure.atomicTypes.count,
                       result.primitiveStructure.atomCount, file: file, line: line)
        for (index, (type, point)) in fractional.enumerated() {
            let primitiveIndex = result.inputToPrimitiveMapping[index]
            guard result.primitiveStructure.fractionalPositions.indices.contains(primitiveIndex) else {
                XCTFail("primitive mapping is out of range", file: file, line: line)
                continue
            }
            XCTAssertEqual(result.primitiveStructure.atomicTypes[primitiveIndex], type,
                           "primitive representative must preserve type", file: file, line: line)
            let inputCartesian = cartesian(point, in: result.inputLattice)
            let primitiveCartesian = cartesian(
                result.primitiveStructure.fractionalPositions[primitiveIndex],
                in: result.primitiveStructure.latticeRows
            )
            assertEqualModuloLattice(primitiveCartesian, inputCartesian,
                                     latticeRows: result.primitiveStructure.latticeRows,
                                     file: file, line: line)
        }
        return result
    }

    func testDatasetPrimitiveMappingForNonDiagonalFaceCenteredCell() {
        let conventional = CrystalSymmetryMatrix(cubicRows.flatMap { $0 })
        let change = CrystalSymmetryMatrix([
            1, 1, 0,
            0, 1, 1,
            0, 0, 1,
        ])
        let input = [
            (29, SIMD3<Double>(0, 0, 0)),
            (29, SIMD3<Double>(0, 0.5, 0.5)),
            (29, SIMD3<Double>(0.5, 0, 0.5)),
            (29, SIMD3<Double>(0.5, 0.5, 0)),
        ]
        let transformed = changedFractionalCoordinates(input, by: change)
        let s = scene(matrix: changedBasis(conventional, by: change), atoms: transformed)
        let result = assertDatasetPrimitiveRepresentatives(s, input: transformed)
        XCTAssertEqual(result.primitiveStructure.atomCount, 1)
        XCTAssertEqual(result.primitiveStructure.atomicTypes, [29])
    }

    func testDatasetPrimitiveMappingForNonDiagonalBodyCenteredCell() {
        let conventional = CrystalSymmetryMatrix(cubicRows.flatMap { $0 })
        let change = CrystalSymmetryMatrix([
            1, 0, 1,
            0, 1, 1,
            0, 0, 1,
        ])
        let input = [
            (26, SIMD3<Double>(0, 0, 0)),
            (26, SIMD3<Double>(0.5, 0.5, 0.5)),
        ]
        let transformed = changedFractionalCoordinates(input, by: change)
        let s = scene(matrix: changedBasis(conventional, by: change), atoms: transformed)
        let result = assertDatasetPrimitiveRepresentatives(s, input: transformed)
        XCTAssertEqual(result.primitiveStructure.atomCount, 1)
        XCTAssertEqual(result.primitiveStructure.atomicTypes, [26])
    }

    func testDatasetPrimitiveMappingForNonDiagonalRhombohedralCell() {
        let a = 3.0
        let hexagonal: [[Double]] = [
            [a, 0, 0],
            [-a / 2, a * sqrt(3) / 2, 0],
            [0, 0, 7.0],
        ]
        let change = CrystalSymmetryMatrix([
            1, 1, 0,
            0, 1, 1,
            0, 0, 1,
        ])
        let input: [(Int, SIMD3<Double>)] = [
            (6, SIMD3(0, 0, 0)),
            (6, SIMD3(2.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)),
            (6, SIMD3(1.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0)),
        ]
        let base = CrystalSymmetryMatrix(hexagonal.flatMap { $0 })
        let transformed = changedFractionalCoordinates(input, by: change)
        let s = scene(matrix: changedBasis(base, by: change), atoms: transformed)
        let result = assertDatasetPrimitiveRepresentatives(s, input: transformed)
        XCTAssertEqual(result.primitiveStructure.atomicTypes, [6])
    }

    func testExposedMappingsPreserveCartesianCoordinatesForRotatedSkewedCell() {
        let conventional = CrystalSymmetryMatrix(cubicRows.flatMap { $0 })
        let change = CrystalSymmetryMatrix([
            1, 1, 0,
            0, 1, 1,
            0, 0, 1,
        ])
        let rotation = CrystalSymmetryMatrix([
            0, -1, 0,
            1, 0, 0,
            0, 0, 1,
        ])
        let input = [
            (29, SIMD3<Double>(0, 0, 0)),
            (29, SIMD3<Double>(0, 0.5, 0.5)),
            (29, SIMD3<Double>(0.5, 0, 0.5)),
            (29, SIMD3<Double>(0.5, 0.5, 0)),
        ]
        let transformed = changedFractionalCoordinates(input, by: change)
        let skewed = changedBasis(conventional, by: change)
        let rotated = skewed.multiplied(by: rotation.transposed)
        let result = symmetry(scene(matrix: rotated, atoms: transformed))

        let inputFractional = SIMD3<Double>(0.17, -0.21, 0.39)
        let bravaisFractional = result.inputToPreidealizedBravaisFractional
            .applying(to: inputFractional)
        assertCartesianEqual(
            cartesian(inputFractional, in: result.inputLattice),
            cartesian(bravaisFractional, in: result.preidealizedBravaisLattice)
        )
        let bravaisRecovered = result.preidealizedBravaisToInputFractional
            .applying(to: bravaisFractional)
        XCTAssertEqual(bravaisRecovered.x, inputFractional.x, accuracy: 1e-8)
        XCTAssertEqual(bravaisRecovered.y, inputFractional.y, accuracy: 1e-8)
        XCTAssertEqual(bravaisRecovered.z, inputFractional.z, accuracy: 1e-8)

        let bravaisReciprocal = SIMD3<Double>(0.13, -0.27, 0.31)
        let inputReciprocal = result.preidealizedBravaisReciprocalToInput
            .applying(to: bravaisReciprocal)
        let inputReciprocalCartesian = result.inputLattice.inverted()!
            .applying(to: inputReciprocal)
        let bravaisReciprocalCartesian = result.preidealizedBravaisLattice.inverted()!
            .applying(to: bravaisReciprocal)
        assertCartesianEqual(inputReciprocalCartesian, bravaisReciprocalCartesian)
        let recoveredReciprocal = result.inputReciprocalToPreidealizedBravais
            .applying(to: inputReciprocal)
        XCTAssertEqual(recoveredReciprocal.x, bravaisReciprocal.x, accuracy: 1e-8)
        XCTAssertEqual(recoveredReciprocal.y, bravaisReciprocal.y, accuracy: 1e-8)
        XCTAssertEqual(recoveredReciprocal.z, bravaisReciprocal.z, accuracy: 1e-8)

        let primitiveFractional = SIMD3<Double>(0.19, -0.22, 0.41)
        let conventionalFractional = result.primitiveToConventionalFractional
            .applying(to: primitiveFractional)
        assertCartesianEqual(
            cartesian(primitiveFractional, in: result.detectedPrimitiveLattice),
            cartesian(conventionalFractional, in: result.standardizedLattice)
        )
        let recoveredPrimitive = result.conventionalToPrimitiveFractional
            .applying(to: conventionalFractional)
        XCTAssertEqual(recoveredPrimitive.x, primitiveFractional.x, accuracy: 1e-8)
        XCTAssertEqual(recoveredPrimitive.y, primitiveFractional.y, accuracy: 1e-8)
        XCTAssertEqual(recoveredPrimitive.z, primitiveFractional.z, accuracy: 1e-8)

        let primitiveReciprocal = SIMD3<Double>(-0.11, 0.23, 0.37)
        let conventionalReciprocal = result.primitiveReciprocalToConventional
            .applying(to: primitiveReciprocal)
        let primitiveReciprocalCartesian = result.detectedPrimitiveLattice.inverted()!
            .applying(to: primitiveReciprocal)
        let conventionalReciprocalCartesian = result.standardizedLattice.inverted()!
            .applying(to: conventionalReciprocal)
        assertCartesianEqual(primitiveReciprocalCartesian, conventionalReciprocalCartesian)
        let recoveredConventionalReciprocal = result.conventionalReciprocalToPrimitive
            .applying(to: conventionalReciprocal)
        XCTAssertEqual(recoveredConventionalReciprocal.x, primitiveReciprocal.x, accuracy: 1e-8)
        XCTAssertEqual(recoveredConventionalReciprocal.y, primitiveReciprocal.y, accuracy: 1e-8)
        XCTAssertEqual(recoveredConventionalReciprocal.z, primitiveReciprocal.z, accuracy: 1e-8)
        XCTAssertTrue(result.standardizedRotationMatrix.isFinite3x3)
    }

    func testCRYSCALAsymmetricUnitDoesNotClaimSpaceGroup() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/crystal_Pt_fcc.r1")
        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .asymmetricUnit)
        let scene = Scene(loaded: loaded)
        XCTAssertNil(scene.crystalSymmetry?.symmetry)
        XCTAssertEqual(scene.crystalSymmetry?.unavailableReason,
                       .incompleteInput(.asymmetricUnit))
        XCTAssertTrue(scene.crystalSymmetry?.reasonDescription?.contains("asymmetric unit") == true)
    }

    func testCIFUnknownCompletenessDoesNotClaimSpaceGroup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-symmetry-unknown.cif")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        data_unknown_symmetry
        _cell_length_a 4.0
        _cell_length_b 4.0
        _cell_length_c 4.0
        _cell_angle_alpha 90
        _cell_angle_beta 90
        _cell_angle_gamma 90
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        Pt1 Pt 0 0 0
        """.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try Parser.load(url)
        XCTAssertEqual(loaded.symmetryInputCompleteness, .unknown)
        let scene = Scene(loaded: loaded)
        XCTAssertNil(scene.crystalSymmetry?.symmetry)
        XCTAssertEqual(scene.crystalSymmetry?.unavailableReason,
                       .incompleteInput(.unknown))
    }

    func testDiamondFixtureReportsFd3mAndStandardizesCounts() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si110.xsf")
        let s = Scene(loaded: try Parser.load(url))
        let result = symmetry(s)
        XCTAssertEqual(result.spaceGroupNumber, 227)
        XCTAssertEqual(result.internationalSymbol, "Fd-3m")
        XCTAssertEqual(result.primitiveStructure.atomCount, 2)
        XCTAssertEqual(result.conventionalStructure.atomCount, 8)
        XCTAssertEqual(result.inputToPrimitiveMapping.count, 2)
        XCTAssertEqual(result.conventionalStructure.mappingToPrimitive?.count, 8)
        XCTAssertEqual(result.conventionalStructure.volume / result.primitiveStructure.volume,
                       4, accuracy: 1e-7)
    }

    func testHexagonalP63mmc() {
        let a = 3.0
        let rows: [[Double]] = [
            [a, 0, 0],
            [-a / 2, a * sqrt(3) / 2, 0],
            [0, 0, 5.0],
        ]
        let s = scene(rows: rows, atoms: [
            (12, SIMD3(0, 0, 0)),
            (12, SIMD3(2.0 / 3.0, 1.0 / 3.0, 0.5)),
        ])
        let result = symmetry(s)
        XCTAssertEqual(result.spaceGroupNumber, 194)
        XCTAssertEqual(result.internationalSymbol, "P6_3/mmc")
        XCTAssertEqual(result.crystalSystem, .hexagonal)
        XCTAssertEqual(result.bravaisLattice.centering, .primitive)
    }

    func testWyckoffAndEquivalentAtomsForNaCl() {
        let fcc: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0.5, 0.5), SIMD3(0.5, 0, 0.5), SIMD3(0.5, 0.5, 0),
        ]
        let anion = fcc.map { $0 + SIMD3(0.5, 0.5, 0.5) }
        let s = scene(rows: cubicRows,
                      atoms: fcc.map { (11, $0) } + anion.map { (17, $0) })
        let result = symmetry(s)
        XCTAssertEqual(result.spaceGroupNumber, 225)
        XCTAssertEqual(result.conventionalStructure.atomCount, 8)
        XCTAssertEqual(result.primitiveStructure.atomCount, 2)
        XCTAssertEqual(Set(result.equivalentAtoms).count, 2)
        XCTAssertEqual(result.wyckoffLetters, ["a", "a", "a", "a", "b", "b", "b", "b"])
        XCTAssertTrue(result.siteSymmetrySymbols.allSatisfy { !$0.isEmpty })
    }

    func testTriclinicLowSymmetryStructureRemainsP1() {
        let rows: [[Double]] = [
            [3.1, 0, 0],
            [0.2, 4.2, 0],
            [0.1, 0.3, 5.1],
        ]
        let s = scene(rows: rows, atoms: [
            (6, SIMD3(0.123, 0.234, 0.345)),
            (8, SIMD3(0.481, 0.271, 0.619)),
        ])
        let result = symmetry(s)
        XCTAssertEqual(result.spaceGroupNumber, 1)
        XCTAssertEqual(result.crystalSystem, .triclinic)
        XCTAssertEqual(result.pointGroupSymbol, "1")
        XCTAssertEqual(result.symmetryOperations.count, 1)
    }

    func testRigidRotationAndAxisPermutationPreserveClassification() {
        let exact = scene(rows: cubicRows, atoms: [
            (14, SIMD3(0, 0, 0)),
            (14, SIMD3(0.25, 0.25, 0.25)),
        ])
        let rotatedRows = cubicRows.map { row in [-row[1], row[0], row[2]] }
        let rotated = scene(rows: rotatedRows, atoms: [
            (14, SIMD3(0, 0, 0)),
            (14, SIMD3(0.25, 0.25, 0.25)),
        ])
        let permuted = scene(rows: [cubicRows[1], cubicRows[0], cubicRows[2]], atoms: [
            (14, SIMD3(0, 0, 0)),
            (14, SIMD3(0.25, 0.25, 0.25)),
        ])
        let expected = symmetry(exact)
        XCTAssertEqual(symmetry(rotated).spaceGroupNumber, expected.spaceGroupNumber)
        XCTAssertEqual(symmetry(rotated).internationalSymbol, expected.internationalSymbol)
        XCTAssertEqual(symmetry(permuted).spaceGroupNumber, expected.spaceGroupNumber)
        XCTAssertEqual(symmetry(permuted).internationalSymbol, expected.internationalSymbol)
    }

    func testToleranceIsUsedExactlyOnceForPerturbedBcc() {
        let perturbed = scene(rows: cubicRows, atoms: [
            (26, SIMD3(0, 0, 0)),
            (26, SIMD3(0.50008, 0.5, 0.5)),
        ])
        let tight = CrystalSymmetryAnalyzer.analyze(cell: perturbed.cell,
                                                      atoms: perturbed.baseAtoms,
                                                      isCrystal: true, periodicDim: 3,
                                                      tolerance: 1e-6)
        let loose = CrystalSymmetryAnalyzer.analyze(cell: perturbed.cell,
                                                      atoms: perturbed.baseAtoms,
                                                      isCrystal: true, periodicDim: 3,
                                                      tolerance: 1e-3)
        XCTAssertEqual(tight.tolerance, 1e-6)
        XCTAssertEqual(loose.tolerance, 1e-3)
        XCTAssertNotEqual(tight.symmetry?.spaceGroupNumber, 229)
        XCTAssertEqual(loose.symmetry?.spaceGroupNumber, 229)
    }

    func testValidationRejectsMalformedInputWithoutTrapping() {
        let singular = Cell(a: SIMD3(4, 0, 0), b: SIMD3(8, 0, 0), c: SIMD3(0, 0, 4))
        let atom = Atom(coord: .zero, atomicNumber: 14, label: "Si")
        let singularResult = CrystalSymmetryAnalyzer.analyze(cell: singular, atoms: [atom],
                                                               isCrystal: true, periodicDim: 3)
        XCTAssertEqual(singularResult.unavailableReason, .singularCell)

        let nonfinite = CrystalSymmetryAnalyzer.analyze(
            cell: Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4)),
            atoms: [Atom(coord: SIMD3(Float.nan, 0, 0), atomicNumber: 14, label: "Si")],
            isCrystal: true, periodicDim: 3
        )
        XCTAssertEqual(nonfinite.unavailableReason, .nonFiniteAtom(0))

        let tooMany = Array(repeating: atom, count: CrystalSymmetryAnalyzer.baseAtomCap + 1)
        let oversized = CrystalSymmetryAnalyzer.analyze(
            cell: Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4)),
            atoms: tooMany, isCrystal: true, periodicDim: 3
        )
        XCTAssertEqual(oversized.unavailableReason,
                       .atomCountExceeded(CrystalSymmetryAnalyzer.baseAtomCap + 1,
                                          CrystalSymmetryAnalyzer.baseAtomCap))

        let invalidTolerance = CrystalSymmetryAnalyzer.analyze(
            cell: singular, atoms: [atom], isCrystal: true, periodicDim: 3, tolerance: 0
        )
        XCTAssertEqual(invalidTolerance.unavailableReason, .invalidTolerance)
        XCTAssertEqual(CrystalSymmetryAnalyzer.baseAtomCap, 4096)
        let tooTight = CrystalSymmetryAnalyzer.analyze(
            cell: singular, atoms: [atom], isCrystal: true, periodicDim: 3,
            tolerance: CrystalSymmetryAnalyzer.practicalToleranceRange.lowerBound / 10
        )
        XCTAssertEqual(tooTight.unavailableReason, .invalidTolerance)
        let tooLoose = CrystalSymmetryAnalyzer.analyze(
            cell: singular, atoms: [atom], isCrystal: true, periodicDim: 3,
            tolerance: CrystalSymmetryAnalyzer.practicalToleranceRange.upperBound * 10
        )
        XCTAssertEqual(tooLoose.unavailableReason, .invalidTolerance)
        let lowerBound = CrystalSymmetryAnalyzer.analyze(
            cell: Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4)),
            atoms: [atom], isCrystal: true, periodicDim: 3,
            tolerance: CrystalSymmetryAnalyzer.practicalToleranceRange.lowerBound
        )
        XCTAssertNotEqual(lowerBound.unavailableReason, .invalidTolerance)
        let upperBound = CrystalSymmetryAnalyzer.analyze(
            cell: Cell(a: SIMD3(4, 0, 0), b: SIMD3(0, 4, 0), c: SIMD3(0, 0, 4)),
            atoms: [atom], isCrystal: true, periodicDim: 3,
            tolerance: CrystalSymmetryAnalyzer.practicalToleranceRange.upperBound
        )
        XCTAssertNotEqual(upperBound.unavailableReason, .invalidTolerance)
        let slabLike = CrystalSymmetryAnalyzer.analyze(
            cell: singular, atoms: [atom], isCrystal: true, periodicDim: 2
        )
        XCTAssertEqual(slabLike.unavailableReason, .notThreeDimensional)
    }

    func testFractionalPositionsAreWrappedSafely() {
        let wrapped = scene(rows: cubicRows, atoms: [(14, SIMD3(1.25, -0.75, 2.0))])
        let result = symmetry(wrapped)
        XCTAssertEqual(result.spaceGroupNumber, 221)
        XCTAssertEqual(result.conventionalStructure.atomCount, 1)
    }

    func testAnalysisStaysOnBaseAtomsAfterSupercellWidening() {
        let base = scene(rows: cubicRows, atoms: [(14, SIMD3(0, 0, 0))])
        let widened = base.widenSuperCell(SuperCell(n1: 2, n2: 1, n3: 1))
        XCTAssertEqual(widened.atoms.count, 2)
        XCTAssertEqual(widened.crystalSymmetry?.symmetry?.spaceGroupNumber, 221)
        XCTAssertEqual(widened.crystalSymmetry?.symmetry?.conventionalStructure.atomCount, 1)
    }

    @MainActor
    func testAnimationRecomputesSymmetryAndPreservesEditedKPath() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.latch.axsf")
        let frame0 = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0))
        let frame1 = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 1))
        XCTAssertNotNil(frame0.crystalSymmetry?.symmetry)
        XCTAssertNotNil(frame1.crystalSymmetry?.symmetry)
        XCTAssertNotEqual(frame0.crystalSymmetry?.symmetry?.spaceGroupNumber,
                          frame1.crystalSymmetry?.symmetry?.spaceGroupNumber)

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(frame0, from: url, frameIndex: 0)
        let edited = [KPoint(SIMD3<Float>(0, 0, 0), "edited")]
        // Provenance is the source of truth on the state; set it before the geometry
        // so the synchronous onChange -> syncFromState adopts .userEdited and the
        // frame reload transfers (rather than regenerates) the route.
        controller.state.kPathProvenance = .userEdited
        controller.state.kPathSignature = nil
        controller.state.kPathPoints = edited
        XCTAssertEqual(controller.scene.kPathPoints, edited)
        controller.state.frameIndex = 1
        XCTAssertEqual(controller.scene.currentFrame, 1)
        XCTAssertEqual(controller.scene.kPathPoints, edited)
        XCTAssertEqual(controller.scene.crystalSymmetry?.symmetry?.spaceGroupNumber,
                       frame1.crystalSymmetry?.symmetry?.spaceGroupNumber)
    }

    @MainActor
    func testSidebarReceivesReadOnlySymmetryForFreshCrystalLoad() {
        let crystal = scene(rows: cubicRows, atoms: [(14, SIMD3(0, 0, 0))])
        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(crystal)
        XCTAssertEqual(controller.state.crystalSymmetry?.symmetry?.spaceGroupNumber, 221)
        XCTAssertEqual(controller.state.crystalSymmetry?.symmetry?.crystalSystem, .cubic)
        XCTAssertEqual(controller.state.crystalSymmetry?.symmetry?.bravaisLattice.centering, .primitive)
    }

    @MainActor
    func testControllerInitializesSidebarFromLoadedScene() {
        var crystal = scene(rows: cubicRows, atoms: [(14, SIMD3(0, 0, 0))])
        crystal.displayMode = .spaceFill
        crystal.atomScale = 0.72
        crystal.showStructure = false
        let controller = MainWindowController(scene: crystal, showWindow: false)
        XCTAssertEqual(controller.state.displayMode, .spaceFill)
        XCTAssertEqual(controller.state.atomScale, 0.72, accuracy: 1e-6)
        XCTAssertFalse(controller.state.showStructure)
        XCTAssertEqual(controller.state.crystalSymmetry?.symmetry?.spaceGroupNumber, 221)
    }

    @MainActor
    func testWindowCloseStopsPlayback() throws {
        let url = URL(fileURLWithPath: #file).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/si.latch.axsf")
        let initial = Scene(loaded: try Parser.load(url, as: nil, frameIndex: 0))
        let controller = MainWindowController(scene: initial, showWindow: false)
        controller.loadFile(initial, from: url, frameIndex: 0)
        controller.state.isPlaying = true
        XCTAssertTrue(controller.state.isPlaying)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification,
                                                 object: controller.window))
        XCTAssertFalse(controller.state.isPlaying)
    }

    func testSceneCodableDoesNotPersistDerivedSymmetry() throws {
        let s = scene(rows: cubicRows, atoms: [(14, SIMD3(0, 0, 0))])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-symmetry-state.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try StateStore.save(s, camera: nil, sourceURL: nil, to: url)
        let stateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(stateObject["crystalSymmetry"])
        let data = try JSONEncoder().encode(s)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["crystalSymmetry"])
        var legacyObject = object
        legacyObject.removeValue(forKey: "crystalSymmetry")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(Scene.self, from: legacyData)
        XCTAssertNil(decoded.crystalSymmetry)
    }
}
