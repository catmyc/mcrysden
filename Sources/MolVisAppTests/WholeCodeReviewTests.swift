import XCTest
import AppKit
import simd
@testable import MolVisApp

final class WholeCodeReviewTests: XCTestCase {
    private func image(width: Int = 2, height: Int = 2) throws -> CGImage {
        let bytes = [UInt8](repeating: 255, count: width * height * 4)
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw NSError(domain: "WholeCodeReviewTests", code: 1)
        }
        return image
    }

    func testRasterWrapperRejectsUnrepresentablePublicWriteSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try RasterExporter.write(cgImage: image(), to: url,
                                                        size: CGSize(width: CGFloat.infinity, height: 2)))
    }

    func testEPSCanBeCreatedAtANewDestination() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".eps")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try RasterExporter.write(cgImage: image(), to: url, size: CGSize(width: 2, height: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("%!PS-Adobe"))
    }

    func testPathologicalBrillouinZoneIsRefusedPromptly() {
        let cell = Cell(a: SIMD3<Float>(1e-8, 0, 0),
                        b: SIMD3<Float>(0, 1, 0),
                        c: SIMD3<Float>(0, 0, 1))
        XCTAssertNil(BrillouinZone.build(cell: cell, atoms: []))
    }

    func testKPathBoundsMalformedSamplingAndCoordinates() {
        let huge = KPath(points: [KPoint(.zero), KPoint(SIMD3<Float>(1, 0, 0))],
                         pointsPerSegment: Int.max)
        XCTAssertEqual(huge.interpolated().count, 1_000_000)

        let nonfinite = KPath(points: [KPoint(.zero), KPoint(SIMD3<Float>(.infinity, 0, 0))])
        XCTAssertTrue(nonfinite.interpolated().isEmpty)
        XCTAssertEqual(KPathExport.issMultiplier(nonfinite, maxDen: Int.min), 1)
    }

    func testBandParserRejectsNonfiniteKPointRatherThanEnteringMeshMath() {
        let text = """
        number of k points= 2
        cryst. coord.
        k( 1) = (0 0 0), wk = 0.5
        k( 2) = (1 0 0), wk = 0.5
        k = 0 0 0 bands (ev):
        1.0 2.0
        k = 1e999 0 0 bands (ev):
        1.0 2.0
        """
        XCTAssertNil(BandParser.parse(text))
    }

    func testIsosurfaceRejectsNonfiniteFieldValues() {
        let field = ScalarField(nx: 2, ny: 2, nz: 2, origin: .zero,
                                vec: [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)],
                                values: [0, 0, 0, 0, 0, 0, 0, .nan], minValue: 0, maxValue: 0)
        XCTAssertTrue(IsoMesh(field: field, isoLevel: 0).vertices.isEmpty)
        XCTAssertEqual(field.worldGradient(.nan, 0, 0), .zero)
    }
}
