import AppKit
import Foundation
import simd
import XCTest
@testable import MolVisApp

/// Focused coverage for the new electronic-structure analysis presentation layer:
/// the band+DOS linked report, QE-projwfc DOS label enrichment, orbital coloring,
/// and the linked-cursor guide-line energy on the graph views.
///
/// The first and last exercises reference APIs (`ElectronicAnalysisPresentation.linkedReport`,
/// `DOSParser.parse(_:sourceName:)`, `BandGrapherView.linkedCursorEnergy`,
/// `DOSGrapherView.linkedCursorEnergy`) that are landing on parallel branches; they are
/// written to the documented contract so the suite stays green once those branches integrate.
@MainActor
final class ElectronicAnalysisTests: XCTestCase {

    // MARK: - Fixtures

    /// Insulator band path: 9 k-points, 4 bands, E_f = 0. Two flat valence bands pinned
    /// at -2.0 / -0.5 eV and two conduction bands at +0.5 / +3.0 eV, so VBM = -0.5,
    /// CBM = +0.5, gap = 1.0 eV, non-metallic, direct (VBM and CBM at the same k).
    private func makeInsulatorBandPath() -> BandStructure {
        let kPoints = (0..<9).map { i -> BandKPoint in
            let frac = SIMD3<Float>(Float(i) / 8.0, 0, 0)
            return BandKPoint(k: frac, weight: 1, label: "", energies: [-2.0, -0.5, 0.5, 3.0])
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: 0, nSpin: 1, kPointsPerSpin: 9)
    }

    /// Metallic band path: 4 bands where the second crosses E_f = 0, forcing
    /// isMetallic = true and gap = 0 from BandAnalysis.bandGap.
    private func makeMetallicBandPath() -> BandStructure {
        let kPoints = (0..<9).map { i -> BandKPoint in
            let frac = SIMD3<Float>(Float(i) / 8.0, 0, 0)
            let crossing = -0.3 + (Float(i) / 8.0) * 0.6  // -0.3 .. +0.3, crosses 0
            return BandKPoint(k: frac, weight: 1, label: "",
                              energies: [-1.0, -0.5, crossing, 1.0])
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: 0, nSpin: 1, kPointsPerSpin: 9)
    }

    /// Small 10-kpoint band path for the graph-view cursor test (valid for
    /// energyAtViewPoint: nKPoints > 1, nBands > 0).
    private func makeShortBandPath() -> BandStructure {
        let kPoints = (0..<10).map { i -> BandKPoint in
            BandKPoint(k: SIMD3(Float(i) / 9, 0, 0), weight: 1, label: "", energies: [-1.0, 1.0])
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: 0, nSpin: 1, kPointsPerSpin: 10)
    }

    /// DOS whose `dosGap` is ~`width` eV, centered at `center`, by holding the DOS at 0.0
    /// across the plateau and 1.0 outside it. Energies span -3...3 in 0.5 eV steps.
    private func makeGapDOS(width: Float, center: Float = 0, fermi: Float? = 0) -> DensityOfStates {
        let energies = (-6...6).map { Float($0) * 0.5 }
        let half = width / 2
        let lo = center - half, hi = center + half
        let values = energies.map { (Float($0) >= lo && Float($0) <= hi) ? Float(0) : Float(1.0) }
        return DensityOfStates(energies: energies,
                               series: [DOSSeries(label: "Total DOS", values: values)],
                               fermiEnergy: fermi)
    }

    private func makeSmallDOS() -> DensityOfStates {
        let energies = (-6...6).map { Float($0) * 0.5 }
        let values = energies.map { _ in Float(1.0) }
        return DensityOfStates(energies: energies,
                               series: [DOSSeries(label: "Total DOS", values: values)],
                               fermiEnergy: 0)
    }

    // MARK: - Linked band+DOS report and QE projwfc DOS label enrichment

