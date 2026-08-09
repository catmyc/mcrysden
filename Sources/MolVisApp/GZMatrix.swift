import Foundation
import simd

/// Thread-local diagnostic set on a Z-matrix parse failure. `parse` returns nil
/// on any malformed input and records a short reason here; the bridge surfaces it
/// via `ParseError`. Not thread-safe across concurrent parses, but mcrysden parses
/// one file at a time.
internal enum GZMatrixError {
    static let key = "mcrysden_gzmatrix_error"
    static func clear() { Thread.current.threadDictionary[key] = nil }
    static func set(_ message: String) { Thread.current.threadDictionary[key] = message }
    static func get() -> String? { Thread.current.threadDictionary[key] as? String }
}

/// Reader for Gaussian-style Z-matrix inputs (`.gzmat`, `.zmat`) — the format
/// XCrySDen opens through OpenBabel. Internal coordinates (bond length, valence
/// angle, dihedral) are converted to Cartesian Ångström here, natively.
///
/// Supported dialect
/// -----------------
/// ```
/// #Put Keywords Here             <- optional route/comment line ('#' or '!')
///
/// water                          <- optional title line
///
/// 0  1                           <- optional charge/multiplicity (two ints)
/// O
/// H  1  r2
/// H  1  r3  2  a3
///
/// Variables:                     <- section labels are ignored
/// r2= 0.9600
/// r3= 0.9600
/// a3= 104.5000
/// ```
/// * A coordinate row is `<symbol> [ref bond [ref angle [ref dihedral [flag]]]]`.
///   Each `ref` is a 1-based row index (counting dummy rows); `0` or `-` means
///   "not defined" and is only meaningful for the first rows.
/// * Bond/angle/dihedral fields are either numeric literals or variable names,
///   optionally negated (`-a3`). Variable names are case-insensitive and may be
///   defined *before or after* the coordinate block (OpenBabel writes them
///   after); a pre-pass collects `name = value`, `name= value` and `name value`.
/// * Element symbols may carry a trailing tag (`C1`, `H12`); the alphabetic
///   prefix is used for lookup. Dummy centres `X` / `Bq` (with optional tag) are
///   placed and usable as references, but are not emitted as atoms.
/// * Units follow the Gaussian defaults: Ångström and degrees.
///
/// Simplifications
/// ---------------
/// * Only the dihedral convention is supported. A trailing field after the
///   dihedral must be `0`; Gaussian's `1` variant (second valence angle plus a
///   chirality sign) is rejected rather than mis-built.
/// * No route-section parsing: keywords, `ModRedundant`, basis sets, `@`
///   includes, `Opt=Z-matrix` variable/constant distinctions, and multi-job
///   `--Link1--` files are ignored (only the first coordinate block is read).
/// * Cartesian-in-Gaussian-input files (symbol + three floats) are not this
///   reader's job; such rows have no reference indices and are rejected.
/// * Output is a molecule: no cell, no bonds (bonding is a downstream heuristic).
///
/// Failure is always `nil` — malformed user files must never trap.
enum GZMatrixParser {
    /// Parse Gaussian Z-matrix text into Cartesian atoms (Å), or nil when the
    /// text is not a Z-matrix. Never traps. Result has no cell (molecule).
    static func parse(_ text: String) -> [Atom]? {
        GZMatrixError.clear()
        guard !text.isEmpty else { GZMatrixError.set("empty input"); return nil }
        guard text.count <= maxCharacters else { GZMatrixError.set("input exceeds \(maxCharacters) chars"); return nil }

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
            .map { stripComment(String($0)) }
        guard lines.count <= maxLines else { GZMatrixError.set("input exceeds \(maxLines) lines"); return nil }

        let variables = collectVariables(lines)
        let candidates = lines.map { line -> Row? in
            let tokens = tokenize(line)
            return tokens.isEmpty ? nil : parseRow(tokens)
        }

        // Locate the single coordinate block. Everything before it (route line,
        // title, charge/multiplicity) is skipped; everything after it only
        // contributes variable definitions, already collected above.
        //
        // A block starts at a reference-free row that is *immediately* followed
        // by a row with references — the lookahead is what keeps a title such as
        // "CO2" from being mistaken for a first atom. A lone reference-free row
        // is the single-atom fallback.
        var start: Int?
        var fallback: Int?
        for (i, row) in candidates.enumerated() {
            guard let row, row.refs.isEmpty else { continue }
            fallback = i   // last standalone row wins: a title like "CO2" lexes
                           // as an element but precedes the real first atom
            if i + 1 < candidates.count, let next = candidates[i + 1], !next.refs.isEmpty {
                start = i
                break
            }
        }
        guard let begin = start ?? fallback else {
            GZMatrixError.set("no coordinate block found")
            return nil
        }

        var rows: [Row] = []
        for i in begin..<candidates.count {
            guard let row = candidates[i] else {
                // A line that is shaped like a coordinate row but failed to
                // parse (unknown element, unsupported dihedral flag, bad field,
                // or a non-finite value) must fail the whole file rather than
                // silently truncate it: a bad row here leaves later rows
                // unparsed, so abort loudly with a line-scoped diagnostic.
                if looksLikeRow(tokenize(lines[i])) {
                    GZMatrixError.set("malformed coordinate row at line \(i + 1)")
                    return nil
                }
                break                                           // blank / section label ends the block
            }
            if i > begin, row.refs.isEmpty { break }            // a second origin ends the block
            rows.append(row)
            guard rows.count <= maxRows else {
                GZMatrixError.set("coordinate block exceeds \(maxRows) rows")
                return nil
            }
        }
        guard !rows.isEmpty else {
            GZMatrixError.set("no coordinate rows in block")
            return nil
        }

        guard let built = build(rows, variables: variables) else {
            GZMatrixError.set(GZMatrixError.get() ?? "internal-coordinate conversion failed")
            return nil
        }
        return built
    }

