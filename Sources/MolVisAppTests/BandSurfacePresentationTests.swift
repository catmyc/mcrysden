import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for the fs.x-style band-window selection, no-Fermi gap reference,
/// and adaptive sampling density added to the band-surface builder.
final class BandSurfacePresentationTests: XCTestCase {

    /// Complete 2x2 crystal mesh, one spin channel, energies `base + band`.
    private func makeMesh(
        bandBase: Float = 0,
        bandStep: Float = 1,
        nBands: Int = 4,
        fermiEnergy: Float?
    ) -> BandStructure {
        let nodes: [Float] = [0, 0.5]
        var kps: [BandKPoint] = []
        for x in nodes {
            for y in nodes {
                let base = x + y + bandBase
                kps.append(BandKPoint(k: SIMD3<Float>(x, y, 0), weight: 1.0 / 4,
                                      label: "",
                                      energies: (0..<nBands).map { base + Float($0) * bandStep }))
            }
        }
        return BandStructure(kPoints: kps, fermiEnergy: fermiEnergy, nSpin: 1,
                             kPointsAreCrystal: true, kPointsPerSpin: 4, isMesh: true,
                             periodicDim: 2)
    }

    private func build(
        _ bands: BandStructure,
        options: BandSurfaceOptions = BandSurfaceOptions()
    ) throws -> BandSurface {
        let region = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]
        return try BandSurfaceBuilder.build(bands: bands, region: region,
                                            regionLabels: ["A", "B", "C"], options: options)
    }

    func testWindowSelectsAllBandsIntersectingFermiWindow() throws {
        // Bands: b0 in [0,1], b1 in [1,2], b2 in [2,3], b3 in [3,4]; Ef=3.5,
        // window [2.5,4.5] -> b2 and b3.
        let mesh = makeMesh(fermiEnergy: 3.5)
        let surface = try build(mesh)
        XCTAssertEqual(surface.sheets.map(\.band), [2, 3])
    }

    func testEmptyWindowFallsBackToClosestBands() throws {
        // All bands far below Ef: the window is empty, so the bandCount=2
        // closest-to-Ef rule must take over.
        let mesh = makeMesh(fermiEnergy: 100)
        let surface = try build(mesh)
        // closestBands returns distance order [3,2]; build() re-sorts the
        // fallback keys spin-major/band-minor before sampling.
        XCTAssertEqual(surface.sheets.map(\.band), [2, 3])
    }

    func testWindowCapsAtMaxBands() throws {
        let mesh = makeMesh(bandStep: 0.1, nBands: 40, fermiEnergy: 2.0)
        var options = BandSurfaceOptions()
        options.maxBands = 8
        let surface = try build(mesh, options: options)
        XCTAssertEqual(surface.sheets.count, 8)
        XCTAssertEqual(surface.sheets.first?.band, 0)
        XCTAssertEqual(surface.sheets.last?.band, 7)
    }

    func testNoFermiUsesLargestGapMidpoint() throws {
        // Two manifolds: bands 0-1 near energy 0, bands 2-3 near energy 10.
        // Without a Fermi level the default selects the manifolds adjacent to
        // the largest gap: the VBM band 1 and the CBM band 2.
        var kps: [BandKPoint] = []
        for x in [Float(0), 0.5] {
            for y in [Float(0), 0.5] {
                let base = x + y
                kps.append(BandKPoint(k: SIMD3<Float>(x, y, 0), weight: 0.25, label: "",
                                      energies: [base, base + 0.3, base + 10, base + 10.3]))
            }
        }
        let mesh = BandStructure(kPoints: kps, fermiEnergy: nil, nSpin: 1,
                                 kPointsAreCrystal: true, kPointsPerSpin: 4, isMesh: true,
                                 periodicDim: 2)
        let reference = BandSurfaceBuilder.largestGapReference(mesh)
        XCTAssertNotNil(reference)
        XCTAssertGreaterThan(reference!, 5)
        XCTAssertLessThan(reference!, 10)
        let surface = try build(mesh)
        XCTAssertEqual(surface.sheets.map(\.band), [1, 2])
    }

    func testAdaptiveGridSizeBoundsTriangles() throws {
        // Many selected sheets force a coarser sampling grid so the triangle
        // count stays interactive; few sheets keep the requested resolution.
        let many = makeMesh(bandStep: 0.1, nBands: 40, fermiEnergy: 2.0)
        var options = BandSurfaceOptions()
        options.maxBands = 32
        let manySurface = try build(many, options: options)
        let triCount = manySurface.sheets.count * (manySurface.gridSize - 1) * (manySurface.gridSize - 1) * 2
        XCTAssertLessThanOrEqual(triCount, 160_000)
        XCTAssertLessThan(manySurface.gridSize, options.gridSize)

        let few = makeMesh(fermiEnergy: 3.5)
        let fewSurface = try build(few)
        XCTAssertEqual(fewSurface.gridSize, 56)
    }
}
