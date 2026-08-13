import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for QE symmetry-matrix parsing and full-grid reconstruction of
/// symmetry-reduced k-meshes (the fs.x fill_fs_grid method).
final class BandGridSymmetryTests: XCTestCase {

    /// A 4x4x1 slab mesh reduced by the mirror x -> -x plus time reversal: the
    /// wedge keeps x in {0, 1/4, 1/2} and every y. Its symmetry orbit tiles
    /// the full 16-point grid (the classic fs.x reconstruction case).
    private func makeFullAndWedge() -> (full: BandStructure, wedge: BandStructure) {
        let xNodes: [Float] = [0, 0.25, 0.5, 0.75]
        let yNodes: [Float] = [0, 0.25, 0.5, 0.75]
        let perSpin = xNodes.count * yNodes.count
        let energy: Float = 2.5   // constant: every symmetry partner shares it
        var fullPoints: [BandKPoint] = []
        for y in yNodes {
            for x in xNodes {
                let k = SIMD3<Float>(x, y, 0)
                fullPoints.append(BandKPoint(k: k, weight: 0, label: "",
                                             energies: [energy, energy + 1]))
            }
        }
        let mirror = QESymmetryOp(
            rotation: [SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
            translation: .zero)
        let ops = [mirror]
        let full = BandStructure(
            kPoints: fullPoints, fermiEnergy: 0.5, nSpin: 1,
            kPointsAreCrystal: true, kPointsPerSpin: perSpin, isMesh: true,
            periodicDim: 2, timeReversalSymmetric: true,
            symmetryOperations: ops)

        // Mirror wedge: x in {0, 0.25, 0.5}; the mirror image of the x=0.25
        // column plus the time-reversal images complete the full 4x4 grid.
        let wedgePoints = fullPoints.filter { $0.k.x < 0.75 }
        let wedge = BandStructure(
            kPoints: wedgePoints, fermiEnergy: 0.5, nSpin: 1,
            kPointsAreCrystal: true, kPointsPerSpin: wedgePoints.count, isMesh: true,
            periodicDim: 2, timeReversalSymmetric: true,
            symmetryOperations: ops)
        return (full, wedge)
    }

    func testParseSymmetryOps() {
        let text = """
        Program PWSCF v.7.3.1 starts
        4 Sym. Ops. (no inversion) found
          isym =  1     identity
        cryst.   s( 1) = (     1          0          0      )
                      (     0          1          0      )
                      (     0          0          1      )
        cart.    s( 1) = (  1.0000000  0.0000000  0.0000000 )
          isym =  2     180 deg rotation
         Time Reversal   1
        cryst.   s( 2) = (    -1          0          0      )    f =( -0.2500000 )
                      (     0         -1          0      )       ( -0.2500000 )
                      (     0          0         -1      )       ( -0.2500000 )
        cart.    s( 2) = ( -1.0000000  0.0000000  0.0000000 )
        """
        let ops = BandGridSymmetry.parseSymmetryOps(text)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[0].rotation[0], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(ops[0].translation, .zero)
        XCTAssertFalse(ops[0].timeReversal)
        XCTAssertEqual(ops[1].rotation[0], SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(ops[1].translation.x, -0.25, accuracy: 1e-5)
        XCTAssertEqual(ops[1].translation.y, -0.25, accuracy: 1e-5)
        XCTAssertEqual(ops[1].translation.z, -0.25, accuracy: 1e-5)
        XCTAssertTrue(ops[1].timeReversal)

        XCTAssertTrue(BandGridSymmetry.parseSymmetryOps("No symmetry!").isEmpty)
    }

    func testParseKGridSpec() {
        let automatic = """
        K_POINTS {automatic}
        4 4 2 0 0 0
        """
        XCTAssertEqual(BandGridSymmetry.parseKGridSpec(automatic),
                       QEKGridSpec(dims: [4, 4, 2], shifts: [0, 0, 0]))

        let gamma = "K_POINTS gamma\n6 6 1"
        XCTAssertEqual(BandGridSymmetry.parseKGridSpec(gamma),
                       QEKGridSpec(dims: [6, 6, 1], shifts: [1.0 / 12.0, 1.0 / 12.0, 0.5]))

        let shifted = "K_POINTS {automatic}\n4 4 1 1 1 0"
        XCTAssertEqual(BandGridSymmetry.parseKGridSpec(shifted),
                       QEKGridSpec(dims: [4, 4, 1], shifts: [0.125, 0.125, 0]))

        // A 4-number automatic card defaults the shifts to zero.
        let unshiftedShort = "K_POINTS {automatic}\n4 4 1"
        XCTAssertEqual(BandGridSymmetry.parseKGridSpec(unshiftedShort),
                       QEKGridSpec(dims: [4, 4, 1], shifts: [0, 0, 0]))

        // Concatenated outputs: the LAST calculation's card wins.
        let concatenated = """
        Program PWSCF v.7.3.1 starts
        K_POINTS {automatic}
        2 2 1 0 0 0
        Program PWSCF v.7.3.1 starts
        K_POINTS {automatic}
        4 4 1 0 0 0
        """
        XCTAssertEqual(BandGridSymmetry.parseKGridSpec(concatenated),
                       QEKGridSpec(dims: [4, 4, 1], shifts: [0, 0, 0]))

        XCTAssertNil(BandGridSymmetry.parseKGridSpec("no card"))
        XCTAssertNil(BandGridSymmetry.parseKGridSpec("K_POINTS {automatic}\nnot numbers"))
        XCTAssertNil(BandGridSymmetry.parseKGridSpec("K_POINTS {crystal}\n0 0 0 1 1 1"))
    }

    func testExpandReconstructsFullGrid() throws {
        let (full, wedge) = makeFullAndWedge()
        XCTAssertLessThan(wedge.kPointsPerSpin, full.kPointsPerSpin)

        let expanded = try BandGridSymmetry.expand(wedge)
        XCTAssertTrue(expanded.isMesh)
        XCTAssertEqual(expanded.kPointsPerSpin, 16)
        XCTAssertEqual(expanded.nSpin, 1)
        XCTAssertEqual(expanded.nBands, 2)

        // Reconstructed energies reproduce the constant source values.
        for kp in expanded.kPoints {
            XCTAssertEqual(kp.energies[0], 2.5, accuracy: 1e-4)
            XCTAssertEqual(kp.energies[1], 3.5, accuracy: 1e-4)
        }

        // The expanded structure is a complete mesh detectable by the
        // interpolation layer, and re-expanding is idempotent.
        let grid = try BandMeshInterpolator.meshGrid(from: expanded)
        XCTAssertEqual(grid.dims, [4, 4, 1])
        let again = try BandGridSymmetry.expand(expanded)
        XCTAssertEqual(again.kPointsPerSpin, expanded.kPointsPerSpin)
    }

    func testExpandErrorPaths() throws {
        let (_, wedge) = makeFullAndWedge()
        var noOps = wedge
        noOps.symmetryOperations = []
        XCTAssertThrowsError(try BandGridSymmetry.expand(noOps)) { error in
            XCTAssertEqual(error as? BandGridSymmetryError, .noSymmetryData)
        }

        var nonGrid = wedge
        nonGrid.kPoints[0] = BandKPoint(k: SIMD3<Float>(0.123, 0.456, 0.789),
                                        weight: 0, label: "", energies: [0, 1])
        XCTAssertThrowsError(try BandGridSymmetry.expand(nonGrid)) { error in
            XCTAssertEqual(error as? BandGridSymmetryError, .unrepresentableCoordinates)
        }
    }

    func testFractionalTranslationIsIgnoredForKPointMapping() throws {
        // A nonsymmorphic fractional translation acts on real-space atoms, not
        // on k-points: adding it would push orbit points off the z=0 plane.
        let (_, wedge) = makeFullAndWedge()
        var translated = wedge
        translated.symmetryOperations = [
            QESymmetryOp(
                rotation: [SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
                translation: SIMD3<Float>(0, 0, 0.5))
        ]
        let expanded = try BandGridSymmetry.expand(translated)
        XCTAssertEqual(expanded.kPointsPerSpin, 16)
        XCTAssertTrue(expanded.kPoints.allSatisfy { abs($0.k.z) < 1e-4 },
                      "fractional translations must not displace k-points")
    }

    func testPerOperationTimeReversalContributesImages() throws {
        // A magnetized run has no GLOBAL time reversal, but an operation marked
        // `Time Reversal 1` still generates its negated images.
        let (_, wedge) = makeFullAndWedge()
        var magnetic = wedge
        magnetic.timeReversalSymmetric = false
        magnetic.symmetryOperations = [
            QESymmetryOp(
                rotation: [SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
                translation: .zero),
            QESymmetryOp(
                rotation: [SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
                translation: .zero,
                timeReversal: true)
        ]
        let expanded = try BandGridSymmetry.expand(magnetic)
        XCTAssertEqual(expanded.kPointsPerSpin, 16)
    }

    func testMeshInterpolatorExpandsWedgeAutomatically() throws {
        let (_, wedge) = makeFullAndWedge()
        let grid = try BandMeshInterpolator.meshGrid(from: wedge)
        XCTAssertEqual(grid.pointCount, 16)
        XCTAssertEqual(grid.dims, [4, 4, 1])
    }
}
