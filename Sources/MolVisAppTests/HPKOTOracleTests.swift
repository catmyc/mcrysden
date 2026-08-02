import Foundation
import XCTest
import simd
@testable import MolVisApp

// Oracle fixtures were generated with SeekPath 2.1.0.  They retain both
// SeekPath's canonical primitive reciprocal basis and the basis returned by
// get_path_orig_cell, which is the independent input-oriented expectation.

private struct HPKOTFixture: Decodable {
    let lattice: [[Double]]
    let positions: [[Double]]
    let numbers: [Int]
    let expected_variant: String
    let expected_labels: [String]
    let expected_breaks: [Int]
    let expected_coords: [[Double]]
    let reciprocal_primitive_lattice: [[Double]]
    let input_oriented_reciprocal_primitive_lattice: [[Double]]
}

private enum HPKOTOracle {
    static let fixtures: [String: HPKOTFixture] = {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hpkot_oracle.json")
        guard let data = try? Data(contentsOf: url),
              let fixtures = try? JSONDecoder().decode([String: HPKOTFixture].self, from: data) else {
            return [:]
        }
        return fixtures
    }()
}

private typealias ReciprocalBasis = (
    a: SIMD3<Float>,
    b: SIMD3<Float>,
    c: SIMD3<Float>
)

final class HPKOTOracleTests: XCTestCase {

    private func makeScene(_ fixture: HPKOTFixture) -> Scene? {
        makeScene(latticeRows: fixture.lattice,
                  positions: fixture.positions,
                  numbers: fixture.numbers)
    }

