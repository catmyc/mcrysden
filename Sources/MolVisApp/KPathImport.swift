import Foundation
import simd

/// K-path file formats that can be imported into the k-path editor.
enum KPathImportFormat: Equatable {
    case qe        // QE K_POINTS crystal card (explicit list)
    case vasp      // VASP KPOINTS line-mode file
    case wannier90 // Wannier90 kpoint_path block
    case kpf       // XCrySDen native .kpf file
}

enum KPathImportError: Error, LocalizedError {
    case unsupportedFile(path: String, reason: String)
    case notAPath(path: String, reason: String)
    case malformed(path: String, reason: String)
    case tooManyPoints(path: String, count: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let path, let reason):
            return "\(path): unsupported k-path file — \(reason)"
        case .notAPath(let path, let reason):
            return "\(path): not a band path — \(reason)"
        case .malformed(let path, let reason):
            return "\(path): \(reason)"
        case .tooManyPoints(let path, let count):
            return "\(path): too many k-points (\(count) > \(KPathImport.maxPoints))"
        }
    }
}

enum KPathImport {
    /// Maximum route size (matches the editor's 1024-node route cap).
    static let maxPoints = 1024

    /// Reject files larger than this to bound memory use on parse.
    static let maxFileBytes = 16 * 1024 * 1024

