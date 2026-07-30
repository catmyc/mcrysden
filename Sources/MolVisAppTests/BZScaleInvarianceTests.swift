import XCTest
import simd
@testable import MolVisApp

final class BZScaleInvarianceTests: XCTestCase {
    func testUniformScalePreservesSkewPrimitiveTopology() throws {
        let factors: [Float] = [0.25, 1, 10, 10_000]
        let reference = try XCTUnwrap(buildSkew(scale: 1))

        for factor in factors {
            let scaled = try XCTUnwrap(buildSkew(scale: factor), "skew BZ failed at scale \(factor)")
            assertSameTopology(reference, scaled, factor: factor)
            assertCartesianScale(reference, scaled, factor: factor)
        }
    }

    func testUniformScalePreservesCenteredTopologyAtTinyReciprocalScale() throws {
        let factors: [Float] = [0.5, 1, 100, 10_000]
        let reference = try XCTUnwrap(buildFCC(scale: 1))
        XCTAssertEqual(reference.faces.count, 14)

        for factor in factors {
            let scaled = try XCTUnwrap(buildFCC(scale: factor), "centered BZ failed at scale \(factor)")
            if factor == 10_000 {
                XCTAssertLessThan(simd_length(scaled.reciprocal.a), 1e-3,
                                  "large direct cell must exercise sub-1e-3 reciprocal coordinates")
            }
            assertSameTopology(reference, scaled, factor: factor)
            assertCartesianScale(reference, scaled, factor: factor)
        }
    }

    func testCenteredFCCAndBCCSurviveExtremeRepresentableScales() throws {
        let factors: [Float] = [Float.leastNormalMagnitude * 0.5, 1e-20, 1e20, 1e36]
        let referenceFCC = try XCTUnwrap(buildFCC(scale: 1))
        let referenceBCC = try XCTUnwrap(buildBCC(scale: 1))
        XCTAssertEqual(referenceFCC.faces.count, 14)
        XCTAssertEqual(referenceBCC.faces.count, 12)

        for factor in factors {
            let fcc = try XCTUnwrap(buildFCC(scale: factor), "fcc BZ failed at scale \(factor)")
            let bcc = try XCTUnwrap(buildBCC(scale: factor), "bcc BZ failed at scale \(factor)")
            assertSameTopology(referenceFCC, fcc, factor: factor)
            assertSameTopology(referenceBCC, bcc, factor: factor)
            assertRoundTrips(fcc, factor: factor)
            assertRoundTrips(bcc, factor: factor)
        }
    }

    func testBeyondRepresentableReciprocalFailsNonfatally() {
        XCTAssertNil(buildFCC(scale: Float.leastNonzeroMagnitude))
        XCTAssertNil(buildBCC(scale: Float.leastNonzeroMagnitude))
    }

    private func buildSkew(scale: Float) -> BrillouinZone? {
        let base = Cell.fromLattice(a: 4, b: 5, c: 6, alpha: 70, beta: 80, gamma: 75)
        let cell = Cell(a: base.a * scale, b: base.b * scale, c: base.c * scale)
        let atom = Atom(coord: .zero, atomicNumber: 14, label: "Si")
        return BrillouinZone.build(cell: cell, atoms: [atom])
    }

    private func buildFCC(scale: Float) -> BrillouinZone? {
        let a = 5.43 * scale
        let cell = Cell(a: SIMD3<Float>(a, 0, 0),
                        b: SIMD3<Float>(0, a, 0),
                        c: SIMD3<Float>(0, 0, a))
        let atoms: [Atom] = [SIMD3(0, 0, 0), SIMD3(0, 0.5 * a, 0.5 * a),
                             SIMD3(0.5 * a, 0, 0.5 * a), SIMD3(0.5 * a, 0.5 * a, 0)]
            .map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
        return BrillouinZone.build(cell: cell, atoms: atoms)
    }

    private func buildBCC(scale: Float) -> BrillouinZone? {
        let a = 5.43 * scale
        let cell = Cell(a: SIMD3<Float>(a, 0, 0),
                        b: SIMD3<Float>(0, a, 0),
                        c: SIMD3<Float>(0, 0, a))
        let atoms: [Atom] = [SIMD3(0, 0, 0), SIMD3(0.5 * a, 0.5 * a, 0.5 * a)]
            .map { Atom(coord: $0, atomicNumber: 14, label: "Si") }
        return BrillouinZone.build(cell: cell, atoms: atoms)
    }