    // MARK: - Limits

    private static let maxCharacters = 100_000
    private static let maxLines = 10_000
    private static let maxRows = 10_000
    private static let maxAtoms = 1_000

    // MARK: - Row model

    /// One coordinate line: the element (or dummy) plus up to three
    /// (reference row, internal-coordinate value) pairs, in Z-matrix order.
    private struct Row {
        var atomicNumber: Int      // 0 for a dummy centre (X / Bq)
        var label: String
        var isDummy: Bool
        var refs: [Int]            // 0-based row indices, count == values.count
        var values: [Field]
    }

    /// A bond/angle/dihedral field: literal number or (possibly negated) variable.
    private enum Field {
        case literal(Double)
        case variable(String, negated: Bool)
    }

    // MARK: - Lexing

    /// Drop Gaussian comments (`!` to end of line) and normalize `=` and CR.
    private static func stripComment(_ line: String) -> String {
        var s = line
        if let bang = s.firstIndex(of: "!") { s = String(s[s.startIndex..<bang]) }
        s = s.replacingOccurrences(of: "\r", with: " ")
        s = s.replacingOccurrences(of: "=", with: " = ")
        s = s.replacingOccurrences(of: ",", with: " ")
        return s
    }

    /// Whitespace-split, dropping the `=` separator so `r2= 0.96`, `r2 = 0.96`
    /// and `r2 0.96` all lex to `["r2", "0.96"]`.
    private static func tokenize(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { $0 != "=" }
    }

    // MARK: - Variables

    /// Pre-pass over every line: a two-token line whose first token starts with
    /// a letter and whose second token is a number is a variable definition.
    /// Coordinate rows never have exactly two tokens, so this is unambiguous.
    private static func collectVariables(_ lines: [String]) -> [String: Double] {
        var table: [String: Double] = [:]
        for line in lines {
            let tokens = tokenize(line)
            guard tokens.count == 2,
                  let first = tokens[0].first, first.isLetter,
                  let value = Double(tokens[1]), value.isFinite else { continue }
            let name = tokens[0].lowercased()
            if table[name] == nil { table[name] = value }   // first definition wins
        }
        return table
    }

    private static func resolve(_ field: Field, _ variables: [String: Double]) -> Double? {
        switch field {
        case .literal(let v):
            return v.isFinite ? v : nil
        case .variable(let name, let negated):
            guard let v = variables[name], v.isFinite else { return nil }
            return negated ? -v : v
        }
    }

    // MARK: - Row parsing

    /// A reference field: 1-based row index, or `0` / `-` for "none".
    private static func reference(_ token: String) -> Int?? {
        if token == "-" { return Int??.some(nil) }
        guard let index = Int(token) else { return nil }
        if index == 0 { return Int??.some(nil) }
        guard index > 0 else { return nil }
        return .some(index)
    }

    private static func value(_ token: String) -> Field? {
        if let v = Double(token) { return v.isFinite ? .literal(v) : nil }
        var name = token
        var negated = false
        if name.hasPrefix("-") { negated = true; name.removeFirst() }
        else if name.hasPrefix("+") { name.removeFirst() }
        guard let first = name.first, first.isLetter,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return .variable(name.lowercased(), negated: negated)
    }

    /// Split a symbol token into its alphabetic prefix ("C1" -> "C").
    private static func elementSymbol(_ token: String) -> String? {
        let prefix = String(token.prefix(while: { $0.isLetter }))
        guard !prefix.isEmpty else { return nil }
        // Reject tags that are not symbol-shaped ("water", "Variables").
        guard prefix.count <= 3 else { return nil }
        return prefix
    }

