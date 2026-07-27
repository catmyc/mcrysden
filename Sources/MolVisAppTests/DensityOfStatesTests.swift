import AppKit
import XCTest

@testable import MolVisApp

final class DensityOfStatesTests: XCTestCase {
    func testNonSpinTotalDOSExcludesIntegratedColumn() throws {
        let text = """
        # E (eV) dos(E) Int dos(E) EFermi = 5.250 eV
        -2.0  0.25  0.00
        -1.0  1.50  0.75
         0.0  2.75  2.50
         1.0  0.50  3.25
        """

        let dos = try XCTUnwrap(DOSParser.parse(text))
        XCTAssertEqual(dos.energies, [-2, -1, 0, 1])
        XCTAssertEqual(dos.series.count, 1, "integrated DOS must not become a plotted series")
        XCTAssertEqual(dos.series[0].values, [0.25, 1.5, 2.75, 0.5])
        XCTAssertEqual(dos.fermiEnergy, 5.25)
    }

    func testSpinTotalDOSRetainsBothSpinChannels() throws {
        let text = """
        # E (eV) dosup(E) dosdw(E) Int dos(E) EFermi = -0.375 eV
        -1.0  0.10  0.20  0.00
         0.0  0.40  0.60  0.65
         1.0  0.30  0.50  1.55
        """

        let dos = try XCTUnwrap(DOSParser.parse(text))
        XCTAssertEqual(dos.series.count, 2, "spin DOS must have up and down series only")
        XCTAssertEqual(dos.series[0].values, [0.1, 0.4, 0.3])
        XCTAssertEqual(dos.series[1].values, [0.2, 0.6, 0.5])
        XCTAssertEqual(dos.fermiEnergy, -0.375)
        let labels = dos.series.map { $0.label.lowercased() }
        XCTAssertTrue(labels[0].contains("up"), "first spin channel should be labelled up")
        XCTAssertTrue(labels[1].contains("down") || labels[1].contains("dw"),
                      "second spin channel should be labelled down")
    }

    func testProjectedDOSRetainsAndLabelsEveryProjection() throws {
        let text = """
        # E (eV) ldosup(E) ldosdw(E) pdosup(E) pdosdw(E)
        -1.0  1.0  2.0  0.25  0.50
         0.0  3.0  4.0  0.75  1.00
         1.0  5.0  6.0  1.25  1.50
        """

        let dos = try XCTUnwrap(DOSParser.parse(text))
        XCTAssertEqual(dos.series.count, 4, "projected columns must not be mistaken for integrated DOS")
        XCTAssertEqual(dos.series.map(\.values), [
            [1, 3, 5],
            [2, 4, 6],
            [0.25, 0.75, 1.25],
            [0.5, 1, 1.5],
        ])

        let labels = dos.series.map { $0.label.lowercased() }
        XCTAssertTrue(labels[0].contains("ldos") && labels[0].contains("up"))
        XCTAssertTrue(labels[1].contains("ldos") && (labels[1].contains("down") || labels[1].contains("dw")))
        XCTAssertTrue(labels[2].contains("pdos") && labels[2].contains("up"))
        XCTAssertTrue(labels[3].contains("pdos") && (labels[3].contains("down") || labels[3].contains("dw")))
        XCTAssertEqual(Set(labels).count, 4, "each projected channel needs a distinct label")
    }

    func testFortranDExponentIsAccepted() throws {
        let text = """
        # E (eV) dos(E) Int dos(E) EFermi = 1.250D+00 eV
        -1.000D+00  2.500D-01  0.000D+00
         0.000D+00  1.250D+00  5.000D-01
         1.000D+00  2.500D+00  2.375D+00
        """

        let dos = try XCTUnwrap(DOSParser.parse(text))
        XCTAssertEqual(dos.energies, [-1, 0, 1])
        XCTAssertEqual(dos.series.first?.values, [0.25, 1.25, 2.5])
        XCTAssertEqual(dos.fermiEnergy, 1.25)
    }

    func testMalformedJaggedAndNonMonotonicTablesAreRejected() {
        let invalidInputs = [
            """
            # E (eV) dos(E) Int dos(E)
            -1.0  0.25  0.00
             0.0  not-a-number  0.50
             1.0  0.75  1.00
            """,
            """
            # E (eV) dos(E) Int dos(E)
            -1.0  0.25  0.00
             0.0  0.50
             1.0  0.75  1.00
            """,
            """
            # E (eV) dos(E) Int dos(E)
            -1.0  0.25  0.00
             1.0  0.75  1.00
             0.0  0.50  1.50
            """,
        ]

        for (index, text) in invalidInputs.enumerated() {
            XCTAssertNil(DOSParser.parse(text), "invalid table \(index) must be rejected in full")
        }
    }

