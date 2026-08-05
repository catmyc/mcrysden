import XCTest
import Metal
import simd
@testable import MolVisApp

/// Verifies the File > Print… support: the printable-representation builders
/// in `PrintSupport` produce correctly sized, non-empty output for Metal and
/// graph layers, refuse absurd page sizes without trapping, and degrade
/// gracefully for an empty scene.
final class PrintTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    // A 400x300 pt page at 2 px/pt = 800x600 px, comfortably under the cap.
    private let pageRect = NSRect(x: 0, y: 0, width: 400, height: 300)
    private let expectedPixelSize = NSSize(width: 800, height: 600)

    // The Metal scene printable-representation builder must render a non-empty
    // image of the expected size for a loaded fixture structure.
    func testPrintRepresentations() throws {
        let scene = Scene(loaded: try Parser.load(fixture("si110.xsf")))
        let controller = MainWindowController(scene: scene, showWindow: false)
        let pixelDims = try PrintSupport.pixelDimensions(for: pageRect)
        let pixelViewport = SIMD2<Float>(Float(pixelDims.width), Float(pixelDims.height))
        let image = try PrintSupport.renderMetalScene(
            scene: controller.scene,
            camera: controller.renderCamera(),
            labels: [],
            pixelViewport: pixelViewport,
            pageRect: pageRect)

        XCTAssertEqual(image.size.width, expectedPixelSize.width)
        XCTAssertEqual(image.size.height, expectedPixelSize.height)

        // The rendered frame must contain foreground pixels (the structure).
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(foregroundPixels(cgImage), 0,
                             "printed Metal scene must contain foreground pixels")
    
        // --- merged (isolated scope) ---
        do {

        let energies: [Float] = [-2, -1, 0, 1, 2]
        let dos = DensityOfStates(
            energies: energies,
            series: [DOSSeries(label: "total", values: [0, 1, 2, 1, 0])],
            fermiEnergy: 0)
        let grapher = DOSGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        grapher.densityOfStates = dos

        let image = try PrintSupport.renderGraph(grapher, pageRect: pageRect)
        XCTAssertEqual(image.size.width, expectedPixelSize.width)
        XCTAssertEqual(image.size.height, expectedPixelSize.height)

        // The graph frame must contain drawn pixels (the curve/axes) beyond a
        // flat white fill. Sample the center region: a white-only image would
        // have every pixel at (255,255,255); the curve introduces non-white.
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(nonWhitePixels(cgImage), 0,
                             "printed DOS graph must contain drawn pixels")
        }

        // --- merged (isolated scope) ---
        do {

        let kPoints = [
            BandKPoint(k: SIMD3<Float>(0, 0, 0), weight: 1, label: "Γ", energies: [-1, 0, 1]),
            BandKPoint(k: SIMD3<Float>(0.5, 0, 0), weight: 1, label: "X", energies: [-0.5, 0.5, 1.5]),
        ]
        let bands = BandStructure(kPoints: kPoints, fermiEnergy: 0, nSpin: 1,
                                  reciprocal: nil, kPointsPerSpin: kPoints.count)
        let grapher = BandGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        grapher.bandStructure = bands

        let image = try PrintSupport.renderGraph(grapher, pageRect: pageRect)
        XCTAssertEqual(image.size.width, expectedPixelSize.width)
        XCTAssertEqual(image.size.height, expectedPixelSize.height)

        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(nonWhitePixels(cgImage), 0,
                             "printed band graph must contain drawn pixels")
        }

        // --- merged (isolated scope) ---
        do {

        let scene = Scene()
        let controller = MainWindowController(scene: scene, showWindow: false)

        // An empty scene must render without crashing — a blank frame is OK.
        let pixelDims = try PrintSupport.pixelDimensions(for: pageRect)
        let pixelViewport = SIMD2<Float>(Float(pixelDims.width), Float(pixelDims.height))
        let image = try PrintSupport.renderMetalScene(
            scene: controller.scene,
            camera: controller.renderCamera(),
            labels: [],
            pixelViewport: pixelViewport,
            pageRect: pageRect)
        XCTAssertEqual(image.size.width, expectedPixelSize.width)
        XCTAssertEqual(image.size.height, expectedPixelSize.height)

        // A graph view with no data still draws (an "empty" message) and must
        // produce a valid image without crashing.
        let emptyGrapher = DOSGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let graphImage = try PrintSupport.renderGraph(emptyGrapher, pageRect: pageRect)
        XCTAssertEqual(graphImage.size.width, expectedPixelSize.width)
        XCTAssertEqual(graphImage.size.height, expectedPixelSize.height)
        }
}

    // The graph printable-representation builder must produce a correctly sized
    // image for a DOS scene.

    // Same contract for the band-structure graph.

    // Absurd page sizes must be refused with an error — never trap on an Int
    // cast or allocate a pathological buffer.
    func testPrintContracts() throws {
        let absurd = NSRect(x: 0, y: 0,
                            width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        XCTAssertThrowsError(try PrintSupport.pixelDimensions(for: absurd))

        let zero = NSRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertThrowsError(try PrintSupport.pixelDimensions(for: zero))

        // A finite but huge page that overflows the total-pixel cap must also
        // throw, not trap. 50000 pt * 2 px/pt = 100000 px/axis; the squared
        // total exceeds Int.max.
        let overflow = NSRect(x: 0, y: 0, width: 50_000, height: 50_000)
        XCTAssertThrowsError(try PrintSupport.pixelDimensions(for: overflow))

        // Exactly at the per-axis cap is refused.
        let axisOverflow = NSRect(x: 0, y: 0,
                                  width: CGFloat(PrintSupport.maxAxisDimension) / PrintSupport.scale + 1,
                                  height: 100)
        XCTAssertThrowsError(try PrintSupport.pixelDimensions(for: axisOverflow))

        // The total-pixel cap is enforced with overflow-checked arithmetic: a
        // page whose pixel count does not overflow Int but exceeds the cap
        // must still throw. 5000 * 5000 = 25_000_000 > 16_000_000.
        let capOverflow = NSRect(x: 0, y: 0, width: 2500, height: 2500)
        XCTAssertThrowsError(try PrintSupport.pixelDimensions(for: capOverflow))
    
        // --- merged (isolated scope) ---
        do {

        var scene = Scene()
        scene.background = "#000000"
        scene.showLabels = true
        scene.showAxes = false
        scene.showCellFrame = false
        scene.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]

        let controller = MainWindowController(scene: scene, showWindow: false)
        let camera = controller.renderCamera()

        let pixelDims = try PrintSupport.pixelDimensions(for: pageRect)
        let pixelViewport = SIMD2<Float>(Float(pixelDims.width), Float(pixelDims.height))
        let pointViewport = SIMD2<Float>(Float(pageRect.width), Float(pageRect.height))

        // Project the atom's label position for both viewports.
        let atom = scene.atoms[0]
        let pixelPoint = MainWindowController.projectPoint(atom.coord, camera: camera, viewport: pixelViewport)
        let pointPoint = MainWindowController.projectPoint(atom.coord, camera: camera, viewport: pointViewport)

        // Both projections must succeed (atom is at origin, in front of camera).
        XCTAssertNotNil(pixelPoint, "atom must project in the pixel viewport")
        XCTAssertNotNil(pointPoint, "atom must project in the point viewport")

        // The pixel-viewport projection must be exactly `scale` times the
        // point-viewport projection. If labels were projected for points, they
        // would land at half position in the print-resolution image.
        XCTAssertEqual(pixelPoint!.x, pointPoint!.x * PrintSupport.scale, accuracy: 0.01,
                       "label x must be scaled to pixel viewport")
        XCTAssertEqual(pixelPoint!.y, pointPoint!.y * PrintSupport.scale, accuracy: 0.01,
                       "label y must be scaled to pixel viewport")

        // The pixel-viewport label position must be within the pixel image bounds.
        XCTAssertGreaterThanOrEqual(pixelPoint!.x, 0)
        XCTAssertLessThanOrEqual(pixelPoint!.x, CGFloat(pixelDims.width))
        XCTAssertGreaterThanOrEqual(pixelPoint!.y, 0)
        XCTAssertLessThanOrEqual(pixelPoint!.y, CGFloat(pixelDims.height))

        // Rendering with labels projected for the pixel viewport must succeed
        // and produce a correctly sized image (the assert inside
        // renderMetalScene verifies pixelViewport matches pixel dimensions).
        let image = try PrintSupport.renderMetalScene(
            scene: controller.scene,
            camera: camera,
            labels: [LabelOverlayView.Label(symbol: "C", x: pixelPoint!.x - 10, y: pixelPoint!.y - 12)],
            pixelViewport: pixelViewport,
            pageRect: pageRect)
        XCTAssertEqual(image.size.width, expectedPixelSize.width)
        XCTAssertEqual(image.size.height, expectedPixelSize.height)
        }
}

    // An empty scene must produce a graceful result — no crash, valid image,
    // correct size — rather than trapping on a nil renderer or empty geometry.

    // Labels MUST be projected for the pixel viewport (pageRect * scale), not
    // the point viewport. If labels were projected for points and composited
    // onto the pixel image, they would land at half their intended position.
    // This test verifies that the projection viewport used for printing matches
    // the pixel dimensions, not the point dimensions.

    // MARK: - Pixel helpers

    private func foregroundPixels(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] != 0 || pixels[index + 1] != 0 || pixels[index + 2] != 0 {
                count += 1
            }
        }
    }

    private func nonWhitePixels(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] != 255 || pixels[index + 1] != 255 || pixels[index + 2] != 255 {
                count += 1
            }
        }
    }
}