    /// Detect the format of a file by extension hints then content sniffing.
    static func format(of url: URL) throws -> KPathImportFormat {
        try checkFileWithinLimits(url)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw KPathImportError.unsupportedFile(path: url.path,
                                                   reason: "could not read file: \(error.localizedDescription)")
        }
        return try detectFormat(text: normalize(text), url: url)
    }

    /// Parse a k-path file into editor coordinates (fractional crystal coords).
    /// Returns the detected format alongside the path so callers can apply
    /// format-specific policy (e.g. VASP carries an explicit sampling density).
    static func importKPath(from url: URL) throws -> (path: KPath, format: KPathImportFormat) {
        try checkFileWithinLimits(url)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw KPathImportError.malformed(path: url.path,
                                             reason: "could not read file: \(error.localizedDescription)")
        }
        let normalized = normalize(text)
        let format = try detectFormat(text: normalized, url: url)
        let path = try parseNormalized(text: normalized, url: url, format: format)
        return (path: path, format: format)
    }

    /// Pure-text parse (used by tests and by format(of:) sniffing).
    static func parse(text: String, url: URL) throws -> KPath {
        let text = normalize(text)
        let format = try detectFormat(text: text, url: url)
        return try parseNormalized(text: text, url: url, format: format)
    }

    private static func parseNormalized(text: String, url: URL, format: KPathImportFormat) throws -> KPath {
        switch format {
        case .qe: return try parseQE(text: text, path: url.path)
        case .vasp: return try parseVASP(text: text, path: url.path)
        case .wannier90: return try parseWannier90(text: text, path: url.path)
        case .kpf: return try parseKPF(text: text, path: url.path)
        }
    }

    // MARK: - Format detection

    private static func detectFormat(text: String, url: URL) throws -> KPathImportFormat {
        let ext = url.pathExtension.lowercased()
        let lastComp = url.lastPathComponent.lowercased()

        if ext == "kpf" { return .kpf }
        if lastComp == "kpoints" || ext == "kpoints" { return .vasp }

        let sig = significantLines(text)

        for line in sig {
            if line.lowercased().hasPrefix("k_points") { return .qe }
        }
        for line in sig {
            if line.lowercased().contains("kpoint_path") { return .wannier90 }
        }
        if sig.count >= 3 && sig[2].lowercased().hasPrefix("line") { return .vasp }

        throw KPathImportError.unsupportedFile(path: url.path,
                                               reason: "file does not match any supported k-path format (QE K_POINTS, VASP KPOINTS, Wannier90 kpoint_path, XCrySDen KPF)")
    }

    // MARK: - QE K_POINTS crystal

    private static func parseQE(text: String, path: String) throws -> KPath {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var cardLine: String?
        var cardIndex: Int?
        for (i, line) in lines.enumerated() {
            if line.lowercased().hasPrefix("k_points") {
                cardLine = line
                cardIndex = i
                break
            }
        }
        guard let cardLine = cardLine, let cardIndex = cardIndex else {
            throw KPathImportError.malformed(path: path, reason: "no K_POINTS card found")
        }

        let qualifier = extractQECardQualifier(cardLine)
        let mode = qualifier.lowercased()
        switch mode {
        case "", "crystal":
            break
        case "automatic":
            throw KPathImportError.notAPath(path: path,
                                            reason: "uniform k-grid (automatic), not a band path — use K_POINTS crystal")
        case "tpiba_b":
            throw KPathImportError.notAPath(path: path,
                                            reason: "K_POINTS tpiba_b is an unsupported Cartesian band path without active cell/alat context — use K_POINTS crystal coordinates")
        default:
            throw KPathImportError.notAPath(path: path,
                                            reason: "K_POINTS mode '\(mode)' is not a band path; use crystal, KPF, VASP, or Wannier90 kpoint_path")
        }

        var index = cardIndex + 1
        while index < lines.count {
            let line = lines[index]
            if !line.isEmpty && !isCommentLine(line) { break }
            index += 1
        }
        guard index < lines.count else {
            throw KPathImportError.malformed(path: path, reason: "K_POINTS card has no count line")
        }
        let countLine = stripTrailingComment(lines[index])
        guard let n = strictPositiveInt(countLine) else {
            throw KPathImportError.malformed(path: path,
                                             reason: "K_POINTS count must be a positive integer, got '\(countLine)'")
        }
        guard n <= maxPoints else {
            throw KPathImportError.tooManyPoints(path: path, count: n)
        }

        var points: [KPoint] = []
        points.reserveCapacity(n)
        index += 1
        while points.count < n && index < lines.count {
            let line = lines[index]
            index += 1
            if line.isEmpty || isCommentLine(line) { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3 else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "K_POINTS data line must have at least 3 coordinates: '\(line)'")
            }
            guard let x = Float(tokens[0]), x.isFinite,
                  let y = Float(tokens[1]), y.isFinite,
                  let z = Float(tokens[2]), z.isFinite else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "K_POINTS data line has non-finite coordinate: '\(line)'")
            }
            if tokens.count >= 4 {
                guard let w = Float(tokens[3]), w.isFinite else {
                    throw KPathImportError.malformed(path: path,
                                                     reason: "K_POINTS weight must be finite: '\(line)'")
                }
            }
            points.append(KPoint(SIMD3<Float>(x, y, z)))
        }
        guard points.count == n else {
            throw KPathImportError.malformed(path: path,
                                             reason: "expected \(n) k-point lines, found \(points.count)")
        }
        return KPath(points: points, pointsPerSegment: 20, breaks: [])
    }

    private static func extractQECardQualifier(_ cardLine: String) -> String {
        let lower = cardLine.lowercased()
        guard let range = lower.range(of: "k_points") else { return "" }
        let rest = String(cardLine[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let stripped = stripTrailingComment(rest)
        return stripped.trimmingCharacters(in: CharacterSet(charactersIn: "{}()"))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - VASP line-mode

    private static func parseVASP(text: String, path: String) throws -> KPath {
        let sig = significantLines(text)

        guard !sig.isEmpty else {
            throw KPathImportError.malformed(path: path, reason: "VASP KPOINTS file is empty")
        }

        // line1 = comment (ignore) when it is not a valid integer N. This handles both
        // the standard VASP layout (title + N + ...) and files that omit the title.
        var startIdx = 0
        if sig.count >= 2 && strictPositiveInt(stripTrailingComment(sig[0])) == nil {
            startIdx = 1
        }
        // Automatic/grid markers are diagnosed BEFORE the line-count guard so a
        // short automatic-mesh file reports "not a band path" instead of a vague
        // line-count complaint. The marker can also sit on the skipped title line
        // (standard VASP automatic files: title, then G/M/Automatic).
        let nLine = stripTrailingComment(sig[startIdx])
        let skippedMarker = startIdx == 1 && isAutomaticMarker(stripTrailingComment(sig[0]))
        if skippedMarker || isAutomaticMarker(nLine) {
            throw KPathImportError.notAPath(path: path,
                                            reason: "VASP KPOINTS appears to be automatic/grid mode, not a line-mode band path")
        }
        guard sig.count >= startIdx + 4 else {
            throw KPathImportError.malformed(path: path,
                                             reason: "VASP KPOINTS line-mode requires at least 4 lines (N, Line-mode, Reciprocal, and data)")
        }

        guard let n = strictPositiveInt(nLine) else {
            throw KPathImportError.malformed(path: path,
                                             reason: "VASP KPOINTS points-per-segment must be a positive integer, got '\(nLine)'")
        }

        let modeLine = sig[startIdx + 1]
        guard let modeFirst = modeLine.trimmingCharacters(in: .whitespaces).first,
              modeFirst == "L" || modeFirst == "l" else {
            throw KPathImportError.notAPath(path: path,
                                            reason: "VASP automatic/grid mode is not a band path")
        }

        let coordLine = sig[startIdx + 2]
        let coordFirst = coordLine.trimmingCharacters(in: .whitespaces).first.map { String($0).lowercased() } ?? ""
        if coordFirst == "c" || coordFirst == "k" {
            throw KPathImportError.notAPath(path: path,
                                            reason: "VASP Cartesian line-mode is not supported for import; use Reciprocal")
        }

        let dataLines = sig[(startIdx + 3)...]
        var kpoints: [KPoint] = []
        for line in dataLines {
            // Coordinates come from the pre-delimiter portion; a label may sit
            // as a bare fourth column or as a suffix after the first !/# marker
            // (the app's own VASP export writes labels there).
            let coordsText = stripTrailingComment(line)
            let tokens = coordsText.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3 else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "VASP k-point line must have at least 3 coordinates: '\(line)'")
            }
            guard let x = Float(tokens[0]), x.isFinite,
                  let y = Float(tokens[1]), y.isFinite,
                  let z = Float(tokens[2]), z.isFinite else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "VASP k-point line has non-finite coordinate: '\(line)'")
            }
            var label = ""
            if tokens.count > 3 {
                label = normalizeGamma(String(tokens[3].prefix(64)))
            } else if let suffix = trailingCommentLabel(line), !suffix.isEmpty {
                label = normalizeGamma(String(suffix.prefix(64)))
            }
            kpoints.append(KPoint(SIMD3<Float>(x, y, z), label))
        }

        guard kpoints.count >= 2 else {
            throw KPathImportError.malformed(path: path,
                                             reason: "VASP line-mode requires at least 2 k-points (1 segment)")
        }
        guard kpoints.count % 2 == 0 else {
            throw KPathImportError.malformed(path: path,
                                             reason: "VASP line-mode has odd number of k-points (\(kpoints.count)); segments require pairs")
        }
        guard kpoints.count <= maxPoints else {
            throw KPathImportError.tooManyPoints(path: path, count: kpoints.count)
        }

        var segments: [(start: KPoint, end: KPoint)] = []
        segments.reserveCapacity(kpoints.count / 2)
        for i in stride(from: 0, to: kpoints.count, by: 2) {
            segments.append((kpoints[i], kpoints[i + 1]))
        }

        let clampedN = min(200, max(2, n))
        let (points, breaks) = assemblePath(from: segments)
        return KPath(points: points, pointsPerSegment: clampedN, breaks: breaks)
    }

    // MARK: - Wannier90 kpoint_path

    private static func parseWannier90(text: String, path: String) throws -> KPath {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Prefer an explicit "begin kpoint_path" delimiter (inline comments
        // allowed, since Wannier90 treats text after !/# as comments); fall
        // back to an exact bare "kpoint_path" line for legacy files.
        var blockStart: Int?
        var blockEnd: Int?
        var usingBeginEnd = false
        for (i, line) in lines.enumerated() {
            if delimiterKey(line) == "begin kpoint_path" {
                blockStart = i
                usingBeginEnd = true
                break
            }
        }
        if blockStart == nil {
            for (i, line) in lines.enumerated() {
                if !isCommentLine(line) && delimiterKey(line) == "kpoint_path" {
                    blockStart = i
                    break
                }
            }
        }
        guard let blockStart = blockStart else {
            throw KPathImportError.malformed(path: path, reason: "no kpoint_path block found")
        }

        if usingBeginEnd {
            for i in (blockStart + 1)..<lines.count {
                if delimiterKey(lines[i]) == "end kpoint_path" {
                    blockEnd = i
                    break
                }
            }
            guard blockEnd != nil else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "kpoint_path block is not terminated by 'end kpoint_path'")
            }
        }

        var segments: [(start: KPoint, end: KPoint)] = []
        let endIdx = blockEnd ?? lines.count
        for i in (blockStart + 1)..<endIdx {
            let line = lines[i]
            if line.isEmpty || isCommentLine(line) { continue }
            // Wannier90 treats characters after the earliest `!` or `#` as an
            // inline comment; strip it before tokenizing the row.
            let content = stripTrailingComment(line)
            let tokens = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if !usingBeginEnd {
                // For bare legacy blocks, a short all-nonnumeric line or a
                // scalar keyword assignment (e.g. "bands_plot = true") is a
                // likely following keyword; stop the block there.
                let shortKeyword = tokens.count <= 2 && tokens.allSatisfy({ !isNumeric($0) })
                let assignmentKeyword = tokens.count >= 2 && !isNumeric(tokens[0])
                    && (tokens[1] == "=" || tokens[1] == ":")
                if shortKeyword || assignmentKeyword { break }
                if tokens.count <= 2 {
                    throw KPathImportError.malformed(path: path,
                                                     reason: "malformed kpoint_path row: '\(line)'")
                }
            }
            guard tokens.count == 8 else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "kpoint_path row must have 8 tokens (label x y z label x y z): '\(line)'")
            }
            // Documented interleaved: label1 x1 y1 z1 label2 x2 y2 z2.
            if !isNumeric(tokens[0]), !isNumeric(tokens[4]),
               let kx1 = Float(tokens[1]), kx1.isFinite,
               let ky1 = Float(tokens[2]), ky1.isFinite,
               let kz1 = Float(tokens[3]), kz1.isFinite,
               let kx2 = Float(tokens[5]), kx2.isFinite,
               let ky2 = Float(tokens[6]), ky2.isFinite,
               let kz2 = Float(tokens[7]), kz2.isFinite {
                segments.append((KPoint(SIMD3<Float>(kx1, ky1, kz1),
                                        normalizeGamma(String(tokens[0].prefix(64)))),
                                 KPoint(SIMD3<Float>(kx2, ky2, kz2),
                                        normalizeGamma(String(tokens[4].prefix(64))))))
                continue
            }
            // Legacy two-labels-first: label1 label2 x1 y1 z1 x2 y2 z2.
            if !isNumeric(tokens[0]), !isNumeric(tokens[1]),
               let x1 = Float(tokens[2]), x1.isFinite,
               let y1 = Float(tokens[3]), y1.isFinite,
               let z1 = Float(tokens[4]), z1.isFinite,
               let x2 = Float(tokens[5]), x2.isFinite,
               let y2 = Float(tokens[6]), y2.isFinite,
               let z2 = Float(tokens[7]), z2.isFinite {
                segments.append((KPoint(SIMD3<Float>(x1, y1, z1),
                                        normalizeGamma(String(tokens[0].prefix(64)))),
                                 KPoint(SIMD3<Float>(x2, y2, z2),
                                        normalizeGamma(String(tokens[1].prefix(64))))))
                continue
            }
            throw KPathImportError.malformed(path: path,
                                             reason: "kpoint_path row matches neither the documented interleaved form nor the legacy two-labels-first form: '\(line)'")
        }

        guard !segments.isEmpty else {
            throw KPathImportError.malformed(path: path,
                                             reason: "kpoint_path block has no valid data lines")
        }
        let (totalPoints, overflow) = segments.count.multipliedReportingOverflow(by: 2)
        guard !overflow, totalPoints <= maxPoints else {
            throw KPathImportError.tooManyPoints(path: path, count: overflow ? maxPoints + 1 : totalPoints)
        }

        let (points, breaks) = assemblePath(from: segments)
        return KPath(points: points, pointsPerSegment: 20, breaks: breaks)
    }

    // MARK: - KPF (XCrySDen)

    private static func parseKPF(text: String, path: String) throws -> KPath {
        let sig = significantLines(text)
        guard !sig.isEmpty else {
            throw KPathImportError.malformed(path: path, reason: "KPF file is empty")
        }

        let mLine = stripTrailingComment(sig[0])
        guard let m = strictPositiveInt(mLine) else {
            throw KPathImportError.malformed(path: path,
                                             reason: "KPF ISS multiplier must be a positive integer, got '\(mLine)'")
        }
        let mFloat = Float(m)
        guard mFloat.isFinite, mFloat > 0 else {
            throw KPathImportError.malformed(path: path, reason: "KPF ISS multiplier overflow")
        }

        var points: [KPoint] = []
        for i in 1..<sig.count {
            let line = stripTrailingComment(sig[i])
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3 else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "KPF line must have at least 3 integer coordinates: '\(line)'")
            }
            guard let kx = strictInt(tokens[0]) else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "KPF coordinate must be an integer, got '\(tokens[0])' on line: '\(line)'")
            }
            guard let ky = strictInt(tokens[1]) else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "KPF coordinate must be an integer, got '\(tokens[1])' on line: '\(line)'")
            }
            guard let kz = strictInt(tokens[2]) else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "KPF coordinate must be an integer, got '\(tokens[2])' on line: '\(line)'")
            }
            let fx = Float(kx) / mFloat
            let fy = Float(ky) / mFloat
            let fz = Float(kz) / mFloat
            guard fx.isFinite && fy.isFinite && fz.isFinite else {
                throw KPathImportError.malformed(path: path,
                                                 reason: "KPF fractional coordinate overflow on line: '\(line)'")
            }
            var label = ""
            if tokens.count >= 4 {
                label = String(tokens[3...].joined(separator: " ").prefix(64))
            }
            points.append(KPoint(SIMD3<Float>(fx, fy, fz), label))
        }

        guard !points.isEmpty else {
            throw KPathImportError.malformed(path: path, reason: "KPF file has no k-points")
        }
        guard points.count <= maxPoints else {
            throw KPathImportError.tooManyPoints(path: path, count: points.count)
        }
        return KPath(points: points, pointsPerSegment: 20, breaks: [])
    }

    // MARK: - Shared connectivity helper

    /// Build the flat point list and break set from consecutive segments. A shared
    /// endpoint is coalesced: when the next segment's start equals the previous
    /// segment's end within `tol` per component, only the new end node is appended.
    /// Otherwise a break is inserted between the two components. Zero-length
    /// segments (identical endpoints) keep both points.
    private static func assemblePath(from segments: [(start: KPoint, end: KPoint)], tol: Float = 1e-4)
        -> (points: [KPoint], breaks: Set<Int>) {
        var points: [KPoint] = []
        var breaks = Set<Int>()
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                let prevEnd = points[points.count - 1].frac
                let nextStart = seg.start.frac
                let same = abs(prevEnd.x - nextStart.x) < tol
                    && abs(prevEnd.y - nextStart.y) < tol
                    && abs(prevEnd.z - nextStart.z) < tol
                if same {
                    points.append(seg.end)
                    continue
                }
                breaks.insert(points.count - 1)
            }
            points.append(seg.start)
            points.append(seg.end)
        }
        breaks = Set(breaks.filter { $0 >= 0 && $0 < points.count - 1 })
        return (points, breaks)
    }

    // MARK: - Token helpers

    private static func checkFileWithinLimits(_ url: URL) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return }
        if size > Int64(maxFileBytes) {
            throw KPathImportError.malformed(path: url.path, reason: "file too large")
        }
    }

    private static func significantLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isCommentLine($0) }
    }

    /// Normalize CRLF/CR to LF so line splits behave regardless of the file's
    /// line endings (a CR+LF pair reads as a single Character grapheme cluster),
    /// and drop a UTF-8 byte-order mark so a BOM cannot poison the first line's
    /// format detection or token parse.
    private static func normalize(_ text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.first == "\u{FEFF}" { normalized.removeFirst() }
        return normalized
    }

    private static func isCommentLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first == "#" || first == "!" || first == ";"
    }

    private static func stripTrailingComment(_ line: String) -> String {
        var cut: String.Index? = nil
        for ch in ["!", "#"] {
            if let r = line.range(of: ch) {
                if cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
            }
        }
        if let cut = cut {
            return String(line[..<cut]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// First whitespace-delimited token after the earliest trailing `!`/`#`
    /// comment marker on a line (VASP files often carry the k-point label
    /// there), or nil when the line has no comment marker.
    private static func trailingCommentLabel(_ line: String) -> String? {
        var cut: String.Index? = nil
        for ch in ["!", "#"] {
            if let r = line.range(of: ch) {
                if cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
            }
        }
        guard let cut = cut else { return nil }
        let rest = line[cut...].drop(while: { $0 == "!" || $0 == "#" })
        return rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    /// Delimiter comparison form: inline comments stripped, then lowercased.
    /// Wannier90 treats characters after the earliest `!`/`#` as comments, so
    /// "begin kpoint_path ! comment" compares equal to "begin kpoint_path".
    private static func delimiterKey(_ line: String) -> String {
        stripTrailingComment(line).lowercased()
    }

    private static func strictPositiveInt(_ s: String) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }

    private static func isNumeric(_ s: String) -> Bool {
        guard let f = Float(s) else { return false }
        return f.isFinite
    }

    /// VASP automatic-mesh markers that can appear in place of a line-mode
    /// points-per-segment integer ("G"/"M"/"Automatic", or "Line-mode" missing
    /// its N line).
    private static func isAutomaticMarker(_ s: String) -> Bool {
        let lower = s.lowercased()
        // Prefix match for "Automatic generation"/"Automatic mesh", the standard
        // VASP automatic-grid header lines, so those files report "not a band
        // path" instead of a confusing integer-parse error.
        return lower.hasPrefix("automatic")
            || lower.hasPrefix("line-mode") || lower.hasPrefix("line mode") || lower == "line"
            || lower == "g" || lower == "m" || lower == "auto"
    }

    private static func strictInt(_ s: String) -> Int? {
        Int(s.trimmingCharacters(in: .whitespaces))
    }

    private static func normalizeGamma(_ label: String) -> String {
        let lower = label.lowercased()
        if lower == "gamma" || lower == "gm" || lower == "g" || lower == "γ" { return "G" }
        return label
    }
}
