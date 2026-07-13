import Foundation
import simd

// Quantum-EPWscf BAND structure: k-points + eigenvalues parsed from a PWscf
// `.out` (or bands-output) file. The result feeds the 2D Grapher that draws the
// band structure. This is the Tier A #5 keystone — once bands are parsed, the
// reader also underpins the (deferred) Tier B DOS.

/// One k-point along the path: fractional coords (`k`), a optional high-symmetry
/// label (e.g. "Γ","X","M"), and the per-band eigenvalues at this k in eV.
struct BandKPoint: Codable {
    let k: SIMD3<Float>
    /// Integration weight `wk` from the QE k-point list, when present. Used only to
    /// detect uniform-weight sampling meshes (all equal -> likely a Monkhorst-Pack
    /// grid, not a band path); the band energies do not depend on it.
    let weight: Float
    let label: String
    var energies: [Float]   // eV, per band index
}

/// A parsed band structure. `bands[ib][ik]` = energy of band ib at k-point ik.
/// `kDistances` is the cumulative path length, used as the x-coordinate of the
/// Grapher.
struct BandStructure: Codable {
    var kPoints: [BandKPoint]
    /// Fermi energy in eV, when the calculation reports one (metallic). Insulating
    /// outputs report highest-occupied/lowest-unoccupied levels instead, leaving
    /// this nil -> the grapher omits the Fermi line rather than forging a 0 eV line.
    var fermiEnergy: Float?
    var nSpin: Int
    /// Reciprocal lattice vectors b1,b2,b3 (rows, units of 2π/a_0) parsed from the
    /// QE output.
    var reciprocal: [SIMD3<Float>]?
    /// Whether the k-points are crystal (fractional) coordinates. When false
    /// (cartesian, in units of 2π/a_0, as the QE header labels them), `kDistances`
    /// use plain Euclidean length; when true, the reciprocal metric converts each
    /// fractional step to a physical length. Detected from the k-point list header
    /// of the SELECTED iteration (not the whole file). Default false: a cartesian
    /// file mis-read as crystal would be double-transformed, so err on the side of
    /// NOT applying the metric when uncertain.
    var kPointsAreCrystal: Bool = false
    /// Number of k-points per spin channel. For a spin-polarized (nSpin=2) QE
    /// output, each channel's k-points are concatenated in `kPoints`; the grapher
    /// renders them as separate, unconnected sub-paths. 1 for spinless output.
    var kPointsPerSpin: Int
    /// True when all k-points carry the same integration weight — the signature of
    /// a uniform Monkhorst-Pack sampling mesh. The grapher renders such data as
    /// disconnected points (a mesh is not a band path and must not be connected).
    var isMesh: Bool = false

    /// Number of bands (assume uniform across k-points).
    var nBands: Int { kPoints.first?.energies.count ?? 0 }
    var nKPoints: Int { kPoints.count }

    /// Cumulative path distance for each k-point (x-axis of the band plot).
    ///
    /// For CRYSTAL k-points (fractional) with reciprocal vectors present, this is
    /// the PHYSICAL distance: each fractional step `dk` is mapped to Cartesian via
    /// B = [b1 b2 b3] and |B·dk| = sqrt(dk^T G dk) is accumulated. For CARTESIAN
    /// k-points (the common case, as the QE header labels them) the steps are
    /// already in physical units (2π/a_0), so plain Euclidean |dk| is correct and
    /// applying the metric again would double-transform the coordinates. Without
    /// reciprocal vectors, fall back to plain Euclidean length regardless.
    var kDistances: [Float] {
        // Reciprocal-metric tensor G_ij = b_i·b_j; |B·dk| = sqrt(dk^T G dk).
        var G: simd_float3x3?
        if kPointsAreCrystal, let b = reciprocal, b.count == 3 {
            let c0 = b[0], c1 = b[1], c2 = b[2]
            G = simd_float3x3(rows: [
                SIMD3(dot(c0, c0), dot(c0, c1), dot(c0, c2)),
                SIMD3(dot(c1, c0), dot(c1, c1), dot(c1, c2)),
                SIMD3(dot(c2, c0), dot(c2, c1), dot(c2, c2)),
            ])
        }
        // Distances are computed PER SPIN CHANNEL: a spin-polarized output repeats
        // each k-point for spin-up then spin-down, and we must not accumulate a
        // spurious step across the boundary between channels.
        let n = kPointsPerSpin
        guard n > 0 else { return .init(repeating: 0, count: kPoints.count) }
        // First channel starts at 0; each subsequent channel restarts at 0 too.
        var d: [Float] = .init(repeating: 0, count: kPoints.count)
        for s in 0..<nSpin {
            let base = s * n
            for i in (base + 1)..<(base + n) {
                let dk = kPoints[i].k - kPoints[i - 1].k
                let step: Float
                if let G {
                    step = sqrt(simd_dot(dk, G * dk))
                } else {
                    step = sqrt(dot(dk, dk))
                }
                d[i] = d[i - 1] + step
            }
        }
        return d
    }

