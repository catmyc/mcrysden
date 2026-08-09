import Foundation
import simd

// CRYSTAL properties-file readers (band structure + density of states).
//
// CRYSTAL's post-processing ("properties") code writes band structures to
// Fortran unit 9 (historically `fort.9`, also `BAND*`) and DOS to unit 8
// (`fort.8`, `DOSS*`). XCrySDen reads both; these parsers give mcrysden the
// same native path. The outputs feed straight into the existing band/DOS
// graph views via the already-built `BandStructure` and `DensityOfStates`
// models — see `BandStructure.swift` / `DensityOfStates.swift`.
//
// ─────────────────────────────────────────────────────────────────────────
// Supported BAND layouts (defensively parsed; variants exist across versions)
// ─────────────────────────────────────────────────────────────────────────
// A k-point block is one k-coordinate line (3 reals) followed by that k's
// band energies, which may wrap across several continuation lines:
//
//       kx        ky        kz
//       e1 e2 e3 e4 e5 e6 e7 e8
//       e9 e10 ...
//       kx'       ky'       kz'
//       ...
//
// Header (any subset, order-independent; case-insensitive):
//   • "N. OF K POINTS = <nk>" / "NUMBER OF K POINTS" / "NKPT"   -> nk
//   • "N. OF BANDS = <nb>"   / "NUMBER OF BANDS"   / "NBANDS"   -> nbands
//   • a leading line of exactly TWO integer-valued floats       -> (nk, nb)
//     (the common compact header); consumed before parsing
//   • "E(FERMI)= <v>" / "E(F) = <v>" / "FERMI ENERGY = <v>"    -> fermiEnergy
//   • unit line naming HARTREE / ATOMIC UNITS                  -> energies are
//     in Hartree (multiplied by 27.211386 to eV). Otherwise eV.
//   • a SPIN / POLARIZED / "up"+"down" marker                  -> spin hint
//
// When nbands is NOT given by any header, it is DERIVED: a k-line is a line
// of exactly 3 floats; the floats between consecutive k-lines are the bands.
// This requires energy lines to differ in width from the 3-float k-lines (the
// common case: energies wrap 5-8 per line). If the pattern is ambiguous the
// file is rejected (nil).
//
// ─────────────────────────────────────────────────────────────────────────
// Supported DOS layouts
// ─────────────────────────────────────────────────────────────────────────
// A whitespace table whose first column is energy and the rest are DOS
// series (total, then possibly spin up/down or projections):
//
//       ENERGY    DOSS    DOSS    ...
//       -20.0     0.0     0.1
//       -19.9     0.0     0.2
//       ...
//
//   • energy column must be strictly increasing (a decrease ends the table;
//     an exact duplicate row is skipped). One column count (modal); all rows
//     must agree.
//   • column labels are taken from the header line whose word tokens best
//     match the data column count (e.g. "ENERGY DOSS TOTAL" -> drop the
//     energy token, label the series). Fallback: "dos-1", "dos-2", ...
//   • a trailing column labeled as integrated DOS ("integrated"/"intdos"/
//     "idos") is dropped, mirroring the QE reader.
//   • "E(FERMI)"/"FERMI ENERGY" and HARTREE/EV unit lines are read from the
//     header.
//
// ─────────────────────────────────────────────────────────────────────────
// Shared simplifications & invariants
// ─────────────────────────────────────────────────────────────────────────
// • k-coordinates are crystal (fractional) coordinates: `kPointsAreCrystal`
//   is true so the existing kDistances metric applies. Reciprocal vectors are
//   NOT present in CRYSTAL band files, so `reciprocal` is nil and the x-axis
//   falls back to Euclidean length in fractional units (documented, non-nil,
//   never traps).
// • Energy unit default is eV; only an explicit Hartree/atomic-units header
//   triggers conversion (band energies and fermi ×27.211386). For DOS the
//   energy column is scaled to eV and the DOS values scaled INVERSELY so the
//   integral ∫DOS dE is preserved across the unit change.
// • Spin: a band file is read as two channels only when the first half of
//   the k-points is coordinate-equal to the second half AND (a spin marker
//   is present OR the header nk equals half the k-count). Otherwise single
//   spin. When in doubt -> nSpin = 1.
// • Deterministic (pure function of the input) and non-trapping: the input
//   is capped at 2,000,000 characters, at most 100,000 data rows and
//   1,000,000 total energy values. Fortran "glued" floats with no space
//   between them (e.g. "90.000120.000") are best-effort recovered by a
//   regex float scanner (the same pattern as `Parser.scanFloats`) — this is
//   a heuristic for axis-title glue (kept for WIEN2k compatibility), so the
//   split is not guaranteed correct.
// • Both readers are gated on their first meaningful (non-empty, non-comment)
//   line: it must be either a pure-number data line or carry a recognized
//   CRYSTAL keyword, otherwise the file is rejected immediately without
//   scanning the rest. See `passesBandGate` and `passesDOSGate`.

