import Foundation

struct DOSSeries: Codable {
    var label: String
    var values: [Float]
}

struct DensityOfStates: Codable {
    var energies: [Float]
    var series: [DOSSeries]
    var fermiEnergy: Float?
}

/// Parses the whitespace-delimited tables written by Quantum Espresso `dos.x`
/// and `projwfc.x` (total, spin-resolved, LDOS, PDOS, and m-resolved PDOS).
/// The first column must be energy in eV; a recognizable trailing integrated-DOS
/// column is omitted. Free-form projected-state listings are not supported.
///
/// When `sourceName` is a QE projwfc filename, per-orbital PDOS labels are
/// enriched with the species + orbital (e.g. "Fe p") so the projection
/// character is visible in the grapher. `nil` leaves behavior unchanged.
enum DOSParser {
    static func parse(_ text: String, sourceName: String? = nil) -> DensityOfStates? {
        var rows: [[Float]] = []
        var columnCounts: [Int: Int] = [:]
        var headers: [String] = []
        var fermiEnergy: Float?
        var totalValues = 0

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if fermiEnergy == nil {
                fermiEnergy = parseFermiEnergy(line)
            }

            let dataPart = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let uncommented = dataPart.split(separator: "!", maxSplits: 1).first.map(String.init) ?? ""
            let tokens = uncommented.split(whereSeparator: { $0 == " " || $0 == "\t" })

            guard let first = tokens.first, number(first) != nil else {
                headers.append(line)
                continue
            }

            var row: [Float] = []
            row.reserveCapacity(tokens.count)
            for token in tokens {
                guard let value = number(token), value.isFinite else { return nil }
                row.append(value)
            }
            guard row.count >= 2 else { return nil }
            rows.append(row)
            totalValues += row.count
            if rows.count > 100_000 || totalValues > 1_000_000 { return nil }
            columnCounts[row.count, default: 0] += 1
        }

        var monotonic: [[Float]] = []
        columnCounts.removeAll()
        for row in rows {
            if let last = monotonic.last, row[0] <= last[0] {
                if row[0] < last[0] { return nil }
                continue
            }
            monotonic.append(row)
            columnCounts[row.count, default: 0] += 1
        }

        guard monotonic.count >= 2,
              let modalCount = columnCounts.max(by: {
                  $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
              })?.key,
              monotonic.allSatisfy({ $0.count == modalCount }) else { return nil }

        let header = headers.max(by: { headerScore($0) < headerScore($1) }) ?? ""
        let integratedIndex = hasTrailingIntegratedDOS(header) ? modalCount - 2 : nil
        let keptIndices = (0..<(modalCount - 1)).filter { $0 != integratedIndex }
        guard !keptIndices.isEmpty else { return nil }

        let inferred = inferredLabels(from: header)
        var labels: [String] = []
        for sourceIndex in keptIndices {
            let label = sourceIndex < inferred.count ? inferred[sourceIndex] : "DOS \(sourceIndex + 1)"
            labels.append(label)
        }
        if let sourceName = sourceName, let enriched = projectedLabels(fromSourceName: sourceName, labels: labels) {
            labels = enriched
        }
        uniquify(&labels)

