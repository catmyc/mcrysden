import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for the BandSurfaceBuilder review-fix changes: the mesh-derived
/// region API (Findings 3, meshRegion), the 2D-plane region validation in
/// build() (Finding 4), and decoder hardening (Finding 10).
final class BandSurfaceBuilderFixTests: XCTestCase {

    // MARK: - Helpers

    /// Build a synthetic mesh BandStructure: axis-aligned product grid over the
    /// given per-axis node lists, energies linear per band. Mirrors
    /// BandMeshSurfaceTests.makeMesh.
    private static func makeMesh(
        nodeLists: [[Float]],
        nBands: Int,
        nSpin: Int = 1,
        fermiEnergy: Float? = nil,
        bandSlope: (Float, Float, Float) = (1, 2, 3)
    ) -> BandStructure {
        let dims = nodeLists.map { $0.count }
        let perSpin = dims[0] * dims[1] * dims[2]
        var kPoints: [BandKPoint] = []
        for _ in 0..<nSpin {
            for ix in 0..<dims[0] {
                for iy in 0..<dims[1] {
                    for iz in 0..<dims[2] {
                        let x = nodeLists[0][ix], y = nodeLists[1][iy], z = nodeLists[2][iz]
                        let k = SIMD3<Float>(x, y, z)
                        let base = bandSlope.0 * x + bandSlope.1 * y + bandSlope.2 * z
                        let energies = (0..<nBands).map { base + Float($0) * 5.0 }
                        kPoints.append(BandKPoint(k: k, weight: 1, label: "", energies: energies))
                    }
                }
            }
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: fermiEnergy, nSpin: nSpin,
                             kPointsPerSpin: perSpin, isMesh: true, periodicDim: 3)
    }

