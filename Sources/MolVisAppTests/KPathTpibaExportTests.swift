import Foundation
import simd
import XCTest
@testable import MolVisApp

final class KPathTpibaExportTests: XCTestCase {
    func testTpibaBExportUsesActiveCellAndCrystalBWeights() throws {
        // The first direct vector has length 5, so the explicit QE convention is
        // alat = 5 even though the cell is rotated and anisotropic.
        let cell = Cell(a: SIMD3<Float>(3, 4, 0),
                        b: SIMD3<Float>(-4, 3, 0),
                        c: SIMD3<Float>(0, 0, 10))
        let path = KPath(points: [
            KPoint(SIMD3<Float>(0, 0, 0), "G"),
            KPoint(SIMD3<Float>(0.5, 0.25, 0.5), "A"),
            KPoint(SIMD3<Float>(0, 0.5, 0), "B"),
        ], pointsPerSegment: 20, breaks: [1])

        let text = try KPathExport.export(path, as: .qeTpibaB, cell: cell)
        XCTAssertEqual(text, "3\n"
            + "0.000000 0.000000 0.000000 19\n"
            + "0.100000 0.550000 0.250000 0\n"
            + "-0.400000 0.300000 0.000000 0\n")
        XCTAssertEqual(KPathExportFormat.qeTpibaB.defaultFilename, "kpath.tpiba_b")
        XCTAssertTrue(KPathExport.isEnabledInEditor(path, as: .qeTpibaB))
        XCTAssertTrue(KPathExport.editorHelp(path, as: .qeTpibaB).contains("alat = |cell.a|"))

        // tpiba_b must not alter the established crystal_b fractional output or
        // its shared edge weights/break jump encoding.
        let crystalB = try KPathExport.export(path, as: .qeCrystalB)
        XCTAssertEqual(crystalB, "3\n"
            + "0.000000 0.000000 0.000000 19\n"
            + "0.500000 0.250000 0.500000 0\n"
            + "0.000000 0.500000 0.000000 0\n")

        XCTAssertThrowsError(try KPathExport.export(path, as: .qeTpibaB)) { error in
            guard case KPathExport.ExportError.missingCell = error else {
                return XCTFail("expected missingCell, got \(error)")
            }
        }

        let singularCell = Cell(a: SIMD3<Float>(1, 0, 0),
                                b: SIMD3<Float>(2, 0, 0),
                                c: SIMD3<Float>(0, 0, 1))
        XCTAssertThrowsError(try KPathExport.export(path, as: .qeTpibaB, cell: singularCell)) { error in
            guard case KPathExport.ExportError.invalidCell = error else {
                return XCTFail("expected invalidCell, got \(error)")
            }
        }

        // The cell is valid here; only this finite route coordinate exceeds the
        // representable tpiba_b output range and must not be blamed on the cell.
        let narrowCell = Cell(a: SIMD3<Float>(1, 0, 0),
                              b: SIMD3<Float>(0, 0.001, 0),
                              c: SIMD3<Float>(0, 0, 1))
        let hugeRoute = KPath(points: [
            KPoint(.zero, "G"),
            KPoint(SIMD3<Float>(0, Float.greatestFiniteMagnitude, 0), "Y"),
        ])
        XCTAssertThrowsError(try KPathExport.export(hugeRoute, as: .qeTpibaB, cell: narrowCell)) { error in
            guard case KPathExport.ExportError.unrepresentableRoute = error else {
                return XCTFail("expected unrepresentableRoute, got \(error)")
            }
        }

        let automatic = "K_POINTS automatic\n2 2 2 0 0 0\n"
        XCTAssertThrowsError(try KPathImport.parse(text: automatic,
                                                   url: URL(fileURLWithPath: "automatic.in"))) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("uniform k-grid (automatic)"))
            XCTAssertFalse(description.contains("tpiba_b"))
        }
        let tpiba = "K_POINTS tpiba_b\n2\n0.0 0.0 0.0\n0.5 0.0 0.0\n"
        XCTAssertThrowsError(try KPathImport.parse(text: tpiba,
                                                   url: URL(fileURLWithPath: "tpiba.in"))) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("Cartesian band path"))
            XCTAssertTrue(description.contains("active cell/alat context"))
            XCTAssertTrue(description.contains("K_POINTS crystal coordinates"))
            XCTAssertFalse(description.contains("uniform k-grid"))
        }
    }
}