        let energies = monotonic.map { $0[0] }
        let series = zip(keptIndices, labels).map { sourceIndex, label in
            DOSSeries(label: label, values: monotonic.map { $0[sourceIndex + 1] })
        }
        return DensityOfStates(energies: energies, series: series, fermiEnergy: fermiEnergy)
    }

    private static func number<S: StringProtocol>(_ token: S) -> Float? {
        Float(token.replacingOccurrences(of: "D", with: "E")
            .replacingOccurrences(of: "d", with: "e"))
    }

    private static func parseFermiEnergy(_ line: String) -> Float? {
        guard line.range(of: "fermi", options: .caseInsensitive) != nil else { return nil }
        let pattern = #"(?i)fermi[^+\-0-9.]*(?:energy[^+\-0-9.]*)?([+\-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eEdD][+\-]?[0-9]+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return number(line[range])
    }

    private static func headerScore(_ line: String) -> Int {
        let lower = line.lowercased()
        return ["dos", "pdos", "ldos", "energy", "e(ev)", "e (ev)"].reduce(0) {
            $0 + (lower.contains($1) ? 1 : 0)
        }
    }

    private static func hasTrailingIntegratedDOS(_ header: String) -> Bool {
        let compact = header.lowercased().filter { $0.isLetter }
        return compact.contains("integrateddos") || compact.contains("intdos") || compact.contains("idos")
    }

    private static func inferredLabels(from header: String) -> [String] {
        let tokens = header.lowercased().split { !$0.isLetter }
        var labels: [String] = []
        for tokenSlice in tokens {
            let token = String(tokenSlice)
            let kind: String
            if token.contains("ldos") {
                kind = "LDOS"
            } else if token.contains("pdos") {
                kind = "PDOS"
            } else if token.hasPrefix("dos") {
                kind = "DOS"
            } else {
                continue
            }

            if token.contains("up") {
                labels.append("\(kind) up")
            } else if token.contains("down") || token.contains("dw") {
                labels.append("\(kind) down")
            } else {
                labels.append(kind == "DOS" ? "Total DOS" : kind)
            }
        }
        return labels
    }

    private static func uniquify(_ labels: inout [String]) {
        var totals: [String: Int] = [:]
        for label in labels { totals[label, default: 0] += 1 }
        var seen: [String: Int] = [:]
        for index in labels.indices where totals[labels[index], default: 0] > 1 {
            seen[labels[index], default: 0] += 1
            labels[index] += " \(seen[labels[index], default: 0])"
        }
    }

    /// If `sourceName` is a QE projwfc filename, return enriched labels where the
    /// projection character is visible; otherwise nil (caller keeps `labels`).
    ///
    /// - `pdos_atm#<N>(<Species>)_wfc#<M>(<orbital>)`: PDOS-kind labels become
    ///   "<Species> <orbital>" (preserving an up/down suffix); "Total DOS" is kept.
    /// - `pdos_tot` (optionally `_up`/`_down`): the total series is labeled
    ///   "Total DOS" (+ " up"/" down" suffix when present).
    static func projectedLabels(fromSourceName sourceName: String, labels: [String]) -> [String]? {
        let name = sourceName.lowercased()

        // Per-atom-per-orbital: pdos_atm#N(Species)_wfc#M(orbital).
        let atomPattern = #"pdos_atm#\d+\(([a-z]{1,3})\)_wfc#\d+\(([spdf])\)"#
        if let expression = try? NSRegularExpression(pattern: atomPattern),
           let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let species = capturedString(sourceName, match: match, group: 1),
           let orbital = capturedString(sourceName, match: match, group: 2)?.lowercased() {
            let base = "\(species) \(orbital)"
            return labels.map { label in
                if isTotalDOS(label) { return label }
                let suffix = upDownSuffix(label)
                return base + suffix
            }
        }

        // Total DOS: pdos_tot with optional _up/_down.
        let totPattern = #"pdos_tot(?:_(up|down))?"#
        if let expression = try? NSRegularExpression(pattern: totPattern),
           expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
            let fileSuffix = suffixFromTotalSource(sourceName) ?? ""
            return labels.map { label in
                if isTotalDOS(label) {
                    let ownSuffix = upDownSuffix(label)
                    return "Total DOS" + (ownSuffix.isEmpty ? fileSuffix : ownSuffix)
                }
                return label
            }
        }

        return nil
    }

    /// True when the label denotes a total-DOS series (not a PDOS/LDOS projection).
    private static func isTotalDOS(_ label: String) -> Bool {
        label == "Total DOS" || label.hasPrefix("DOS ")
    }

    /// The trailing " up"/" down"/"" suffix of a PDOS-kind label.
    private static func upDownSuffix(_ label: String) -> String {
        if label.hasSuffix(" up") { return " up" }
        if label.hasSuffix(" down") { return " down" }
        return ""
    }

    /// Map a `pdos_tot` filename's `_up`/`_down` suffix to a label suffix.
    private static func suffixFromTotalSource(_ sourceName: String) -> String? {
        let lower = sourceName.lowercased()
        let pattern = #"pdos_tot(?:_(up|down))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let word = capturedString(lower, match: match, group: 1) else { return nil }
        return " \(word)"
    }

    /// Returns the captured group (by index) from `string` for `match`, or nil
    /// if the group did not participate.
    private static func capturedString(_ string: String, match: NSTextCheckingResult, group: Int) -> String? {
        guard let range = Range(match.range(at: group), in: string) else { return nil }
        return String(string[range])
    }
}