    func testDOSExtensionDispatchesThroughParserLoad() throws {
        try assertExtensionDispatch("dos")
    }

    func testPDOSExtensionDispatchesThroughParserLoad() throws {
        try assertExtensionDispatch("pdos")
    }

    func testStandardProjwfcFilenamesDispatchThroughParserLoad() throws {
        try assertExtensionDispatch("pdos_tot")
        try assertExtensionDispatch("pdos_atm#1(Fe)_wfc#2(p)")
    }

    func testOpenPanelPredicateAcceptsStandardProjwfcFilename() throws {
        XCTAssertTrue(App.supportsOpenURL(URL(fileURLWithPath: "/tmp/prefix.pdos_atm#1(Fe)_wfc#2(p)")))
        XCTAssertTrue(App.supportsOpenURL(URL(fileURLWithPath: "/tmp/prefix.pdos_tot")))
        XCTAssertFalse(App.supportsOpenURL(URL(fileURLWithPath: "/tmp/unsupported.blob")))
    }

    @MainActor
    func testLoadedDOSFlowsIntoSceneAndSelectsDOSViewport() throws {
        let loaded = try loadTemporaryDOS(suffix: "dos")
        let scene = Scene(loaded: loaded)
        XCTAssertNotNil(scene.densityOfStates, "LoadedScene -> Scene must preserve DOS data")

        let controller = MainWindowController(scene: Scene(), showWindow: false)
        controller.loadFile(scene)
        XCTAssertFalse(controller.dosGrapher.isHidden)
        XCTAssertTrue(controller.canvas.isHidden)
        XCTAssertTrue(controller.bandGrapher.isHidden)
        XCTAssertTrue(controller.colorPlane.isHidden)
        XCTAssertGreaterThan(controller.viewport.bounds.width, 0)
        XCTAssertEqual(controller.dosGrapher.frame, controller.viewport.bounds,
                       "DOS graph must fill the split-view viewport")

        controller.loadFile(Scene())
        XCTAssertTrue(controller.dosGrapher.isHidden)
        XCTAssertFalse(controller.canvas.isHidden, "loading a normal scene must restore Metal")
    }

    @MainActor
    func testDOSGrapherDrawsParsedDataIntoBitmap() throws {
        let text = """
        # E (eV) dos(E) Int dos(E) EFermi = 0.0 eV
        -1.0  0.25  0.00
         0.0  1.50  0.75
         1.0  0.50  1.75
        """
        let dos = try XCTUnwrap(DOSParser.parse(text))
        let view = DOSGrapherView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.densityOfStates = dos
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 320,
            pixelsHigh: 240,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let bytes = try XCTUnwrap(bitmap.bitmapData)
        var bluePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                if blue > red + 30 && blue > green + 30 { bluePixels += 1 }
            }
        }
        XCTAssertGreaterThan(bluePixels, 20,
                             "drawing populated DOS must render the blue first-series curve")
    }

    @MainActor
    func testAppExportRoutesDOSToGraphForAllContainers() throws {
        let loaded = try loadTemporaryDOS(suffix: "dos")
        let scene = Scene(loaded: loaded)
        let size = CGSize(width: 320, height: 240)
        for ext in ["png", "pdf", "svg", "eps", "ps"] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcrysden-dos-export-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: url) }
            let image = try App.exportScene(scene, camera: nil, to: url, size: size)
            XCTAssertGreaterThan((try? Data(contentsOf: url).count) ?? 0, 100, ".\(ext) export is empty")
            XCTAssertGreaterThan(bluePixelCount(image), 20,
                                 ".\(ext) must wrap the DOS graph, not an empty Metal scene")
        }
    }

    private func assertExtensionDispatch(_ ext: String) throws {
        let loaded = try loadTemporaryDOS(suffix: ext)
        let dos = try XCTUnwrap(loaded.densityOfStates, ".\(ext) should dispatch to DOSParser")
        XCTAssertTrue(loaded.atoms.isEmpty)
        XCTAssertEqual(dos.energies, [-1, 0, 1])
        XCTAssertEqual(dos.series.count, 1)
        XCTAssertEqual(dos.series[0].values, [0.25, 1.5, 0.5])
        XCTAssertEqual(dos.fermiEnergy, 2.5)
    }

    private func loadTemporaryDOS(suffix: String) throws -> LoadedScene {
        let text = """
        # E (eV) dos(E) Int dos(E) EFermi = 2.5 eV
        -1.0  0.25  0.00
         0.0  1.50  0.75
         1.0  0.50  1.75
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-dos-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: url) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try Parser.load(url)
    }

    private func bluePixelCount(_ image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let bytes = bitmap.bitmapData, bitmap.samplesPerPixel >= 3 else { return 0 }
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
                let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                if blue > red + 30 && blue > green + 30 { count += 1 }
            }
        }
        return count
    }
}