private enum EnergyUnit { case ev, hartree }

private let hartreeToEV: Float = 27.211386

/// Matches a signed decimal with an optional exponent, including Fortran "D"
/// notation. Glued adjacent floats (no separating space) tokenize correctly
/// because each match is greedy from its start. Mirrors `Parser.scanFloats`.
private let floatPattern = #"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eEdD][+-]?\d+)?"#

/// All floats in `s` in order, with D/d exponents normalized to `e` for
/// `Float()` (which does not accept Fortran "D" notation). Non-finite matches
/// are dropped.
private func scanFloats(_ s: String) -> [Float] {
    var out: [Float] = []
    guard let rx = try? NSRegularExpression(pattern: floatPattern) else { return out }
    let ns = s as NSString
    for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let token = ns.substring(with: m.range)
            .replacingOccurrences(of: "D", with: "e")
            .replacingOccurrences(of: "d", with: "e")
        if let v = Float(token), v.isFinite { out.append(v) }
    }
    return out
}

/// True when `line` is composed ONLY of floats and whitespace (a data line).
/// Glued floats are consumed by the regex, leaving only whitespace, so a
/// glued line still reads as one data line (best-effort; see file header).
/// A line with any letter is a header/text line.
private func isDataLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    let stripped = trimmed.replacingOccurrences(of: floatPattern, with: " ", options: .regularExpression)
    return stripped.trimmingCharacters(in: .whitespaces).isEmpty
}

/// The first capture group of `pattern` in `line` as a Float (D-normalized),
/// or nil. Case-insensitive patterns set `(?i)`.
private func captureFloat(_ line: String, _ pattern: String) -> Float? {
    guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = line as NSString
    guard let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) else { return nil }
    let token = String(line[r])
        .replacingOccurrences(of: "D", with: "e")
        .replacingOccurrences(of: "d", with: "e")
    return Float(token).flatMap { $0.isFinite ? $0 : nil }
}

/// The first capture group of `pattern` in `line` as an Int, or nil.
private func captureInt(_ line: String, _ pattern: String) -> Int? {
    guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = line as NSString
    guard let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: line) else { return nil }
    return Int(String(line[r]))
}

// MARK: - CRYSTAL band structure