    private func makeScene(latticeRows: [[Double]],
                           positions: [[Double]],
                           numbers: [Int]) -> Scene? {
        guard latticeRows.count == 3,
              latticeRows.allSatisfy({ $0.count == 3 }),
              latticeRows.flatMap({ $0 }).allSatisfy({ $0.isFinite }),
              positions.count == numbers.count,
              positions.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isFinite }) }) else {
            return nil
        }

        let matrix = CrystalSymmetryMatrix(latticeRows.flatMap { $0 })
        let vectors = (0..<3).map { row in
            SIMD3<Float>(Float(matrix[row, 0]), Float(matrix[row, 1]), Float(matrix[row, 2]))
        }
        let cell = Cell(a: vectors[0], b: vectors[1], c: vectors[2])
        let atoms = zip(numbers, positions).map { number, fractional in
            let f = SIMD3<Double>(fractional[0], fractional[1], fractional[2])
            let cartesian = matrix.transposed.applying(to: f)
            return Atom(
                coord: SIMD3<Float>(Float(cartesian.x), Float(cartesian.y), Float(cartesian.z)),
                atomicNumber: number,
                label: ElementTable.symbol(number)
            )
        }

        var loaded = LoadedScene()
        loaded.atoms = atoms
        loaded.cell = cell
        loaded.isCrystal = true
        loaded.periodicDim = 3
        return Scene(loaded: loaded)
    }

    private func fixtureBasis(_ rows: [[Double]],
                              context: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) -> ReciprocalBasis? {
        guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else {
            XCTFail("\(context): expected a 3x3 reciprocal basis", file: file, line: line)
            return nil
        }
        return basisFromFlat(rows.flatMap { $0 }, context: context, file: file, line: line)
    }

    private func basisFromFlat(_ values: [Double],
                               context: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> ReciprocalBasis? {
        guard values.count == 9, values.allSatisfy({ $0.isFinite }) else {
            XCTFail("\(context): expected nine finite reciprocal-basis values", file: file, line: line)
            return nil
        }
        return (
            a: SIMD3<Float>(Float(values[0]), Float(values[1]), Float(values[2])),
            b: SIMD3<Float>(Float(values[3]), Float(values[4]), Float(values[5])),
            c: SIMD3<Float>(Float(values[6]), Float(values[7]), Float(values[8]))
        )
    }

    private func flatRows(_ basis: ReciprocalBasis) -> [Double] {
        [
            Double(basis.a.x), Double(basis.a.y), Double(basis.a.z),
            Double(basis.b.x), Double(basis.b.y), Double(basis.b.z),
            Double(basis.c.x), Double(basis.c.y), Double(basis.c.z),
        ]
    }

    private func assertVector(_ actual: SIMD3<Float>,
                              equals expected: SIMD3<Float>,
                              accuracy: Float,
                              context: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "\(context).x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "\(context).y", file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "\(context).z", file: file, line: line)
    }

    private func assertBasis(_ actual: ReciprocalBasis,
                             equals expected: ReciprocalBasis,
                             accuracy: Float = 1e-4,
                             context: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        assertVector(actual.a, equals: expected.a, accuracy: accuracy, context: "\(context).a", file: file, line: line)
        assertVector(actual.b, equals: expected.b, accuracy: accuracy, context: "\(context).b", file: file, line: line)
        assertVector(actual.c, equals: expected.c, accuracy: accuracy, context: "\(context).c", file: file, line: line)
    }

    private func cartesian(_ fractional: SIMD3<Float>, in basis: ReciprocalBasis) -> SIMD3<Float> {
        basis.a * fractional.x + basis.b * fractional.y + basis.c * fractional.z
    }

    private func assertCartesianMapping(_ path: [HPKOTPath],
                                        mapped: [HPKOTPath],
                                        expectedInputOrientedBasis: ReciprocalBasis,
                                        inputCell: Cell,
                                        context: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertEqual(mapped.count, path.count, "\(context): mapped point count", file: file, line: line)
        let inputReciprocal = inputCell.reciprocalVectors
        for (index, (point, mappedPoint)) in zip(path, mapped).enumerated() {
            XCTAssertEqual(mappedPoint.label, point.label, "\(context) point \(index): label", file: file, line: line)
            let expectedCartesian = cartesian(point.frac, in: expectedInputOrientedBasis)
            let actualCartesian = inputReciprocal.a * mappedPoint.frac.x
                + inputReciprocal.b * mappedPoint.frac.y
                + inputReciprocal.c * mappedPoint.frac.z
            assertVector(actualCartesian, equals: expectedCartesian, accuracy: 2e-3,
                         context: "\(context) point \(index) \(point.label)", file: file, line: line)
        }
    }

    func testAll29VariantsMatchSeekPath() {
        XCTAssertEqual(HPKOTOracle.fixtures.count, 29, "expected all 29 extended-Bravais fixtures")

        for (name, fixture) in HPKOTOracle.fixtures.sorted(by: { $0.key < $1.key }) {
            guard let scene = makeScene(fixture) else {
                XCTFail("\(name): malformed fixture scene")
                continue
            }
            guard let symmetry = scene.crystalSymmetry?.symmetry else {
                XCTFail("\(name): symmetry unavailable")
                continue
            }
            guard let result = HPKOTGenerator.generate(for: symmetry) else {
                XCTFail("\(name): HPKOT generation failed")
                continue
            }
            guard let cell = scene.cell,
                  let canonicalExpected = fixtureBasis(fixture.reciprocal_primitive_lattice,
                                                       context: "\(name) canonical oracle"),
                  let inputOrientedExpected = fixtureBasis(
                    fixture.input_oriented_reciprocal_primitive_lattice,
                    context: "\(name) input-oriented oracle"
                  ) else {
                continue
            }

            XCTAssertEqual(result.variant, fixture.expected_variant, "\(name): variant")
            XCTAssertEqual(result.points.map(\.label), fixture.expected_labels, "\(name): labels")
            XCTAssertEqual(result.breaks, fixture.expected_breaks, "\(name): breaks")
            XCTAssertEqual(result.points.count, fixture.expected_coords.count, "\(name): point count")

            for (index, (point, expected)) in zip(result.points, fixture.expected_coords).enumerated() {
                guard expected.count == 3 else {
                    XCTFail("\(name) point \(index): malformed coordinate oracle")
                    continue
                }
                XCTAssertEqual(point.frac.x, Float(expected[0]), accuracy: 1e-5, "\(name) point \(index) x")
                XCTAssertEqual(point.frac.y, Float(expected[1]), accuracy: 1e-5, "\(name) point \(index) y")
                XCTAssertEqual(point.frac.z, Float(expected[2]), accuracy: 1e-5, "\(name) point \(index) z")
            }

            // Canonical values are get_path's primitive reciprocal basis.
            assertBasis(result.canonicalPrimRecip, equals: canonicalExpected,
                        context: "\(name) canonical primitive reciprocal")

            // This is independently generated by SeekPath.get_path_orig_cell,
            // not reconstructed from this implementation's standardization.
            assertBasis(result.inputOrientedPrimRecip, equals: inputOrientedExpected,
                        context: "\(name) input-oriented primitive reciprocal")

            let mapped = HPKOTGenerator.mapToInputReciprocal(
                result.points,
                breaks: result.breaks,
                inputOrientedPrimRecip: result.inputOrientedPrimRecip,
                inputCell: cell
            )
            assertCartesianMapping(result.points, mapped: mapped.points,
                                   expectedInputOrientedBasis: inputOrientedExpected,
                                   inputCell: cell, context: "\(name) input mapping")
        }
    }

    func testRotatedBasisAndSafeFailureContracts() {
        assertTriclinicRotation(fixtureName: "aP2", angle: .pi / 4)
        assertTriclinicRotation(fixtureName: "aP3", angle: .pi / 6)
        assertCF1RotatedCellUsesCubicEquivalentFrame()

        let unit = CrystalSymmetryMatrix([1, 0, 0, 0, 1, 0, 0, 0, 1])
        let selection = VariantSelect.select(
            spaceGroup: 71,
            a: 3, b: 3, c: 3,
            cosalpha: 0, cosbeta: 0, cosgamma: 0,
            centering: .body,
            hallNumber: nil,
            standardizedLattice: unit,
            transformation: .identity
        )
        // SeekPath sorts [(c, 1), (b, 3), (a, 2)] with Python's complete
        // tuple ordering. At an exact tie that selects the b entry, oI3.
        XCTAssertEqual(selection?.variant, "oI3")

        // Invalid selector metrics, evaluator expressions, and singular cells
        // must fail safely instead of producing a malformed HPKOT path.
        XCTAssertNil(VariantSelect.select(
            spaceGroup: 75,
            a: .nan, b: 1, c: 1,
            cosalpha: 0, cosbeta: 0, cosgamma: 0,
            centering: .primitive,
            hallNumber: nil,
            standardizedLattice: unit,
            transformation: .identity
        ))
        XCTAssertNil(VariantSelect.select(
            spaceGroup: 75,
            a: 1, b: 0, c: 1,
            cosalpha: 0, cosbeta: 0, cosgamma: 0,
            centering: .primitive,
            hallNumber: nil,
            standardizedLattice: unit,
            transformation: .identity
        ))
        XCTAssertNil(VariantSelect.select(
            spaceGroup: 75,
            a: 1, b: 1, c: 1,
            cosalpha: 0, cosbeta: 1.01, cosgamma: 0,
            centering: .primitive,
            hallNumber: nil,
            standardizedLattice: unit,
            transformation: .identity
        ))
        XCTAssertNil(KParamEval.evalCompound(
            "totally_unknown_expr(a,b,c)",
            1, 1, 1, 0, 0, 0, [:]
        ))
        XCTAssertNil(KParamEval.evalCompound(
            "1-Z*b*b/a/a",
            1, 1, 1, 0, 0, 0, [:]
        ))
        XCTAssertNil(KParamEval.evalSimple("not_a_known_value", [:]))
        XCTAssertNil(KParamEval.evalSimple("X", [:]))

        let singular = CrystalSymmetryMatrix([1, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNil(VariantSelect.select(
            spaceGroup: 1,
            a: 1, b: 1, c: 1,
            cosalpha: 0, cosbeta: 0, cosgamma: 0,
            centering: .primitive,
            hallNumber: nil,
            standardizedLattice: singular,
            transformation: .identity
        ))
    }

    private func rotationAroundZ(_ angle: Double) -> [[Double]] {
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        return [
            [cosAngle, -sinAngle, 0],
            [sinAngle, cosAngle, 0],
            [0, 0, 1],
        ]
    }

    /// Row-vector direct and reciprocal bases transform as rows * R^T.
    private func rotateRows(_ rows: [[Double]], by rotation: [[Double]]) -> [[Double]] {
        var result = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                for component in 0..<3 {
                    result[row][column] += rows[row][component] * rotation[column][component]
                }
            }
        }
        return result
    }

    private func matches(_ actual: ReciprocalBasis,
                         flatExpected: [Double],
                         accuracy: Float) -> Bool {
        let actualValues = flatRows(actual)
        guard flatExpected.count == actualValues.count else { return false }
        return zip(actualValues, flatExpected).allSatisfy {
            abs($0 - $1) <= Double(accuracy)
        }
    }

    private func assertTriclinicRotation(fixtureName: String, angle: Double) {
        guard let fixture = HPKOTOracle.fixtures[fixtureName],
              let baselineInputBasis = fixtureBasis(
                fixture.input_oriented_reciprocal_primitive_lattice,
                context: "\(fixtureName) baseline input-oriented oracle"
              ) else {
            XCTFail("missing \(fixtureName) fixture")
            return
        }
        let rotation = rotationAroundZ(angle)
        let rotatedLattice = rotateRows(fixture.lattice, by: rotation)
        guard let scene = makeScene(
            latticeRows: rotatedLattice,
            positions: fixture.positions,
            numbers: fixture.numbers
        ), let symmetry = scene.crystalSymmetry?.symmetry,
           let result = HPKOTGenerator.generate(for: symmetry),
           let cell = scene.cell,
           let expectedBasis = fixtureBasis(
            rotateRows([
                [Double(baselineInputBasis.a.x), Double(baselineInputBasis.a.y), Double(baselineInputBasis.a.z)],
                [Double(baselineInputBasis.b.x), Double(baselineInputBasis.b.y), Double(baselineInputBasis.b.z)],
                [Double(baselineInputBasis.c.x), Double(baselineInputBasis.c.y), Double(baselineInputBasis.c.z)],
            ], by: rotation),
            context: "\(fixtureName) physically rotated input-oriented oracle"
           ) else {
            XCTFail("\(fixtureName): rotated scene generation failed")
            return
        }

        XCTAssertEqual(result.variant, fixture.expected_variant, "\(fixtureName): rotation changed variant")
        // These asymmetric aP fixtures have no nontrivial proper rotational
        // freedom that could silently relabel the frame, so strict physical
        // covariance is expected.
        assertBasis(result.inputOrientedPrimRecip, equals: expectedBasis, accuracy: 2e-4,
                    context: "\(fixtureName) rotated input-oriented primitive reciprocal")

        let mapped = HPKOTGenerator.mapToInputReciprocal(
            result.points,
            breaks: result.breaks,
            inputOrientedPrimRecip: result.inputOrientedPrimRecip,
            inputCell: cell
        )
        assertCartesianMapping(result.points, mapped: mapped.points,
                               expectedInputOrientedBasis: expectedBasis,
                               inputCell: cell,
                               context: "\(fixtureName) rotated input mapping")
    }

    private func cubicProperRotations() -> [[Double]] {
        let permutations = [
            [0, 1, 2], [0, 2, 1], [1, 0, 2],
            [1, 2, 0], [2, 0, 1], [2, 1, 0],
        ]
        let signs: [Double] = [-1, 1]
        var rotations: [[Double]] = []
        for permutation in permutations {
            var inversions = 0
            for i in 0..<3 {
                for j in (i + 1)..<3 where permutation[i] > permutation[j] {
                    inversions += 1
                }
            }
            let permutationDeterminant: Double = inversions.isMultiple(of: 2) ? 1 : -1
            for sx in signs {
                for sy in signs {
                    for sz in signs where permutationDeterminant * sx * sy * sz == 1 {
                        let rowSigns = [sx, sy, sz]
                        var matrix = Array(repeating: 0.0, count: 9)
                        for row in 0..<3 {
                            matrix[row * 3 + permutation[row]] = rowSigns[row]
                        }
                        rotations.append(matrix)
                    }
                }
            }
        }
        return rotations
    }

    private func assertCF1RotatedCellUsesCubicEquivalentFrame() {
        let rotation = rotationAroundZ(.pi / 3)
        guard let fixture = HPKOTOracle.fixtures["cF1"],
              let baselineBasis = fixtureBasis(
                fixture.input_oriented_reciprocal_primitive_lattice,
                context: "cF1 baseline input-oriented oracle"
              ),
              let scene = makeScene(
                latticeRows: rotateRows(fixture.lattice, by: rotation),
                positions: fixture.positions,
                numbers: fixture.numbers
              ),
              let symmetry = scene.crystalSymmetry?.symmetry,
              let result = HPKOTGenerator.generate(for: symmetry),
              let cell = scene.cell else {
            XCTFail("cF1: rotated scene generation failed")
            return
        }

        XCTAssertEqual(result.variant, fixture.expected_variant, "cF1: rotation changed variant")

        // A cubic crystal has 24 proper point-group rotations. spglib may
        // choose any symmetry-equivalent conventional frame after a physical
        // rotation, so strict B0 * R^T covariance is not a unique contract.
        // SeekPath-equivalent frames are B0 * W * R^T for W in that group.
        let baselineRows = flatRows(baselineBasis)
        let candidates = cubicProperRotations().map { cubicRotation in
            let cubicEquivalent = matMultiply(baselineRows, cubicRotation)
            return rotateRows([
                Array(cubicEquivalent[0..<3]),
                Array(cubicEquivalent[3..<6]),
                Array(cubicEquivalent[6..<9]),
            ], by: rotation).flatMap { $0 }
        }
        guard let matchedRows = candidates.first(where: {
            matches(result.inputOrientedPrimRecip, flatExpected: $0, accuracy: 2e-4)
        }), let expectedBasis = basisFromFlat(
            matchedRows,
            context: "cF1 cubic-equivalent rotated oracle"
        ) else {
            XCTFail("cF1: input-oriented basis is not a proper cubic equivalent of the rotated oracle")
            return
        }

        assertBasis(result.inputOrientedPrimRecip, equals: expectedBasis, accuracy: 2e-4,
                    context: "cF1 cubic-equivalent input-oriented primitive reciprocal")
        let mapped = HPKOTGenerator.mapToInputReciprocal(
            result.points,
            breaks: result.breaks,
            inputOrientedPrimRecip: result.inputOrientedPrimRecip,
            inputCell: cell
        )
        assertCartesianMapping(result.points, mapped: mapped.points,
                               expectedInputOrientedBasis: expectedBasis,
                               inputCell: cell,
                               context: "cF1 cubic-equivalent input mapping")
    }

}
