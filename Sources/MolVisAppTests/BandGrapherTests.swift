import XCTest
import simd
@testable import MolVisApp

final class BandGrapherTests: XCTestCase {
    /// A simple two-k-point, single-band insulating band structure with a known gap.
    private func makeBandStructure(fermi: Float? = 0.0) -> BandStructure {
        let k0 = BandKPoint(k: SIMD3<Float>(0, 0, 0), weight: 1, label: "Γ", energies: [-2.0, 3.0])
        let k1 = BandKPoint(k: SIMD3<Float>(0.5, 0, 0), weight: 1, label: "X", energies: [-1.0, 4.0])
        return BandStructure(kPoints: [k0, k1], fermiEnergy: fermi, nSpin: 1,
                             reciprocal: nil, kPointsAreCrystal: false,
                             kPointsPerSpin: 2, isMesh: false)
    }

    /// Metallic band structure: band 0 crosses the Fermi level (isMetallic = true).
    private func makeMetallicBandStructure() -> BandStructure {
        let k0 = BandKPoint(k: SIMD3<Float>(0, 0, 0), weight: 1, label: "Γ", energies: [-1.0, 2.0])
        let k1 = BandKPoint(k: SIMD3<Float>(0.5, 0, 0), weight: 1, label: "X", energies: [1.0, 3.0])
        return BandStructure(kPoints: [k0, k1], fermiEnergy: 0.0, nSpin: 1,
                             reciprocal: nil, kPointsAreCrystal: false,
                             kPointsPerSpin: 2, isMesh: false)
    }

    private func makeView() -> BandGrapherView {
        let view = BandGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.bandStructure = makeBandStructure()
        return view
    }

    func testEnergyAtViewPointBottomIsMin() {
        let view = makeView()
        view.fermiShift = 0
        // Bottom of the plot area (near the axis origin) maps to the LOWEST energy.
        // Energies are -2..3 plus padding; near the bottom should be <= -1.
        let originY = view.bounds.height - 44   // axis origin y
        let e = view.energyAtViewPoint(NSPoint(x: 100, y: originY - 2))
        XCTAssertNotNil(e)
        XCTAssertLessThanOrEqual(e!, -1.0)
    }

    func testEnergyAtViewPointTopIsMax() {
        let view = makeView()
        view.fermiShift = 0
        // Top of the plot area maps to the HIGHEST energy (>= 2).
        let e = view.energyAtViewPoint(NSPoint(x: 100, y: 30))
        XCTAssertNotNil(e)
        XCTAssertGreaterThanOrEqual(e!, 2.0)
    }

    func testEnergyAtViewPointOutsideNil() {
        let view = makeView()
        XCTAssertNil(view.energyAtViewPoint(NSPoint(x: -50, y: -50)))
    }

    func testFermiShiftReadoutStaysFinite() {
        let view = makeView()
        let p = NSPoint(x: 100, y: 100)
        // energyAtViewPoint reports original eV. A pure display shift moves the bands
        // and the auto-range together, so the readout at a fixed screen point stays
        // finite and bounded by the padded energy window either side of the shift.
        view.fermiShift = 0
        let e0 = view.energyAtViewPoint(p)
        view.fermiShift = 5.0
        let e5 = view.energyAtViewPoint(p)
        XCTAssertNotNil(e0)
        XCTAssertNotNil(e5)
        // Energies span -2..3 padded; both readouts must lie within a sensible window.
        XCTAssertGreaterThan(e0!, -5)
        XCTAssertLessThan(e0!, 6)
        XCTAssertGreaterThan(e5!, -5)
        XCTAssertLessThan(e5!, 6)
    }

    func testEnergyWindowClampsRange() {
        let view = makeView()
        view.energyWindow = -1...1
        // A point near the top of the plot (low displayed energy) should report within window.
        let e = view.energyAtViewPoint(NSPoint(x: 100, y: 30))
        XCTAssertNotNil(e)
        // Reported original energy = displayed + shift(0); displayed is within -1...1.
        XCTAssertGreaterThanOrEqual(e!, -1.5)
        XCTAssertLessThanOrEqual(e!, 1.5)
    }

