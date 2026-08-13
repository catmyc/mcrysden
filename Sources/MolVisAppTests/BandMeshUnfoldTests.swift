import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Targeted coverage for TR-half unfolding and shifted-grid interpolation in
/// BandMeshInterpolator.meshGrid / interpolate.
final class BandMeshUnfoldTests: XCTestCase {

    // MARK: - Helpers

    private static func makeMesh(
        nodeLists: [[Float]],
        nBands: Int,
        nSpin: Int = 1,
        bandSlope: (Float, Float, Float) = (1, 2, 3),
        channelOffset: [Float] = []
    ) -> BandStructure {
        let dims = nodeLists.map { $0.count }
        let perSpin = dims[0] * dims[1] * dims[2]
        var kPoints: [BandKPoint] = []
        for s in 0..<nSpin {
            let off = s < channelOffset.count ? channelOffset[s] : 0
            for ix in 0..<dims[0] {
                for iy in 0..<dims[1] {
                    for iz in 0..<dims[2] {
                        let k = SIMD3<Float>(nodeLists[0][ix], nodeLists[1][iy], nodeLists[2][iz])
                        let x = nodeLists[0][ix], y = nodeLists[1][iy], z = nodeLists[2][iz]
                        let base = bandSlope.0 * x + bandSlope.1 * y + bandSlope.2 * z + off
                        let energies = (0..<nBands).map { base + Float($0) * 5.0 }
                        kPoints.append(BandKPoint(k: k, weight: 1, label: "", energies: energies))
                    }
                }
            }
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: nil, nSpin: nSpin,
                             kPointsAreCrystal: true,
                             kPointsPerSpin: perSpin, isMesh: true, periodicDim: 3)
    }

    // MARK: - (a) Shifted-grid interpolation

    func testShiftedGridInterpolation() {
        let sixth: Float = 1.0 / 6.0
        let half: Float = 1.0 / 2.0
        let fiveSixths: Float = 5.0 / 6.0
        let nodes: [[Float]] = [[sixth, half, fiveSixths],
                                 [sixth, half, fiveSixths],
                                 [sixth, half, fiveSixths]]
        // Energies = x only (bandSlope (1,0,0)) so interpolation reduces to x.
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1, bandSlope: (1, 0, 0))
        let grid = try! BandMeshInterpolator.meshGrid(from: bands)
        let values = bands.kPoints.map { $0.energies[0] }

        // x=0.1: unwraps into [5/6, 1+1/6), frac 0.8 between 5/6 and wrapped 1/6.
        // expected = 0.2*(5/6) + 0.8*(1/6) = 0.3.
        let v01 = grid.interpolate(values, at: SIMD3<Float>(0.1, 0.5, 0.5))!
        XCTAssertEqual(v01, 0.2 * fiveSixths + 0.8 * sixth, accuracy: 1e-3)

        // x=0.95: interior of closing cell, frac (0.95-5/6)/(1/3)=0.35.
        // expected = 0.65*(5/6) + 0.35*(1/6) = 0.6.
        let v95 = grid.interpolate(values, at: SIMD3<Float>(0.95, 0.5, 0.5))!
        XCTAssertEqual(v95, 0.65 * fiveSixths + 0.35 * sixth, accuracy: 1e-3)

        // x=0.5: interior node, exact.
        let v5 = grid.interpolate(values, at: SIMD3<Float>(0.5, 0.5, 0.5))!
        XCTAssertEqual(v5, 0.5, accuracy: 1e-4)