    /// True when a line has the shape of a coordinate row (`symbol ref ...`)
    /// even if it fails to parse — used to distinguish "the block ended" from
    /// "the block contains something this reader must not silently drop".
    private static func looksLikeRow(_ tokens: [String]) -> Bool {
        guard tokens.count >= 3, elementSymbol(tokens[0]) != nil else { return false }
        return tokens[1] == "-" || Int(tokens[1]) != nil
    }

    private static func parseRow(_ tokens: [String]) -> Row? {
        guard let symbol = elementSymbol(tokens[0]) else { return nil }
        let upper = symbol.uppercased()
        let isDummy = (upper == "X" || upper == "BQ")
        let z = isDummy ? 0 : ElementTable.atomicNumber(symbol)
        guard isDummy || z > 0 else { return nil }

        var refs: [Int] = []
        var values: [Field] = []
        var index = 1
        while index + 1 < tokens.count, refs.count < 3 {
            guard let maybeRef = reference(tokens[index]) else { return nil }
            guard let ref = maybeRef else {
                // "0"/"-" placeholder: consume the (ignored) paired value.
                guard value(tokens[index + 1]) != nil else { return nil }
                index += 2
                continue
            }
            guard let field = value(tokens[index + 1]) else { return nil }
            refs.append(ref - 1)
            values.append(field)
            index += 2
        }

        // Optional trailing dihedral-type flag; only the dihedral convention (0)
        // is supported, and only after a full three-reference row.
        if index < tokens.count {
            guard refs.count == 3, index == tokens.count - 1,
                  let flag = Int(tokens[index]), flag == 0 else { return nil }
            index += 1
        }
        guard index == tokens.count else { return nil }

        let label = isDummy ? upper.capitalized : ElementTable.symbol(z)
        return Row(atomicNumber: z, label: label, isDummy: isDummy, refs: refs, values: values)
    }

    // MARK: - Internal -> Cartesian

    private static func build(_ rows: [Row], variables: [String: Double]) -> [Atom]? {
        var positions: [SIMD3<Double>] = []     // includes dummy centres
        positions.reserveCapacity(rows.count)
        var atoms: [Atom] = []

        for (i, row) in rows.enumerated() {
            // Every reference must point at an already-placed, in-range row.
            for ref in row.refs where ref < 0 || ref >= i { return nil }
            guard Set(row.refs).count == row.refs.count else { return nil }

            var params: [Double] = []
            for field in row.values {
                guard let v = resolve(field, variables) else { return nil }
                params.append(v)
            }

            let position: SIMD3<Double>
            switch row.refs.count {
            case 0:
                guard i == 0 else { return nil }
                position = .zero
            case 1:
                let a = positions[row.refs[0]]
                position = a + SIMD3(params[0], 0, 0)
            case 2:
                position = place(a: positions[row.refs[0]], b: positions[row.refs[1]], c: nil,
                                 r: params[0], theta: params[1], phi: 0)
            default:
                position = place(a: positions[row.refs[0]], b: positions[row.refs[1]],
                                 c: positions[row.refs[2]],
                                 r: params[0], theta: params[1], phi: params[2])
            }
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
            positions.append(position)

            if !row.isDummy {
                guard atoms.count < maxAtoms else { return nil }
                atoms.append(Atom(coord: SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z)),
                                  atomicNumber: row.atomicNumber, label: row.label))
            }
        }

        return atoms.isEmpty ? nil : atoms
    }

    /// Natural-extension reference frame: place a point at distance `r` from
    /// `a`, subtending angle `theta` (degrees) at `a` with `b`, and dihedral
    /// `phi` (degrees) about the b→a axis measured from the (c, b, a) plane.
    /// With `c == nil` an arbitrary but deterministic plane is used, which is
    /// how the third Z-matrix row lands in the xy-plane.
    private static func place(a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>?,
                              r: Double, theta: Double, phi: Double) -> SIMD3<Double> {
        let t = theta * .pi / 180
        let p = phi * .pi / 180
        let u = unit(a - b) ?? SIMD3(1, 0, 0)
        var normal = c.flatMap { unit(cross(b - $0, u)) }
        if normal == nil { normal = perpendicular(u) }
        let n = normal ?? SIMD3(0, 0, 1)
        let v = cross(n, u)   // unit: n ⟂ u and both normalized
        return a + u * (-r * cos(t)) + v * (r * sin(t) * cos(p)) + n * (r * sin(t) * sin(p))
    }

    private static func unit(_ v: SIMD3<Double>) -> SIMD3<Double>? {
        let n = simd_length(v)
        guard n > 1e-12, n.isFinite else { return nil }
        return v / n
    }

    /// Any unit vector orthogonal to `v` (assumed normalized), chosen so the
    /// result is deterministic and never degenerate.
    private static func perpendicular(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let axis: SIMD3<Double> = abs(v.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        return unit(cross(v, axis)) ?? SIMD3(0, 0, 1)
    }
}
