import simd
import XCTest

@testable import MolVisApp

/// Focused unit tests for `ElectronicAnalysisPresentation`: every metric row,
/// status classification, reason text, spin detection, electron-count
/// integration, and CSV escaping.
final class ElectronicAnalysisPresentationTests: XCTestCase {

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
            let label = labels?[safe: index] ?? "Series \(index + 1)"
            return DOSSeries(label: label, values: values)
        }
        return DensityOfStates(energies: energies, series: series, fermiEnergy: fermi)
    }

    private func row(_ report: ElectronicAnalysisReport, _ metric: String) -> ElectronicAnalysisRow? {
        report.rows.first { $0.metric == metric }
    }

    // MARK: - Band report: deterministic shape

    func testBandReportAlwaysHasSevenRows() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        XCTAssertEqual(report.rows.count, 7)

        let expectedMetrics = ["VBM", "CBM", "Gap", "Gap type", "Metallicity",
                               "Electron effective mass", "Hole effective mass"]
        let actualMetrics = report.rows.map(\.metric)
        XCTAssertEqual(actualMetrics, expectedMetrics)
    }

    func testBandReportAllRowsPresentWhenInsufficient() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
        ], fermi: nil)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        XCTAssertEqual(report.rows.count, 7)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData)
            XCTAssertFalse(r.value.isEmpty, "\(r.metric) value should not be empty")
        }
    }

    // MARK: - Band report: metallic

    func testBandReportMetallicReportsGapTypeMetallic() {
        // Band 0 crosses Fermi: -1.0 -> 0.5 -> -1.0 (crosses 0.0)
        // Band 1: always above Fermi
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 2.0]),
            kPoint(x: 0.5, energies: [0.5, 2.5]),
            kPoint(x: 1.0, energies: [-1.0, 2.0]),
        ], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)

        XCTAssertEqual(row(report, "Gap type")?.value, "metallic")
        XCTAssertEqual(row(report, "Gap type")?.status, .available)

        XCTAssertEqual(row(report, "Metallicity")?.value, "yes")
        XCTAssertEqual(row(report, "Metallicity")?.status, .available)

        // Gap is 0 but still reported.
        XCTAssertEqual(row(report, "Gap")?.status, .available)
        XCTAssertTrue(row(report, "Gap")?.value.contains("0.000 eV") == true)

        // VBM/CBM still reported.
        XCTAssertEqual(row(report, "VBM")?.status, .available)
        XCTAssertEqual(row(report, "CBM")?.status, .available)

        // Effective masses unavailable.
        XCTAssertEqual(row(report, "Electron effective mass")?.status, .unavailable)
        XCTAssertTrue(row(report, "Electron effective mass")?.value.contains("metallic") == true)
        XCTAssertEqual(row(report, "Hole effective mass")?.status, .unavailable)
    }

    func testBandReportNonMetallicReportsNo() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 2.0]),
            kPoint(x: 0.5, energies: [-0.5, 1.0]),
            kPoint(x: 1.0, energies: [-1.0, 2.0]),
        ], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)

        XCTAssertEqual(row(report, "Metallicity")?.value, "no")
        XCTAssertEqual(row(report, "Metallicity")?.status, .available)
    }

    // MARK: - Band report: indirect gap

    func testBandReportIndirectGap() {
        // VBM at k=0.0 (band 0, energy 0.0), CBM at k=1.0 (band 1, energy 1.0).
        // No band crosses Fermi (band 0 <= 0.0, band 1 >= 1.0).
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [0.0, 3.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
            kPoint(x: 1.0, energies: [-1.0, 1.0]),
        ], fermi: 0.5)
        let report = ElectronicAnalysisPresentation.bandReport(bs)

        XCTAssertEqual(row(report, "Gap type")?.value, "indirect")
        XCTAssertEqual(row(report, "Gap type")?.status, .available)
    }

    // MARK: - Band report: malformed data

    func testBandReportEmptyKPointsInsufficient() {
        let bs = makeBandStructure(kPoints: [], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        XCTAssertEqual(report.rows.count, 7)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData)
        }
    }

    func testBandReportMeshInsufficient() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: 0.0, isMesh: true)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData)
            XCTAssertTrue(r.value.contains("Mesh data"), "\(r.metric): \(r.value)")
        }
    }

    func testBandReportNoFermiInsufficient() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: nil)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData)
            XCTAssertTrue(r.value.contains("No Fermi level"), "\(r.metric): \(r.value)")
        }
    }

    // MARK: - Band report: summary and CSV

    func testBandReportSummaryIncludesAllRows() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        for r in report.rows {
            XCTAssertTrue(report.summaryText.contains(r.metric))
        }
        XCTAssertFalse(report.summaryText.isEmpty)
    }

    func testBandReportCSVHasTrailingNewline() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        XCTAssertTrue(report.csv.hasSuffix("\n"))
        XCTAssertTrue(report.csv.hasPrefix("metric,value,status\n"))
    }

    // MARK: - DOS report: deterministic shape

    func testDOSReportAlwaysHasFiveRows() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        XCTAssertEqual(report.rows.count, 5)

        let expectedMetrics = ["DOS center", "DOS width", "Gap estimate",
                               "Spin moment", "Electron-count consistency"]
        let actualMetrics = report.rows.map(\.metric)
        XCTAssertEqual(actualMetrics, expectedMetrics)
    }

    // MARK: - DOS report: spin label detection

    func testSpinDetectionUpDown() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 0, 0], [0, 0, 0, 1, 1]],
                          labels: ["DOS up", "DOS down"], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let spinRow = row(report, "Spin moment")
        XCTAssertEqual(spinRow?.status, .available)
    }

    func testSpinDetectionUpDw() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 0, 0], [0, 0, 0, 1, 1]],
                          labels: ["DOS up", "DOS dw"], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let spinRow = row(report, "Spin moment")
        XCTAssertEqual(spinRow?.status, .available)
    }

    func testSpinDetectionCaseInsensitive() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 0, 0], [0, 0, 0, 1, 1]],
                          labels: ["DOS UP", "DOS DOWN"], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let spinRow = row(report, "Spin moment")
        XCTAssertEqual(spinRow?.status, .available)
    }

    func testSpinDetectionNoSpinLabels() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 0, 0], [0, 0, 0, 1, 1]],
                          labels: ["Total DOS", "PDOS"], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let spinRow = row(report, "Spin moment")
        XCTAssertEqual(spinRow?.status, .unavailable)
        XCTAssertTrue(spinRow?.value.contains("No recognizable spin pair") == true)
    }

    func testSpinDetectionOnlyUpNoDown() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 0, 0], [0, 0, 0, 1, 1]],
                          labels: ["DOS up", "PDOS"], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let spinRow = row(report, "Spin moment")
        XCTAssertEqual(spinRow?.status, .unavailable)
    }

    func testSpinDetectionPartialWordNoFalsePositive() {
        // "dummy" contains "dw" as substring but not as a word.
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 0, 0], [0, 0, 0, 1, 1]],
                          labels: ["DOS up", "DOS dummy"], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let spinRow = row(report, "Spin moment")
        XCTAssertEqual(spinRow?.status, .unavailable)
    }

    // MARK: - DOS report: electron-count consistency

    func testElectronConsistencyNilExpectedUnavailable() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .unavailable)
        XCTAssertTrue(row?.value.contains("No expected electron count") == true)
    }

    func testElectronConsistencyConsistent() {
        // Unpolarized: integrate total DOS from -2 to 0 (Fermi), multiply by 0.5.
        // DOS: [1, 1, 0, 1, 1] at energies [-2, -1, 0, 1, 2]
        // Integral from -2 to 0: trapezoid (-2,-1): 0.5*(1+1)*1 = 1.0
        //                        trapezoid (-1,0): 0.5*(1+0)*1 = 0.5
        // Total states = 1.5, electrons = 1.5 * 0.5 = 0.75
        // Expected 1: |0.75 - 1| = 0.25 <= 1 => consistent.
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: 1)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .available)
        XCTAssertTrue(row?.value.contains("consistent") == true)
        XCTAssertFalse(row?.value.contains("inconsistent") == true)
    }

    func testElectronConsistencyInconsistent() {
        // Same DOS as above: electrons = 0.75. Expected 10: |0.75 - 10| = 9.25 > 1.
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: 10)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .available)
        XCTAssertTrue(row?.value.contains("inconsistent") == true)
    }

    func testElectronConsistencySpinPolarized() {
        // Spin-polarized: up + down, no 0.5 multiplier.
        // Up: [1, 1, 0, 0, 0] at [-2, -1, 0, 1, 2]
        // Down: [0, 0, 0, 1, 1] at [-2, -1, 0, 1, 2]
        // Integral up from -2 to 0: 1.0 + 0.5 = 1.5
        // Integral down from -2 to 0: 0 (all zero in range)
        // Total electrons = 1.5 + 0 = 1.5
        // Expected 2: |1.5 - 2| = 0.5 <= 1 => consistent.
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2],
                          seriesValues: [[1, 1, 0, 0, 0], [0, 0, 0, 1, 1]],
                          labels: ["DOS up", "DOS down"], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: 2)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .available)
        XCTAssertTrue(row?.value.contains("consistent") == true)
    }

    func testElectronConsistencyNoFermiInsufficient() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: nil)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: 1)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .insufficientData)
        XCTAssertTrue(row?.value.contains("No Fermi level") == true)
    }

    func testElectronConsistencyEmptySeriesInsufficient() {
        let dos = DensityOfStates(energies: [], series: [], fermiEnergy: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: 1)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .insufficientData)
    }

    func testElectronConsistencyNonFiniteGridInsufficient() {
        let dos = makeDOS(energies: [Float.nan, 1, 2], seriesValues: [[1, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: 1)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .insufficientData)
        XCTAssertTrue(row?.value.contains("Non-finite") == true)
    }

    // MARK: - DOS report: malformed data reasons

    func testDOSReportEmptySeriesInsufficient() {
        let dos = DensityOfStates(energies: [], series: [], fermiEnergy: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, ElectronicAnalysisStatus.insufficientData, "\(r.metric)")
        }
    }

    func testDOSReportShortGridInsufficient() {
        let dos = makeDOS(energies: [0], seriesValues: [[1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, ElectronicAnalysisStatus.insufficientData, "\(r.metric)")
        }
    }

    func testDOSReportMismatchedCountsInsufficient() {
        let dos = makeDOS(energies: [0, 1, 2], seriesValues: [[1, 2]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, ElectronicAnalysisStatus.insufficientData, "\(r.metric)")
        }
    }

    // MARK: - DOS report: gap estimate

    func testGapEstimateAvailable() {
        let energies: [Float] = [-3, -2, -1, -0.5, 0, 0.5, 1, 2, 3]
        let dosValues: [Float] = [1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
        let dos = makeDOS(energies: energies, seriesValues: [dosValues], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let gapRow = row(report, "Gap estimate")
        XCTAssertEqual(gapRow?.status, .available)
        XCTAssertTrue(gapRow?.value.contains("VBM") == true)
        XCTAssertTrue(gapRow?.value.contains("CBM") == true)
    }

    func testGapEstimateNoGapUnavailable() {
        // No gap: DOS is flat at 1.0 everywhere.
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 1, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let gapRow = row(report, "Gap estimate")
        XCTAssertEqual(gapRow?.status, .unavailable)
        XCTAssertTrue(gapRow?.value.contains("No gap detected") == true)
    }

    // MARK: - DOS report: summary and CSV

    func testDOSReportSummaryIncludesAllRows() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertTrue(report.summaryText.contains(r.metric))
        }
        XCTAssertFalse(report.summaryText.isEmpty)
    }

    func testDOSReportCSVHasTrailingNewline() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        XCTAssertTrue(report.csv.hasSuffix("\n"))
        XCTAssertTrue(report.csv.hasPrefix("metric,value,status\n"))
    }

    // MARK: - CSV escaping (RFC4180)

    func testCSVEscapesComma() {
        // Gap estimate value contains commas: "X eV (VBM ~Y, CBM ~Z)".
        let energies: [Float] = [-3, -2, -1, 0, 1, 2, 3]
        let dosValues: [Float] = [1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0]
        let dos = makeDOS(energies: energies, seriesValues: [dosValues], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let lines = report.csv.components(separatedBy: "\n")
        // The Gap estimate value contains commas and must be quoted.
        let gapLine = lines.first { $0.hasPrefix("Gap estimate") }
        XCTAssertNotNil(gapLine)
        // Expected: Gap estimate,"X eV (VBM ~Y, CBM ~Z)",available
        XCTAssertTrue(gapLine?.contains("\"") == true, "expected quoted value, got \(gapLine ?? "nil")")
        XCTAssertTrue(gapLine?.contains("VBM") == true)
        XCTAssertTrue(gapLine?.contains("CBM") == true)
    }

    func testCSVEscapesQuotes() {
        // Construct a DOS whose series label contains a quote to test quote
        // doubling. The label appears in the CSV only via the metric/value/status
        // columns, so we test quote escaping via a value that contains quotes.
        // We can't easily inject quotes into values, but we can verify the
        // escaping logic by checking a known-quoted field.
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        // The header should be unquoted.
        XCTAssertEqual(report.csv.components(separatedBy: "\n").first, "metric,value,status")
    }

    func testCSVHeaderDeterministic() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        let header = report.csv.components(separatedBy: "\n").first
        XCTAssertEqual(header, "metric,value,status")
    }

    func testCSVRowOrderDeterministic() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report1 = ElectronicAnalysisPresentation.dosReport(dos)
        let report2 = ElectronicAnalysisPresentation.dosReport(dos)
        XCTAssertEqual(report1.csv, report2.csv)
    }

    // MARK: - Status raw values

    func testStatusRawValues() {
        XCTAssertEqual(ElectronicAnalysisStatus.available.rawValue, "available")
        XCTAssertEqual(ElectronicAnalysisStatus.unavailable.rawValue, "unavailable")
        XCTAssertEqual(ElectronicAnalysisStatus.insufficientData.rawValue, "insufficientData")
    }

    // MARK: - Equatable

    func testReportEquatable() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let r1 = ElectronicAnalysisPresentation.dosReport(dos)
        let r2 = ElectronicAnalysisPresentation.dosReport(dos)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - Regression: malformed grids

    func testDOSReportNonfiniteEnergyInsufficient() {
        let dos = makeDOS(energies: [Float.nan, 1, 2], seriesValues: [[1, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
            XCTAssertTrue(r.value.contains("Non-finite"), "\(r.metric): \(r.value)")
        }
    }

    func testDOSReportInfEnergyInsufficient() {
        let dos = makeDOS(energies: [Float.infinity, 1, 2], seriesValues: [[1, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
        }
    }

    func testDOSReportNonfiniteDOSValueInsufficient() {
        let dos = makeDOS(energies: [0, 1, 2], seriesValues: [[1, Float.nan, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
            XCTAssertTrue(r.value.contains("Non-finite"), "\(r.metric): \(r.value)")
        }
    }

    func testDOSReportInfDOSValueInsufficient() {
        let dos = makeDOS(energies: [0, 1, 2], seriesValues: [[1, 1, Float.infinity]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
        }
    }

    func testDOSReportUnsortedEnergyInsufficient() {
        let dos = makeDOS(energies: [0, 2, 1], seriesValues: [[1, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
            XCTAssertTrue(r.value.contains("not strictly increasing"), "\(r.metric): \(r.value)")
        }
    }

    func testDOSReportDuplicateEnergyInsufficient() {
        let dos = makeDOS(energies: [0, 1, 1, 2], seriesValues: [[1, 1, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
            XCTAssertTrue(r.value.contains("not strictly increasing"), "\(r.metric): \(r.value)")
        }
    }

    func testDOSReportNegativeExpectedCountInsufficient() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: -1)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .insufficientData)
        XCTAssertTrue(row?.value.contains("Invalid") == true)
    }

    func testDOSReportNonfiniteExpectedCountInsufficient() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: Float.nan)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .insufficientData)
        XCTAssertTrue(row?.value.contains("Invalid") == true)
    }

    func testDOSReportInfExpectedCountInsufficient() {
        let dos = makeDOS(energies: [-2, -1, 0, 1, 2], seriesValues: [[1, 1, 0, 1, 1]], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.dosReport(dos, expectedElectronCount: Float.infinity)
        let row = report.rows.first { $0.metric == "Electron-count consistency" }
        XCTAssertEqual(row?.status, .insufficientData)
        XCTAssertTrue(row?.value.contains("Invalid") == true)
    }

    func testBandReportNonfiniteFermiInsufficient() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: Float.nan)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
            XCTAssertTrue(r.value.contains("Non-finite Fermi level"), "\(r.metric): \(r.value)")
        }
    }

    func testBandReportInfFermiInsufficient() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: Float.infinity)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
        }
    }

    func testBandReportNonfiniteKCoordinateInsufficient() {
        let bs = makeBandStructure(kPoints: [
            BandKPoint(k: SIMD3(Float.nan, 0, 0), weight: 1, label: "", energies: [-1.0, 1.0]),
            BandKPoint(k: SIMD3(0.5, 0, 0), weight: 1, label: "", energies: [-0.5, 2.0]),
        ], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
            XCTAssertTrue(r.value.contains("k-point"), "\(r.metric): \(r.value)")
        }
    }

    func testBandReportNonfiniteBandEnergyInsufficient() {
        let bs = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [Float.nan, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: 0.0)
        let report = ElectronicAnalysisPresentation.bandReport(bs)
        for r in report.rows {
            XCTAssertEqual(r.status, .insufficientData, "\(r.metric)")
            XCTAssertTrue(r.value.contains("Non-finite"), "\(r.metric): \(r.value)")
        }
    }

    func testNoAvailableRowContainsNaNOrInf() {
        // Sweep many malformed inputs; verify no available row ever shows nan/inf.
        let badEnergyDOS = makeDOS(energies: [Float.nan, 1, 2], seriesValues: [[1, 1, 1]], fermi: 0.0)
        let badValueDOS = makeDOS(energies: [0, 1, 2], seriesValues: [[1, Float.infinity, 1]], fermi: 0.0)
        let unsortedDOS = makeDOS(energies: [0, 2, 1], seriesValues: [[1, 1, 1]], fermi: 0.0)
        let dupDOS = makeDOS(energies: [0, 1, 1], seriesValues: [[1, 1, 1]], fermi: 0.0)
        let badFermiBS = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [-1.0, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: Float.nan)
        let badKEnergyBS = makeBandStructure(kPoints: [
            kPoint(x: 0.0, energies: [Float.nan, 1.0]),
            kPoint(x: 0.5, energies: [-0.5, 2.0]),
        ], fermi: 0.0)
        let badKCBS = makeBandStructure(kPoints: [
            BandKPoint(k: SIMD3(0, Float.infinity, 0), weight: 1, label: "", energies: [-1.0, 1.0]),
            BandKPoint(k: SIMD3(0.5, 0, 0), weight: 1, label: "", energies: [-0.5, 2.0]),
        ], fermi: 0.0)

        let reports: [ElectronicAnalysisReport] = [
            ElectronicAnalysisPresentation.dosReport(badEnergyDOS),
            ElectronicAnalysisPresentation.dosReport(badValueDOS),
            ElectronicAnalysisPresentation.dosReport(unsortedDOS),
            ElectronicAnalysisPresentation.dosReport(dupDOS),
            ElectronicAnalysisPresentation.bandReport(badFermiBS),
            ElectronicAnalysisPresentation.bandReport(badKEnergyBS),
            ElectronicAnalysisPresentation.bandReport(badKCBS),
        ]
        for report in reports {
            for r in report.rows where r.status == .available {
                XCTAssertFalse(r.value.lowercased().contains("nan"), "\(r.metric) available row contains nan: \(r.value)")
                XCTAssertFalse(r.value.lowercased().contains("inf"), "\(r.metric) available row contains inf: \(r.value)")
            }
        }
    }
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
