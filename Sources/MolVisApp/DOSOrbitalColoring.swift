import AppKit

/// Classifies DOS series labels into an orbital character (s/p/d/f) and maps
/// them to a fixed orbital palette; falls back to the caller's palette by index.
enum DOSOrbitalColoring {
    /// Fixed per-orbital colors: s blue, p red, d green, f purple.
    static let orbitalPalette: [NSColor] = [
        .systemBlue, .systemRed, .systemGreen, .systemPurple
    ]

    /// 's', 'p', 'd', or 'f' when the label contains that exact single-letter
    /// orbital token; nil otherwise. Tokens are matched WORD-wise: split the
    /// lowercased label on non-letter characters and require a token equal to
    /// exactly one of "s","p","d","f". The LAST such token wins, because QE projwfc
    /// labels are "<Species> <orbital>" and single-letter element symbols (S, P, F
    /// for sulfur, phosphorus, fluorine) are themselves in "spdf": "S p" -> "p", "F s"
    /// -> "s", "P d" -> "d". "pdos up" -> nil (token "pdos"), "Fe s" -> "s",
    /// "p up" -> "p", "sp" -> nil (length 2). Deterministic and testable.
    static func orbitalCharacter(of label: String) -> Character? {
        let tokens = label.lowercased().split(whereSeparator: { !$0.isLetter })
        var match: Character? = nil
        for token in tokens where token.count == 1 {
            let c = token.first!
            if "spdf".contains(c) { match = c }
        }
        return match
    }

    /// Fixed per-orbital colors: s blue, p red, d green, f purple. When
    /// orbitalCharacter(of:) is nil, returns palette[index % palette.count].
    static func color(for label: String, index: Int, palette: [NSColor]) -> NSColor {
        if let c = orbitalCharacter(of: label) {
            let idx: Int
            switch c {
            case "s": idx = 0
            case "p": idx = 1
            case "d": idx = 2
            default: idx = 3                // "f"
            }
            return orbitalPalette[idx]
        }
        guard !palette.isEmpty else { return .labelColor }
        return palette[index % palette.count]
    }
}
