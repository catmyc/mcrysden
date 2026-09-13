import XCTest
import BandSurfaceRaster
@testable import MolVisApp

/// Direct boundary tests for the C band-surface rasterizer. The view tests
/// exercise normal geometry; these cases pin the fail-closed behavior for
/// non-finite/huge coordinates that previously reached undefined float-to-int
/// casts inside the C implementation.
final class BandSurfaceRasterTests: XCTestCase {

    private func rasterizeTriangle(_ xyz: [Float],
                                   rgb: [UInt8] = [255, 0, 0]) -> ([UInt8], [Float]) {
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var depth = [Float](repeating: -Float.greatestFiniteMagnitude, count: width * height)
        xyz.withUnsafeBufferPointer { xyzBuffer in
            rgb.withUnsafeBufferPointer { rgbBuffer in
                pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                    depth.withUnsafeMutableBufferPointer { depthBuffer in
                        band_surface_raster_triangles_opaque(
                            pixelBuffer.baseAddress,
                            depthBuffer.baseAddress,
                            Int32(width), Int32(height),
                            xyzBuffer.baseAddress,
                            rgbBuffer.baseAddress,
                            1)
                    }
                }
            }
        }
        return (pixels, depth)
    }

    private func rasterizeQuad(_ xyz: [Float]) -> ([UInt8], [Float]) {
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var depth = [Float](repeating: -Float.greatestFiniteMagnitude, count: width * height)
        xyz.withUnsafeBufferPointer { xyzBuffer in
            pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                depth.withUnsafeMutableBufferPointer { depthBuffer in
                    band_surface_raster_quad_blended(
                        pixelBuffer.baseAddress,
                        depthBuffer.baseAddress,
                        Int32(width), Int32(height),
                        xyzBuffer.baseAddress,
                        1, 0, 0, 0.15, 0)
                }
            }
        }
        return (pixels, depth)
    }

    func testRasterizerRejectsNonFiniteAndExtremeInputs() {
        // Sanity check: a normal triangle must actually rasterize.
        let normal = rasterizeTriangle([1, 1, 10,
                                        6, 1, 10,
                                        1, 6, 10])
        XCTAssertTrue(normal.0.contains(255), "normal triangle must write opaque pixels")

        // NaN vertex must be ignored, leaving the buffers untouched.
        let nanTriangle = rasterizeTriangle([.nan, 1, 10,
                                             6, 1, 10,
                                             1, 6, 10])
        XCTAssertTrue(nanTriangle.0.allSatisfy { $0 == 0 })
        XCTAssertTrue(nanTriangle.1.allSatisfy { $0 == -Float.greatestFiniteMagnitude })

        // Huge finite coordinates must not overflow the float-to-int bounds.
        let huge = Float.greatestFiniteMagnitude
        let hugeTriangle = rasterizeTriangle([0, 0, 0,
                                              huge, 0, 0,
                                              0, 1, 0])
        XCTAssertTrue(hugeTriangle.0.allSatisfy { $0 == 0 })
        XCTAssertTrue(hugeTriangle.1.allSatisfy { $0 == -Float.greatestFiniteMagnitude })

        // Same fail-closed guarantee for the translucent-quad path.
        let nanQuad = rasterizeQuad([.nan, 0, 0, 6, 0, 0, 6, 6, 0, 0, 6, 0])
        XCTAssertTrue(nanQuad.0.allSatisfy { $0 == 0 })
        XCTAssertTrue(nanQuad.1.allSatisfy { $0 == -Float.greatestFiniteMagnitude })
    }
}