        // No flat strip: value at 0.1 must NOT equal node-0 value (1/6).
        XCTAssertNotEqual(v01, sixth, accuracy: 1e-3)
    }

    // MARK: - (b) TR-half unfold

    func testTRHalfUnfold() {
        let nodes: [[Float]] = [[0.125, 0.375],
                                 [0.125, 0.375, 0.625, 0.875],
                                 [0.5]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1, bandSlope: (1, 1, 0))
        let grid = try! BandMeshInterpolator.meshGrid(from: bands)

        XCTAssertEqual(grid.dims, [4, 4, 1])
        XCTAssertEqual(grid.pointCount, 16)
        let xNodes: [Float] = [0.125, 0.375, 0.625, 0.875]
        XCTAssertEqual(grid.nodes[0].count, xNodes.count)
        for j in 0..<xNodes.count {
            XCTAssertEqual(grid.nodes[0][j], xNodes[j], accuracy: 1e-3)
        }

        let perSpin = bands.kPointsPerSpin
        let channel = Array(bands.kPoints[0..<perSpin])
        let values = channel.map { $0.energies[0] }

        // Source value at (0.375, 0.375, 0.5): energy = x + y = 0.75.
        let srcEnergy = grid.interpolate(values, at: SIMD3<Float>(0.375, 0.375, 0.5))!
        XCTAssertEqual(srcEnergy, 0.75, accuracy: 1e-4)

        // TR copy applies to the FULL k-vector: (0.625, 0.375, 0.5) = -k where
        // k = (0.375, 0.625, 0.5) mod 1, so it must read E(0.375, 0.625, 0.5)
        // = 0.375 + 0.625 = 1.0 — NOT E(0.375, 0.375, 0.5). The other axes are
        // negated too (only x is unfolded, but y maps 0.375 <-> 0.625).
        let trEnergy = grid.interpolate(values, at: SIMD3<Float>(0.625, 0.375, 0.5))!
        XCTAssertEqual(trEnergy, 1.0, accuracy: 1e-4)
        let trEnergy2 = grid.interpolate(values, at: SIMD3<Float>(0.875, 0.125, 0.5))!
        // partner = (0.125, 0.875, 0.5), energy = 0.125 + 0.875 = 1.0
        XCTAssertEqual(trEnergy2, 1.0, accuracy: 1e-4)
        let trEnergy3 = grid.interpolate(values, at: SIMD3<Float>(0.875, 0.875, 0.5))!
        // partner = (0.125, 0.125, 0.5), energy = 0.125 + 0.125 = 0.25
        XCTAssertEqual(trEnergy3, 0.25, accuracy: 1e-4)

        // Seam continuity across the x=0.375/0.625 boundary. The TR copy maps the
        // negated half onto its partner so E(-k)=E(k) holds exactly — the seam value
        // is the TR-correct fold of the source data (0.875). It differs from the
        // naive full-grid linear extrapolation (1.0) only because the test function
        // x + y is not itself time-reversal symmetric, so the unfolded half does not
        // simply continue the linear trend. Both sides of the seam must still agree.
        let seam = grid.interpolate(values, at: SIMD3<Float>(0.5, 0.5, 0.5))!
        let justBelow = grid.interpolate(values, at: SIMD3<Float>(0.5 - 1e-4, 0.5, 0.5))!
        let justAbove = grid.interpolate(values, at: SIMD3<Float>(0.5 + 1e-4, 0.5, 0.5))!
        XCTAssertEqual(seam, justBelow, accuracy: 1e-3)
        XCTAssertEqual(seam, justAbove, accuracy: 1e-3)
    }

    // MARK: - (c) nSpin=2 reduced mesh rejected

    func testReducedMeshSpinPolarizedRejected() {
        let nodes: [[Float]] = [[0.125, 0.375],
                                 [0.125, 0.375, 0.625, 0.875],
                                 [0.5]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1, nSpin: 2, bandSlope: (1, 1, 0))
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: bands)) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .symmetryReducedMesh)
        }
    }

    // MARK: - (d) Incomplete non-TR-half axis rejected

    func testIncompleteNonTRHalfRejected() {
        // x={0,0.25,0.5}: negation of 0 is 0 -> overlap, union count != 2n.
        let nodes: [[Float]] = [[0, 0.25, 0.5],
                                 [0, 0.25, 0.5, 0.75],
                                 [0]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1)
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: bands)) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .symmetryReducedMesh)
        }
    }

    // MARK: - (e) Complete shifted grid accepted

    func testCompleteShiftedGridAccepted() {
        let sixth: Float = 1.0 / 6.0
        let half: Float = 1.0 / 2.0
        let fiveSixths: Float = 5.0 / 6.0
        let nodes: [[Float]] = [[sixth, half, fiveSixths],
                                 [sixth, half, fiveSixths],
                                 [sixth, half, fiveSixths]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1, bandSlope: (1, 2, 3))
        let grid = try! BandMeshInterpolator.meshGrid(from: bands)
        XCTAssertEqual(grid.dims, [3, 3, 3])
        XCTAssertEqual(grid.pointCount, 27)
    }

    // MARK: - (f) Multi-axis reduction rejected

    func testMultiAxisReductionRejected() {
        // Both x and y are half-grids: 4 points, two incomplete axes.
        let nodes: [[Float]] = [[0.125, 0.375],
                                 [0.125, 0.375],
                                 [0.5]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1)
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: bands)) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .symmetryReducedMesh)
        }
    }

    // MARK: - (h) Y-axis and Z-axis unfolding (axis position must not be hard-coded)

    func testTRHalfUnfoldYAxis() {
        // y is the TR-reduced half grid; x is complete; z is a TR-invariant slice.
        let nodes: [[Float]] = [[0.125, 0.375, 0.625, 0.875],
                                 [0.125, 0.375],
                                 [0.5]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1, bandSlope: (1, 1, 0))
        let grid = try! BandMeshInterpolator.meshGrid(from: bands)
        XCTAssertEqual(grid.dims, [4, 4, 1])
        XCTAssertEqual(grid.pointCount, 16)
        XCTAssertEqual(grid.nodes[1].count, 4)
        for j in 0..<4 {
            XCTAssertEqual(grid.nodes[1][j], [0.125, 0.375, 0.625, 0.875][j], accuracy: 1e-3)
        }
        let perSpin = bands.kPointsPerSpin
        let channel = Array(bands.kPoints[0..<perSpin])
        let values = channel.map { $0.energies[0] }
        // (0.375, 0.625, 0.5) = -k with k = (0.625, 0.375, 0.5): E = 0.625 + 0.375 = 1.0.
        let e = grid.interpolate(values, at: SIMD3<Float>(0.375, 0.625, 0.5))!
        XCTAssertEqual(e, 1.0, accuracy: 1e-4)
        // (0.625, 0.875, 0.5): x partner 0.375, y partner 0.125 -> E = 0.5.
        let e2 = grid.interpolate(values, at: SIMD3<Float>(0.625, 0.875, 0.5))!
        XCTAssertEqual(e2, 0.5, accuracy: 1e-4)
        // (0.875, 0.625, 0.5): x partner 0.125, y partner 0.375 -> E = 0.5.
        let e3 = grid.interpolate(values, at: SIMD3<Float>(0.875, 0.625, 0.5))!
        XCTAssertEqual(e3, 0.5, accuracy: 1e-4)
    }

    func testTRHalfUnfoldZAxis() {
        // z is the TR-reduced half grid; x and y are complete.
        let nodes: [[Float]] = [[0.125, 0.375, 0.625, 0.875],
                                 [0.125, 0.375, 0.625, 0.875],
                                 [0.125, 0.375]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1, bandSlope: (1, 1, 1))
        let grid = try! BandMeshInterpolator.meshGrid(from: bands)
        XCTAssertEqual(grid.dims, [4, 4, 4])
        XCTAssertEqual(grid.pointCount, 64)
        XCTAssertEqual(grid.nodes[2].count, 4)
        let perSpin = bands.kPointsPerSpin
        let channel = Array(bands.kPoints[0..<perSpin])
        let values = channel.map { $0.energies[0] }
        // (0.375, 0.375, 0.625) = -k with k = (0.625, 0.625, 0.375):
        // E = 0.625 + 0.625 + 0.375 = 1.625.
        let e = grid.interpolate(values, at: SIMD3<Float>(0.375, 0.375, 0.625))!
        XCTAssertEqual(e, 1.625, accuracy: 1e-4)
        // (0.625, 0.375, 0.875): k = (0.375, 0.625, 0.125): E = 0.375+0.625+0.125 = 1.125.
        let e2 = grid.interpolate(values, at: SIMD3<Float>(0.625, 0.375, 0.875))!
        XCTAssertEqual(e2, 1.125, accuracy: 1e-4)
    }

    // MARK: - (i) Degenerate axis must be time-reversal invariant

    func testTRHalfUnfoldRejectsNonInvariantDegenerateAxis() {
        // x half-reduced, y complete, z = {0.25}: z is degenerate but NOT
        // TR-invariant (0.25 maps to 0.75, which is absent), so unfolding must
        // be rejected rather than fabricate the 0.75 slice's energies.
        let nodes: [[Float]] = [[0.125, 0.375],
                                 [0.125, 0.375, 0.625, 0.875],
                                 [0.25]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 1, bandSlope: (1, 1, 0))
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: bands)) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .symmetryReducedMesh)
        }
    }

    // MARK: - (j) Time-reversal-breaking calculations must not unfold

    func testMagneticMeshNotUnfolded() {
        let nodes: [[Float]] = [[0.125, 0.375],
                                 [0.125, 0.375, 0.625, 0.875],
                                 [0.5]]
        var bands = Self.makeMesh(nodeLists: nodes, nBands: 1, bandSlope: (1, 1, 0))
        bands.timeReversalSymmetric = false
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: bands)) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .symmetryReducedMesh)
        }
    }

    // MARK: - (g) Cartesian k-points require a reciprocal basis

    func testCartesianMeshRequiresReciprocal() {
        let nodes: [[Float]] = [[0, 0.5], [0, 0.5], [0]]
        var kPoints: [BandKPoint] = []
        for x in nodes[0] {
            for y in nodes[1] {
                for z in nodes[2] {
                    kPoints.append(BandKPoint(k: SIMD3(x, y, z), weight: 1, label: "",
                                              energies: [x + y]))
                }
            }
        }
        let makeBands = { (recip: [SIMD3<Float>]?) -> BandStructure in
            BandStructure(kPoints: kPoints, fermiEnergy: nil, nSpin: 1,
                          reciprocal: recip, kPointsAreCrystal: false,
                          kPointsPerSpin: 4, isMesh: true, periodicDim: 2)
        }
        // No reciprocal basis: raw Cartesian coordinates cannot be interpreted.
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: makeBands(nil))) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .missingReciprocalBasis)
        }
        // Singular reciprocal basis: the Cartesian -> fractional conversion fails.
        XCTAssertThrowsError(try BandMeshInterpolator.meshGrid(from: makeBands([
            SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 0)]))) { err in
            XCTAssertEqual(err as? BandMeshInterpolationError, .missingReciprocalBasis)
        }
        // Valid identity basis (2pi/a == 1): Cartesian == fractional here.
        let grid = try! BandMeshInterpolator.meshGrid(from: makeBands([
            SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]))
        XCTAssertEqual(grid.dims, [2, 2, 1])
    }
}