/// Parse CRYSTAL band-structure text into a `BandStructure`, or nil when the
/// text does not look like a CRYSTAL BAND file. Never traps.
enum CrystalBandParser {
    static func parse(_ text: String) -> BandStructure? {
        guard text.count <= 2_000_000 else { return nil }
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        guard passesBandGate(lines) else { return nil }

        let header = BandHeader.scan(lines)
        var numberLines = extractDataLines(lines)
        guard numberLines.count <= 100_000 else { return nil }

        // Prefer keyword counts; fall back to a leading "nk nbands" pair.
        var nk = header.nk
        var nbands = header.nbands
        if nbands <= 0, numberLines.count >= 1, numberLines[0].count == 2,
           numberLines[0].allSatisfy({ $0.isFinite && $0 == $0.rounded() }) {
            // Checked conversion: a value like 1e20 would trap Int() and is
            // not a valid k-point/band count anyway.
            let rawNk = numberLines[0][0].rounded()
            let rawNb = numberLines[0][1].rounded()
            guard let nk64 = Int64(exactly: rawNk), let nb64 = Int64(exactly: rawNb) else { return nil }
            nk = max(0, min(2_000_000, Int(nk64)))
            nbands = max(0, min(2_000_000, Int(nb64)))
            numberLines.removeFirst()
        }

        let kpoints: [BandKPoint]
        if nbands > 0 {
            kpoints = accumulateKPoints(numberLines, nbands: nbands)
        } else if let derived = deriveLayout(numberLines) {
            kpoints = accumulateKPoints(numberLines, nbands: derived.nbands)
            if nk <= 0 { nk = derived.nk }
        } else {
            return nil
        }
        guard !kpoints.isEmpty else { return nil }

        // Total energy-value cap across all k-points.
        let totalValues = kpoints.reduce(0) { $0 + $1.energies.count }
        guard totalValues <= 1_000_000 else { return nil }

        // Spin / channel layout.
        let (nSpin, perSpin) = channelLayout(kpoints, header: header, nk: nk)

        let scale: Float = header.units == .hartree ? hartreeToEV : 1.0
        let scaled = kpoints.map { kp in
            BandKPoint(k: kp.k, weight: kp.weight, label: kp.label,
                        energies: kp.energies.map { $0 * scale })
        }
        let fermi = header.fermi.map { $0 * scale }

        // Guard against Float overflow from the unit scaling (near-FLT_MAX
        // values in Hartree become inf); such a file is not representable.
        for kp in scaled {
            if !kp.energies.allSatisfy({ $0.isFinite }) { return nil }
        }
        if let f = fermi, !f.isFinite { return nil }

        return BandStructure(kPoints: scaled, fermiEnergy: fermi, nSpin: nSpin,
                              reciprocal: nil, kPointsAreCrystal: true,
                              kPointsPerSpin: perSpin, isMesh: false)
    }

