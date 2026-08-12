import AppKit
import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Coverage for the 3D band-surface plot view: headless draw smoke, export
/// rotation identity, and the controller + export wiring.
@MainActor
final class BandSurfaceViewTests: XCTestCase {

    // MARK: - Surface builder

    /// A tiny deterministic surface: gridSize 6, one sheet, values = s*1 + t*2 + 3.
    private func makeSurface() -> BandSurface {
        let gridSize = 6
        var values: [Float] = []
        values.reserveCapacity(gridSize * gridSize)
        for ti in 0..<gridSize {
            for si in 0..<gridSize {
                let s = Float(si) / Float(gridSize - 1)
                let t = Float(ti) / Float(gridSize - 1)
                values.append(s * 1.0 + t * 2.0 + 3.0)
            }
        }
        let energyMin = values.min()!
        let energyMax = values.max()!
        let sheet = BandSurfaceSheet(band: 0, spin: 0, label: "band 1", values: values)
        return BandSurface(
            region: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(0.5, 0.5, 0),
                     SIMD3<Float>(0, 0.5, 0)],
            regionLabels: ["G", "X", "M", ""],
            gridSize: gridSize,
            sheets: [sheet],
            fermiEnergy: 3.6,
            spinCount: 1,
            energyMin: energyMin,
            energyMax: energyMax
        )
    }

    // MARK: - Helpers

    /// Render a view into a fresh bitmap (cleared to white) and return it.
    private func renderToBitmap(_ view: NSView, background: NSColor = .white) -> NSBitmapImageRep? {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        ctx.cgContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: w, height: h))
        view.draw(view.bounds)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Count distinct RGBA colors in a bitmap.
    private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow
        var colors = Set<UInt64>()
        guard let base = rep.bitmapData else { return 0 }
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                let key = UInt64(p[0]) | (UInt64(p[1]) << 8) | (UInt64(p[2]) << 16) | (UInt64(p[3]) << 24)
                colors.insert(key)
            }
        }
        return colors.count
    }

    /// Count pixels that are NOT white (255,255,255,*).
    private func nonWhitePixels(_ rep: NSBitmapImageRep) -> Int {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow
        var count = 0
        guard let base = rep.bitmapData else { return 0 }
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                if p[0] != 255 || p[1] != 255 || p[2] != 255 { count += 1 }
            }
        }
        return count
    }

    /// Raw pixel data for byte comparison.
    private func pixelData(_ rep: NSBitmapImageRep) -> Data {
        let h = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow
        var data = Data(capacity: h * rowBytes)
        guard let base = rep.bitmapData else { return data }
        for y in 0..<h {
            data.append(base.advanced(by: y * rowBytes), count: rowBytes)
        }
        return data
    }

    // MARK: - Tests

    func testDrawSmoke() {
        let surface = makeSurface()
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }
        // Surface + shading produce non-uniform coloring.
        XCTAssertGreaterThan(distinctColors(rep), 20, "expected > 20 distinct colors, got \(distinctColors(rep))")
        XCTAssertGreaterThan(nonWhitePixels(rep), 100, "expected > 100 non-white pixels")

        // Mouse-drag rotation: horizontal drag orbits (azimuth), vertical drag
        // tilts (elevation); dragging up raises the viewpoint and elevation is
        // clamped to ±89°.
        view.rotate(byDeltaX: 20, deltaY: -40)
        XCTAssertEqual(view.azimuthDegrees, 30 - 20 * 0.5, accuracy: 1e-4)
        XCTAssertEqual(view.elevationDegrees, 24 + 40 * 0.5, accuracy: 1e-4)
        view.rotate(byDeltaX: 0, deltaY: 10_000)
        XCTAssertEqual(view.elevationDegrees, -89, accuracy: 1e-4)
        view.rotate(byDeltaX: 0, deltaY: -10_000)
        XCTAssertEqual(view.elevationDegrees, 89, accuracy: 1e-4)
    }

    func testExportRotationIdentity() {
        let surface = makeSurface()
        let size = CGRect(x: 0, y: 0, width: 240, height: 200)

        // Default draw with export background.
        let view1 = BandSurfaceView(frame: size)
        view1.bandSurface = surface
        view1.exportBackground = .white
        guard let rep1 = renderToBitmap(view1) else { return XCTFail("render 1 failed") }

        // Different rotation but export forces defaults.
        let view2 = BandSurfaceView(frame: size)
        view2.bandSurface = surface
        view2.azimuthDegrees = 90
        view2.exportBackground = .white
        guard let rep2 = renderToBitmap(view2) else { return XCTFail("render 2 failed") }

        // Byte-identical: export forces default rotation.
        XCTAssertEqual(pixelData(rep1), pixelData(rep2), "export must force default rotation")
    }

    func testControllerAndExportWiring() throws {
        let surface = makeSurface()
        var scene = Scene()
        scene.bandSurface = surface

        let wc = MainWindowController(scene: scene, showWindow: false)
        // Band surface visible, graphs and canvas hidden.
        XCTAssertFalse(wc.bandSurfaceView.isHidden, "band surface view should be visible")
        XCTAssertTrue(wc.linkedGraphs.isHidden, "linked graphs should be hidden")
        XCTAssertTrue(wc.canvas.isHidden, "canvas should be hidden")

        // Export scene produces a valid image file.
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_band_surface_test_\(UUID().uuidString).png")
        let image = try App.exportScene(scene, camera: nil, to: tmpURL,
                                         size: CGSize(width: 240, height: 200))
        XCTAssertNotNil(image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
        XCTAssertGreaterThan((attrs[.size] as? Int ?? 0), 0, "exported file must be non-empty")
        try? FileManager.default.removeItem(at: tmpURL)
    }
}
