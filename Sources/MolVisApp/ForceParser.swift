import Foundation
import simd

// Forces / stress / energy readouts from a QE PWscf `.out` (or `.pwo`) file. The
// parser reads the per-atom forces of the LAST complete SCF iteration (the one
// the user actually sees), the total force, the total energy, and — when present
// — the stress tensor. The result feeds `Scene.forceSet`; the renderer draws
// force arrows and a readout when it is present.

/// Forces, total force, energy, and optional stress parsed from the final SCF
/// iteration of a QE output.
struct ForceSet: Codable {
    /// Per-atom force vectors in eV/Å, parallel to Scene.atoms: `forces[i]`
    /// is the force on atom `i`, placed by the PRINTED atom index (`atom N`) so
    /// a malformed line can't shift forces onto the wrong atoms.
    var forces: [SIMD3<Float>]
    /// Total force magnitude reported by QE (convergence diagnostic), eV/Å. Optional: nil when the
    // file's force block prints no "Total force" line, so the UI can distinguish absent from zero.
    var totalForce: Float?
    /// Total energy of the final iteration, eV. Optional: nil when the file emits no
    // "total energy" line in the force block's iteration, distinguishing absent from zero.
    var totalEnergy: Float?
    /// Stress tensor in Ry/Bohr³ (3×3, row-major) if QE printed one, else nil.
    var stress: [SIMD3<Float>]?
    /// Number of force-bearing SCF iterations found in the file (informational).
    var nIterations: Int
}

enum ForceParser {
    /// Ry/au → eV/Å conversion: 1 Ry = 13.605693 eV, 1 au (Bohr) = 0.529177 Å,
    /// so 1 Ry/au = 13.605693 / 0.529177 eV/Å.
    static let ryPerAu_to_eVPerAng: Float = 13.605693 / 0.529177
    /// Ry → eV.
    static let ry_to_eV: Float = 13.605693

    /// Parse the `Forces acting on atoms` blocks of a QE `.out` and return a
    /// ForceSet for the final COMPLETE iteration. Returns nil if no complete
    /// force block is found. A block is complete only when its printed atom
    /// indices form exactly the contiguous range 1..N with no gaps and no
    /// duplicates — a truncated or shifted block is skipped so an earlier
    /// complete iteration is used instead of a misaligned final one.
    ///
    /// `atomCount`, when supplied, additionally requires the block to match the
    /// number of atoms in the structure (so a block that parses a subset is
    /// rejected). Optional because the parser is also exercised standalone.
    ///
    /// Frame mapping: in a relaxation the file alternates `ATOMIC_POSITIONS` (the
    /// geometry the C `parse_pwo` reads for each frame) with the `Forces acting on
    /// atoms` block printed after that step's SCF converged. So frame N's forces
    /// are the block within the window [geomStarts[N], geomStarts[N+1]). When
    /// `frameIndex` is supplied and geometry blocks exist, the parser selects the
    /// force block of THAT frame instead of the file's last one. Bands/single-point
    /// outputs (no per-step `ATOMIC_POSITIONS`) fall back to the last complete block.
    static func parse(_ text: String, frameIndex: Int? = nil, atomCount: Int? = nil) -> ForceSet? {
        let lines = text.components(separatedBy: "\n")
        // All force-block start lines in the file, in order.
        let forceStarts = lines.enumerated().compactMap { li, line -> Int? in
            line.contains("Forces acting on atoms") ? li : nil
        }
        guard !forceStarts.isEmpty else { return nil }
        // WHOLE-FILE block count (informational). Held locally, never as shared mutable state, so
        // concurrent parses of different files can't clobber each other's count: this call's count
        // is copied into totalIterations below before any value reaches the produced ForceSet.
        let totalIterations = forceStarts.count

        // Geometry (ATOMIC_POSITIONS) blocks index frames — same convention the C parse_pwo uses.
        let geomStarts = lines.enumerated().compactMap { li, line -> Int? in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("ATOMIC_POSITIONS") ? li : nil
        }
        // Helper: last COMPLETE force block whose header lies in [from, to). Returns the ForceSet,
        // the END line of its block (just past the Total force line) and the START line (its
        // Forces acting header), so the caller can pair energy/stress within THIS block's
        // boundaries. energyWinStart = start lets the energy search look BEFORE the block header.
        func bestIn(_ from: Int, _ to: Int) -> (fs: ForceSet, endLine: Int, start: Int)? {
            let lo = max(from, 0), hi = min(to, lines.count)
            let inWindow = forceStarts.filter { $0 >= lo && $0 < hi }
            for start in inWindow.reversed() {
                let blockEnd = forceStarts.first(where: { $0 > start }) ?? hi
                if let (fs, endLine) = parseBlock(lines, start: start, atomCount: atomCount,
                                                  nIterations: totalIterations, blockEnd: blockEnd) {
                    return (fs, endLine, start)
                }
            }
            return nil
        }

        // FRAME MAPPING. QE prints each ionic step's forces during/after its SCF. Two real ordering
        // conventions exist, so a single fixed rule fails one of them:
        //   (a) single-point / scf:          [geometry  ...  forces]            forces follow geom
        //   (b) relaxation (most common):   [[geom]  forces_k  [geom_{k+1}]]   forces precede next geom
        // We associate frame k with the force block in its forward window [geom[k], geom[k+1]).
        // The forward window works for (a) (single geom, forces after) and for (b) intermediate
        // frames. For the LAST frame in (b) the converged forces precede it, so the forward window
        // [geom_last, EOF) may be empty — in that case we return nil rather than borrow forces from
        // a different geometry (the backward window would give frame k-1's forces, which were
        // computed on a different set of atomic positions). Modes without geometry markers fall back
        // to the converged (last complete) block, matching BandParser's final-iteration convention.
        // Pair energy/stress with the accepted force block using its actual boundaries, so metadata
        // never crosses into a different iteration (P2 fix).
        func finish(_ result: (fs: ForceSet, endLine: Int, start: Int), _ fallbackBlockEnd: Int) -> ForceSet {
            var fs = result.fs
            // The stress search must not cross into a later (possibly rejected) iteration's
            // output. Bound it by the next Forces-acting header after the accepted block, so
            // a rejected later block's stress tensor is never a candidate.
            let stressEnd = forceStarts.first(where: { $0 > result.start }) ?? fallbackBlockEnd
            fillEnergyAndStress(lines, &fs, blockEnd: stressEnd,
                                stressWindowStart: result.endLine, energySearchEnd: result.start)
            return fs
        }
        if let fdx = frameIndex, !geomStarts.isEmpty, fdx >= 0, fdx < geomStarts.count {
            let gk = geomStarts[fdx]
            let nextGeom = (fdx + 1 < geomStarts.count) ? geomStarts[fdx + 1] : lines.count
            if let r = bestIn(gk, nextGeom) { return finish(r, nextGeom) }  // forward window
            return nil
        }
        // No frameIndex / no geometry markers: return the last complete block and pair its energy
        // (search backward from its start so the preceding total-energy line is found).
        if let r = bestIn(0, lines.count) { return finish(r, lines.count) }
        return nil
    }

