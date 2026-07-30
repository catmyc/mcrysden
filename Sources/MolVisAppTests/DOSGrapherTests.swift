import XCTest
@testable import MolVisApp

final class DOSGrapherTests: XCTestCase {
    /// A DOS with a clear insulating gap around the Fermi level. Values are 0.0 for
    /// |energy| < 1.0 and a Gaussian shoulder outside, giving a gap region the
    /// analysis detects with edges interpolated to the threshold crossing.
    private func makeGapDOS(fermi: Float? = 0.0) -> DensityOfStates {
        let energies = Array(stride(from: Float(-5), through: Float(5), by: Float(0.5)))
        let values = energies.map { abs($0) < 1.0 ? 0.0 : exp(-($0 * $0) / 20.0) }
        return DensityOfStates(energies: energies,
                               series: [DOSSeries(label: "Total DOS", values: values)],
                               fermiEnergy: fermi)
    }

    /// A metallic DOS: broad Gaussian with an offset so it never dips below the
    /// detection threshold — no gap region exists anywhere on the grid.
    private func makeMetallicDOS(fermi: Float? = 0.0) -> DensityOfStates {
        let energies = Array(stride(from: Float(-5), through: Float(5), by: Float(0.5)))
        let values = energies.map { exp(-($0 * $0) / 20.0) + 0.1 }
        return DensityOfStates(energies: energies,
                               series: [DOSSeries(label: "Total DOS", values: values)],
                               fermiEnergy: fermi)
    }

    private func makeView() -> DOSGrapherView {
        let view = DOSGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.densityOfStates = makeGapDOS()
        return view
    }

    func testEnergyAtViewPointMidpoint() {
        let view = makeView()
        let info = view.dataAtViewPoint(NSPoint(x: 100, y: 150))
        XCTAssertNotNil(info)
        XCTAssertEqual(info!.energy, 0.0, accuracy: 1.5)
    }

    func testEnergyAtViewPointOutsideNil() {
        let view = makeView()
        XCTAssertNil(view.dataAtViewPoint(NSPoint(x: -50, y: -50)))
        XCTAssertNil(view.dataAtViewPoint(NSPoint(x: 100, y: -50)))
    }

    func testFermiShiftDoesNotCrash() {
        let view = makeView()
        view.fermiShift = 2.0
        let info = view.dataAtViewPoint(NSPoint(x: 100, y: 150))
        XCTAssertNotNil(info)
    }

    func testEnergyWindowApplied() {
        let view = makeView()
        view.energyWindow = -2...2
        let info = view.dataAtViewPoint(NSPoint(x: 100, y: 150))
        XCTAssertNotNil(info)
        XCTAssertGreaterThanOrEqual(info!.energy, -3.0)
        XCTAssertLessThanOrEqual(info!.energy, 3.0)
    }

    func testDefaultStateValid() {
        let view = makeView()
        XCTAssertNil(view.energyWindow)
        XCTAssertEqual(view.fermiShift, 0)
        XCTAssertEqual(view.zoomScale, 1.0)
        XCTAssertNotNil(view.dataAtViewPoint(NSPoint(x: 100, y: 150)))
    }

    // MARK: - Gap-edge marker data

    func testDOSMarkerDataGapped() {
        let view = makeView()
        guard let markers = view.dosMarkerData() else {
            return XCTFail("Expected gap-edge markers for insulating DOS")
        }
        // Marker energies bracket the Fermi level.
        XCTAssertLessThan(markers.vbm.energy, 0.0)
        XCTAssertGreaterThan(markers.cbm.energy, 0.0)
        // DOS at each gap edge equals the detection threshold (interpolated).
        XCTAssertGreaterThanOrEqual(markers.vbm.dosValue, 0.0)
        XCTAssertGreaterThanOrEqual(markers.cbm.dosValue, 0.0)
        XCTAssertLessThan(markers.vbm.dosValue, 0.1)
        XCTAssertLessThan(markers.cbm.dosValue, 0.1)
    }

    func testDOSMarkerDataExactAtSamples() {
        // Gap extends to the lower grid edge so gap start = energies[0] exactly.
        // The DOS value at that grid point is 0.0 (exact, no interpolation error).
        let energies: [Float] = [-3, -2, -1, 0, 1, 2, 3]
        let values: [Float] = [0.0, 0.0, 0.0, 0.0, 0.5, 1.0, 1.0]
        let dos = DensityOfStates(energies: energies,
                                  series: [DOSSeries(label: "Total DOS", values: values)],
                                  fermiEnergy: 0.0)
        let view = DOSGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.densityOfStates = dos
        guard let markers = view.dosMarkerData() else {
            return XCTFail("Expected gap-edge markers")
        }
        // Gap start is the first grid point (exact sample, DOS = 0.0).
        XCTAssertEqual(markers.vbm.energy, -3.0, accuracy: 1e-5)
        XCTAssertEqual(markers.vbm.dosValue, 0.0, accuracy: 1e-5)
        // Gap end is interpolated between grid points.
        XCTAssertGreaterThan(markers.cbm.energy, 0.0)
        XCTAssertLessThan(markers.cbm.dosValue, 0.1)
    }

