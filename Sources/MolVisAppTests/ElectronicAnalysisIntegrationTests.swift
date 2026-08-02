import simd
import XCTest

@testable import MolVisApp

/// Integration tests for the electronic-analysis presentation and sidebar wiring.
/// Drives `MainWindowController(scene:showWindow:false)` and inspects the
/// runtime-only report state the controller installs into `SideBarState`.
final class ElectronicAnalysisIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func kPoint(x: Float, energies: [Float], label: String = "") -> BandKPoint {
        BandKPoint(k: SIMD3(x, 0, 0), weight: 1, label: label, energies: energies)
    }

    private func makeBandStructure(
        kPoints: [BandKPoint],
        fermi: Float?,
        nSpin: Int = 1,
        isMesh: Bool = false
    ) -> BandStructure {
        return BandStructure(
            kPoints: kPoints,
            fermiEnergy: fermi,
            nSpin: nSpin,
            reciprocal: nil,
            kPointsAreCrystal: false,
            kPointsPerSpin: kPoints.count / nSpin,
            isMesh: isMesh
        )
    }

    private func makeDOS(
        energies: [Float],
        seriesValues: [[Float]],
        labels: [String]? = nil,
        fermi: Float? = nil
    ) -> DensityOfStates {
        let series = seriesValues.enumerated().map { index, values in
            let label = labels.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? "Series \(index + 1)"
            return DOSSeries(label: label, values: values)
        }
        return DensityOfStates(energies: energies, series: series, fermiEnergy: fermi)
    }

    // MARK: - Band report

    func testBandReportComputesGapAndEffectiveMasses() {
        // Direct gap: valence band peaks and conduction band minimum both at k=0.5.
        // Parabolic bands so the finite-difference effective mass is well-defined.
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 2.0]),
            kPoint(x: 0.5, energies: [-0.5, 1.0]),
            kPoint(x: 1.0, energies: [-1.0, 2.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: 0.0)

        let report = ElectronicAnalysisPresentation.bandReport(bs)

        // Exactly 7 deterministic rows.
        XCTAssertEqual(report.rows.count, 7)

        let gapRow = report.rows.first { $0.metric == "Gap" }
        XCTAssertNotNil(gapRow)
        XCTAssertEqual(gapRow?.status, .available)
        XCTAssertTrue(gapRow?.value.contains("1.500 eV") == true, "expected 1.500 eV gap, got \(gapRow?.value ?? "nil")")

        let typeRow = report.rows.first { $0.metric == "Gap type" }
        XCTAssertNotNil(typeRow)
        XCTAssertEqual(typeRow?.status, .available)
        XCTAssertEqual(typeRow?.value, "direct")

        let vbmRow = report.rows.first { $0.metric == "VBM" }
        XCTAssertNotNil(vbmRow)
        XCTAssertEqual(vbmRow?.status, .available)

        let cbmRow = report.rows.first { $0.metric == "CBM" }
        XCTAssertNotNil(cbmRow)
        XCTAssertEqual(cbmRow?.status, .available)

        let metallicityRow = report.rows.first { $0.metric == "Metallicity" }
        XCTAssertNotNil(metallicityRow)
        XCTAssertEqual(metallicityRow?.status, .available)
        XCTAssertEqual(metallicityRow?.value, "no")

        // Effective mass rows should be present and available.
        let electronMassRow = report.rows.first { $0.metric == "Electron effective mass" }
        XCTAssertNotNil(electronMassRow)
        XCTAssertEqual(electronMassRow?.status, .available)

        let holeMassRow = report.rows.first { $0.metric == "Hole effective mass" }
        XCTAssertNotNil(holeMassRow)
        XCTAssertEqual(holeMassRow?.status, .available)

        // Summary text should mention the gap and include all rows.
        XCTAssertTrue(report.summaryText.contains("Gap"))
        XCTAssertTrue(report.summaryText.contains("VBM"))
        XCTAssertTrue(report.summaryText.contains("CBM"))
        XCTAssertTrue(report.summaryText.contains("Gap type"))
        XCTAssertTrue(report.summaryText.contains("Metallicity"))
        XCTAssertTrue(report.summaryText.contains("Electron effective mass"))
        XCTAssertTrue(report.summaryText.contains("Hole effective mass"))

        // CSV should have a header and data rows.
        XCTAssertTrue(report.csv.hasPrefix("metric,value,status"))
        XCTAssertTrue(report.csv.contains("Gap"))
    }

    func testBandReportWithoutFermiLevelMarksRowsInsufficient() {
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: nil)

        let report = ElectronicAnalysisPresentation.bandReport(bs)

        // All 7 rows should be insufficientData.
        XCTAssertEqual(report.rows.count, 7)
        for row in report.rows {
            XCTAssertEqual(row.status, .insufficientData, "row \(row.metric) should be insufficientData")
            XCTAssertTrue(row.value.contains("No Fermi level"), "row \(row.metric) reason should mention Fermi, got \(row.value)")
        }

        // Summary should not be blank.
        XCTAssertFalse(report.summaryText.isEmpty)
    }

    func testBandReportMeshMarksRowsInsufficient() {
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: 0.0, isMesh: true)

        let report = ElectronicAnalysisPresentation.bandReport(bs)
        XCTAssertEqual(report.rows.count, 7)
        for row in report.rows {
            XCTAssertEqual(row.status, .insufficientData, "row \(row.metric) should be insufficientData")
            XCTAssertTrue(row.value.contains("Mesh data"), "row \(row.metric) reason should mention mesh, got \(row.value)")
        }
    }

    func testBandReportMetallicityMarksEffectiveMassesUnavailable() {
        // Metallic: a band crosses the Fermi level.
        // Band 0: -1.0, 0.5, -1.0 (crosses 0.0 between k=0 and k=1)
        // Band 1:  2.0, 2.5, 2.0 (always above)
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 2.0]),
            kPoint(x: 0.5, energies: [0.5, 2.5]),
            kPoint(x: 1.0, energies: [-1.0, 2.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: 0.0)

        let report = ElectronicAnalysisPresentation.bandReport(bs)

        let gapTypeRow = report.rows.first { $0.metric == "Gap type" }
        XCTAssertEqual(gapTypeRow?.value, "metallic")

        let metallicityRow = report.rows.first { $0.metric == "Metallicity" }
        XCTAssertEqual(metallicityRow?.value, "yes")

        // VBM and CBM should still be reported.
        let vbmRow = report.rows.first { $0.metric == "VBM" }
        XCTAssertEqual(vbmRow?.status, .available)
        let cbmRow = report.rows.first { $0.metric == "CBM" }
        XCTAssertEqual(cbmRow?.status, .available)

        // Effective masses should be unavailable.
        let electronMassRow = report.rows.first { $0.metric == "Electron effective mass" }
        XCTAssertEqual(electronMassRow?.status, .unavailable)
        XCTAssertTrue(electronMassRow?.value.contains("metallic") == true)

        let holeMassRow = report.rows.first { $0.metric == "Hole effective mass" }
        XCTAssertEqual(holeMassRow?.status, .unavailable)
    }

    // MARK: - DOS report

    func testDOSReportComputesCenterWidthAndGap() {
        // DOS with a clear gap around E=0: flat at 1.0, zero between -1 and 1.
        let energies: [Float] = [-3, -2, -1, -0.5, 0, 0.5, 1, 2, 3]
        let dosValues: [Float] = [1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
        let dos = makeDOS(energies: energies, seriesValues: [dosValues], fermi: 0.0)

        let report = ElectronicAnalysisPresentation.dosReport(dos)

        // Exactly 5 deterministic rows.
        XCTAssertEqual(report.rows.count, 5)

        let centerRow = report.rows.first { $0.metric == "DOS center" }
        XCTAssertNotNil(centerRow)
        XCTAssertEqual(centerRow?.status, .available)

        let widthRow = report.rows.first { $0.metric == "DOS width" }
        XCTAssertNotNil(widthRow)
        XCTAssertEqual(widthRow?.status, .available)

        let gapRow = report.rows.first { $0.metric == "Gap estimate" }
        XCTAssertNotNil(gapRow)
        XCTAssertEqual(gapRow?.status, .available)

        // Single series, no spin labels: spin moment unavailable.
        let spinRow = report.rows.first { $0.metric == "Spin moment" }
        XCTAssertNotNil(spinRow)
        XCTAssertEqual(spinRow?.status, .unavailable)
        XCTAssertTrue(spinRow?.value.contains("No recognizable spin pair") == true)

        // No expected electron count: consistency unavailable.
        let consistencyRow = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertNotNil(consistencyRow)
        XCTAssertEqual(consistencyRow?.status, .unavailable)
        XCTAssertTrue(consistencyRow?.value.contains("No expected electron count") == true)

        XCTAssertFalse(report.summaryText.isEmpty)
        XCTAssertTrue(report.csv.hasPrefix("metric,value,status"))
    }

    func testDOSReportSpinPolarizedIncludesSpinMoment() {
        let energies: [Float] = [-2, -1, 0, 1, 2]
        let upValues: [Float] = [1.0, 1.0, 0.0, 0.0, 0.0]
        let downValues: [Float] = [0.0, 0.0, 0.0, 1.0, 1.0]
        let dos = makeDOS(energies: energies, seriesValues: [upValues, downValues],
                           labels: ["DOS up", "DOS down"], fermi: 0.0)

        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let spinRow = report.rows.first { $0.metric == "Spin moment" }
        XCTAssertNotNil(spinRow)
        XCTAssertEqual(spinRow?.status, .available)
    }

    // MARK: - Controller wiring

    func testControllerComputesBandReportOnSync() {
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
            kPoint(x: 1.0, energies: [-1.0, 1.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: 0.0)

        var scene = Scene()
        scene.bandStructure = bs

        let wc = MainWindowController(scene: scene, showWindow: false)

        let report = wc.state.electronicAnalysisReport
        XCTAssertNotNil(report, "controller should install a band report when only bands are present")

        let gapRow = report?.rows.first { $0.metric == "Gap" }
        XCTAssertNotNil(gapRow)
        XCTAssertEqual(gapRow?.status, .available)
    }

    func testControllerPrefersDOSOverBandsWhenBothPresent() {
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
            kPoint(x: 1.0, energies: [-1.0, 1.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: 0.0)

        let energies: [Float] = [-3, -2, -1, 0, 1, 2, 3]
        let dosValues: [Float] = [1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0]
        let dos = makeDOS(energies: energies, seriesValues: [dosValues], fermi: 0.0)

        var scene = Scene()
        scene.bandStructure = bs
        scene.densityOfStates = dos

        let wc = MainWindowController(scene: scene, showWindow: false)

        let report = wc.state.electronicAnalysisReport
        XCTAssertNotNil(report)

        // DOS report rows: should contain "DOS center" (DOS metric), not "Gap" (band metric).
        let centerRow = report?.rows.first { $0.metric == "DOS center" }
        XCTAssertNotNil(centerRow, "should prefer DOS report when both DOS and bands are present")

        let gapRow = report?.rows.first { $0.metric == "Gap" }
        XCTAssertNil(gapRow, "should not contain band Gap row when DOS report is active")
    }

    func testControllerLeavesReportNilWhenNoData() {
        let scene = Scene()
        let wc = MainWindowController(scene: scene, showWindow: false)
        XCTAssertNil(wc.state.electronicAnalysisReport)
    }

    func testControllerExportCallbacksAreWired() {
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: 0.0)

        var scene = Scene()
        scene.bandStructure = bs

        let wc = MainWindowController(scene: scene, showWindow: false)

        XCTAssertNotNil(wc.state.onExportElectronicAnalysisText)
        XCTAssertNotNil(wc.state.onExportElectronicAnalysisCSV)
    }

    func testControllerRecomputesReportOnSceneReload() {
        let kpsA = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ]
        let bsA = makeBandStructure(kPoints: kpsA, fermi: 0.0)

        var sceneA = Scene()
        sceneA.bandStructure = bsA

        let wc = MainWindowController(scene: sceneA, showWindow: false)

        let reportA = wc.state.electronicAnalysisReport
        XCTAssertNotNil(reportA)
        let gapRowA = reportA?.rows.first { $0.metric == "Gap" }
        XCTAssertEqual(gapRowA?.status, .available)

        // Now load a DOS-only scene: the report should switch to DOS.
        let energies: [Float] = [-2, -1, 0, 1, 2]
        let dosValues: [Float] = [1.0, 1.0, 0.0, 1.0, 1.0]
        let dos = makeDOS(energies: energies, seriesValues: [dosValues], fermi: 0.0)

        var sceneB = Scene()
        sceneB.densityOfStates = dos

        wc.loadFile(sceneB)

        let reportB = wc.state.electronicAnalysisReport
        XCTAssertNotNil(reportB)
        XCTAssertNotNil(reportB?.rows.first { $0.metric == "DOS center" })
        XCTAssertNil(reportB?.rows.first { $0.metric == "Gap" })
    }

    // MARK: - CSV shape

    func testBandReportCSVHasCorrectShape() {
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: 0.0)

        let report = ElectronicAnalysisPresentation.bandReport(bs)
        let lines = report.csv.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "metric,value,status")
        XCTAssertGreaterThan(lines.count, 1)

        // Every data line has exactly three comma-separated fields.
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = line.components(separatedBy: ",")
            XCTAssertEqual(fields.count, 3, "CSV line should have 3 fields: \(line)")
        }
    }

    func testDOSReportCSVHasCorrectShape() {
        let energies: [Float] = [-2, -1, 0, 1, 2]
        let dosValues: [Float] = [1.0, 1.0, 0.0, 1.0, 1.0]
        let dos = makeDOS(energies: energies, seriesValues: [dosValues], fermi: 0.0)

        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let lines = report.csv.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "metric,value,status")
        XCTAssertGreaterThan(lines.count, 1)

        for line in lines.dropFirst() where !line.isEmpty {
            let fields = parseCSVLine(line)
            XCTAssertEqual(fields.count, 3, "CSV line should have 3 fields: \(line)")
        }
    }

    func testReportSummaryTextNeverBlank() {
        let kps = [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ]
        let bs = makeBandStructure(kPoints: kps, fermi: nil)

        let report = ElectronicAnalysisPresentation.bandReport(bs)

        // With no Fermi level, all rows are insufficient; summary must NOT be blank.
        XCTAssertFalse(report.summaryText.isEmpty)
        // Every row should appear in the summary.
        for row in report.rows {
            XCTAssertTrue(report.summaryText.contains(row.metric), "summary should contain \(row.metric)")
        }
    }
}

// MARK: - CSV parsing helper

/// Parse a single RFC4180 CSV line into fields, respecting quoted values.
private func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var i = line.startIndex
    while i < line.endIndex {
        let ch = line[i]
        if ch == "\"" {
            if inQuotes {
                // Check for escaped quote (doubled).
                let next = line.index(after: i)
                if next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                } else {
                    inQuotes = false
                    i = next
                }
            } else {
                inQuotes = true
                i = line.index(after: i)
            }
        } else if ch == "," && !inQuotes {
            fields.append(current)
            current = ""
            i = line.index(after: i)
        } else {
            current.append(ch)
            i = line.index(after: i)
        }
    }
    fields.append(current)
    return fields
}