    private func assertRoundTrips(_ bz: BrillouinZone,
                                  factor: Float,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let basis = simd_float3x3(columns: (bz.reciprocal.a, bz.reciprocal.b, bz.reciprocal.c))
        XCTAssertTrue(BrillouinZone.isFiniteInvertible(basis),
                      "reciprocal basis became numerically singular at scale \(factor)",
                      file: file, line: line)
        for candidate in bz.candidates() {
            let cartesian = BrillouinZone.cartesianFromFractional(candidate.point.frac,
                                                                  reciprocal: bz.reciprocal)
            guard let fractional = BrillouinZone.fractionalFromCartesian(cartesian,
                                                                          reciprocal: bz.reciprocal) else {
                return XCTFail("fractional conversion failed at scale \(factor)", file: file, line: line)
            }
            XCTAssertLessThanOrEqual(simd_length(cartesian - candidate.cartesian),
                                     max(1e-5, simd_length(candidate.cartesian) * 5e-4),
                                     "Cartesian round trip failed at scale \(factor)",
                                     file: file, line: line)
            XCTAssertLessThanOrEqual(simd_length(fractional - candidate.point.frac), 5e-4,
                                     "fractional round trip failed at scale \(factor)",
                                     file: file, line: line)
        }
    }

    private func assertSameTopology(_ reference: BrillouinZone,
                                    _ scaled: BrillouinZone,
                                    factor: Float,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertEqual(scaled.faces.count, reference.faces.count, file: file, line: line)
        XCTAssertEqual(scaled.faces.map(\.count), reference.faces.map(\.count), file: file, line: line)
        XCTAssertEqual(scaled.specialPoints.map { $0.type }, reference.specialPoints.map { $0.type },
                       file: file, line: line)
        XCTAssertEqual(scaled.normals.count, reference.normals.count, file: file, line: line)
        for (lhs, rhs) in zip(reference.normals, scaled.normals) {
            XCTAssertLessThanOrEqual(simd_length(lhs - rhs), 2e-5, file: file, line: line)
        }

        let referenceReciprocal = [reference.reciprocal.a, reference.reciprocal.b, reference.reciprocal.c]
        let scaledReciprocal = [scaled.reciprocal.a, scaled.reciprocal.b, scaled.reciprocal.c]
        for (lhs, rhs) in zip(referenceReciprocal, scaledReciprocal) {
            XCTAssertLessThanOrEqual(simd_length(lhs - rhs * factor), 2e-5,
                                     "reciprocal basis must remain physical and scale inversely",
                                     file: file, line: line)
        }

        let expected = reference.candidates()
        let actual = scaled.candidates()
        XCTAssertEqual(actual.map { $0.point.label }, expected.map { $0.point.label }, file: file, line: line)
        XCTAssertEqual(actual.map { $0.type }, expected.map { $0.type }, file: file, line: line)
        for (lhs, rhs) in zip(expected, actual) {
            XCTAssertLessThanOrEqual(simd_length(lhs.point.frac - rhs.point.frac), 2e-4,
                                     "fractional candidate \(lhs.point.label) changed at scale \(factor): \(lhs.point.frac) vs \(rhs.point.frac)",
                                     file: file, line: line)
        }
    }

    private func assertCartesianScale(_ reference: BrillouinZone,
                                      _ scaled: BrillouinZone,
                                      factor: Float,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        for (referenceFace, scaledFace) in zip(reference.faces, scaled.faces) {
            for (referenceVertex, scaledVertex) in zip(referenceFace, scaledFace) {
                let rescaled = scaledVertex * factor
                let error = simd_length(referenceVertex - rescaled)
                let tolerance = max(3e-5, simd_length(referenceVertex) * 5e-4)
                XCTAssertLessThanOrEqual(error, tolerance,
                                         "Cartesian BZ vertex did not scale inversely at factor \(factor)",
                                         file: file, line: line)
            }
        }
    }
}
