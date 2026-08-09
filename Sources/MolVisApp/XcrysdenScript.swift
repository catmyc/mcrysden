import Foundation

/// View state that can be round-tripped through the XCrySDen script subset.
///
/// This is the narrow, deterministic projection of mcrysden's full scene state
/// that the XCrySDen `.tcl` dialect can express. It covers camera orientation,
/// zoom, the two background colors, and the half-dozen display toggles/scale
/// factors the XCrySDen save format emits. It intentionally omits everything
/// that has no Tcl analog (atoms, bonds, cell, k-path, isosurfaces, ...) — the
/// primary agent wires these into a `Scene` after loading.
struct XcrysdenViewState: Codable, Equatable {
    var azimuth: Float = 225
    var elevation: Float = 45
    var zoom: Float = 1.0
    var backgroundTopHex: String = "#FFFFFF"
    var backgroundBottomHex: String = "#FFFFFF"
    var showCell: Bool = true
    var showBonds: Bool = true
    var atomScale: Float = 1.0
}

/// XCrySDen `.tcl` view-state script save/load for a **documented flat-line
/// subset**.
///
/// Full Tcl is unbounded; mcrysden's native `ScriptRunner` is a separate,
/// line-based engine. This translator sits in between: it emits and consumes a
/// deterministic subset of the XCrySDen dialect that maps 1:1 onto
/// `XcrysdenViewState`, never traps, and silently skips anything it cannot map.
///
/// ## Dialect subset
///
/// On **save** we emit exactly these commands, in order (no `proc`/`main`
/// wrapper — that simplification is intentional and documented here):
///
///     #!/usr/bin/env xcrysden --tcl
///     # mcrysden XCrySDen view-state script (documented flat-line subset)
///     set azimuth <deg>
///     set elevation <deg>
///     set zoom <factor>
///     set background top <#RRGGBB>
///     set background bottom <#RRGGBB>
///     set display cell <0|1>
///     set display bonds <0|1>
///     set atom_scale <factor>
///
/// On **load** each non-blank, non-comment line is tried as a command. The
/// supported spellings (case-insensitive, after lowercasing and treating `-` as
/// `_`) are:
///
///   azimuth            → azimuth
///   elevation          → elevation
///   zoom, zoom_factor  → zoom
///   background_top, background-top, bg_top, background top
///                      → backgroundTopHex
///   background_bottom, background-bottom, bg_bottom, background bottom
///                      → backgroundBottomHex
///   display_cell, show_cell, display-cell, show-cell,
///   displaycell, showcell, display cell, show cell
///                      → showCell
///   display_bonds, show_bonds, display-bonds, show-bonds,
///   displaybonds, showbonds, display bonds, show bonds
///                      → showBonds
///   atom_scale, atom-scale, atomscale
///                      → atomScale
///
/// `set` is optional (recognized and dropped). The key=value form is accepted
/// (`zoom = 2`, `zoom=2`); values may be quoted (`set zoom "2"`). Hex values
/// accept `#RRGGBB`, bare `RRGGBB`, and `0xRRGGBB`, normalized to `#RRGGBB`
/// (uppercase). Boolean values accept `0`/`1`, `true`/`false`, `yes`/`no`,
/// `on`/`off`. One command per line; assignments apply sequentially so a later
/// line wins.
///
/// ## Skip policy
///
/// Lines are **skipped** (counted, reported in the result) when they are
///   * a brace/block line containing `{` or `}` (Tcl multi-op — not supported),
///   * `quit` / `exit` (recognized, no mapping),
///   * an unknown `set VAR value` or any other unrecognized command,
///   * a recognized command whose value fails to parse (non-numeric, bad hex,
///     invalid bool).
///
/// Lines that are **ignored** (not counted, not reported) are blank lines and
/// comment lines (`# ...`, including the `#!/usr/bin/env xcrysden --tcl`
/// shebang). Never traps on any input.
///
/// ## Return contract
///
/// `load` returns `nil` when the text contains zero mapped commands (empty, all
/// comments, or nothing it could translate). Otherwise it returns the resulting
/// view state plus the list of skipped lines (1-based line numbers). A save of
/// any state followed by a load of that text returns an equal state with an
/// empty skipped list.
enum XcrysdenScript {
    /// Serialize a view state as an Xtcl-style script (documented subset).
    static func save(_ state: XcrysdenViewState) -> String {
        var lines: [String] = []
        lines.append("#!/usr/bin/env xcrysden --tcl")
        lines.append("# mcrysden XCrySDen view-state script (documented flat-line subset)")
        lines.append(String(format: "set azimuth %g", state.azimuth))
        lines.append(String(format: "set elevation %g", state.elevation))
        lines.append(String(format: "set zoom %g", state.zoom))
        lines.append("set background top \(normalizeHex(state.backgroundTopHex) ?? state.backgroundTopHex)")
        lines.append("set background bottom \(normalizeHex(state.backgroundBottomHex) ?? state.backgroundBottomHex)")
        lines.append("set display cell \(state.showCell ? 1 : 0)")
        lines.append("set display bonds \(state.showBonds ? 1 : 0)")
        lines.append(String(format: "set atom_scale %g", state.atomScale))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Read an XCrySDen-style script and map its commands onto `base`.
    ///
    /// Returns the resulting view state (mutations applied sequentially, later
    /// wins) plus the list of lines that were NOT mapped. Returns `nil` only
    /// when the text is empty or contains zero mapped commands. Never traps.
    static func load(_ text: String, base: XcrysdenViewState) -> (state: XcrysdenViewState, skipped: [(line: Int, text: String)])? {
        var state = base
        var skipped: [(Int, String)] = []
        var mappedCount = 0

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for (index, raw) in normalized.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }
            if trimmed.contains("{") || trimmed.contains("}") {
                skipped.append((lineNumber, raw))
                continue
            }

            switch parseLine(raw) {
            case .quit, .unknown:
                skipped.append((lineNumber, raw))
            case .set(let field, let rawValue):
                if apply(field: field, rawValue: rawValue, to: &state) {
                    mappedCount += 1
                } else {
                    skipped.append((lineNumber, raw))
                }
            }
        }

