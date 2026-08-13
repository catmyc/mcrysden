import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for the .bxsf -> 2D band-surface conversion and the metric-aware
/// presentation-region library.
final class BXSFBandSurfaceTests: XCTestCase {

    /// A synthetic 9x9x1 square-slab BXSF with two bands whose energies are
    /// linear in the in-plane fractional coordinates.
    private func makeSyntheticBXSF() -> String {
        let nx = 9, ny = 9, nz = 1
        func values(_ offset: Float) -> [Float] {
            var out: [Float] = []
            out.reserveCapacity(nx * ny * nz)
            for iy in 0..<ny {
                for ix in 0..<nx {
                    let fx = Float(ix) / Float(nx - 1)
                    let fy = Float(iy) / Float(ny - 1)
                    out.append(offset + 0.1 * fx + 0.2 * fy)
                }
            }
            return out
        }
        var text = """
        BEGIN_INFO
          Fermi Energy: 4.0
        END_INFO
        BEGIN_BLOCK_BANDGRID_3D
          band_energies
          BANDGRID_3D_BANDS
          2
          \(nx) \(ny) \(nz)
          0. 0. 0.
          1. 0. 0.
          0. 1. 0.
          0. 0. 0.1
        """
        for (bandIndex, offset) in [(6, Float(1)), (7, Float(3))] {
            text += "\nBAND:  \(bandIndex)\n"
            text += values(offset).map { String(format: "%.6f", $0) }.joined(separator: " ") + "\n"
        }
        text += "END_BANDGRID_3D\n"
        return text
    }

