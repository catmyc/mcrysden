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
            d[base] = 0   // explicit per-spin restart at 0 (relies on base being untouched)
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
/// One parsed eigenvalue block: its k-point, the integration weight from the QE
/// k-list, the per-band energies, and the block's k-point position + spin channel
/// (used to keep only complete spin-channel groups after modal filtering).
struct BandParserRecord {
    var k: SIMD3<Float>
    var weight: Float
    var energies: [Float]
    var position: Int      // k-point index in the list (0..kListCount-1)
    var spin: Int          // spin channel (0 = up, 1 = down, ...)
}

enum BandParser {
    static func parse(_ text: String) -> BandStructure? {
        let lines = text.components(separatedBy: "\n")
        // Reciprocal lattice vectors, if present, for crystal-coordinate metric.
        let reciprocal = parseReciprocal(text)

        // K-list metadata (weights, count, coord system) is captured per SECTION: when a
        // new "number of k points" header appears (concatenated/restarted QE output), the
        // previous section's metadata is snapshotted and a fresh section begins. This
        // stops an earlier list from leaking into a later selected iteration.
        struct KListMeta {
            var weights: [Float] = []
            var count: Int = 0          // populated by k-list lines OR the header number
            var headerCount: Int = 0    // the "number of k points= N" number, if parseable
            var isCrystal: Bool = false
        }
        var curMeta = KListMeta()
        func ingestKPointListHeader(_ headerLineIdx: Int) {
            // A new k-point list opens a new section: snapshot any prior metadata and reset —
            // triggered by ANY section start (headerCount>0 OR count>0), so a header-only
            // section (a bare "number of k points= N" with no k(...) list) does not carry the
            // previous section's coordinate convention into the next one.
            if curMeta.count > 0 || curMeta.headerCount > 0 { curMeta = KListMeta() }
            // Parse the explicit count from "number of k points= N". This is the fallback
            // when the section prints a header but no subsequent k(...) ... wk= list (a
            // malformed/truncated or restart-style output): we know N but must NOT inherit
            // the previous section's k-list weights or coordinate convention.
            if let eq = lines[headerLineIdx].firstIndex(of: "=") {
                let tail = lines[headerLineIdx].index(after: eq)
                let numStr = String(lines[headerLineIdx][tail...]).trimmingCharacters(in: .whitespaces)
                curMeta.headerCount = Int(numStr) ?? 0
            }
            // Scan the few lines after "number of k points=" for the coord label.
            for off in 1...3 {
                let idx = headerLineIdx + off
                guard idx < lines.count else { break }
                let low = lines[idx].lowercased()
                if low.contains("cryst. coord") || low.contains("crystal") { curMeta.isCrystal = true; break }
                if low.contains("cart. coord") { curMeta.isCrystal = false; break }
            }
        }

        // Per-iteration accumulator. Each record carries its k-point POSITION (index
        // in the k-list, 0..kListCount-1) and SPIN CHANNEL (0,1,...) so that after
        // modal-band filtering we can keep only positions that are COMPLETE across
        // all spin channels — never mixing partial channels into one bogus path.
        struct Iter {
            var records: [BandParserRecord] = []
            var fermi: Float? = nil
            var meta: KListMeta = KListMeta()   // snapshot of the active k-list metadata
            // Counts EVERY recognized k = ... bands header, even ones whose eigenvalue
            // block is empty/malformed (and thus not appended to records). Deriving
            // position/spin from records.count would let a skipped block shift every
            // later assignment; this counter guards against that.
            var blockCount = 0
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
                // Snapshot the active k-list metadata into this iteration: it is finalized
                // here, and QE does not reprint the list for later iterations, so the
                // metadata active at this boundary belongs to the blocks just parsed.
                if cur.records.isEmpty == false { cur.meta = curMeta }
                if !cur.records.isEmpty { iterations.append(cur) }
                cur = Iter()
                i += 1; continue
            }
            if isKPointListHeader(line) {
                if let w = parseWeight(line) { curMeta.weights.append(w) }
                curMeta.count += 1
                i += 1; continue
            }
            guard let k = parseKHeader(line) else { i += 1; continue }
            // Eigenvalue block. QE orders bands as (k1_up,k2_up,...,kN_up, k1_down,...);
            // position = index % kListCount, spin = index / kListCount. blockCount advances
            // for EVERY recognized header, so an empty/malformed block (not appended) can't
            // shift later assignments.
            //
            // The effective per-channel count is max(parsed k-list lines, header number):
            // when a section prints "number of k points= 3" but no k(...) ... wk list,
            // curMeta.count is 0 yet we know there are 3 k-points — using it lets positions
            // wrap correctly (0,1,2,0,1,2) and assigns spin = idx/3. Falling back to
            // sequential positions would misassign every block.
            cur.blockCount += 1
            let idx = cur.blockCount - 1
            let kListCount = max(curMeta.count, curMeta.headerCount)
            let position = kListCount > 0 ? idx % kListCount : idx
            let spin = kListCount > 0 ? idx / kListCount : 0
            let widx = kListCount > 0 ? idx % kListCount : -1
            let weight = widx >= 0 && widx < curMeta.weights.count ? curMeta.weights[widx] : 0
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
                cur.records.append(BandParserRecord(k: k, weight: weight, energies: energies,
                                                    position: position, spin: spin))
            }
        }
        // Choose the final complete iteration; a file with no boundary lines is one
        // iteration whose Fermi energy is unavailable (nil). Snapshot the currently
        // active k-list metadata into whichever iteration is selected, so each iteration
        // carries the metadata of its own k-list section.
        var chosen = Iter()
        if iterations.isEmpty {
            chosen = cur
            chosen.meta = curMeta
        } else {
            chosen = iterations.last!
        }
        // If the chosen iteration captured no k-list metadata but its section printed a
        // "number of k points= N" header with no following k(...) list, fall back to a
        // count derived from that header — NOT the previous section's list, whose weights
        // and coordinate convention must not leak into this later calculation.
        if chosen.meta.count == 0, chosen.meta.headerCount > 0 {
            chosen.meta.count = chosen.meta.headerCount
        }
        // Do NOT fall back to a prior section's metadata. A chosen iteration with empty
        // meta belongs to a genuinely new/malformed section; inheriting an earlier
        // section's weights or coordinate convention across section boundaries would
        // corrupt spin grouping and mesh detection. Missing metadata stays unknown → the
        // safe single-spin sequential path.
        guard !chosen.records.isEmpty else { return nil }

        let meta = chosen.meta
        // Whether any k-list metadata exists at all (parsed list lines or the header count).
        // When NONE exists, records were assigned sequential positions (single-spin) during
        // parsing, so the post-loop MUST agree: nSpin = 1 with every record its own position.
        let hasKListMeta = meta.count > 0 || meta.headerCount > 0
        // k-points per channel. Use the SAME effective count as position/spin assignment did
        // during parsing (max of parsed list lines and the declared header number) so the
        // channel layout the records were tagged with matches the one the post-loop infers.
        // Treat the header count as authoritative: a partial explicit list that disagrees with
        // it signals a malformed/truncated file, which the divisibility check below rejects.
        let kListCount = hasKListMeta ? max(meta.count, meta.headerCount) : chosen.blockCount

        // Spin channels derived from blockCount (total headers incl. empty ones), not
        // records.count: a missing spin-down block is then visible as a divisibility
        // failure rather than being silently reinterpreted as spinless. Expect
        // blockCount = nSpin * kListCount.
        //
        // When k-list metadata EXISTS and the layout does NOT divide cleanly, the spin
        // structure is genuinely truncated/malformed — flattening it to a single channel
        // would falsely connect the end of one spin channel to the start of the next
        // (e.g. k3_up → k1_down), producing a scientifically invalid path. We REJECT such
        // a calculation (return nil) rather than emit a misleading result. Only when there
        // is NO metadata at all (single-spin, unknown layout) do we treat it as one channel.
        let divisible = kListCount > 0 && chosen.blockCount % kListCount == 0
        if hasKListMeta && !divisible {
            return nil   // truncated spin layout: reject, don't cross-connect channels
        }
        let nSpin: Int = divisible ? chosen.blockCount / kListCount : 1

        // A Monhkorst-Pack sampling mesh is identified by uniform integration weights,
        // regular-grid coordinate spacing, AND spanning ≥2 dimensions (non-collinear):
        // the last condition is what separates a mesh from a straight band path such as
        // a diagonal Γ-Χ, whose points are equally spaced on two axes yet lie on a line.
        // Mesh detection operates on ONE spin channel: QE's k-point list prints each
        // position once (one weight), but the eigenvalue blocks repeat per spin, so
        // chosen.records has nSpin entries per position. Take a single representative
        // channel (spin 0) — for a well-formed calculation it carries every position —
        // ordered by position, so that weights.count == records.count becomes meaningful.
        let perSpin = chosen.records.filter { $0.spin == 0 }.sorted { $0.position < $1.position }
        let isMesh = detectUniformMesh(meta.weights, records: perSpin)

        // Band filtering. A cleanly divisible multi-channel layout drops incomplete groups
        // (positions missing a record in some spin); the single-channel case keeps all.
        let counts = chosen.records.map { $0.energies.count }
        let bandCount = modalValue(counts) ?? counts.max() ?? 0   // most common eigenvalue count
        let bandOk = chosen.records.filter { $0.energies.count == bandCount }
        let filteredRecords: [BandParserRecord]
        if nSpin > 1 {
            var perPosSpinCount: [Int: Int] = [:]
            for r in bandOk { perPosSpinCount[r.position, default: 0] += 1 }
            let completePositions = Set(perPosSpinCount.filter { $0.value == nSpin }.keys)
            filteredRecords = bandOk.filter { completePositions.contains($0.position) }
        } else {
            filteredRecords = bandOk   // single channel: keep everything
        }
        // Re-sort into channel-major order (all of spin 0, then spin 1, ...), each
        // channel ordered by k-point position, so the grapher reads them correctly. For the
        // single-channel case (nSpin == 1) emit in parse order.
        let filtered: [BandKPoint]
        if nSpin > 1 {
            filtered = (0..<nSpin).flatMap { s in
                filteredRecords.filter { $0.spin == s }.sorted { $0.position < $1.position }
                    .map { BandKPoint(k: $0.k, weight: $0.weight, label: "", energies: $0.energies) }
            }
        } else {
            filtered = filteredRecords
                .map { BandKPoint(k: $0.k, weight: $0.weight, label: "", energies: $0.energies) }
        }
        guard !filtered.isEmpty else { return nil }

        let kPointsPerSpin = filtered.count / nSpin
        return BandStructure(kPoints: filtered, fermiEnergy: chosen.fermi, nSpin: nSpin,
                             reciprocal: reciprocal, kPointsAreCrystal: meta.isCrystal,
                             kPointsPerSpin: kPointsPerSpin, isMesh: isMesh)
    }

    /// A Monkhorst-Pack sampling mesh is identified by uniform integration weights AND a
    /// grid-like k-point layout (equal per-axis spacing, spanning ≥2 dimensions, and a
    /// row-uniform factorization of the total). Weights alone are insufficient — a uniform
    /// band path can share them — so the grid structure is the discriminating signature.
    /// Testable directly (see DiagnosticTests).
    static func detectUniformMesh(_ weights: [Float], records: [BandParserRecord]) -> Bool {
        guard weights.count > 1, records.count > 1 else { return false }
        // Require COMPLETE weight coverage: every k-point must have a weight. A partial
        // k-list (e.g. header says 3 k-points but only 2 k(...) ... wk= lines parsed) means
        // we don't know the full grid, so we must not infer a mesh — otherwise a sparse
        // path with a couple of surviving weights would be misclassified. The per-spin
        // k-point count is records.count / nSpin (nSpin == 1 here, since multi-spin is
        // handled by the caller); require weights to cover all of them.
        guard weights.count == records.count else { return false }
        let first = weights[0]
        guard weights.allSatisfy({ abs($0 - first) < 1e-4 }) else { return false }
        return formsMultipartGrid(records.map { $0.k })
    }

    /// True if the k-point coordinates form the signature layout of a Monkhorst-Pack
    /// sampling mesh. Combines independent checks:
    ///   (a) EQUALLY SPACED per non-degenerate axis (no random scatter);
    ///   (b) AT LEAST TWO non-degenerate axes (a 1D line of points is not a mesh);
    ///   (c) the points are NOT COLLINEAR (a diagonal Γ-Χ is spaced on two axes yet lies
    ///       on a line and must be rejected);
    ///   (d) UNIFORM-ROW FACTORIZATION: the total point count factors as
    ///       nRows × nCols (both ≥ 2) along some axis — every distinct coordinate on that
    ///       axis is hit the same number of times (rejects L/sparse band paths);
    static func formsMultipartGrid(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count > 1 else { return false }
        let axes = [points.map { $0.x }, points.map { $0.y }, points.map { $0.z }]
        var nonDegenerateAxes = 0
        for axis in axes {
            let unique = Array(Set(axis.map { ($0 * 1000).rounded() / 1000 })).sorted()
            guard unique.count > 1 else { continue }   // degenerate axis (e.g. slab)
            nonDegenerateAxes += 1
            let step = unique[1] - unique[0]
            if step < 1e-4 { return false }
            for i in 1..<unique.count {
                if abs((unique[i] - unique[i - 1]) - step) > 1e-3 { return false }
            }
        }
        guard nonDegenerateAxes >= 2, !areCollinear(points) else { return false }
        // hasUniformRowFactorization already requires perRow ≥ 3 and a complete row
        // factorization — the strongest topology signal available without metadata.
        return hasUniformRowFactorization(points)
    }

    /// True if the points factor into uniform rows: there is some axis on which every
    /// distinct coordinate value is visited the SAME number of times, and that count
    /// multiplies back to the total (nDistinct × perRow == nPoints, perRow ≥ 3, nDistinct ≥ 2).
    ///
    /// perRow ≥ 3 is the key gate, not a density threshold. The reviewer's sparse-path
    /// counterexamples (e.g. 6 points, 3 x-values each hit twice) have perRow = 2 and are
    /// rightly rejected as paths: a real 2D mesh samples several points along each row,
    /// whereas a band path traverses essentially one point per step. The CH3Rh111 slab
    /// fixture has perRow = 4 (2 rows × 4) and passes. A perfect 3×N Monkhorst grid also
    /// passes (perRow = N ≥ 3). Tolerance accounts for float rounding.
    static func hasUniformRowFactorization(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count >= 6 else { return false }   // a real mesh needs ≥ 2 rows × 3
        let axes = [points.map { $0.x }, points.map { $0.y }, points.map { $0.z }]
        for axis in axes {
            var freq: [Int: Int] = [:]
            for v in axis { let k = Int((v * 1000).rounded()); freq[k, default: 0] += 1 }
            let distinct = freq.count
            guard distinct >= 2 else { continue }
            let perRow = freq.values.first!
            let uniform = perRow >= 3 && distinct * perRow == points.count
                && freq.values.allSatisfy { $0 == perRow }
            guard uniform else { continue }
            return true
        }
        return false
    }

    /// True if all points lie on a single line (within tolerance). Collinear points form
    /// a band path, never a mesh, even if spaced equally on multiple axes. Testable.
    static func areCollinear(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count > 2 else { return true }
        // Find two distinct points to define the line direction.
        guard let p0 = points.first, let idx = points.firstIndex(where: { $0 != p0 }) else { return true }
        let p1 = points[idx]
        let dir = p1 - p0
        let len = simd_length(dir)
        guard len > 1e-6 else { return true }
        let d = dir / len
        for p in points {
            let v = p - p0
            let proj = simd_dot(v, d)
            let closest = p0 + d * proj
            if simd_length(p - closest) > 1e-3 { return false }
        }
        return true
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