        if mappedCount == 0 { return nil }
        return (state, skipped)
    }

    // MARK: - Private parse plumbing

    private enum Field {
        case azimuth, elevation, zoom, atomScale
        case backgroundTop, backgroundBottom
        case showCell, showBonds
    }

    private enum ParsedCommand {
        case set(Field, rawValue: String)
        case quit
        case unknown
    }

    /// Classify a key-token list (already lowercased, `-`→`_`, value stripped).
    private static func classifyKey(_ key: [String]) -> Field? {
        if key.count >= 2 {
            let two = key[0] + "_" + key[1]
            switch two {
            case "background_top", "bg_top": return .backgroundTop
            case "background_bottom", "bg_bottom": return .backgroundBottom
            case "display_cell", "show_cell": return .showCell
            case "display_bonds", "show_bonds": return .showBonds
            default: break
            }
        }
        switch key[0] {
        case "azimuth": return .azimuth
        case "elevation": return .elevation
        case "zoom", "zoom_factor": return .zoom
        case "background_top", "bg_top": return .backgroundTop
        case "background_bottom", "bg_bottom": return .backgroundBottom
        case "display_cell", "displaycell", "show_cell", "showcell": return .showCell
        case "display_bonds", "displaybonds", "show_bonds", "showbonds": return .showBonds
        case "atom_scale", "atomscale": return .atomScale
        default: return nil
        }
    }

    /// Split a token list on `=`: either an explicit `=` token or a `k=v` token.
    /// Returns nil when no `=` is present (caller then treats the last token as
    /// the value and the rest as the key).
    private static func splitEquals(_ tokens: [String]) -> (key: [String], value: String)? {
        if let eq = tokens.firstIndex(of: "=") {
            return (Array(tokens[..<eq]), tokens[(eq + 1)...].joined(separator: " "))
        }
        for (i, tok) in tokens.enumerated() {
            if let r = tok.firstIndex(of: "=") {
                let keyPart = String(tok[..<r])
                let valPart = String(tok[(tok.index(after: r))...])
                var key = Array(tokens[..<i])
                if !keyPart.isEmpty { key.append(keyPart) }
                return (key, valPart)
            }
        }
        return nil
    }

    /// Split a raw line into tokens, respecting double-quoted runs (quotes
    /// stripped), identical in behavior to `ScriptRunner.tokenize`.
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var ch = line.makeIterator()
        while let c = ch.next() {
            if inQuotes {
                if c == "\"" { inQuotes = false } else { current.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == " " || c == "\t" || c == "\r" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Parse a single non-blank, non-comment line into a command.
    private static func parseLine(_ raw: String) -> ParsedCommand {
        let toks = tokenize(raw.trimmingCharacters(in: .whitespaces))
        guard !toks.isEmpty else { return .unknown }
        var t = toks.map { $0.lowercased().replacingOccurrences(of: "-", with: "_") }

        if t.first == "quit" || t.first == "exit" { return .quit }
        if t.first == "set" { t.removeFirst() }
        guard !t.isEmpty else { return .unknown }

        let keyTokens: [String]
        let value: String
        if let (k, v) = splitEquals(t) {
            keyTokens = k
            value = v
        } else {
            guard t.count >= 2 else { return .unknown }
            keyTokens = Array(t.dropLast())
            value = t.last!
        }
        guard !keyTokens.isEmpty, let field = classifyKey(keyTokens) else { return .unknown }
        return .set(field, rawValue: value)
    }

    /// Apply a parsed field/value to the state. Returns false on parse failure
    /// (caller counts the line as skipped). Never traps.
    private static func apply(field: Field, rawValue: String, to state: inout XcrysdenViewState) -> Bool {
        switch field {
        case .azimuth:
            guard let v = parseFloat(rawValue) else { return false }; state.azimuth = v
        case .elevation:
            guard let v = parseFloat(rawValue) else { return false }; state.elevation = v
        case .zoom:
            guard let v = parseFloat(rawValue) else { return false }; state.zoom = v
        case .atomScale:
            guard let v = parseFloat(rawValue) else { return false }; state.atomScale = v
        case .backgroundTop:
            guard let hex = normalizeHex(rawValue) else { return false }; state.backgroundTopHex = hex
        case .backgroundBottom:
            guard let hex = normalizeHex(rawValue) else { return false }; state.backgroundBottomHex = hex
        case .showCell:
            guard let b = parseBool(rawValue) else { return false }; state.showCell = b
        case .showBonds:
            guard let b = parseBool(rawValue) else { return false }; state.showBonds = b
        }
        return true
    }

    private static func parseFloat(_ raw: String) -> Float? {
        // Reject NaN/Inf: a non-finite numeric field is a malformed input to be
        // skipped and reported, not applied.
        guard let v = Float(raw.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return v
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    /// Normalize `#RRGGBB`, `RRGGBB`, or `0xRRGGBB` to `#RRGGBB` (uppercase).
    /// Returns nil when the string is not a valid 6-digit hex color.
    private static func normalizeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let _ = UInt32(s, radix: 16) else { return nil }
        return "#" + s.uppercased()
    }
}