    /// energy(ib, ik) convenience accessor.
    func energy(band ib: Int, k ik: Int) -> Float { kPoints[ik].energies[ib] }
}

/// Parse QE PWscf `bands (ev):` sections from a plain-text `.out` file into a
/// BandStructure. Tolerant of the wrapped multi-column eigenvalue layout. Returns
/// nil if no band data is found (caller falls back to the structure parser).
///
/// A bands calculation usually reports several SCF iterations in one file, each
/// with its own k-points and Fermi energy. Concatenating them yields a physically
/// meaningless path (distinct iterations connected end-to-end), so we split the
/// file into per-iteration blocks and keep ONLY the final complete iteration.
/// Iterations are delimited by the "the Fermi energy is ..." line that QE prints
/// at the end of each; the Fermi energy of the selected iteration is parsed from
/// that line rather than fabricated.
enum BandParser {
    static func parse(_ text: String) -> BandStructure? {
        let lines = text.components(separatedBy: "\n")
        // Reciprocal lattice vectors, if present, for crystal-coordinate metric.
        let reciprocal = parseReciprocal(text)

        // The k-point LIST (with weights + coordinate system) is printed ONCE at the
        // top of a QE bands output and applies to every iteration that follows, so its
        // metadata is captured globally — not per iteration (which would lose it for
        // the final selected iteration, since later iterations don't reprint it).
        var globalWeights: [Float] = []
        var globalKListCount = 0
        var globalIsCrystal = false
        func ingestKPointListHeader(_ headerLineIdx: Int) {
            // Scan the few lines after "number of k points=" for the coord label.
            for off in 1...3 {
                let idx = headerLineIdx + off
                guard idx < lines.count else { break }
                let low = lines[idx].lowercased()
                if low.contains("cryst. coord") || low.contains("crystal") { globalIsCrystal = true; break }
                if low.contains("cart. coord") { globalIsCrystal = false; break }
            }
        }

        // Per-iteration accumulator: just k-points, eig-block count, and Fermi energy.
        struct Iter {
            var kPoints: [BandKPoint] = []
            var eigBlockCount = 0
            var fermi: Float? = nil
        }
        var iterations: [Iter] = []
        var cur = Iter()
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("number of k points") {
                ingestKPointListHeader(i)
                i += 1; continue
            }
            if isIterationBoundary(line) {
                cur.fermi = parseFermiEnergy(line)
                if !cur.kPoints.isEmpty { iterations.append(cur) }
                cur = Iter()
                i += 1; continue
            }
            if isKPointListHeader(line) {
                if let w = parseWeight(line) { globalWeights.append(w) }
                globalKListCount += 1
                i += 1; continue
            }
            guard let k = parseKHeader(line) else { i += 1; continue }
            // Eigenvalue block. Its weight is the k-list weight for the corresponding
            // unique k-point (modulo the k-list count, since spin-polarized output
            // repeats each k-point's block once per spin channel).
            cur.eigBlockCount += 1
            let widx = globalKListCount > 0 ? (cur.eigBlockCount - 1) % globalKListCount : -1
            let weight = widx >= 0 && widx < globalWeights.count ? globalWeights[widx] : 0
            i += 1
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            var energies: [Float] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isIterationBoundary(t) { break }
                if parseKHeader(t) != nil { break }
                var row: [Float] = []
                for s in t.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    if let v = Float(s) { row.append(v) }
                }
                if row.isEmpty { break }
                energies.append(contentsOf: row)
                i += 1
            }
            if !energies.isEmpty {
                cur.kPoints.append(BandKPoint(k: k, weight: weight, label: "", energies: energies))
            }
        }
        // Choose the final complete iteration; a file with no boundary lines is one
        // iteration whose Fermi energy is unavailable (nil).
        var chosen = Iter()
        if iterations.isEmpty {
            chosen = cur
        } else {
            chosen = iterations.last!
        }
        guard !chosen.kPoints.isEmpty else { return nil }

        // Spin channels: a spin-polarized run prints each unique k-point's eigenvalue
        // block once per spin, so per-iteration eigBlockCount = nSpin * kListCount.
        // When kListCount is 0 (no k-list parsed) assume a single channel.
        let nSpin: Int
        let kPointsPerSpin: Int
        if globalKListCount > 0 && chosen.eigBlockCount % globalKListCount == 0 {
            nSpin = chosen.eigBlockCount / globalKListCount
            kPointsPerSpin = globalKListCount
        } else {
            nSpin = 1
            kPointsPerSpin = chosen.kPoints.count
        }

        // Uniform-weight k-points are a Monkhorst-Pack sampling mesh, not an ordered
        // band path: connecting them is physically meaningless, so flag for scatter.
        let isMesh = detectUniformMesh(globalWeights)

        // Deduce the band count from the MODE (most common length), and drop any
        // k-point whose record does NOT match it. Zero-padding short records would
        // fabricate bands that were never computed and distort the Fermi region.
        let counts = chosen.kPoints.map { $0.energies.count }
        let bandCount = modalValue(counts) ?? counts.max() ?? 0
        let filtered = chosen.kPoints.filter { $0.energies.count == bandCount }
        guard !filtered.isEmpty else { return nil }
        return BandStructure(kPoints: filtered, fermiEnergy: chosen.fermi, nSpin: nSpin,
                             reciprocal: reciprocal, kPointsAreCrystal: globalIsCrystal,
                             kPointsPerSpin: kPointsPerSpin, isMesh: isMesh)
    }

    /// True if every weight is (within tolerance) the same value — the hallmark of
    /// a uniform Monkhorst-Pack sampling mesh rather than a band path.
    private static func detectUniformMesh(_ weights: [Float]) -> Bool {
        guard weights.count > 1 else { return false }
        let first = weights[0]
        return weights.allSatisfy { abs($0 - first) < 1e-4 }
    }

    /// True if `line` terminates a band-iteration block: the metallic Fermi-energy
    /// line, or an insulating occupation-summary line (highest occupied / lowest
    /// unoccupied) that QE prints in its place.
    private static func isIterationBoundary(_ line: String) -> Bool {
        if parseFermiEnergy(line) != nil { return true }
        let lower = line.lowercased()
        return lower.contains("highest occupied") || lower.contains("lowest unoccupied")
    }

    /// The full-precision k-point LIST lines `k( N) = (...), wk = ...` are not
    /// eigenvalue blocks — skip them so they are not mistaken for k-headers.
    private static func isKPointListHeader(_ line: String) -> Bool {
        line.contains("k(") && line.contains("wk =")
    }

    /// Parse the integration weight `wk` from a k-list line
    /// `k( N) = ( ... ), wk = W`. Returns nil if absent/malformed.
    private static func parseWeight(_ line: String) -> Float? {
        guard let wkRange = line.range(of: "wk =") else { return nil }
        let after = String(line[wkRange.upperBound...])
        return after.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.flatMap { Float($0) }
    }

    /// Detect whether the k-point list is in crystal (fractional) or cartesian
    /// coordinates, from the header line QE prints above the `k( N) = ...` list.
    /// "cryst. coord." -> crystal; "cart. coord." -> cartesian. If the label is
    /// absent, assume cartesian (the common case) to avoid a double transform.
    private static func detectKPointCoordSystem(_ text: String) -> Bool {
        // Find the "number of k points=" header, then scan the few lines right
        // after it for the coordinate-system label.
        let lines = text.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { $0.contains("number of k points") }) else { return false }
        for off in 1...3 {
            let idx = marker + off
            guard idx < lines.count else { break }
            let low = lines[idx].lowercased()
            if low.contains("cryst. coord") || low.contains("crystal") { return true }
            if low.contains("cart. coord") || low.contains("cartesian") { return false }
        }
        return false
    }

    /// Parse the reciprocal lattice vectors b1..b3 from the QE "reciprocal axes"
    /// block (in units of 2π/a_0). Returns nil if the block is absent/malformed.
    private static func parseReciprocal(_ text: String) -> [SIMD3<Float>]? {
        let lines = text.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { $0.contains("reciprocal axes") }) else { return nil }
        // The three vector rows follow the marker: "b(1) = ( x y z )".
        var vecs: [SIMD3<Float>] = []
        for offset in 1...3 {
            let idx = marker + offset
            guard idx < lines.count else { return nil }
            // Isolate the parenthesised triple.
            guard let lpar = lines[idx].firstIndex(of: "("),
                  let rpar = lines[idx].lastIndex(of: ")"), rpar > lpar else { return nil }
            let body = String(lines[idx][lines[idx].index(after: lpar)..<rpar])
            let nums = body.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).compactMap { Float($0) }
            guard nums.count >= 3 else { return nil }
            vecs.append(SIMD3<Float>(nums[0], nums[1], nums[2]))
        }
        return vecs.count == 3 ? vecs : nil
    }

    /// Parse "  k =  .1250  .2165 -.1852 ( 6180 PWs)   bands (ev):" ->
    /// k=(0.125,0.2165,-0.1852).
    ///
    /// Only the first three numbers are the k-vector. The fourth numeric token in
    /// this header is the plane-wave count "( 6180 PWs)", NOT a k-point weight, so
    /// we stop at three. (The BandKPoint.weight field exists for completeness but
    /// is not populated, since the bands header carries no valid weight.)
    private static func parseKHeader(_ line: String) -> SIMD3<Float>? {
        guard let eqRange = line.range(of: "k =") ?? line.range(of: "k=") else { return nil }
        let after = String(line[eqRange.upperBound...])
        let toks = after.split(whereSeparator: { $0 == " " || $0 == "\t" })
        var nums: [Float] = []
        for t in toks {
            if let v = Float(t) { nums.append(v) }
            if nums.count == 3 { break }   // kx, ky, kz only — skip the PW count
        }
        guard nums.count >= 3 else { return nil }
        return SIMD3<Float>(nums[0], nums[1], nums[2])
    }

    /// Parse "     the Fermi energy is     4.6669 ev" -> 4.6669, or
    /// "     the Fermi energy is    -4.25 ev" -> -4.25.
    ///
    /// The unsigned `[0-9]+\.[0-9]+` silently dropped the sign for negative Fermi
    /// energies (insulators, some dopings) and rejected integers/scientific form. A
    /// signed, exponent-aware decimal is matched instead.
    static func parseFermiEnergy(_ line: String) -> Float? {
        // Require the literal QE phrase so a casual "Fermi" mention elsewhere (e.g.
        // a methods paragraph) does not false-positive.
        guard let phrase = line.range(of: "the Fermi energy is") else { return nil }
        // Match the FIRST signed decimal in the remainder of the line. QE may emit
        // Fortran "D" exponent notation (e.g. "1.5D-3"); normalize d/D to e/E before
        // handing it to Float, which does not parse D-notation itself.
        let tail = String(line[phrase.upperBound...])
        let pattern = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eEdD][+-]?\d+)?"#
        guard let r = tail.range(of: pattern, options: .regularExpression) else { return nil }
        let token = String(tail[r]).replacingOccurrences(of: "D", with: "e").replacingOccurrences(of: "d", with: "e")
        return Float(token)
    }

    /// Most common value in `xs`, or nil if empty. Used to pick the representative
    /// band count so a single short block doesn't drag the count down.
    private static func modalValue(_ xs: [Int]) -> Int? {
        guard !xs.isEmpty else { return nil }
        var freq: [Int: Int] = [:]
        for x in xs { freq[x, default: 0] += 1 }
        return freq.max(by: { $0.value < $1.value })?.key
    }
}
