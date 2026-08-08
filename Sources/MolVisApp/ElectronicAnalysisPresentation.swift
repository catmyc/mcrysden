import Foundation

/// Status tag for an electronic-analysis row.
enum ElectronicAnalysisStatus: String {
    case available
    case unavailable
    case insufficientData
}

/// One row of an electronic-analysis report: a metric name, its formatted
/// value, and a status tag. Unavailable/insufficient rows are still included
/// so the user sees which metrics the data cannot provide.
struct ElectronicAnalysisRow: Equatable {
    let metric: String
    let value: String
    let status: ElectronicAnalysisStatus
}

/// A computed electronic-analysis report: tabular rows, a concise multiline
/// summary, and a CSV payload. Produced by `ElectronicAnalysisPresentation`.
struct ElectronicAnalysisReport: Equatable {
    let rows: [ElectronicAnalysisRow]

    /// Multiline summary that includes ALL rows (never blank). Available rows
    /// show their value; unavailable/insufficient rows show the reason.
    var summaryText: String {
        rows.map { "\($0.metric): \($0.value) [\($0.status.rawValue)]" }.joined(separator: "\n")
    }

    /// RFC4180-escaped CSV with a deterministic header and row order.
    var csv: String {
        var lines = ["metric,value,status"]
        for row in rows {
            lines.append("\(csvEscape(row.metric)),\(csvEscape(row.value)),\(csvEscape(row.status.rawValue))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\r") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}

/// Pure presentation layer over `BandAnalysis` / `DOSAnalysis`. Turns a parsed
/// `BandStructure` or `DensityOfStates` into a display-ready report with both
/// available and unavailable rows clearly tagged.
enum ElectronicAnalysisPresentation {

    // MARK: - Band report

    /// Produces a deterministic 7-row band-structure report:
    /// VBM, CBM, Gap, Gap type, Metallicity,
    /// Electron effective mass, Hole effective mass.
    static func bandReport(_ bs: BandStructure) -> ElectronicAnalysisReport {
        let quality = assessBandQuality(bs)

        var rows: [ElectronicAnalysisRow] = []
        rows.append(vbmRow(bs, quality: quality))
        rows.append(cbmRow(bs, quality: quality))
        rows.append(gapRow(bs, quality: quality))
        rows.append(gapTypeRow(bs, quality: quality))
        rows.append(metallicityRow(bs, quality: quality))
        rows.append(electronMassRow(bs, quality: quality))
        rows.append(holeMassRow(bs, quality: quality))

        return ElectronicAnalysisReport(rows: rows)
    }

    // MARK: - DOS report

    /// Produces a deterministic 5-row DOS report:
    /// DOS center, DOS width, Gap estimate, Spin moment,
    /// Electron-count consistency.
    static func dosReport(_ dos: DensityOfStates, expectedElectronCount: Float? = nil) -> ElectronicAnalysisReport {
        var rows: [ElectronicAnalysisRow] = []
        rows.append(dosCenterRow(dos))
        rows.append(dosWidthRow(dos))
        rows.append(gapEstimateRow(dos))
        rows.append(spinMomentRow(dos))
        rows.append(electronConsistencyRow(dos, expectedElectronCount: expectedElectronCount))

        return ElectronicAnalysisReport(rows: rows)
    }

    // MARK: - Linked band + DOS report

    /// Combined band + DOS report: the 7 band rows, then the 5 DOS rows, then two
    /// cross-check rows ("Gap agreement", "Band-edge agreement"). Deterministic.
    static func linkedReport(band: BandStructure, dos: DensityOfStates) -> ElectronicAnalysisReport {
        var rows: [ElectronicAnalysisRow] = []
        rows.append(contentsOf: bandReport(band).rows)
        rows.append(contentsOf: dosReport(dos).rows)
        rows.append(gapAgreementRow(band: band, dos: dos))
        rows.append(bandEdgeAgreementRow(band: band, dos: dos))
        return ElectronicAnalysisReport(rows: rows)
    }

    private static func gapAgreementRow(band: BandStructure, dos: DensityOfStates) -> ElectronicAnalysisRow {
        if band.isMesh {
            return ElectronicAnalysisRow(metric: "Gap agreement (bands vs DOS)", value: "Mesh data (not a band path)", status: .insufficientData)
        }
        guard let bandGap = BandAnalysis.bandGap(band) else {
            let reason = band.fermiEnergy == nil ? "No Fermi level" : "No band gap determined"
            return ElectronicAnalysisRow(metric: "Gap agreement (bands vs DOS)", value: reason, status: band.fermiEnergy == nil ? .insufficientData : .unavailable)
        }
        guard let dosGap = DOSAnalysis.dosGap(dos) else {
            return ElectronicAnalysisRow(metric: "Gap agreement (bands vs DOS)", value: "No DOS gap detected", status: .unavailable)
        }
        let delta = abs(bandGap.gap - dosGap.gapWidth)
        if delta <= 0.5 {
            return ElectronicAnalysisRow(metric: "Gap agreement (bands vs DOS)", value: String(format: "agree (Δ %.3f eV)", delta), status: .available)
        }
        return ElectronicAnalysisRow(metric: "Gap agreement (bands vs DOS)", value: String(format: "disagree (Δ %.3f eV)", delta), status: .available)
    }

    private static func bandEdgeAgreementRow(band: BandStructure, dos: DensityOfStates) -> ElectronicAnalysisRow {
        guard let bandGap = BandAnalysis.bandGap(band), bandGap.vbm.isFinite else {
            return ElectronicAnalysisRow(metric: "Band-edge agreement (bands vs DOS)", value: "No band gap determined", status: .unavailable)
        }
        guard let dosGap = DOSAnalysis.dosGap(dos), dosGap.vbmEstimate.isFinite else {
            return ElectronicAnalysisRow(metric: "Band-edge agreement (bands vs DOS)", value: "No DOS gap detected", status: .unavailable)
        }
        let delta = abs(bandGap.vbm - dosGap.vbmEstimate)
        if delta <= 0.5 {
            return ElectronicAnalysisRow(metric: "Band-edge agreement (bands vs DOS)", value: String(format: "agree (Δ %.3f eV)", delta), status: .available)
        }
        return ElectronicAnalysisRow(metric: "Band-edge agreement (bands vs DOS)", value: String(format: "disagree (Δ %.3f eV)", delta), status: .available)
    }

    // MARK: - Band row factories

    private static func assessBandQuality(_ bs: BandStructure) -> (insufficient: Bool, reason: String) {
        if bs.isMesh {
            return (true, "Mesh data (not a band path)")
        }
        guard let ef = bs.fermiEnergy else {
            return (true, "No Fermi level")
        }
        guard ef.isFinite else {
            return (true, "Non-finite Fermi level")
        }
        guard bs.nBands > 0, bs.nKPoints > 0, bs.hasValidChannelLayout else {
            return (true, "Malformed band structure")
        }
        for kp in bs.kPoints {
            guard kp.k.x.isFinite, kp.k.y.isFinite, kp.k.z.isFinite else {
                return (true, "Non-finite k-point coordinates")
            }
            for e in kp.energies {
                guard e.isFinite else {
                    return (true, "Non-finite band energies")
                }
            }
        }
        return (false, "")
    }

    private static func vbmRow(_ bs: BandStructure, quality: (insufficient: Bool, reason: String)) -> ElectronicAnalysisRow {
        if quality.insufficient {
            return ElectronicAnalysisRow(metric: "VBM", value: quality.reason, status: .insufficientData)
        }
        guard let gap = BandAnalysis.bandGap(bs), gap.vbm.isFinite else {
            return ElectronicAnalysisRow(metric: "VBM", value: "No band gap determined", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "VBM", value: String(format: "%.3f eV", gap.vbm), status: .available)
    }

    private static func cbmRow(_ bs: BandStructure, quality: (insufficient: Bool, reason: String)) -> ElectronicAnalysisRow {
        if quality.insufficient {
            return ElectronicAnalysisRow(metric: "CBM", value: quality.reason, status: .insufficientData)
        }
        guard let gap = BandAnalysis.bandGap(bs), gap.cbm.isFinite else {
            return ElectronicAnalysisRow(metric: "CBM", value: "No band gap determined", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "CBM", value: String(format: "%.3f eV", gap.cbm), status: .available)
    }

    private static func gapRow(_ bs: BandStructure, quality: (insufficient: Bool, reason: String)) -> ElectronicAnalysisRow {
        if quality.insufficient {
            return ElectronicAnalysisRow(metric: "Gap", value: quality.reason, status: .insufficientData)
        }
        guard let gap = BandAnalysis.bandGap(bs), gap.gap.isFinite else {
            return ElectronicAnalysisRow(metric: "Gap", value: "No band gap determined", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "Gap", value: String(format: "%.3f eV", gap.gap), status: .available)
    }

    private static func gapTypeRow(_ bs: BandStructure, quality: (insufficient: Bool, reason: String)) -> ElectronicAnalysisRow {
        if quality.insufficient {
            return ElectronicAnalysisRow(metric: "Gap type", value: quality.reason, status: .insufficientData)
        }
        guard let gap = BandAnalysis.bandGap(bs) else {
            return ElectronicAnalysisRow(metric: "Gap type", value: "No gap type determined", status: .unavailable)
        }
        let kind = gap.isMetallic ? "metallic" : (gap.isDirect ? "direct" : "indirect")
        return ElectronicAnalysisRow(metric: "Gap type", value: kind, status: .available)
    }

    private static func metallicityRow(_ bs: BandStructure, quality: (insufficient: Bool, reason: String)) -> ElectronicAnalysisRow {
        if quality.insufficient {
            return ElectronicAnalysisRow(metric: "Metallicity", value: quality.reason, status: .insufficientData)
        }
        guard let gap = BandAnalysis.bandGap(bs) else {
            return ElectronicAnalysisRow(metric: "Metallicity", value: "Cannot be determined", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "Metallicity", value: gap.isMetallic ? "yes" : "no", status: .available)
    }

    private static func electronMassRow(_ bs: BandStructure, quality: (insufficient: Bool, reason: String)) -> ElectronicAnalysisRow {
        if quality.insufficient {
            return ElectronicAnalysisRow(metric: "Electron effective mass", value: quality.reason, status: .insufficientData)
        }
        guard let gap = BandAnalysis.bandGap(bs) else {
            return ElectronicAnalysisRow(metric: "Electron effective mass", value: "No band gap determined", status: .unavailable)
        }
        if gap.isMetallic {
            return ElectronicAnalysisRow(metric: "Electron effective mass", value: "Not meaningful for metallic systems", status: .unavailable)
        }
        guard let masses = BandAnalysis.effectiveMassesNearGap(bs), masses.electronMass.isFinite else {
            return ElectronicAnalysisRow(metric: "Electron effective mass", value: "Could not be determined", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "Electron effective mass", value: String(format: "%.3f m0", masses.electronMass), status: .available)
    }

    private static func holeMassRow(_ bs: BandStructure, quality: (insufficient: Bool, reason: String)) -> ElectronicAnalysisRow {
        if quality.insufficient {
            return ElectronicAnalysisRow(metric: "Hole effective mass", value: quality.reason, status: .insufficientData)
        }
        guard let gap = BandAnalysis.bandGap(bs) else {
            return ElectronicAnalysisRow(metric: "Hole effective mass", value: "No band gap determined", status: .unavailable)
        }
        if gap.isMetallic {
            return ElectronicAnalysisRow(metric: "Hole effective mass", value: "Not meaningful for metallic systems", status: .unavailable)
        }
        guard let masses = BandAnalysis.effectiveMassesNearGap(bs), masses.holeMass.isFinite else {
            return ElectronicAnalysisRow(metric: "Hole effective mass", value: "Could not be determined", status: .unavailable)
        }
        // `holeMass` is the raw signed hbar^2/(d2E/dk2) at the VBM — negative there
        // because the VBM is a maximum (d2E/dk2 < 0). The physical hole mass is the
        // magnitude; negate for display and label the sign convention.
        let physicalHoleMass = -masses.holeMass
        return ElectronicAnalysisRow(metric: "Hole effective mass", value: String(format: "%.3f m0", physicalHoleMass), status: .available)
    }

    // MARK: - DOS row factories

    private static func dosCenterRow(_ dos: DensityOfStates) -> ElectronicAnalysisRow {
        let q = assessDOSQuality(dos)
        if q.insufficient {
            return ElectronicAnalysisRow(metric: "DOS center", value: q.reason, status: .insufficientData)
        }
        guard let center = DOSAnalysis.bandCenter(dos), center.isFinite else {
            return ElectronicAnalysisRow(metric: "DOS center", value: "Zero DOS weight", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "DOS center", value: String(format: "%.3f eV", center), status: .available)
    }

    private static func dosWidthRow(_ dos: DensityOfStates) -> ElectronicAnalysisRow {
        let q = assessDOSQuality(dos)
        if q.insufficient {
            return ElectronicAnalysisRow(metric: "DOS width", value: q.reason, status: .insufficientData)
        }
        guard let width = DOSAnalysis.bandWidth(dos), width.isFinite else {
            return ElectronicAnalysisRow(metric: "DOS width", value: "Zero DOS weight", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "DOS width", value: String(format: "%.3f eV", width), status: .available)
    }

    private static func gapEstimateRow(_ dos: DensityOfStates) -> ElectronicAnalysisRow {
        let q = assessDOSQuality(dos)
        if q.insufficient {
            return ElectronicAnalysisRow(metric: "Gap estimate", value: q.reason, status: .insufficientData)
        }
        guard let gap = DOSAnalysis.dosGap(dos), gap.gapWidth.isFinite, gap.vbmEstimate.isFinite, gap.cbmEstimate.isFinite else {
            return ElectronicAnalysisRow(metric: "Gap estimate", value: "No gap detected", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "Gap estimate", value: String(format: "%.3f eV (VBM ~%.3f, CBM ~%.3f)", gap.gapWidth, gap.vbmEstimate, gap.cbmEstimate), status: .available)
    }

    private static func spinMomentRow(_ dos: DensityOfStates) -> ElectronicAnalysisRow {
        let q = assessDOSQuality(dos)
        if q.insufficient {
            return ElectronicAnalysisRow(metric: "Spin moment", value: q.reason, status: .insufficientData)
        }
        guard let pair = detectSpinPair(dos) else {
            return ElectronicAnalysisRow(metric: "Spin moment", value: "No recognizable spin pair (up/down)", status: .unavailable)
        }
        guard let moment = DOSAnalysis.spinMoment(dos, upSeriesIndex: pair.up, downSeriesIndex: pair.down), moment.isFinite else {
            return ElectronicAnalysisRow(metric: "Spin moment", value: "Could not be determined", status: .unavailable)
        }
        return ElectronicAnalysisRow(metric: "Spin moment", value: String(format: "%.3f", moment), status: .available)
    }

    private static func electronConsistencyRow(_ dos: DensityOfStates, expectedElectronCount: Float?) -> ElectronicAnalysisRow {
        let q = assessDOSQuality(dos)
        if q.insufficient {
            return ElectronicAnalysisRow(metric: "Electron-count consistency", value: q.reason, status: .insufficientData)
        }
        guard let expected = expectedElectronCount else {
            return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "No expected electron count supplied", status: .unavailable)
        }
        guard expected.isFinite, expected >= 0 else {
            return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "Invalid expected electron count", status: .insufficientData)
        }
        guard let ef = dos.fermiEnergy, ef.isFinite else {
            return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "No Fermi level", status: .insufficientData)
        }

        guard let eMin = dos.energies.first else {
            return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "Empty energy grid", status: .insufficientData)
        }

        let electrons: Float
        if let pair = detectSpinPair(dos) {
            let upIntegral: Float
            if ef > eMin {
                guard let v = integrateDOS(dos, seriesIndex: pair.up, range: eMin...ef) else {
                    return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "Integration failed", status: .insufficientData)
                }
                upIntegral = v
            } else {
                upIntegral = 0
            }
            let downIntegral: Float
            if ef > eMin {
                guard let v = integrateDOS(dos, seriesIndex: pair.down, range: eMin...ef) else {
                    return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "Integration failed", status: .insufficientData)
                }
                downIntegral = v
            } else {
                downIntegral = 0
            }
            electrons = upIntegral + downIntegral
        } else {
            let totalStates: Float
            if ef > eMin {
                guard let v = integrateDOS(dos, seriesIndex: 0, range: eMin...ef) else {
                    return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "Integration failed", status: .insufficientData)
                }
                totalStates = v
            } else {
                totalStates = 0
            }
            electrons = totalStates * 0.5
        }

        guard electrons.isFinite else {
            return ElectronicAnalysisRow(metric: "Electron-count consistency", value: "Integration produced non-finite result", status: .insufficientData)
        }

        let consistent = abs(electrons - expected) <= 1
        let value = String(format: "%@ (expected %.2f e-, DOS %.2f e-)", consistent ? "consistent" : "inconsistent", expected, electrons)
        return ElectronicAnalysisRow(metric: "Electron-count consistency", value: value, status: .available)
    }

    // MARK: - DOS helpers

    private static func assessDOSQuality(_ dos: DensityOfStates) -> (insufficient: Bool, reason: String) {
        guard !dos.series.isEmpty else {
            return (true, "No DOS series")
        }
        guard dos.energies.count >= 2 else {
            return (true, "Insufficient energy grid")
        }
        for s in dos.series {
            if s.values.count != dos.energies.count {
                return (true, "Mismatched energy/value counts")
            }
        }
        for e in dos.energies {
            guard e.isFinite else {
                return (true, "Non-finite energy values")
            }
        }
        for i in 1..<dos.energies.count {
            guard dos.energies[i] > dos.energies[i - 1] else {
                return (true, "Energy grid not strictly increasing")
            }
        }
        for s in dos.series {
            for v in s.values {
                guard v.isFinite else {
                    return (true, "Non-finite DOS values")
                }
            }
        }
        return (false, "")
    }

    /// Trapezoidal integral of DOS value v over the clipped energy range,
    /// with linear interpolation at partial-interval boundaries.
    private static func integrateDOS(_ dos: DensityOfStates, seriesIndex: Int, range: ClosedRange<Float>) -> Float? {
        guard seriesIndex >= 0, seriesIndex < dos.series.count else { return nil }
        let values = dos.series[seriesIndex].values
        let energies = dos.energies
        guard values.count == energies.count, energies.count >= 2 else { return nil }

        let lo = range.lowerBound
        let hi = range.upperBound
        guard lo < hi else { return nil }

        var sum: Float = 0
        for i in 0..<(energies.count - 1) {
            let e0 = energies[i]
            let e1 = energies[i + 1]
            let v0 = values[i]
            let v1 = values[i + 1]
            let a = max(e0, lo)
            let b = min(e1, hi)
            guard a < b else { continue }
            let de = e1 - e0
            guard de > 0 else { continue }
            let fa = v0 + (v1 - v0) * (a - e0) / de
            let fb = v0 + (v1 - v0) * (b - e0) / de
            sum += 0.5 * (fa + fb) * (b - a)
        }
        return sum
    }

    /// Detect a spin-polarized pair by case-insensitive labels: one series
    /// containing "up" and another containing "down" or "dw". Returns nil if
    /// no recognizable pair is found.
    private static func detectSpinPair(_ dos: DensityOfStates) -> (up: Int, down: Int)? {
        var upIndex: Int?
        var downIndex: Int?

        for (i, series) in dos.series.enumerated() {
            let words = wordsInLabel(series.label)
            if words.contains("up") {
                upIndex = i
            }
            if words.contains("down") || words.contains("dw") {
                downIndex = i
            }
        }

        guard let up = upIndex, let down = downIndex else { return nil }
        return (up: up, down: down)
    }

    /// Split a DOS series label into lowercase words (letters only).
    private static func wordsInLabel(_ label: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in label.lowercased() {
            if ch.isLetter {
                current.append(ch)
            } else {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }
}