    func testLinkedReportAndDOSLabelEnrichment() {
        // --- Linked band+DOS report ---
        let band = makeInsulatorBandPath()

        // Confirm the band gap the report will summarize: ~1.0 eV.
        guard let bandGap = BandAnalysis.bandGap(band) else {
            return XCTFail("insulator band path must yield a band gap")
        }
        XCTAssertEqual(bandGap.gap, 1.0, accuracy: 0.05)
        XCTAssertFalse(bandGap.isMetallic)

        // DOS plateau aligned to the band gap [-0.5, 0.5] => dosGap ~1.0 eV.
        let agreeDOS = makeGapDOS(width: 1.0)
        guard let dosGap = DOSAnalysis.dosGap(agreeDOS) else {
            return XCTFail("aligned DOS must yield a DOS gap")
        }
        XCTAssertEqual(dosGap.gapWidth, 1.0, accuracy: 0.1)

        let bandR = ElectronicAnalysisPresentation.bandReport(band)
        let report = ElectronicAnalysisPresentation.linkedReport(band: band, dos: agreeDOS)

        // 14 rows = 7 band + 5 DOS + 2 cross-check.
        XCTAssertEqual(report.rows.count, 14)
        // The first 7 rows are exactly the standalone band report.
        for (i, row) in bandR.rows.enumerated() {
            XCTAssertEqual(report.rows[i].metric, row.metric)
            XCTAssertEqual(report.rows[i].value, row.value)
            XCTAssertEqual(report.rows[i].status, row.status)
        }

        let gapRow = report.rows[12]
        let edgeRow = report.rows[13]
        XCTAssertEqual(gapRow.metric, "Gap agreement (bands vs DOS)")
        XCTAssertEqual(edgeRow.metric, "Band-edge agreement (bands vs DOS)")
        XCTAssertEqual(gapRow.status, .available)
        XCTAssertEqual(edgeRow.status, .available)
        XCTAssertTrue(gapRow.value.lowercased().contains("agree"),
                      "matching gaps should agree, got: \(gapRow.value)")
        XCTAssertTrue(edgeRow.value.lowercased().contains("agree"),
                      "aligned band/DOS edges should agree, got: \(edgeRow.value)")

        // Deterministic: summary and CSV are non-empty and stable across calls.
        XCTAssertFalse(report.summaryText.isEmpty)
        XCTAssertFalse(report.csv.isEmpty)
        let again = ElectronicAnalysisPresentation.linkedReport(band: band, dos: agreeDOS)
        XCTAssertEqual(report.csv, again.csv)
        XCTAssertEqual(report.summaryText, again.summaryText)

        // (b) Widen the DOS plateau to ~2.5 eV => both cross-checks now disagree.
        let disagreeDOS = makeGapDOS(width: 2.5)
        let disagree = ElectronicAnalysisPresentation.linkedReport(band: band, dos: disagreeDOS)
        let dGap = disagree.rows[12]
        let dEdge = disagree.rows[13]
        XCTAssertTrue(dGap.value.lowercased().contains("disagree"),
                      "mismatched gaps should disagree, got: \(dGap.value)")
        XCTAssertTrue(dEdge.value.lowercased().contains("disagree"),
                      "mismatched band/DOS edges should disagree, got: \(dEdge.value)")

        // (c) Metallic band + gapped DOS: a metallic system has no gap, so agreement
        // with a gapped DOS must NOT report "agree" (documented deterministic outcome).
        let metallic = makeMetallicBandPath()
        let metalReport = ElectronicAnalysisPresentation.linkedReport(band: metallic, dos: agreeDOS)
        let mGap = metalReport.rows[12]
        XCTAssertTrue(mGap.value.lowercased().contains("disagree") || mGap.status != .available,
                      "metallic band vs gapped DOS must not agree, got: \(mGap.value) [\(mGap.status)]")

        // (d) Unavailable cross-check: a band with no Fermi level. The cross-check
        // rows must be tagged insufficient/unavailable, never .available.
        var noFermi = band
        noFermi.fermiEnergy = nil
        let noFermiReport = ElectronicAnalysisPresentation.linkedReport(band: noFermi, dos: agreeDOS)
        for idx in [12, 13] {
            XCTAssertNotEqual(noFermiReport.rows[idx].status, .available,
                              "cross-check row \(idx) must not be available without a Fermi level")
        }

        // --- QE projwfc DOS label enrichment ---
        let text = """
         #  E (eV)        l     DOS(E)     PDOS(E)     PDOS(E)
          -10.0       0    0.5        0.1        0.1
          -9.0        0    0.6        0.2        0.2
          -8.0        0    0.7        0.3        0.3
        """

        // QE projwfc per-atom/per-orbital file => PDOS-kind series gain "Si s".
        let enriched = DOSParser.parse(text, sourceName: "si.pdos_atm#1(Si)_wfc#1(s)")
        XCTAssertNotNil(enriched)
        let eLabels = enriched!.series.map { $0.label }
        XCTAssertTrue(eLabels.contains { $0.contains("Si s") },
                      "PDOS series should be enriched to 'Si s', got: \(eLabels)")
        XCTAssertFalse(eLabels.contains { $0 == "PDOS" },
                       "no label should remain a bare 'PDOS', got: \(eLabels)")

        // pdos_tot => the total series is relabeled "Total DOS" (uniquified if duplicated).
        let total = DOSParser.parse(text, sourceName: "si.pdos_tot")
        XCTAssertNotNil(total)
        let tLabels = total!.series.map { $0.label }
        XCTAssertTrue(tLabels.contains { $0.contains("Total DOS") },
                      "pdos_tot should yield a Total DOS label, got: \(tLabels)")
        XCTAssertFalse(tLabels.contains { $0 == "PDOS" },
                       "pdos_tot should not leave a bare 'PDOS', got: \(tLabels)")

        // nil source name => old inferred labels unchanged (PDOS present).
        let plain = DOSParser.parse(text)
        XCTAssertNotNil(plain)
        XCTAssertTrue(plain!.series.map { $0.label }.contains { $0.contains("PDOS") },
                      "nil source name must not enrich labels, got: \(plain!.series.map { $0.label })")

        // Malformed source names fall back gracefully to the old labels without trapping.
        for bad in ["not-a-name.txt", "", "pdos_atm#(p)"] {
            let parsed = DOSParser.parse(text, sourceName: bad)
            XCTAssertNotNil(parsed, "malformed source name '\(bad)' must parse without trapping")
            XCTAssertTrue(parsed!.series.map { $0.label }.contains { $0.contains("PDOS") },
                          "malformed source name must leave labels unchanged, got: \(parsed!.series.map { $0.label })")
        }
    }

