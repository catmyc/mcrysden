import simd
import XCTest

@testable import MolVisApp

final class CenteringDetectionTests: XCTestCase {
    private let cubicCell = Cell(a: SIMD3(1, 0, 0),
                                  b: SIMD3(0, 1, 0),
                                  c: SIMD3(0, 0, 1))

    func testLargePrimitiveBodyAndFaceCellsUseBoundedLookupWork() {
        let primitiveFractions = randomFractions(count: 4_096, seed: 0x13579BDF)
        assertCentering(.primitive, fractions: primitiveFractions,
                        maximumComparisons: primitiveFractions.count * 4 * 27)

        let bodyFractions = centeredFractions(baseCount: 2_048,
                                              offsets: [SIMD3(0.5, 0.5, 0.5)],
                                              seed: 0x2468ACE0)
        assertCentering(.body, fractions: bodyFractions,
                        maximumComparisons: bodyFractions.count * 4 * 27)

        let faceFractions = centeredFractions(baseCount: 1_024,
                                              offsets: [SIMD3(0.5, 0.5, 0),
                                                       SIMD3(0.5, 0, 0.5),
                                                       SIMD3(0, 0.5, 0.5)],
                                              seed: 0x10203040)
        assertCentering(.face, fractions: faceFractions,
                        maximumComparisons: faceFractions.count * 4 * 27)
    }

    func testMixedSpeciesPreventCenteringAndDuplicatesRemainEquivalent() {
        let bodyFractions = [SIMD3<Float>(0, 0, 0), SIMD3(0.5, 0.5, 0.5)]
        let mixed = [Atom(coord: cubicCell.cartesian(bodyFractions[0]), atomicNumber: 14, label: "Si"),
                     Atom(coord: cubicCell.cartesian(bodyFractions[1]), atomicNumber: 8, label: "O")]
        assertCentering(.primitive, fractions: bodyFractions, atoms: mixed)

        let duplicated = bodyFractions.flatMap { fraction in
            [Atom(coord: cubicCell.cartesian(fraction), atomicNumber: 14, label: "Si"),
             Atom(coord: cubicCell.cartesian(fraction), atomicNumber: 14, label: "Si")]
        }
        assertCentering(.body, fractions: bodyFractions, atoms: duplicated)
    }