    /// First meaningful (non-empty, non-comment) line must be numeric or a
    /// recognized CRYSTAL/BAND keyword, else this is clearly not a BAND file.
    private static func passesBandGate(_ lines: [String]) -> Bool {
        let keywords = ["band", "k point", "k-point", "n. of", "number of",
                        "nbands", "nkpt", "crystal", "properties", "fermi",
                        "hartree", "angstrom", "lattice", "reciprocal", "spin",
                        "polarized", "electronvolt", "eigenvalue"]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.first == "!" || trimmed.first == "#" ||
               trimmed.first == "*" || trimmed.first == "%" { continue }
            if isDataLine(trimmed) { return true }
            let lower = trimmed.lowercased()
            if keywords.contains(where: { lower.contains($0) }) { return true }
            // A leading fermi-energy line ("E(F)= <v>", "E(FERMI)= ...") can
            // precede the numerical bands; accept it rather than reject the file.
            let fermiPattern = #"^\s*E\s*\(\s*F(?:ERMI)?\s*\)"#
            if lower.range(of: fermiPattern, options: .regularExpression) != nil { return true }
            return false
        }
        return false
    }

    /// The longest contiguous run of pure-number lines (blank lines skipped),
    /// i.e. the data region, isolated from any numeric header fragments.
    private static func extractDataLines(_ lines: [String]) -> [[Float]] {
        struct Item { let isNum: Bool; let floats: [Float] }
        var items: [Item] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let num = isDataLine(trimmed)
            items.append(Item(isNum: num, floats: num ? scanFloats(trimmed) : []))
        }
        var bestStart = 0, bestLen = 0, curStart = 0, curLen = 0
        for i in items.indices {
            if items[i].isNum {
                if curLen == 0 { curStart = i }
                curLen += 1
            } else if curLen > bestLen {
                bestLen = curLen; bestStart = curStart; curLen = 0
            }
        }
        if curLen > bestLen { bestLen = curLen; bestStart = curStart }
        guard bestLen > 0 else { return [] }
        return items[bestStart..<(bestStart + bestLen)].map { $0.floats }
    }

    /// Read k-points with a known band count: each block is a 3-float k-line
    /// followed by `nbands` energy floats gathered across continuation lines.
    private static func accumulateKPoints(_ numberLines: [[Float]], nbands: Int) -> [BandKPoint] {
        var out: [BandKPoint] = []
        var i = 0
        while i < numberLines.count {
            let line = numberLines[i]
            guard line.count >= 3 else { break }
            let k = SIMD3<Float>(line[0], line[1], line[2])
            var energies = Array(line.dropFirst(3))
            i += 1
            while energies.count < nbands && i < numberLines.count {
                energies.append(contentsOf: numberLines[i])
                i += 1
            }
            guard energies.count >= nbands else { break }
            energies = Array(energies.prefix(nbands))
            out.append(BandKPoint(k: k, weight: 1, label: "", energies: energies))
        }
        return out
    }

    /// Derive (nbands, nk) without a header: k-lines are the lines of exactly
    /// 3 floats; the floats between consecutive k-lines are the bands. Requires
    /// a consistent repeating pattern (all gaps equal, trailing block complete).
    private static func deriveLayout(_ numberLines: [[Float]]) -> (nbands: Int, nk: Int)? {
        let counts = numberLines.map { $0.count }
        let kIdx = counts.indices.filter { counts[$0] == 3 }
        guard kIdx.count >= 2, kIdx[0] == 0 else { return nil }
        var gaps: [Int] = []
        for j in 0..<(kIdx.count - 1) {
            var sum = 0
            for idx in (kIdx[j] + 1)..<kIdx[j + 1] { sum += counts[idx] }
            gaps.append(sum)
        }
        var trailing = 0
        for idx in (kIdx.last! + 1)..<counts.count { trailing += counts[idx] }
        guard let nb = gaps.first, nb > 0, gaps.allSatisfy({ $0 == nb }) else { return nil }
        guard trailing == nb else { return nil }
        return (nbands: nb, nk: kIdx.count)
    }

    /// Two channels only when the first half of k-points is coordinate-equal to
    /// the second half AND (a spin marker or header nk == half). Else one.
    private static func channelLayout(_ kpoints: [BandKPoint], header: BandHeader, nk: Int) -> (Int, Int) {
        let total = kpoints.count
        var nSpin = 1, perSpin = total
        if total % 2 == 0 {
            let half = total / 2
            let paired = (0..<half).allSatisfy { i in
                simd_length(kpoints[i].k - kpoints[i + half].k) < 1e-3
            }
            if paired && (header.spinHint || header.nk == half || nk == half) {
                nSpin = 2; perSpin = half
            }
        }
        return (nSpin, perSpin)
    }
}

/// Header metadata for a CRYSTAL band file, scanned order-independently.
private struct BandHeader {
    var nk: Int = 0
    var nbands: Int = 0
    var fermi: Float?
    var units: EnergyUnit = .ev
    var spinHint: Bool = false