    private static func assertVecEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                       _ tol: Float, _ message: String = "",
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: Float(tol), message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: Float(tol), message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: Float(tol), message, file: file, line: line)
    }

    // MARK: - meshRegion

    /// (a) z-degenerate slab mesh: region == one reciprocal cell (1,0,0)/(0,1,0).
    func testMeshRegionZSlab() {
        let quarter: Float = 1.0 / 4.0
        let half: Float = 1.0 / 2.0
        let nodes: [[Float]] = [[0, quarter, half, 0.75],
                                [0, quarter, half, 0.75],
                                [0]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2, fermiEnergy: 6.0)
        let (region, labels) = try! BandSurfaceBuilder.meshRegion(from: bands)
        XCTAssertEqual(region.count, 3)
        XCTAssertEqual(labels.count, 4)
        Self.assertVecEqual(region[0], SIMD3<Float>(0, 0, 0), 1e-4, "p0")
        Self.assertVecEqual(region[1], SIMD3<Float>(1, 0, 0), 1e-4, "p1")
        Self.assertVecEqual(region[2], SIMD3<Float>(0, 1, 0), 1e-4, "p2")

        // Building from this region succeeds with finite values.
        let opts = BandSurfaceOptions(maxBands: 16, gridSize: 16, bandCount: 2)
        let surface = try! BandSurfaceBuilder.build(bands: bands, region: region,
                                                     regionLabels: labels, options: opts)
        XCTAssertTrue(surface.sheets.allSatisfy { $0.values.allSatisfy { $0.isFinite } })
    }

    /// (b) shifted 2D mesh: p0 reflects the node origin.
    func testMeshRegionShifted() {
        let sixth: Float = 1.0 / 6.0
        let half: Float = 1.0 / 2.0
        let fiveSixths: Float = 5.0 / 6.0
        let nodes: [[Float]] = [[sixth, half, fiveSixths],
                                [sixth, half, fiveSixths],
                                [half]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2, fermiEnergy: 6.0)
        let (region, _) = try! BandSurfaceBuilder.meshRegion(from: bands)
        XCTAssertEqual(region.count, 3)
        Self.assertVecEqual(region[0], SIMD3<Float>(sixth, sixth, half), 1e-4, "p0")
        Self.assertVecEqual(region[1], SIMD3<Float>(sixth + 1, sixth, half), 1e-4, "p1")
        Self.assertVecEqual(region[2], SIMD3<Float>(sixth, sixth + 1, half), 1e-4, "p2")
    }

    /// (c) 3D bulk mesh: meshRegion throws requiresTwoDimensionalMesh.
    func testMeshRegion3DBulkThrows() {
        let nodes: [[Float]] = [[0, 0.5], [0, 0.5], [0, 0.5]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2)
        XCTAssertThrowsError(try BandSurfaceBuilder.meshRegion(from: bands)) { err in
            XCTAssertEqual(err as? BandSurfaceError, .requiresTwoDimensionalMesh)
        }
    }

    // MARK: - build() 2D-plane validation

    /// (d) region varying along the degenerate axis is rejected.
    func testBuildRejectsDegenerateVariation() {
        let nodes: [[Float]] = [[0, 0.5], [0, 0.5], [0]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2, fermiEnergy: 6.0)
        let region = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(0, 0.5, 0.3)]
        let opts = BandSurfaceOptions(maxBands: 16, gridSize: 16, bandCount: 1)
        XCTAssertThrowsError(try BandSurfaceBuilder.build(bands: bands, region: region,
                                                            regionLabels: ["", "", ""],
                                                            options: opts)) { err in
            XCTAssertEqual(err as? BandSurfaceError, .degenerateRegion)
        }
    }

    /// (e) region fixed mod 1 on the degenerate axis is accepted.
    func testBuildAcceptsDegenerateModOne() {
        let nodes: [[Float]] = [[0, 0.5], [0, 0.5], [0]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2, fermiEnergy: 6.0)
        let region = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 1), SIMD3<Float>(0, 0.5, 1)]
        let opts = BandSurfaceOptions(maxBands: 16, gridSize: 16, bandCount: 1)
        let surface = try! BandSurfaceBuilder.build(bands: bands, region: region,
                                                     regionLabels: ["", "", ""], options: opts)
        XCTAssertTrue(surface.sheets.allSatisfy { $0.values.allSatisfy { $0.isFinite } })
    }

    /// (f) zero 2D determinant on the active axes (but 3D-non-collinear because
    /// of an integer shift along the degenerate axis) is rejected.
    func testBuildRejectsZero2DDeterminant() {
        // x-degenerate mesh: x {0}, y {0,0.5}, z {0,0.5}.
        let nodes: [[Float]] = [[0], [0, 0.5], [0, 0.5]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2, fermiEnergy: 6.0)
        // Edges (0,0.5,0.5) and (0,1,1): x components are 0 (integer -> OK on
        // degenerate axis), but the active (y,z) det = 0.5*1 - 0.5*1 = 0.
        let region = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0.5, 0.5), SIMD3<Float>(0, 1, 1)]
        let opts = BandSurfaceOptions(maxBands: 16, gridSize: 16, bandCount: 1)
        XCTAssertThrowsError(try BandSurfaceBuilder.build(bands: bands, region: region,
                                                            regionLabels: ["", "", ""],
                                                            options: opts)) { err in
            XCTAssertEqual(err as? BandSurfaceError, .degenerateRegion)
        }
    }

    // MARK: - Decoder hardening

    /// (g) valid round-trips survive; malformed payloads are rejected.
    func testDecoderValidation() {
        let nodes: [[Float]] = [[0, 0.5], [0, 0.5], [0]]
        let bands = Self.makeMesh(nodeLists: nodes, nBands: 2, fermiEnergy: 6.0)
        let region = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(0.5, 0.5, 0)]
        let opts = BandSurfaceOptions(maxBands: 16, gridSize: 2, bandCount: 1)
        let surface = try! BandSurfaceBuilder.build(bands: bands, region: region,
                                                     regionLabels: ["G", "X", "M"],
                                                     options: opts)

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        // Valid round-trip succeeds.
        let validData = try! encoder.encode(surface)
        let decoded = try! decoder.decode(BandSurface.self, from: validData)
        XCTAssertEqual(decoded.gridSize, surface.gridSize)
        XCTAssertEqual(decoded.region.count, 4)
        XCTAssertEqual(decoded.sheets.count, surface.sheets.count)

        // A minimal BandSurface JSON template (gridSize 2 -> 4 values per sheet).
        let template = """
        {"region":[[0.0,0.0,0.0],[0.5,0.0,0.0],[0.5,0.5,0.0],[1.0,0.5,0.0]],\
        "regionLabels":["G","X","M",""],\
        "gridSize":2,\
        "sheets":[{"band":0,"spin":0,"label":"b","values":[1.0,2.0,3.0,4.0]}],\
        "spinCount":1,\
        "energyMin":1.0,\
        "energyMax":4.0}
        """

        // Region with 3 entries (needs exactly 4).
        XCTAssertTrue(decoder.decodeExpectingThrow(BandSurface.self, from: """
        {"region":[[0.0,0.0,0.0],[1.0,0.0,0.0],[0.0,1.0,0.0]],\
        "regionLabels":["a","b","c",""],"gridSize":2,\
        "sheets":[{"band":0,"spin":0,"label":"b","values":[1.0,2.0,3.0,4.0]}],\
        "spinCount":1,"energyMin":1.0,"energyMax":4.0}
        """.data(using: .utf8)!))

        // energyMin > energyMax.
        XCTAssertTrue(decoder.decodeExpectingThrow(BandSurface.self, from:
            template.replacingOccurrences(of: "\"energyMax\":4.0", with: "\"energyMax\":0.5")
                .data(using: .utf8)!))

        // Sheet values array too short (gridSize 2 needs 4, give 2).
        XCTAssertTrue(decoder.decodeExpectingThrow(BandSurface.self, from: """
        {"region":[[0.0,0.0,0.0],[0.5,0.0,0.0],[0.5,0.5,0.0],[1.0,0.5,0.0]],\
        "regionLabels":["G","X","M",""],"gridSize":2,\
        "sheets":[{"band":0,"spin":0,"label":"b","values":[1.0,2.0]}],\
        "spinCount":1,"energyMin":1.0,"energyMax":4.0}
        """.data(using: .utf8)!))

        // Non-finite sheet value (1e309 -> Float.infinity).
        XCTAssertTrue(decoder.decodeExpectingThrow(BandSurface.self, from: """
        {"region":[[0.0,0.0,0.0],[0.5,0.0,0.0],[0.5,0.5,0.0],[1.0,0.5,0.0]],\
        "regionLabels":["G","X","M",""],"gridSize":2,\
        "sheets":[{"band":0,"spin":0,"label":"b","values":[1e309,2.0,3.0,4.0]}],\
        "spinCount":1,"energyMin":1.0,"energyMax":4.0}
        """.data(using: .utf8)!))
    }
}

private extension JSONDecoder {
    /// Decode and return true iff any error is thrown.
    func decodeExpectingThrow<T: Decodable>(_ type: T.Type, from data: Data) -> Bool {
        do {
            _ = try decode(type, from: data)
            return false
        } catch {
            return true
        }
    }
}