    func testUnbalancedDuplicateMultiplicityCannotFakeBodyCentering() {
        let fractions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0),
                         SIMD3<Float>(0.5, 0.5, 0.5)]
        assertCentering(.primitive, fractions: fractions)
    }

    func testBalancedDuplicateMultiplicitySupportsBodyAndFaceCentering() {
        let body = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0),
                     SIMD3<Float>(0.5, 0.5, 0.5), SIMD3<Float>(0.5, 0.5, 0.5)]
        assertCentering(.body, fractions: body)

        let offsets = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0.5, 0),
                       SIMD3<Float>(0.5, 0, 0.5), SIMD3<Float>(0, 0.5, 0.5)]
        let face = offsets.flatMap { [$0, $0] }
        assertCentering(.face, fractions: face)
    }

    func testLargeSameBinClusterPrimitiveLookupStaysBounded() {
        let fractions = Array(repeating: SIMD3<Float>(0.125, 0.2, 0.3), count: 4_096)
        var comparisons = 0
        let actual = Lattice.detectCentering(atoms(fractions), cell: cubicCell,
                                             candidateComparisons: &comparisons)
        assertCentering(.primitive, actual: actual)
        XCTAssertLessThanOrEqual(comparisons, fractions.count * 4 * 27)
    }

    func testAdversarialClusterFallsBackAtComparisonBudget() {
        let sourceCount = 1_365
        let source = (0..<sourceCount).map { index in
            SIMD3<Float>(0.1001 + Float(index) * 0.0000001, 0.2, 0.3)
        }
        let mismatches = Array(repeating: SIMD3<Float>(0.612, 0.7, 0.8), count: sourceCount)
        let nearMatches = source.reversed().map {
            SIMD3<Float>($0.x + 0.508, 0.7, 0.8)
        } + [SIMD3<Float>(source[0].x + 0.508, 0.7, 0.8)]
        let fractions = source + mismatches + nearMatches
        XCTAssertEqual(fractions.count, 4_096)
        var comparisons = 0
        let actual = Lattice.detectCentering(atoms(fractions), cell: cubicCell,
                                             candidateComparisons: &comparisons)

        assertCentering(.primitive, actual: actual)
        XCTAssertGreaterThan(comparisons, 100_000)
        XCTAssertLessThanOrEqual(comparisons, fractions.count * 4 * 27)
    }

    func testPeriodicToleranceAcrossZeroOneBoundary() {
        // The x coordinates of the base and yz-translated sites differ across
        // the periodic boundary by 0.001, below the existing 0.01 tolerance.
        let fractions = [SIMD3<Float>(0.9995, 0.2, 0.3),
                         SIMD3<Float>(0.4995, 0.7, 0.3),
                         SIMD3<Float>(0.4995, 0.2, 0.8),
                         SIMD3<Float>(0.0005, 0.7, 0.8)]
        assertCentering(.face, fractions: fractions)
    }

    func testSkewCellUsesFractionalCoordinatesForCentering() {
        let cell = Cell.fromLattice(a: 4, b: 5, c: 6,
                                    alpha: 74, beta: 83, gamma: 67)
        let fractions = [SIMD3<Float>(0.13, 0.27, 0.41),
                         SIMD3<Float>(0.63, 0.77, 0.91)]
        let skewAtoms = atoms(fractions, cell: cell)
        assertCentering(.body, fractions: fractions, atoms: skewAtoms, cell: cell)
    }

    func testRepeatedDetectionIsDeterministicIncludingLookupWork() {
        let fractions = centeredFractions(baseCount: 1_024,
                                          offsets: [SIMD3(0.5, 0.5, 0),
                                                    SIMD3(0.5, 0, 0.5),
                                                    SIMD3(0, 0.5, 0.5)],
                                          seed: 0x55667788)
        let atoms = atoms(fractions)
        var firstComparisons = 0
        var secondComparisons = 0
        let first = Lattice.detectCentering(atoms, cell: cubicCell,
                                            candidateComparisons: &firstComparisons)
        let second = Lattice.detectCentering(atoms, cell: cubicCell,
                                             candidateComparisons: &secondComparisons)
        assertCentering(.face, actual: first)
        assertCentering(first, actual: second)
        XCTAssertEqual(secondComparisons, firstComparisons)
    }

    private func assertCentering(_ expected: LatticeCentering,
                                 fractions: [SIMD3<Float>],
                                 atoms: [Atom]? = nil,
                                 cell: Cell? = nil,
                                 maximumComparisons: Int? = nil,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        let cell = cell ?? cubicCell
        let atoms = atoms ?? self.atoms(fractions, cell: cell)
        var comparisons = 0
        let actual = Lattice.detectCentering(atoms, cell: cell,
                                             candidateComparisons: &comparisons)
        assertCentering(expected, actual: actual, file: file, line: line)
        if let maximumComparisons {
            XCTAssertLessThanOrEqual(comparisons, maximumComparisons,
                                     "spatial lookup candidate work became superlinear",
                                     file: file, line: line)
        }
    }

    private func assertCentering(_ expected: LatticeCentering,
                                 actual: LatticeCentering,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        switch (expected, actual) {
        case (.primitive, .primitive), (.body, .body), (.face, .face):
            break
        default:
            XCTFail("expected \(name(expected)), got \(name(actual))", file: file, line: line)
        }
    }

    private func name(_ centering: LatticeCentering) -> String {
        switch centering {
        case .primitive: return "primitive"
        case .body: return "body"
        case .face: return "face"
        }
    }

    private func atoms(_ fractions: [SIMD3<Float>], cell: Cell? = nil) -> [Atom] {
        let cell = cell ?? cubicCell
        return fractions.map { Atom(coord: cell.cartesian($0), atomicNumber: 14, label: "Si") }
    }

    private func centeredFractions(baseCount: Int,
                                   offsets: [SIMD3<Float>],
                                   seed: UInt64) -> [SIMD3<Float>] {
        let bases = randomFractions(count: baseCount, seed: seed)
        return bases.flatMap { base in
            [base] + offsets.map { wrapped(base + $0) }
        }
    }

    private func randomFractions(count: Int, seed: UInt64) -> [SIMD3<Float>] {
        var state = seed
        func next() -> Float {
            state = state &* 2862933555777941757 &+ 3037000493
            return Float((state >> 24) % 1_000_000) / 1_000_000
        }
        return (0..<count).map { _ in SIMD3(next(), next(), next()) }
    }

    private func wrapped(_ value: SIMD3<Float>) -> SIMD3<Float> {
        value - floor(value)
    }
}
