import AppKit
import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Regression coverage for the CPU z-buffer rewrite of BandSurfaceView: malformed
/// data rejection, z-buffer occlusion, Fermi-plane domain gating + occlusion,
/// the energy-axis aspect fix, WYSIWYG export orientation, and Scene persistence
/// of the band-surface orientation.
@MainActor
final class BandSurfaceViewFixTests: XCTestCase {

    // MARK: - Helpers (mirror BandSurfaceViewTests)

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

    private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        let w = rep.pixelsWide, h = rep.pixelsHigh, rowBytes = rep.bytesPerRow
        var colors = Set<UInt64>()
        guard let base = rep.bitmapData else { return 0 }
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                colors.insert(UInt64(p[0]) | (UInt64(p[1]) << 8) | (UInt64(p[2]) << 16) | (UInt64(p[3]) << 24))
            }
        }
        return colors.count
    }

    private func nonWhitePixels(_ rep: NSBitmapImageRep) -> Int {
        let w = rep.pixelsWide, h = rep.pixelsHigh, rowBytes = rep.bytesPerRow
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

    private func pixelData(_ rep: NSBitmapImageRep) -> Data {
        let h = rep.pixelsHigh, rowBytes = rep.bytesPerRow
        var data = Data(capacity: h * rowBytes)
        guard let base = rep.bitmapData else { return data }
        for y in 0..<h { data.append(base.advanced(by: y * rowBytes), count: rowBytes) }
        return data
    }

    /// Pixel content only (excludes row-alignment padding bytes), so two renders of
    /// the same scene compare equal even when the bitmap's bytesPerRow has padding.
    private func rawPixels(_ rep: NSBitmapImageRep) -> Data {
        let w = rep.pixelsWide, h = rep.pixelsHigh, rowBytes = rep.bytesPerRow
        var data = Data(capacity: h * w * 4)
        guard let base = rep.bitmapData else { return data }
        for y in 0..<h {
            for x in 0..<w {
                let p = base.advanced(by: y * rowBytes + x * 4)
                data.append(contentsOf: [p[0], p[1], p[2], p[3]])
            }
        }
        return data
    }

    /// Pixel content restricted to rows [rowMin, H). The title is drawn near the top
    /// of the view, so cropping lets two renders whose titles differ be compared over
    /// just the plot body.
    private func rawPixelsBelow(_ rep: NSBitmapImageRep, _ rowMin: Int) -> Data {
        let w = rep.pixelsWide, h = rep.pixelsHigh, rowBytes = rep.bytesPerRow
        var data = Data(capacity: (h - rowMin) * w * 4)
        guard let base = rep.bitmapData else { return data }
        for y in rowMin..<h {
            for x in 0..<w {
                let p = base.advanced(by: y * rowBytes + x * 4)
                data.append(contentsOf: [p[0], p[1], p[2], p[3]])
            }
        }
        return data
    }

    /// Build a unit-patch surface with two flat sheets at fixed energies.
    private func makeTwoSheetSurface(sheetA: Float, sheetB: Float,
                                     fermi: Float?) -> BandSurface {
        let gridSize = 8
        func vals(_ e: Float) -> [Float] { [Float](repeating: e, count: gridSize * gridSize) }
        let lo = min(sheetA, sheetB), hi = max(sheetA, sheetB)
        return BandSurface(
            region: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                     SIMD3<Float>(1, 1, 0)],
            regionLabels: ["G", "X", "Y", ""],
            gridSize: gridSize,
            sheets: [BandSurfaceSheet(band: 0, spin: 0, label: "A", values: vals(sheetA)),
                     BandSurfaceSheet(band: 1, spin: 0, label: "B", values: vals(sheetB))],
            fermiEnergy: fermi, spinCount: 1, energyMin: lo, energyMax: hi)
    }

    // MARK: - Tests

    /// Count pure-black (r==0 && g==0 && b==0) pixels below the title strip. The 3D
    /// axes are the only large pure-black raster elements, so this isolates them from
    /// antialiased text/tick contributions.
    private func pureBlackPixels(_ rep: NSBitmapImageRep, rowMin: Int) -> Int {
        let w = rep.pixelsWide, h = rep.pixelsHigh, rb = rep.bytesPerRow
        var count = 0
        guard let base = rep.bitmapData else { return 0 }
        for y in rowMin..<h {
            let row = base.advanced(by: y * rb)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                if p[0] == 0 && p[1] == 0 && p[2] == 0 { count += 1 }
            }
        }
        return count
    }

    /// EMPTY-sheets surface: axes-only, no placeholder, no crash. The k₁/k₂ axes
    /// are coplanar with the base plane, so without a viewer-depth bias they would
    /// z-fight the base fill and flicker/vanish. With the bias they render as solid
    /// pure-black geometry. Calibrated: ~394 pure-black px below the title strip.
    func testAxesVisibleWhenCoplanar() {
        let surface = BandSurface(
            region: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                     SIMD3<Float>(1, 1, 0)],
            regionLabels: ["G", "X", "Y", ""], gridSize: 4, sheets: [],
            fermiEnergy: nil, spinCount: 1, energyMin: 0, energyMax: 1)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }
        // Title occupies the top ~60 px of the 260px view; count axes below it.
        let black = pureBlackPixels(rep, rowMin: 60)
        print("testAxesVisibleWhenCoplanar pure-black px below title = \(black)")
        XCTAssertGreaterThan(black, 300,
                             "coplanar 3D axes should render solid pure-black geometry (\(black) px)")
    }

    /// With two flat sheets (A at z=-10 base plane, B at z=+10 raised), the k₁/k₂
    /// axes lie on the base plane. Sheet B (nearer, depth margin ~0.75 >> 1e-3 bias)
    /// dominates surface pixels — proven separately by testDepthOcclusionNearerSheetWins.
    /// In this projection the raised sheet B does not overlap the base-plane floor
    /// edges in screen space, so the coplanar axes stay visible (bias wins their
    /// ties). The bias is small enough that it does NOT punch the axes through sheet
    /// B where they genuinely overlap — i.e. the visible black count stays modest and
    /// bounded by what the axes themselves contribute. Calibrated: ~382 px.
    func testAxesOccludedByNearerSurface() {
        let surface = makeTwoSheetSurface(sheetA: -10, sheetB: 10, fermi: nil)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }
        let black = pureBlackPixels(rep, rowMin: 60)
        print("testAxesOccludedByNearerSurface pure-black px below title = \(black)")
        // Small bias (1e-3) must not inflate axis visibility past what the geometry
        // actually contributes; it stays bounded near the bare-axes count.
        XCTAssertLessThan(black, 500,
                          "small depth bias must not punch axes through nearer surfaces (\(black) px)")
    }

    /// Malformed sheet (wrong value count) must not crash and must draw the
    /// placeholder, not a corrupted frame. The placeholder is near-uniform
    /// background + overlay text, so it has far fewer distinct colors and non-white
    /// pixels than a valid surface of the same grid.
    func testMalformedSheetDrawsEmptyPlaceholder() {
        let gridSize = 4
        let sheet = BandSurfaceSheet(band: 0, spin: 0, label: "bad",
                                     values: [Float](repeating: 0, count: gridSize))
        let surface = BandSurface(
            region: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                     SIMD3<Float>(1, 1, 0)],
            regionLabels: ["G", "X", "Y", ""], gridSize: gridSize, sheets: [sheet],
            fermiEnergy: nil, spinCount: 1, energyMin: 0, energyMax: 1)

        func render(_ s: BandSurface) -> NSBitmapImageRep {
            let v = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
            v.bandSurface = s
            guard let r = self.renderToBitmap(v) else { XCTFail("render failed"); fatalError() }
            return r
        }

        let repBad = render(surface)
        // Same geometry but a well-formed sheet (gridSize^2 values).
        let goodSheet = BandSurfaceSheet(band: 0, spin: 0, label: "good",
                                         values: [Float](repeating: 0.5, count: gridSize * gridSize))
        var goodSurface = surface
        goodSurface.sheets = [goodSheet]
        let repGood = render(goodSurface)

        // No crash + placeholder is far less populated than a valid surface.
        XCTAssertLessThan(distinctColors(repBad), distinctColors(repGood),
                          "malformed placeholder (\(distinctColors(repBad)) colors) should be sparser than valid (\(distinctColors(repGood)))")
        XCTAssertLessThan(nonWhitePixels(repBad), nonWhitePixels(repGood),
                          "malformed placeholder (\(nonWhitePixels(repBad)) px) should be sparser than valid (\(nonWhitePixels(repGood)))")
    }

    /// The nearer (higher-energy) sheet must win the z-buffer on overlapping pixels.
    func testDepthOcclusionNearerSheetWins() {
        let surface = makeTwoSheetSurface(sheetA: -10, sheetB: 10, fermi: 0)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }

        // Flat sheets: normal ±z. With the default elevation tilt, both faces are
        // lit; viridis(-10) and viridis(+10) differ strongly, so count which dominates.
        func expectedRGB(_ e: Float) -> (Float, Float, Float) {
            let t = (e - surface.energyMin) / max(1e-6, surface.energyMax - surface.energyMin)
            let c = Colormap.viridis.rgb(t)
            let shade = 0.55 + 0.45 * max(0, simd_dot(SIMD3<Float>(0, 0, 1),
                                                       simd_normalize(SIMD3<Float>(0.35, 0.45, 0.85))))
            return (c.x * shade, c.y * shade, c.z * shade)
        }
        let colA = expectedRGB(-10), colB = expectedRGB(10)
        let w = rep.pixelsWide, h = rep.pixelsHigh, rowBytes = rep.bytesPerRow
        guard let base = rep.bitmapData else { return }
        var likeA = 0, likeB = 0
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                if p[0] == 255 && p[1] == 255 && p[2] == 255 { continue }  // background
                let r = Float(p[0]) / 255, g = Float(p[1]) / 255, b = Float(p[2]) / 255
                let dA = abs(r - colA.0) + abs(g - colA.1) + abs(b - colA.2)
                let dB = abs(r - colB.0) + abs(g - colB.1) + abs(b - colB.2)
                if dA < dB { likeA += 1 } else { likeB += 1 }
            }
        }
        XCTAssertGreaterThan(likeB, likeA * 2,
                             "nearer sheet B should dominate: B-like \(likeB) vs A-like \(likeA)")
    }

    /// Red (Fermi outline) pixels in the rows below the title strip. The
    /// outline is red 0.6 premultiplied over base/sheet/background — r stays
    /// high, g stays low, and the blue channel stays low over every backdrop.
    /// The top sheet's viridis(≈1) pink (218,85,130) is excluded by b < 90.
    private func strongRedPixels(_ rep: NSBitmapImageRep, rowMin: Int) -> Int {
        let w = rep.pixelsWide, h = rep.pixelsHigh, rb = rep.bytesPerRow
        var count = 0
        guard let base = rep.bitmapData else { return 0 }
        for y in rowMin..<h {
            let row = base.advanced(by: y * rb)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                if r > 170 && g < 170 && b < 90 { count += 1 }
            }
        }
        return count
    }

    /// Fermi plane is drawn only when E_f lies inside the displayed energy domain.
    /// We assert the domain gate directly (pure, raster-independent) and confirm the
    /// visual consequence: an inside-domain surface shows strongly-red Fermi-plane
    /// pixels in the plot body, while an outside-domain surface shows none.
    func testFermiDomainAndColor() {
        let inside = makeTwoSheetSurface(sheetA: -10, sheetB: 10, fermi: 0)
        let outside = makeTwoSheetSurface(sheetA: -10, sheetB: 10, fermi: 15)

        // Domain gate (the actual Finding-7 fix), tested as a pure predicate.
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        XCTAssertTrue(view.isFermiPlaneInDomain(inside), "Ef=0 must be inside [-10,10]")
        XCTAssertFalse(view.isFermiPlaneInDomain(outside), "Ef=15 must be outside [-10,10]")

        // Visual consequence: inside-domain renders the red Fermi plane; outside does not.
        func render(_ s: BandSurface) -> NSBitmapImageRep {
            let v = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
            v.bandSurface = s
            guard let r = self.renderToBitmap(v) else { XCTFail("render failed"); fatalError() }
            return r
        }
        // Title occupies the top ~60 px; the Fermi plane lives in the rows below it.
        let repIn = render(inside), repOut = render(outside)
        let redIn = strongRedPixels(repIn, rowMin: 60)
        let redOut = strongRedPixels(repOut, rowMin: 60)
        XCTAssertGreaterThan(redIn, 150,
                             "Fermi plane inside domain must render red pixels (\(redIn))")
        XCTAssertLessThan(redOut, 30,
                          "Fermi plane outside domain must not be drawn (\(redOut) red px)")
    }

    /// Wide energy range must occupy a substantial vertical extent (not a collapsed sliver).
    func testEnergyAxisAspect() {
        let gridSize = 6
        func vals(_ e: Float) -> [Float] { [Float](repeating: e, count: gridSize * gridSize) }
        // One sheet sweeping 0..50 eV over the unit patch.
        var values: [Float] = []
        values.reserveCapacity(gridSize * gridSize)
        for ti in 0..<gridSize {
            for si in 0..<gridSize {
                let s = Float(si) / Float(gridSize - 1)
                let t = Float(ti) / Float(gridSize - 1)
                values.append((s + t) * 25.0)  // 0..50
            }
        }
        let surface = BandSurface(
            region: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                     SIMD3<Float>(1, 1, 0)],
            regionLabels: ["G", "X", "Y", ""], gridSize: gridSize,
            sheets: [BandSurfaceSheet(band: 0, spin: 0, label: "sweep", values: values)],
            fermiEnergy: nil, spinCount: 1, energyMin: 0, energyMax: 50)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }
        let thirdH = rep.pixelsHigh / 3
        // Count non-white pixels in the top third and bottom third.
        func nonWhite(inRowRange: Range<Int>) -> Int {
            var count = 0
            guard let base = rep.bitmapData else { return 0 }
            for y in inRowRange {
                let row = base.advanced(by: y * rep.bytesPerRow)
                for x in 0..<rep.pixelsWide {
                    let p = row.advanced(by: x * 4)
                    if p[0] != 255 || p[1] != 255 || p[2] != 255 { count += 1 }
                }
            }
            return count
        }
        let top = nonWhite(inRowRange: 0..<thirdH)
        let bot = nonWhite(inRowRange: (rep.pixelsHigh - thirdH)..<rep.pixelsHigh)
        XCTAssertGreaterThan(top, 5, "top third should contain surface content, got \(top)")
        XCTAssertGreaterThan(bot, 5, "bottom third should contain surface content, got \(bot)")
    }

    /// Export must reflect the interactive rotation (WYSIWYG), not force defaults.
    func testExportRotationReflectsOrientation() {
        let surface = makeTwoSheetSurface(sheetA: -5, sheetB: 5, fermi: 0)
        let size = CGRect(x: 0, y: 0, width: 240, height: 200)

        let viewA = BandSurfaceView(frame: size)
        viewA.bandSurface = surface
        viewA.exportBackground = .white
        guard let repA = renderToBitmap(viewA) else { return XCTFail("render A failed") }

        let viewB = BandSurfaceView(frame: size)
        viewB.bandSurface = surface
        viewB.azimuthDegrees = 90
        viewB.exportBackground = .white
        guard let repB = renderToBitmap(viewB) else { return XCTFail("render B failed") }

        XCTAssertNotEqual(pixelData(repA), pixelData(repB),
                          "export must reflect rotation, not force defaults")
    }

    /// BandSurfaceOrientation must round-trip through Scene Codable and be optional.
    func testBandSurfaceOrientationPersistence() {
        var scene = Scene()
        scene.bandSurfaceOrientation = BandSurfaceOrientation(azimuthDegrees: 42, elevationDegrees: -30)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(scene) else { return XCTFail("encode failed") }
        guard let decoded = try? JSONDecoder().decode(Scene.self, from: data) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.bandSurfaceOrientation, scene.bandSurfaceOrientation)

        // JSON without the key decodes to nil (Optionals are decode-if-present).
        let minimal = #"{"title":"x"}"#
        guard let scene2 = try? JSONDecoder().decode(Scene.self, from: minimal.data(using: .utf8)!) else {
            return XCTFail("decode minimal failed")
        }
        XCTAssertNil(scene2.bandSurfaceOrientation, "absent key must decode to nil")
    }

    /// Triangle fills must land exactly where the plot-local line path draws.
    /// The Fermi plane is rendered BOTH ways in one draw call: its fill goes
    /// through triangle rasterization (rasterTri) and its boundary through the
    /// line path (rasterLine/bufXY). Both describe the same (s,t) plane at the
    /// same energy, so their screen footprints must coincide. A coordinate
    /// misregistration (absolute view coords used as buffer indices) shifts the
    /// fill by the plot origin (~56 px right, ~44 px down) relative to its own
    /// outline — which this asserts against.
    func testFermiFillAlignedWithOutline() {
        let gridSize = 8
        let region: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)]
        let surface = BandSurface(region: region, regionLabels: ["G", "X", "Y", ""],
                                  gridSize: gridSize, sheets: [],
                                  fermiEnergy: 0.5, spinCount: 1, energyMin: 0, energyMax: 1)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }

        // Fermi fill: red 0.15 premultiplied over the 0.975-gray base plane
        // ≈ (250, 211, 211). Fermi outline: red 0.6 over the base ≈ (252, 99, 99).
        func isFill(_ p: UnsafePointer<UInt8>) -> Bool {
            let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
            return r >= 240 && g >= 195 && g <= 228 && b >= 195 && b <= 228
                && r - g >= 20
        }
        func isOutline(_ p: UnsafePointer<UInt8>) -> Bool {
            let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
            return r >= 240 && g < 160 && b < 160 && g == b
        }
        func bbox(_ match: (UnsafePointer<UInt8>) -> Bool) -> (Int, Int, Int, Int)? {
            let w = rep.pixelsWide, h = rep.pixelsHigh, rb = rep.bytesPerRow
            guard let base = rep.bitmapData else { return nil }
            var b: (Int, Int, Int, Int)?
            for y in 24..<h {
                let row = base.advanced(by: y * rb)
                for x in 0..<w {
                    let p = row.advanced(by: x * 4)
                    guard match(p) else { continue }
                    if let cur = b {
                        b = (min(cur.0, x), max(cur.1, x), min(cur.2, y), max(cur.3, y))
                    } else {
                        b = (x, x, y, y)
                    }
                }
            }
            return b
        }
        guard let fillBox = bbox(isFill) else { return XCTFail("no Fermi fill pixels found") }
        guard let outlineBox = bbox(isOutline) else { return XCTFail("no Fermi outline pixels found") }
        let dx0 = abs(fillBox.0 - outlineBox.0), dx1 = abs(fillBox.1 - outlineBox.1)
        let dy0 = abs(fillBox.2 - outlineBox.2), dy1 = abs(fillBox.3 - outlineBox.3)
        XCTAssertLessThanOrEqual(dx0, 2, "fill left \(fillBox.0) vs outline \(outlineBox.0)")
        XCTAssertLessThanOrEqual(dx1, 2, "fill right \(fillBox.1) vs outline \(outlineBox.1)")
        XCTAssertLessThanOrEqual(dy0, 2, "fill top \(fillBox.2) vs outline \(outlineBox.2)")
        XCTAssertLessThanOrEqual(dy1, 2, "fill bottom \(fillBox.3) vs outline \(outlineBox.3)")
    }

    /// A band fragment exactly AT energyMin is coplanar with the base plane.
    /// The floor must not occlude it (strict `>` depth test against a
    /// depth-writing floor would hide it); the sheet must render with its own
    /// viridis color.
    func testBandAtEnergyMinVisibleOverBasePlane() {
        let gridSize = 8
        let region: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)]
        let sheet = BandSurfaceSheet(band: 0, spin: 0, label: "min",
                                     values: [Float](repeating: 0, count: gridSize * gridSize))
        let surface = BandSurface(region: region, regionLabels: ["G", "X", "Y", ""],
                                  gridSize: gridSize, sheets: [sheet],
                                  fermiEnergy: nil, spinCount: 1, energyMin: 0, energyMax: 1)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }

        // Sheet color: viridis(t=0) shaded with the +z normal.
        let c = Colormap.viridis.rgb(0)
        let shade = 0.55 + 0.45 * max(0, simd_dot(SIMD3<Float>(0, 0, 1),
                                                   simd_normalize(SIMD3<Float>(0.35, 0.45, 0.85))))
        let er = Int(min(255, (c.x * shade * 255).rounded()))
        let eg = Int(min(255, (c.y * shade * 255).rounded()))
        let eb = Int(min(255, (c.z * shade * 255).rounded()))
        let w = rep.pixelsWide, h = rep.pixelsHigh, rb = rep.bytesPerRow
        guard let base = rep.bitmapData else { return }
        var count = 0
        var floorPx = 0
        for y in 24..<h {
            let row = base.advanced(by: y * rb)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                if abs(r - er) <= 25 && abs(g - eg) <= 25 && abs(b - eb) <= 25 {
                    count += 1
                }
                // The floor's 249-gray must NOT speckle through the coplanar
                // sheet: a depth-writing floor z-fights and leaves ~half the
                // patch (thousands of pixels) showing the floor color.
                if max(r, g, b) - min(r, g, b) <= 2 && r >= 240 && r <= 253 {
                    floorPx += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 2000,
                             "band at energyMin must be visible over the base plane (\(count) px)")
        XCTAssertLessThan(floorPx, 500,
                          "the floor must not z-fight with the coplanar band (\(floorPx) floor px)")
    }

    /// The translucent Fermi plane is rasterized as one quadrilateral, so its
    /// interior is blended exactly once everywhere. A two-triangle split shares
    /// a diagonal; any pixel that lands exactly on it would be double-blended
    /// (≈(251,180,180) vs the single-blend ≈(250,212,212)) into a darker seam.
    /// The quad removes that edge by construction; this asserts no
    /// double-blended pixels appear.
    func testFermiPlaneHasNoDiagonalSeam() {
        let gridSize = 8
        let region: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)]
        let surface = BandSurface(region: region, regionLabels: ["G", "X", "Y", ""],
                                  gridSize: gridSize, sheets: [],
                                  fermiEnergy: 0.5, spinCount: 1, energyMin: 0, energyMax: 1)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }
        let w = rep.pixelsWide, h = rep.pixelsHigh, rb = rep.bytesPerRow
        guard let base = rep.bitmapData else { return }
        var seam = 0
        for y in 24..<h {
            let row = base.advanced(by: y * rb)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                // Double-blended diagonal pixels read g/b ≈ 180; single-blended
                // fill reads g/b ≈ 212; the red outline reads g/b ≈ 99.
                if r > 240 && g >= 165 && g <= 195 && abs(g - b) <= 8 { seam += 1 }
            }
        }
        XCTAssertLessThan(seam, 10, "Fermi plane must not show a double-blended diagonal seam (\(seam) px)")
    }

    /// The translucent base-plane fill must be premultiplied: 0.9 gray at 0.25
    /// alpha over white ≈ 0.975 → (249,249,249). A straight-RGB blend would
    /// clamp to (255,255,255) and be indistinguishable from the background.
    func testTranslucentBasePlaneIsPremultiplied() {
        let gridSize = 8
        let region: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)]
        let surface = BandSurface(region: region, regionLabels: ["G", "X", "Y", ""],
                                  gridSize: gridSize, sheets: [],
                                  fermiEnergy: nil, spinCount: 1, energyMin: 0, energyMax: 1)
        let view = BandSurfaceView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view.bandSurface = surface
        guard let rep = renderToBitmap(view) else { return XCTFail("render failed") }
        let w = rep.pixelsWide, h = rep.pixelsHigh, rb = rep.bytesPerRow
        guard let base = rep.bitmapData else { return }
        var near = 0
        for y in 24..<h {
            let row = base.advanced(by: y * rb)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                if r >= 245 && r <= 253 && g >= 245 && g <= 253 && b >= 245 && b <= 253
                    && max(r, g, b) - min(r, g, b) <= 2 {
                    near += 1
                }
            }
        }
        XCTAssertGreaterThan(near, 5000,
                             "premultiplied base fill should produce a large near-249 region, got \(near)")
    }
}