    static func scan(_ lines: [String]) -> BandHeader {
        var h = BandHeader()
        for line in lines {
            let lower = line.lowercased()
            if h.nk <= 0 {
                h.nk = captureInt(line, #"(?i)(?:NUMBER|N\.?)\s*OF\s+K[\s-]*POINTS?\s*[:=]?\s*(\d+)"#)
                    ?? captureInt(line, #"(?i)NKPTS?\s*[:=]?\s*(\d+)"#)
                    ?? 0
            }
            if h.nbands <= 0 {
                h.nbands = captureInt(line, #"(?i)(?:NUMBER|N\.?)\s*OF\s+BANDS?\s*[:=]?\s*(\d+)"#)
                    ?? captureInt(line, #"(?i)NBANDS?\s*[:=]?\s*(\d+)"#)
                    ?? 0
            }
            if h.fermi == nil {
                h.fermi = captureFloat(line, #"(?i)E\s*\(\s*F(?:ERMI)?\s*\)\s*[:=]?\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eEdD][+-]?\d+)?)"#)
                    ?? captureFloat(line, #"(?i)FERMI\s*(?:ENERGY)?\s*[:=]?\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eEdD][+-]?\d+)?)"#)
                    ?? captureFloat(line, #"(?i)EFERMI\s*[:=]?\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eEdD][+-]?\d+)?)"#)
            }
            if h.units == .ev {
                if lower.contains("hartree") || (lower.contains("atomic") && lower.contains("units")) {
                    h.units = .hartree
                } else if lower.contains("ev") || lower.contains("electronvolt") {
                    h.units = .ev
                }
            }
            if !h.spinHint {
                let polarized = lower.contains("polarized") || lower.contains("polarised")
                let updown = (lower.contains(" up") || lower.contains("up")) &&
                             (lower.contains(" down") || lower.contains("down"))
                h.spinHint = (lower.contains("spin") && (polarized || lower.contains("2") || updown)) || updown
            }
        }
        return h
    }
}

// MARK: - CRYSTAL density of states

/// Parse CRYSTAL DOS text into a `DensityOfStates`, or nil when it does not
/// look like CRYSTAL DOS output. Never traps.
enum CrystalDOSParser {
    static func parse(_ text: String) -> DensityOfStates? {
        guard text.count <= 2_000_000 else { return nil }
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        guard passesDOSGate(lines) else { return nil }

        var headerLines: [String] = []
        var dataRows: [[Float]] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if isDataLine(trimmed) {
                let f = scanFloats(trimmed)
                if f.count >= 2 { dataRows.append(f) }
            } else {
                headerLines.append(trimmed)
            }
        }
        guard dataRows.count >= 2, dataRows.count <= 100_000 else { return nil }

        let header = DOSHeader.scan(headerLines)

        // Single (modal) column count; all rows must agree.
        var colCounts: [Int: Int] = [:]
        for r in dataRows { colCounts[r.count, default: 0] += 1 }
        guard let modal = colCounts.max(by: {
            $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
        })?.key, dataRows.allSatisfy({ $0.count == modal }) else { return nil }

        // Strictly increasing energy; a decrease ends the table, a duplicate is skipped.
        var rows: [[Float]] = []
        for r in dataRows {
            if let last = rows.last {
                if r[0] < last[0] { break }
                if r[0] == last[0] { continue }
            }
            rows.append(r)
        }
        guard rows.count >= 2 else { return nil }

        let seriesCount = modal - 1
        guard seriesCount >= 1 else { return nil }

        var labels = chooseSeriesLabels(headerLines, seriesCount: seriesCount, dataColumns: modal)

        // Detect the integrated-DOS column: any header token whose letters spell
        // out an integrated marker ("integrated", "intdos", "idos") names an
        // accumulated-DOS column to drop. CRYSTAL DOSS legends are right-aligned
        // with the table and put the labelled (species) column LAST, so the
        // marker is mapped to a data column by its distance from the END of the
        // header line. Counting header words from the left instead would drop a
        // neighbouring column whenever the legend carries extra leading tokens
        // (a unit or a prefix word). Fall back to the label of the last series,
        // which covers the common "ENERGY DOSS DOSS(INTEGRATED)" shape.
        var integratedCol: Int? = nil
        func isIntegratedToken(_ word: String) -> Bool {
            let compact = word.lowercased().filter { $0.isLetter }
            return compact.contains("integrated") || compact == "intdos" || compact == "idos"
        }
        for line in headerLines {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" })
                .map(String.init)
            for (idx, w) in words.enumerated() where isIntegratedToken(w) {
                // Last header word -> last data column, and so on backwards.
                let fromEnd = words.count - 1 - idx
                let col = modal - 1 - fromEnd
                if col >= 1 && col < modal { integratedCol = col }
            }
        }
        if integratedCol == nil, let lastLab = labels.last {
            let compact = lastLab.lowercased().filter { $0.isLetter }
            if compact.contains("integrated") || compact.contains("intdos") || compact.contains("idos") {
                integratedCol = modal - 1   // last data column
            }
        }

        // Build the kept-series index set (data columns 1..<modal), dropping the
        // integrated column.
        var keepCols: [Int] = []
        for c in 1..<modal where c != integratedCol {
            keepCols.append(c)
        }
        let kept = keepCols.count
        guard kept >= 1 else { return nil }
        labels = (0..<kept).map { $0 < labels.count ? labels[$0] : "dos-\($0 + 1)" }

        let scale: Float = header.units == .hartree ? hartreeToEV : 1.0
        let invScale: Float = header.units == .hartree ? 1.0 / hartreeToEV : 1.0
        guard rows.count * kept <= 1_000_000 else { return nil }

        let energies = rows.map { $0[0] * scale }
        if !energies.allSatisfy({ $0.isFinite }) { return nil }
        var series: [DOSSeries] = []
        for (outIdx, c) in keepCols.enumerated() {
            let label = outIdx < labels.count ? labels[outIdx] : "dos-\(outIdx + 1)"
            let values = rows.map { $0[c] * invScale }
            if !values.allSatisfy({ $0.isFinite }) { return nil }
            series.append(DOSSeries(label: label, values: values))
        }
        let fermi = header.fermi.map { $0 * scale }
        if let f = fermi, !f.isFinite { return nil }
        return DensityOfStates(energies: energies, series: series, fermiEnergy: fermi)
    }

    private static func passesDOSGate(_ lines: [String]) -> Bool {
        let keywords = ["dos", "doss", "energy", "n. of", "number of",
                        "crystal", "properties", "fermi", "hartree", "projection",
                        "spectrum", "electronvolt", "pdos", "ldos", "atomic",
                        "density", "states"]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.first == "!" || trimmed.first == "#" ||
               trimmed.first == "*" || trimmed.first == "%" { continue }
            if isDataLine(trimmed) { return true }
            let lower = trimmed.lowercased()
            if keywords.contains(where: { lower.contains($0) }) { return true }
            return false
        }
        return false
    }

    /// Label the DOS series from the best header line: word tokens whose count
    /// matches the data columns (drop the energy token) or the series count.
    private static func chooseSeriesLabels(_ headerLines: [String], seriesCount: Int, dataColumns: Int) -> [String] {
        var best: [String] = []
        var bestScore = -1
        for line in headerLines {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" })
                .map(String.init)
                .filter { w in w.first?.isLetter == true }
            guard !words.isEmpty else { continue }
            let fit: Int = (words.count == dataColumns || words.count == seriesCount) ? 2 : 1
            let score = fit * 1000 + words.count
            if score > bestScore { bestScore = score; best = words }
        }
        guard !best.isEmpty else { return (1...seriesCount).map { "dos-\($0)" } }
        if best.count == seriesCount { return best }
        if best.count == dataColumns { return Array(best.dropFirst()) }
        return (1...seriesCount).map { "dos-\($0)" }
    }
}

/// Header metadata for a CRYSTAL DOS file.
private struct DOSHeader {
    var fermi: Float?
    var units: EnergyUnit = .ev

    static func scan(_ textLines: [String]) -> DOSHeader {
        var h = DOSHeader()
        for line in textLines {
            let lower = line.lowercased()
            if h.fermi == nil {
                h.fermi = captureFloat(line, #"(?i)E\s*\(\s*F(?:ERMI)?\s*\)\s*[:=]?\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eEdD][+-]?\d+)?)"#)
                    ?? captureFloat(line, #"(?i)FERMI\s*(?:ENERGY)?\s*[:=]?\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eEdD][+-]?\d+)?)"#)
                    ?? captureFloat(line, #"(?i)EFERMI\s*[:=]?\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eEdD][+-]?\d+)?)"#)
            }
            if h.units == .ev {
                if lower.contains("hartree") || (lower.contains("atomic") && lower.contains("units")) {
                    h.units = .hartree
                } else if lower.contains("ev") || lower.contains("electronvolt") {
                    h.units = .ev
                }
            }
        }
        return h
    }
}