    // MARK: - Orbital coloring classification and linked-cursor guide-line energy

    func testOrbitalColoringAndLinkedCursorGuideLine() {
        // --- Orbital coloring classification ---
        XCTAssertEqual(DOSOrbitalColoring.orbitalCharacter(of: "Fe s"), Character("s"))
        XCTAssertEqual(DOSOrbitalColoring.orbitalCharacter(of: "Si p up"), Character("p"))
        XCTAssertEqual(DOSOrbitalColoring.orbitalCharacter(of: "O d"), Character("d"))
        XCTAssertEqual(DOSOrbitalColoring.orbitalCharacter(of: "Ce f"), Character("f"))
        // Multi-letter or non-orbital tokens => nil.
        XCTAssertNil(DOSOrbitalColoring.orbitalCharacter(of: "Total DOS"))
        XCTAssertNil(DOSOrbitalColoring.orbitalCharacter(of: "PDOS up"))
        XCTAssertNil(DOSOrbitalColoring.orbitalCharacter(of: ""))
        XCTAssertNil(DOSOrbitalColoring.orbitalCharacter(of: "sp"))

        let palette: [NSColor] = [.black, .white]
        // Classified label => fixed orbital color, independent of palette/index.
        XCTAssertEqual(DOSOrbitalColoring.color(for: "Fe s", index: 0, palette: palette),
                       DOSOrbitalColoring.orbitalPalette[0])
        XCTAssertEqual(DOSOrbitalColoring.color(for: "Fe p", index: 0, palette: palette),
                       DOSOrbitalColoring.orbitalPalette[1])
        XCTAssertNotEqual(DOSOrbitalColoring.color(for: "Fe s", index: 0, palette: palette),
                          DOSOrbitalColoring.color(for: "Fe p", index: 0, palette: palette))
        // Unclassified label => falls back to the caller's palette by index.
        XCTAssertEqual(DOSOrbitalColoring.color(for: "Total DOS", index: 0, palette: palette), .black)
        XCTAssertEqual(DOSOrbitalColoring.color(for: "Total DOS", index: 1, palette: palette), .white)

        // --- Linked-cursor guide-line energy ---
        let size = CGSize(width: 400, height: 300)
        let band = makeShortBandPath()
        let dos = makeSmallDOS()

        let bandView = BandGrapherView(frame: NSRect(origin: .zero, size: size))
        bandView.bandStructure = band
        let dosView = DOSGrapherView(frame: NSRect(origin: .zero, size: size))
        dosView.densityOfStates = dos

        // Round-trip + nil, and the existing cursor readout still behaves.
        bandView.linkedCursorEnergy = 1.5
        XCTAssertEqual(bandView.linkedCursorEnergy, 1.5)
        XCTAssertNotNil(bandView.energyAtViewPoint(NSPoint(x: 200, y: 150)))
        bandView.linkedCursorEnergy = nil
        XCTAssertNil(bandView.linkedCursorEnergy)

        dosView.linkedCursorEnergy = -0.75
        XCTAssertEqual(dosView.linkedCursorEnergy, -0.75)
        dosView.linkedCursorEnergy = nil
        XCTAssertNil(dosView.linkedCursorEnergy)

        // Drawing with the guide energy set must not trap (mirrors App.exportGraph's
        // headless bitmap-context render path).
        bandView.linkedCursorEnergy = 1.5
        dosView.linkedCursorEnergy = -0.75
        renderHeadless(bandView)
        renderHeadless(dosView)

        // --- Container: opaque export path must paint BOTH children. ---
        // The container splits 50/50 (band left, DOS right); each half must receive
        // real child pixels, not just the white background fill.
        let opaque = LinkedGraphsView(frame: NSRect(origin: .zero, size: size),
                                      bandView: BandGrapherView(frame: .zero),
                                      dosView: DOSGrapherView(frame: .zero),
                                      band: band, dos: dos, bandPresent: true, dosPresent: true)
        opaque.exportBackground = .white
        guard let opaqueRep = renderToBitmap(opaque) else { return XCTFail("opaque render failed") }
        let opaquePixels = countPixels(in: opaqueRep) { p in
            p[0] != 255 || p[1] != 255 || p[2] != 255 || p[3] != 255
        }
        XCTAssertGreaterThan(opaquePixels.left, 0, "band panel must be painted in opaque export")
        XCTAssertGreaterThan(opaquePixels.right, 0, "DOS panel must be painted in opaque export")

        // --- Container: transparent export path must ALSO paint both children. ---
        // Regression for the draw() bug: it returned early when exportBackground == nil,
        // so children were never drawn and the export was blank. With the fix, the
        // container paints its children even with no background fill.
        let transparent = LinkedGraphsView(frame: NSRect(origin: .zero, size: size),
                                           bandView: BandGrapherView(frame: .zero),
                                           dosView: DOSGrapherView(frame: .zero),
                                           band: band, dos: dos, bandPresent: true, dosPresent: true)
        transparent.exportBackground = nil
        transparent.isExportTransparent = true
        guard let transRep = renderToBitmap(transparent) else { return XCTFail("transparent render failed") }
        let transPixels = countPixels(in: transRep) { p in
            p[0] != 0 || p[1] != 0 || p[2] != 0 || p[3] != 0
        }
        XCTAssertGreaterThan(transPixels.left, 0, "band panel must be painted in transparent export")
        XCTAssertGreaterThan(transPixels.right, 0, "DOS panel must be painted in transparent export")
    }

    /// Render a view into a fresh bitmap (cleared to transparent black) and return it.
    private func renderToBitmap(_ view: NSView) -> NSBitmapImageRep? {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        // Known transparent-black baseline so "painted" pixels are unambiguous.
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: w, height: h))
        view.draw(view.bounds)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Count pixels satisfying `predicate` in the left (x < w/2) and right (x >= w/2) halves.
    private func countPixels(in rep: NSBitmapImageRep,
                             where predicate: (UnsafePointer<UInt8>) -> Bool) -> (left: Int, right: Int) {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow
        var left = 0
        var right = 0
        guard let base = rep.bitmapData else { return (0, 0) }
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<w {
                let p = row.advanced(by: x * 4)
                if predicate(p) {
                    if x < w / 2 { left += 1 } else { right += 1 }
                }
            }
        }
        return (left, right)
    }

    /// Render a view into a throwaway bitmap to prove the draw path does not trap.
    private func renderHeadless(_ view: NSView) {
        _ = renderToBitmap(view)
    }
}