    func testBuildFromSynthetic2DBXSF() throws {
        let fs = try FermiSurface.parse(makeSyntheticBXSF())
        XCTAssertEqual(fs.fermiEnergy, 4.0, accuracy: 1e-6)
        XCTAssertEqual(fs.bands.count, 2)

        let cell = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 20))
        var options = BandSurfaceOptions()
        options.gridSize = 24
        let surface = try BXSFBandSurface.build(from: fs, cell: cell, options: options)

        XCTAssertEqual(surface.spinCount, 1)
        XCTAssertEqual(surface.fermiEnergy, 4.0)
        XCTAssertEqual(surface.gridSize, 24)
        XCTAssertEqual(surface.region.count, 4)
        XCTAssertEqual(surface.region[0].x, 0, accuracy: 1e-5)
        XCTAssertEqual(surface.region[0].y, 0, accuracy: 1e-5)
        XCTAssertEqual(surface.region[1].x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(surface.region[1].y, 0, accuracy: 1e-5)
        XCTAssertEqual(surface.regionLabels[0], "Γ")
        XCTAssertEqual(surface.regionLabels[1], "X")

        // Default selection: the fs.x-style ±1 eV window [3,5] around Ef=4.0
        // intersects only band 7 (span [3, 3.3]); band 6 (span [1, 1.3]) is
        // outside the window.
        XCTAssertEqual(surface.sheets.count, 1)
        XCTAssertEqual(surface.sheets.map(\.band), [7])
        for sheet in surface.sheets {
            XCTAssertEqual(sheet.values.count, 24 * 24)
            XCTAssertTrue(sheet.values.allSatisfy { $0.isFinite })
            let sourceLo = sheet.band == 6 ? Float(1) : Float(3)
            let sourceHi = sheet.band == 6 ? Float(1.3) : Float(3.3)
            XCTAssertGreaterThanOrEqual(sheet.values.min() ?? 0, sourceLo - 1e-3)
            XCTAssertLessThanOrEqual(sheet.values.max() ?? 0, sourceHi + 1e-3)
        }
    }

    func testRejects3DBXSF() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RhBulkFcc.bxsf")
        let fs = try BXSFLoader.load(from: url)
        XCTAssertThrowsError(try BXSFBandSurface.build(from: fs)) { error in
            XCTAssertEqual(error as? BandSurfaceError, .requiresTwoDimensionalMesh)
        }
    }

    func testPresentationRegionFamilies() {
        let square = Cell(a: SIMD3(5, 0, 0), b: SIMD3(0, 5, 0), c: SIMD3(0, 0, 20))
        guard let squareRegion = BandSurfaceRegion.presentationRegion(for: square) else {
            return XCTFail("square cell should classify")
        }
        XCTAssertEqual(squareRegion.region.count, 3)
        XCTAssertEqual(squareRegion.labels, ["Γ", "X", "Y", "M"])
        XCTAssertEqual(squareRegion.region[1].x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(squareRegion.region[2].y, 0.5, accuracy: 1e-5)

        // Hexagonal in-plane pair: gamma=120 degrees, a=b. The reciprocal
        // vectors are separated by 60 degrees, so the full-cell region is used;
        // its corners are all Gamma-equivalent, distinguished by the reciprocal
        // lattice steps.
        let hexagonal = Cell.fromLattice(a: 2.46, b: 2.46, c: 6.7,
                                         alpha: 90, beta: 90, gamma: 120)
        guard let hexRegion = BandSurfaceRegion.presentationRegion(for: hexagonal) else {
            return XCTFail("hexagonal cell should classify")
        }
        XCTAssertEqual(hexRegion.labels, ["Γ", "Γ+b₁", "Γ+b₂", "Γ+b₁+b₂"])
        XCTAssertEqual(hexRegion.region[1].x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(hexRegion.region[2].y, 1.0, accuracy: 1e-5)

        // Oblique in-plane metric: unclassifiable -> nil (caller uses full cell).
        let oblique = Cell.fromLattice(a: 4.0, b: 5.0, c: 20,
                                       alpha: 90, beta: 90, gamma: 100)
        XCTAssertNil(BandSurfaceRegion.presentationRegion(for: oblique))
    }

    func testMalformedBXSFThrows() {
        XCTAssertThrowsError(try FermiSurface.parse("no fermi energy line"))
        XCTAssertThrowsError(try FermiSurface.parse("Fermi Energy: 1.0\nno block"))
    }

    func testTwoNodeVacuumAxisSlices() throws {
        // A real fs.x slab writes nz = nk3+1 = 2 (the periodic endpoint is
        // duplicated); the two z-slices must be identical.
        let text = """
        BEGIN_INFO
          Fermi Energy: 4.0
        END_INFO
        BEGIN_BLOCK_BANDGRID_3D
          band_energies
          BANDGRID_3D_BANDS
          1
          5 5 2
          0. 0. 0.
          1. 0. 0.
          0. 1. 0.
          0. 0. 1.
          BAND:  1
          4.0 4.1 4.2 4.3 4.4
          4.2 4.3 4.4 4.5 4.6
          4.4 4.5 4.6 4.7 4.8
          4.6 4.7 4.8 4.9 5.0
          4.8 4.9 5.0 5.1 5.2
          4.0 4.1 4.2 4.3 4.4
          4.2 4.3 4.4 4.5 4.6
          4.4 4.5 4.6 4.7 4.8
          4.6 4.7 4.8 4.9 5.0
          4.8 4.9 5.0 5.1 5.2
          END_BANDGRID_3D
        """
        let fs = try FermiSurface.parse(text)
        var options = BandSurfaceOptions()
        options.gridSize = 16
        let surface = try BXSFBandSurface.build(from: fs, options: options)
        XCTAssertEqual(surface.region.count, 4)
        XCTAssertEqual(surface.sheets.count, 1)
        XCTAssertTrue(surface.sheets[0].values.allSatisfy { $0.isFinite })

        // The same geometry with DIFFERENT z-slices is a genuinely 3D grid,
        // not a 2D slab: it must be rejected.
        var differing = text
        if let lastRange = text.range(of: "4.8 4.9 5.0 5.1 5.2",
                                      options: .backwards) {
            differing.replaceSubrange(lastRange, with: "9.8 9.9 9.0 9.1 9.2")
        }
        XCTAssertNotEqual(differing, text, "the differing slice replacement must apply")
        let differingFS = try FermiSurface.parse(differing)
        XCTAssertThrowsError(try BXSFBandSurface.build(from: differingFS)) { error in
            XCTAssertEqual(error as? BandSurfaceError, .requiresTwoDimensionalMesh)
        }
    }
}