    func testDOSMarkerDataInterpolatedThreshold() {
        let view = makeView()
        guard let gapResult = DOSAnalysis.dosGap(view.densityOfStates!, seriesIndex: 0) else {
            return XCTFail("Expected gap analysis result")
        }
        guard let markers = view.dosMarkerData() else {
            return XCTFail("Expected gap-edge markers")
        }
        // Marker energies match the gap analysis output exactly.
        XCTAssertEqual(markers.vbm.energy, gapResult.gapStart, accuracy: 1e-5)
        XCTAssertEqual(markers.cbm.energy, gapResult.gapEnd, accuracy: 1e-5)
        // Interpolated DOS at each edge is near the detection threshold.
        XCTAssertLessThan(markers.vbm.dosValue, 0.1)
        XCTAssertLessThan(markers.cbm.dosValue, 0.1)
    }

    func testDOSMarkerDataNoGap() {
        let view = makeView()
        view.densityOfStates = makeMetallicDOS()
        XCTAssertNil(view.dosMarkerData())
    }

    func testDOSMarkerDataNoSeries() {
        let view = makeView()
        view.densityOfStates = DensityOfStates(energies: [0, 1], series: [], fermiEnergy: 0)
        XCTAssertNil(view.dosMarkerData())
    }

    func testDOSMarkerDataMismatchedCounts() {
        let view = makeView()
        view.densityOfStates = DensityOfStates(
            energies: [0, 1, 2],
            series: [DOSSeries(label: "Total DOS", values: [1.0, 2.0])],
            fermiEnergy: 0)
        XCTAssertNil(view.dosMarkerData())
    }

    func testDOSMarkerDataNonfiniteEnergies() {
        let view = makeView()
        view.densityOfStates = DensityOfStates(
            energies: [0, Float.nan, 2],
            series: [DOSSeries(label: "Total DOS", values: [1.0, 2.0, 3.0])],
            fermiEnergy: 0)
        XCTAssertNil(view.dosMarkerData())
    }

    func testDOSMarkerDataNonfiniteValues() {
        let view = makeView()
        view.densityOfStates = DensityOfStates(
            energies: [0, 1, 2],
            series: [DOSSeries(label: "Total DOS", values: [1.0, Float.nan, 3.0])],
            fermiEnergy: 0)
        XCTAssertNil(view.dosMarkerData())
    }

    func testDOSMarkerDataUnsortedEnergies() {
        let view = makeView()
        view.densityOfStates = DensityOfStates(
            energies: [0, 2, 1],
            series: [DOSSeries(label: "Total DOS", values: [1.0, 2.0, 3.0])],
            fermiEnergy: 0)
        XCTAssertNil(view.dosMarkerData())
    }

    func testDOSMarkerDataDuplicateEnergies() {
        let view = makeView()
        view.densityOfStates = DensityOfStates(
            energies: [0, 1, 1, 2],
            series: [DOSSeries(label: "Total DOS", values: [1.0, 2.0, 3.0, 4.0])],
            fermiEnergy: 0)
        XCTAssertNil(view.dosMarkerData())
    }

    // MARK: - Drawing

    private func drawViewAndCheckNonEmpty(_ view: NSView) -> Bool {
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        view.draw(view.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.bitmapData else { return false }
        let bytesPerRow = bitmap.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let r = data[offset], g = data[offset + 1], b = data[offset + 2], a = data[offset + 3]
                if a > 0 && (r != 255 || g != 255 || b != 255) { return true }
            }
        }
        return false
    }

    func testDOSDrawingNormal() {
        let view = makeView()
        XCTAssertNotNil(view.dosMarkerData())
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }

    func testDOSDrawingExport() {
        let view = makeView()
        view.exportBackground = NSColor.white
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }

    func testDOSDrawingMetallic() {
        let view = makeView()
        view.densityOfStates = makeMetallicDOS()
        XCTAssertNil(view.dosMarkerData())
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }

    func testDOSDrawingWithInteraction() {
        let view = makeView()
        XCTAssertNotNil(view.dosMarkerData())
        view.energyWindow = -3...3
        view.fermiShift = 0.5
        view.zoomScale = 1.5
        view.panOffset = NSPoint(x: 5, y: -3)
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }
}