    /// Float scan of a QE token run. Splits overflow-glued fields first (QE glues two
    /// adjacent `integer.decimal` fields when a magnitude overflows its column, e.g.
    /// "90.000000120.000000" = 90.000000 + 120.000000), then matches signed decimals.
    /// The split requires the boundary to follow a complete `digit.decimal` run and
    /// precede a new `integer.decimal`, so leading-dot decimals (".011.006") — which
    /// the standard pattern reads correctly already — are left untouched.
    private static func floats(in s: String) -> [Float] {
        let unglued = ForceParser.splitGluedFields(s)
        var out: [Float] = []
        let pattern = #"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = unglued as NSString
        for m in rx.matches(in: unglued, range: NSRange(location: 0, length: ns.length)) {
            if let v = Float(ns.substring(with: m.range)) { out.append(v) }
        }
        return out
    }

    /// Greedy regex float scan of an (already delimited) string.
    private static func greedyFloats(_ s: String) -> [Float] {
        let pattern = #"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return rx.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            Float(ns.substring(with: $0.range))
        }
    }

    /// Insert spaces at overflow-glue boundaries so each QE field parses as its own
    /// float. QE prints forces in fixed-width columns; when a magnitude overflows its
    /// column it glues to the next (e.g. `90.000000120.000000` = 90.000000 + 120.000000).
    /// The line is split on whitespace first; each whitespace-free token that the
    /// greedy scanner reads as 2+ jammed numbers is glued, and its canonical fractional
    /// width is derived FROM THAT TOKEN (so a clean trailing field of a different width
    /// does not distort the split). Clean tokens pass through untouched. Returns the
    /// string unchanged when it contains no glued fields (the usual case).
    private static func splitGluedFields(_ s: String) -> String {
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 1 else { return s }
        var out: [String] = []
        for tok in tokens {
            // A token read as 2+ numbers is glued; snap it to its own canonical width.
            if ForceParser.greedyFloats(tok).count >= 2, let w = ForceParser.uniformFracWidth(tok) {
                out.append(ForceParser.snapToWidth(tok, w))
            } else {
                out.append(tok)
            }
        }
        return out.joined(separator: " ")
    }

    /// Find the fractional width `w` whose repeated `sign? digits '.' digits{w}` parse
    /// consumes `tok` exactly, or nil if none fits (tried 1..16; QE uses <=10).
    private static func uniformFracWidth(_ tok: String) -> Int? {
        let chars = Array(tok)
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        for w in 1...16 {
            var pos = 0
            var ok = true
            while pos < chars.count {
                if chars[pos] == "+" || chars[pos] == "-" { pos += 1 }            // sign
                while pos < chars.count && isDigit(chars[pos]) { pos += 1 }      // integer part
                if pos >= chars.count || chars[pos] != "." { ok = false; break }  // dot
                pos += 1
                var placed = 0
                while placed < w && pos < chars.count && isDigit(chars[pos]) { pos += 1; placed += 1 }
                if placed != w { ok = false; break }
            }
            if ok && pos == chars.count { return w }
        }
        return nil
    }

    /// Re-tokenize a glued QE force string into space-separated fields of fractional
    /// width `w` (from `uniformFracWidth`). Leading/internal whitespace is normalized
    /// to single spaces, matching how the value substring after `force =` is consumed.
    private static func snapToWidth(_ tok: String, _ w: Int) -> String {
        let chars = Array(tok)
        var out = ""
        var pos = 0
        var first = true
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        while pos < chars.count {
            if !first { out.append(" ") }
            first = false
            if chars[pos] == "+" || chars[pos] == "-" { out.append(chars[pos]); pos += 1 }
            while pos < chars.count && isDigit(chars[pos]) { out.append(chars[pos]); pos += 1 }
            if pos < chars.count && chars[pos] == "." { out.append("."); pos += 1 }
            var placed = 0
            while placed < w && pos < chars.count && isDigit(chars[pos]) { out.append(chars[pos]); pos += 1; placed += 1 }
        }
        return out
    }

    /// Parse the integer atom index from the head of an atom force line, e.g.
    /// "atom   1 type  1   force =" -> 1. Returns nil if unparseable.
    private static func parseAtomIndex(_ line: String) -> Int? {
        guard let r = line.range(of: "atom") else { return nil }
        let tail = String(line[r.upperBound...])
        // The first integer token after "atom" is the printed index.
        let pattern = #"\d+"#
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length))
        else { return nil }
        return Int((tail as NSString).substring(with: m.range))
    }

    /// Parse a single force block. Returns nil if the block is malformed,
    /// incomplete (gaps/dupes in the printed indices), or — when atomCount is
    /// given — does not match the expected number of atoms. The caller then tries
    /// an earlier iteration. `nIterations` is the total block count for this file
    /// (passed explicitly, never read from shared state).
    private static func parseBlock(_ lines: [String], start: Int, atomCount: Int?,
                                   nIterations: Int, blockEnd: Int) -> (fs: ForceSet, endLine: Int)? {
        var i = start + 1
        // Skip blank lines after the header.
        while i < blockEnd, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        // Collect forces keyed by the PRINTED atom index: a malformed line (no
        // index or no "force =") is skipped WITHOUT consuming an index, so the
        // remaining indices stay aligned with the real atoms.
        var byIndex: [Int: SIMD3<Float>] = [:]
        while i < blockEnd {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.contains("Total force") { break }
            if !t.hasPrefix("atom") && !t.hasPrefix("prot") { break }
            guard let idx = parseAtomIndex(line) else { i += 1; continue }
            guard let eq = line.range(of: "force =") else { i += 1; continue }
            let nums = floats(in: String(line[eq.upperBound...]))
            guard nums.count >= 3 else { i += 1; continue }
            // A repeated index (atom 1; atom 2; atom 2) would silently overwrite
            // the earlier vector — reject the block so an earlier clean iteration
            // is used instead of one with an arbitrary duplicate value.
            if byIndex[idx] != nil { return nil }
            byIndex[idx] = SIMD3<Float>(nums[0], nums[1], nums[2]) * ryPerAu_to_eVPerAng
            i += 1
        }
        guard !byIndex.isEmpty else { return nil }
        // Completeness: the printed indices must be exactly 1..N, contiguous, no
        // gaps, no duplicates. A truncated final block fails this and is skipped.
        let maxIdx = byIndex.keys.max()!
        guard maxIdx == byIndex.count else { return nil }     // gap or dup shifts count
        for n in 1...maxIdx where byIndex[n] == nil { return nil }  // gap
        if let atomCount, maxIdx != atomCount { return nil }  // subset of the structure
        let forces = (1...maxIdx).map { byIndex[$0]! }

        // Save where the force-atom list ended, before the Total-force scan advances i.
        // When no Total force line exists, the scan would run to blockEnd and the
        // returned endLine = blockEnd would make the stress window empty, discarding any
        // valid stress tensor that follows the atom rows (P2 fix).
        let forceEnd = i

        // Total force line: "Total force =      .267804     Total SCF correction =      .002682".
        // Search only within THIS block (bounded by blockEnd) so a truncated block
        // can't borrow a later iteration's total. Track whether the line was FOUND (vs absent) so
        // the value can be optional: a missing line ⇒ nil (genuinely absent), even though a
        // well-converged structure legitimately reports totalForce ≈ 0.
        var totalForce: Float = 0
        var foundTotalForce = false
        while i < blockEnd {
            let line = lines[i]
            if line.contains("Total force") {
                foundTotalForce = true
                if let eqPos = line.range(of: "=") {
                    // First float strictly after the '=' is the total force.
                    totalForce = (floats(in: String(line[eqPos.upperBound...])).first ?? 0) * ryPerAu_to_eVPerAng
                }
                i += 1   // advance past the Total force line so endLine sits just beyond it
                break
            }
            i += 1
        }
        // endLine: when Total force was found, i is the line just past it (stress follows).
        // When absent, forceEnd is the blank/non-atom line where the atom list stopped, so
        // the stress window still covers any tensor printed after the last atom row.
        let endLine = foundTotalForce ? i : forceEnd
        // totalForce is nil unless a Total force line was actually present, so zero and absent
        // are distinguishable (P2 fix).
        let fs = ForceSet(forces: forces, totalForce: foundTotalForce ? totalForce : nil,
                          totalEnergy: nil, stress: nil, nIterations: nIterations)
        return (fs, endLine)   // endLine: past Total force (or forceEnd when absent)
    }

    /// Scans the text for the total energy ("!    total energy = ...") in Ry and
    /// any stress tensor block, and applies them to `fs`. Kept separate from
    /// parseBlock because energy/stress often precede or straddle the force blocks.
    ///
    /// `nearLine`, when supplied, is the line where the ACCEPTED force block
    /// starts; the energy most relevant to those forces is the last "total energy"
    /// at or before that position (QE prints `total energy` once per SCF cycle,
    /// alongside that cycle's forces). Searching backward from `nearLine` first
    /// pairs energy with its own iteration; only if none precedes the block do we
    /// fall back to the file's final energy. This keeps forces and energy from
    /// diverging when `parse` had to fall back to an earlier, complete block.
    static func fillEnergyAndStress(_ lines: [String], _ fs: inout ForceSet,
                                    blockEnd: Int, stressWindowStart: Int,
                                    energySearchEnd: Int) {
        // The accepted force block occupies [stressWindowStart, blockEnd) (stressWindowStart is
        // the line just past its Total force line). Both energy and stress belong to THIS single
        // iteration, so pair them strictly within its neighbors:
        //   - Energy: QE prints each iteration's `total energy` BEFORE that iteration's forces
        //     block. Searching backward from energySearchEnd (the accepted block's header line)
        //     finds the energy belonging to this block without crossing into a different cycle.
        //     The lower bound is the previous force-header line (or 0), so an earlier iteration's
        //     energy is never picked up.
        //   - Stress: search only [stressWindowStart, blockEnd) (see below), so a stress tensor
        //     printed before the NEXT iteration's force header is never attached to the current
        //     forces (P2 fix).
        func energyBefore(_ limit: Int, winStart: Int) -> Float? {
            for li in stride(from: min(limit, lines.count - 1), through: max(winStart, 0), by: -1) {
                let low = lines[li].lowercased()
                if low.contains("total energy") && low.contains("ry") {
                    if let e = floats(in: lines[li]).first { return e }
                }
            }
            return nil
        }
        let prevForceHeader = (0..<energySearchEnd).reversed().first { lines[$0].contains("Forces acting on atoms") } ?? -1
        if let e = energyBefore(energySearchEnd - 1, winStart: prevForceHeader + 1) {
            fs.totalEnergy = e * ry_to_eV
        }
        fs.stress = parseStress(lines, nearLine: stressWindowStart, blockEnd: blockEnd)
        // nIterations was passed explicitly into parseBlock(fs.nIterations); do NOT
        // clobber it with the static nIterationsStored here, or a concurrent parse of
        // another file would leak its count into this result.
    }

    /// A candidate stress tensor together with the file line it occupies, so the
    /// one nearest the accepted force block can be selected.
    private struct StressCand {
        var line: Int
        var tensor: [SIMD3<Float>]
    }

    /// Try to read a symmetric 3×3 stress tensor (row-major, Ry/Bohr³) from the
    /// QE-style output. Candidates are collected from the CONTIGUOUS output
    /// immediately following the accepted force block (starting at nearLine). The
    /// scan stops at the first structural boundary — a non-blank, non-stress line
    /// that isn't part of an active s( run — so a stress tensor printed before a
    /// later (possibly rejected) iteration's force header is never reached. Returns
    /// nil if no tensor is found in the contiguous region.
    private static func parseStress(_ lines: [String], nearLine: Int, blockEnd: Int) -> [SIMD3<Float>]? {
        let end = min(blockEnd, lines.count)
        var cands: [StressCand] = []

        // (a) Labelled "s(i j)=" rows — consecutive runs of three form one tensor.
        //     Scan CONTIGUOUSLY from nearLine, stopping at the first structural
        //     boundary. This replaces the old all-lines scan + inWindow() filter so
        //     that s( rows from a later (rejected) iteration — separated from the
        //     accepted block by SCF output or other content — are never collected.
        var run: [(Int, [Float])] = []
        var li = nearLine
        while li < end {
            let t = lines[li].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("s("), let eq = t.range(of: ")=") {
                let nums = floats(in: String(t[eq.upperBound...]))
                if nums.count >= 3 { run.append((li, Array(nums.prefix(3)))) }
                li += 1
                continue
            }
            if !run.isEmpty {
                if run.count >= 3 {
                    let tensor = run.prefix(3).map { SIMD3<Float>($0.1[0], $0.1[1], $0.1[2]) }
                    cands.append(StressCand(line: run[2].0, tensor: tensor))
                }
                run.removeAll()
                // After a completed s( run, a blank line is still part of the stress
                // region (QE may separate two tensors with one). A non-blank line that
                // isn't a stress header or another s( run is a structural boundary.
                if !t.isEmpty && !t.lowercased().contains("stress") { break }
            }
            // Before any s( run: skip blanks, stop at non-blank non-stress content.
            if t.isEmpty { li += 1; continue }
            if !t.lowercased().contains("stress") { break }
            li += 1
        }
        if run.count >= 3 {
            let tensor = run.prefix(3).map { SIMD3<Float>($0.1[0], $0.1[1], $0.1[2]) }
            cands.append(StressCand(line: run[2].0, tensor: tensor))
        }

        // (b) three UNLABELLED numeric rows right after a stress header.
        // (c) six-float inline summary on the header line itself.
        // Both forms are only collected when their header line falls within the
        // contiguous region we scanned (nearLine ..< li).
        let scannedEnd = li   // where the contiguous scan stopped
        for (hi, hdr) in lines.enumerated() where hi >= nearLine && hi < scannedEnd {
            let low = hdr.lowercased()
            // (b) unlabelled rows after a stress header
            if low.contains("stress") && low.contains("ry/bohr") {
                var out: [[Float]] = []
                for k in (hi + 1)..<min(hi + 5, end) {
                    let tk = lines[k].trimmingCharacters(in: .whitespaces)
                    if tk.hasPrefix("s(") { continue }
                    if tk.isEmpty { continue }
                    let nums = floats(in: lines[k])
                    guard nums.count >= 3 else { break }
                    out.append(Array(nums.prefix(3)))
                    if out.count == 3 { break }
                }
                if out.count == 3 {
                    cands.append(StressCand(line: hi, tensor: out.map { SIMD3<Float>($0[0], $0[1], $0[2]) }))
                }
            }
            // (c) six-float inline summary
            if low.contains("total") && low.contains("stress") && low.contains("ry/bohr"),
               let eq = hdr.range(of: "=") {
                let nums = floats(in: String(hdr[eq.upperBound...]))
                if nums.count >= 6 {
                    let (xx, yy, zz, xy, xz, yz) = (nums[0], nums[1], nums[2], nums[3], nums[4], nums[5])
                    cands.append(StressCand(line: hi, tensor: [
                        SIMD3(xx, xy, xz), SIMD3(xy, yy, yz), SIMD3(xz, yz, zz)
                    ]))
                }
            }
        }
        guard !cands.isEmpty else { return nil }
        // Prefer the candidate closest to nearLine.
        cands.sort { abs($0.line - nearLine) < abs($1.line - nearLine) }
        return cands[0].tensor
    }
}