    func testDefaultStatePreservesRendering() {
        // With no interaction state set, the grapher must still produce valid output.
        let view = makeView()
        XCTAssertNil(view.energyWindow)
        XCTAssertEqual(view.fermiShift, 0)
        XCTAssertEqual(view.zoomScale, 1.0)
        XCTAssertNotNil(view.energyAtViewPoint(NSPoint(x: 120, y: 150)))
    }

    // MARK: - Band gap marker data

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

    func testBandMarkerDataInsulating() {
        let view = makeView()
        // makeBandStructure: k0 energies [-2, 3], k1 energies [-1, 4], ef=0.
        // VBM = max occupied = -1.0 at k1 (index 1), CBM = min unoccupied = 3.0 at k0 (index 0).
        let markers = view.bandMarkerData()
        XCTAssertNotNil(markers)
        XCTAssertEqual(markers!.vbm.kIndex, 1)
        XCTAssertEqual(markers!.vbm.energy, -1.0)
        XCTAssertEqual(markers!.cbm.kIndex, 0)
        XCTAssertEqual(markers!.cbm.energy, 3.0)
    }

    func testBandMarkerDataMetallic() {
        let view = makeView()
        view.bandStructure = makeMetallicBandStructure()
        // Band 0 crosses ef=0 (ranges -1..1), so isMetallic=true. Markers still
        // return the highest-occupied / lowest-unoccupied extrema: VBM=-1.0 at k0
        // (index 0), CBM=1.0 at k1 (index 1), linking to the reported analysis.
        let markers = view.bandMarkerData()
        XCTAssertNotNil(markers)
        XCTAssertEqual(markers!.vbm.kIndex, 0)
        XCTAssertEqual(markers!.vbm.energy, -1.0)
        XCTAssertEqual(markers!.cbm.kIndex, 1)
        XCTAssertEqual(markers!.cbm.energy, 1.0)
    }

    func testBandMarkerDataMesh() {
        let view = makeView()
        var bs = makeBandStructure()
        bs.isMesh = true
        view.bandStructure = bs
        // Mesh paths have no meaningful VBM/CBM -> no markers.
        XCTAssertNil(view.bandMarkerData())
    }

    func testBandMarkerDataNoFermi() {
        let view = makeView()
        view.bandStructure = makeBandStructure(fermi: nil)
        // No Fermi level -> bandGap returns nil -> no markers.
        XCTAssertNil(view.bandMarkerData())
    }

    func testBandMarkerDataInvalidChannelLayout() {
        let view = makeView()
        let bs = BandStructure(kPoints: [
            BandKPoint(k: SIMD3<Float>(0, 0, 0), weight: 1, label: "Γ", energies: [-2.0, 3.0]),
            BandKPoint(k: SIMD3<Float>(0.5, 0, 0), weight: 1, label: "X", energies: [-1.0, 4.0])
        ], fermiEnergy: 0.0, nSpin: 2, reciprocal: nil, kPointsAreCrystal: false,
            kPointsPerSpin: 2, isMesh: false)
        // nSpin=2 * kPointsPerSpin=2 = 4 != 2 k-points -> invalid layout -> no markers.
        view.bandStructure = bs
        XCTAssertNil(view.bandMarkerData())
    }

    func testBandMarkerDataEmptyKPoints() {
        let view = BandGrapherView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.bandStructure = BandStructure(kPoints: [], fermiEnergy: 0.0, nSpin: 1,
                                           reciprocal: nil, kPointsAreCrystal: false,
                                           kPointsPerSpin: 0, isMesh: false)
        XCTAssertNil(view.bandMarkerData())
    }

    func testBandMarkerDrawingInsulating() {
        let view = makeView()
        XCTAssertNotNil(view.bandMarkerData())
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }

    func testBandMarkerDrawingExport() {
        let view = makeView()
        view.exportBackground = NSColor.white
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }

    func testBandMarkerDrawingMetallic() {
        let view = makeView()
        view.bandStructure = makeMetallicBandStructure()
        // Metallic paths now draw VBM/CBM extrema markers (not suppressed).
        XCTAssertNotNil(view.bandMarkerData())
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }

    func testBandMarkerDrawingWithInteraction() {
        let view = makeView()
        XCTAssertNotNil(view.bandMarkerData())
        view.energyWindow = -3...5
        view.fermiShift = 1.0
        view.zoomScale = 2.0
        view.panOffset = NSPoint(x: 10, y: -5)
        XCTAssertTrue(drawViewAndCheckNonEmpty(view))
    }
}
