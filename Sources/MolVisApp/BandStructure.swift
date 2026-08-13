import Foundation
import simd

// Quantum-EPWscf BAND structure: k-points + eigenvalues parsed from a PWscf
// `.out` (or bands-output) file. The result feeds the 2D Grapher that draws the
// band structure. This is the Tier A #5 keystone — once bands are parsed, a
// uniform mesh also directly underpins total-DOS reconstruction.

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
    /// Real-space QE cell vectors in Angstroms, when the output contains enough
    /// lattice metadata to reconstruct them. Band-only files can omit this.
    var cell: Cell? = nil
    /// Number of physically periodic dimensions used for DOS normalization:
    /// 0 molecule, 1 wire, 2 slab, 3 bulk crystal.
    var periodicDim: Int = 0
    /// Whether the calculation is KNOWN to obey time-reversal symmetry
    /// (E(k) = E(-k)): non-magnetic, collinear, spin-orbit-free, as established
    /// by the QE parser from the output's magnetic/SOC/noncollinear markers.
    /// Defaults to FALSE — absence of evidence is not evidence of symmetry, so
    /// metadata-less band structures (and legacy state files) are never
    /// auto-unfolded. TR-reduced k-meshes are only unfolded when this is true.
    var timeReversalSymmetric: Bool = false

    init(kPoints: [BandKPoint], fermiEnergy: Float?, nSpin: Int,
         reciprocal: [SIMD3<Float>]? = nil,
         kPointsAreCrystal: Bool = false,
         kPointsPerSpin: Int,
         isMesh: Bool = false,
         cell: Cell? = nil,
         periodicDim: Int = 0,
         timeReversalSymmetric: Bool = false) {
        self.kPoints = kPoints
        self.fermiEnergy = fermiEnergy
        self.nSpin = nSpin
        self.reciprocal = reciprocal
        self.kPointsAreCrystal = kPointsAreCrystal
        self.kPointsPerSpin = kPointsPerSpin
        self.isMesh = isMesh
        self.cell = cell
        self.periodicDim = min(3, max(0, periodicDim))
        self.timeReversalSymmetric = timeReversalSymmetric
    }

    // Keep old project files valid after adding the optional real-space cell
    // and periodic-dimensionality metadata.
    private enum CodingKeys: String, CodingKey {
        case kPoints, fermiEnergy, nSpin, reciprocal, kPointsAreCrystal,
             kPointsPerSpin, isMesh, cell, periodicDim, timeReversalSymmetric
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kPoints = try c.decode([BandKPoint].self, forKey: .kPoints)
        fermiEnergy = try c.decodeIfPresent(Float.self, forKey: .fermiEnergy)
        nSpin = try c.decode(Int.self, forKey: .nSpin)
        reciprocal = try c.decodeIfPresent([SIMD3<Float>].self, forKey: .reciprocal)
        kPointsAreCrystal = try c.decodeIfPresent(Bool.self, forKey: .kPointsAreCrystal) ?? false
        kPointsPerSpin = try c.decode(Int.self, forKey: .kPointsPerSpin)
        isMesh = try c.decodeIfPresent(Bool.self, forKey: .isMesh) ?? false
        cell = try c.decodeIfPresent(Cell.self, forKey: .cell)
        periodicDim = min(3, max(0, try c.decodeIfPresent(Int.self, forKey: .periodicDim) ?? 0))
        // Unknown (missing key in legacy files) must NOT claim symmetry: reduced
        // meshes are only unfolded on explicit parser-verified evidence.
        timeReversalSymmetric = try c.decodeIfPresent(Bool.self, forKey: .timeReversalSymmetric) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kPoints, forKey: .kPoints)
        try c.encodeIfPresent(fermiEnergy, forKey: .fermiEnergy)
        try c.encode(nSpin, forKey: .nSpin)
        try c.encodeIfPresent(reciprocal, forKey: .reciprocal)
        try c.encode(kPointsAreCrystal, forKey: .kPointsAreCrystal)
        try c.encode(kPointsPerSpin, forKey: .kPointsPerSpin)
        try c.encode(isMesh, forKey: .isMesh)
        try c.encodeIfPresent(cell, forKey: .cell)
        try c.encode(periodicDim, forKey: .periodicDim)
        try c.encode(timeReversalSymmetric, forKey: .timeReversalSymmetric)
    }

    /// Number of bands safely shared by every k-point. Parser-produced data is
    /// uniform, but taking the minimum keeps a directly-constructed malformed
    /// value from indexing past a shorter energy row in the graph exporter.
    var nBands: Int { kPoints.map(\.energies.count).min() ?? 0 }
    var nKPoints: Int { kPoints.count }

    /// The path grapher indexes channels as `spin * kPointsPerSpin + point`.
    /// Validate that externally/directly constructed values satisfy that layout;
    /// parser-produced structures always do.
    var hasValidChannelLayout: Bool {
        guard nSpin > 0, kPointsPerSpin > 0 else { return false }
        let total = nSpin.multipliedReportingOverflow(by: kPointsPerSpin)
        return !total.overflow && total.partialValue == kPoints.count
    }

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
        guard hasValidChannelLayout else { return .init(repeating: 0, count: kPoints.count) }
        // First channel starts at 0; each subsequent channel restarts at 0 too.
        var d: [Float] = .init(repeating: 0, count: kPoints.count)
        for s in 0..<nSpin {
            let base = s * n
            d[base] = 0
            let end = base + n
            if base + 1 < end {
                for i in (base + 1)..<end {
                    let dk = kPoints[i].k - kPoints[i - 1].k
                    let squared = G.map { simd_dot(dk, $0 * dk) } ?? dot(dk, dk)
                    let step = squared.isFinite ? sqrt(max(0, squared)) : 0
                    d[i] = d[i - 1] + step
                }
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
        let cell = parseRealSpaceCell(text)
        // A reduced k-mesh may only be unfolded when the calculation obeys
        // time reversal (E(k) = E(-k)). Magnetic, spin-orbit/noncollinear, and
        // field-driven calculations break it even for a single spin channel.
        //
        // Detection is bound to the LAST calculation in the file: QE marks a new
        // run with a "Program PWSCF ... starts ..." banner (its end prints a
        // "stops" line, which must not be mistaken for a new run), so
        // concatenated output's earlier calculations (with their own input echo
        // and SCF magnetization lines) must not veto the final selected mesh.
        // Without a banner the whole text is scanned. Within one calculation the
        // SCF section (early iterations) still counts — its magnetization
        // markers are part of the same run.
        let calcStart = lines.lastIndex(where: {
            let lower = $0.lowercased()
            return lower.contains("program pwscf") && lower.contains("starts")
        }) ?? 0
        let calcText = lines[calcStart...].joined(separator: "\n")
        let timeReversalSymmetric = !detectTimeReversalBreaking(calcText)
        // Reciprocal axes are enough to establish that this is a periodic QE
        // calculation even when a bands-only file omitted the real-space axes;
        // DOS generation will then fail explicitly if the volume/area cannot
        // be reconstructed.
        let periodicDim = parsePeriodicDimension(text, hasCell: cell != nil || reciprocal != nil)

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
                var rowMalformed = false
                for s in t.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    if let v = Float(s) {
                        // A token that parses as a number but is non-finite
                        // (NaN/Inf) is malformed data — abort the whole parse
                        // rather than silently shortening the row (which would
                        // misalign every band after it).
                        if !v.isFinite { rowMalformed = true; break }
                        row.append(v)
                    }
                    // Tokens that do not parse as numbers are silently skipped.
                }
                if rowMalformed { return nil }
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
        // A molecule's standard Gamma-only calculation has one k-point and
        // cannot satisfy the multi-point Monkhorst-Pack detector, but its
        // discrete eigenvalues are still a valid molecular DOS input.
        let isGammaMolecule = periodicDim == 0 && meta.weights.count == 1 && perSpin.count == 1
        let isMesh = detectUniformMesh(meta.weights, records: perSpin) || isGammaMolecule

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
                             kPointsPerSpin: kPointsPerSpin, isMesh: isMesh,
                             cell: cell, periodicDim: periodicDim,
                             timeReversalSymmetric: timeReversalSymmetric)
    }

    /// A Monkhorst-Pack sampling mesh is identified by uniform integration weights AND a
    /// grid-like k-point layout (equal per-axis spacing, spanning ≥2 dimensions, and a
    /// row-uniform factorization of the total). Weights alone are insufficient — a uniform
    /// band path can share them — so the grid structure is the discriminating signature.
    /// Testable directly.
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
    /// sampling mesh. A genuine MP mesh is a COMPLETE multidimensional lattice: every
    /// integer combination of its primitive basis vectors, filling a box whose sample
    /// count equals its dimensions' product, with no gaps. This is orientation-independent
    /// (works for sheared slabs AND bulk 3D grids) AND rejects sparse band paths whose
    /// per-axis marginal frequencies look uniform but whose coordinate COMBINATIONS do not
    /// fill a grid (e.g. (0,0),(0,1),(1,0),(1,2),(2,1),(2,2)).
    ///
    /// Two paths, both O(N): a fast AXIS-ALIGNED check (equal spacing on the raw x/y/z
    /// axes with a completely filled Cartesian product — the common bulk 4×4×4 case), and
    /// a general ORIENTATION-INDEPENDENT lattice test that searches a bounded set of the
    /// shortest candidate basis directions (so work is linear, not cubic). Testable.
    static func formsMultipartGrid(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count > 1, !areCollinear(points) else { return false }
        // Fast path: axis-aligned MP grid on the raw axes (covers bulk 3D grids).
        if formsAxisAlignedGrid(points) { return true }
        // General path: orientation-independent complete-lattice test (sheared slabs etc.).
        return formsLatticeGrid(points)
    }

    /// Fast path: an axis-aligned MP grid has equal spacing on each non-degenerate raw
    /// axis AND a completely filled Cartesian product (product of the per-axis sample
    /// counts equals the point count, with every combination present). O(N).
    private static func formsAxisAlignedGrid(_ points: [SIMD3<Float>]) -> Bool {
        let axes = [points.map { $0.x }, points.map { $0.y }, points.map { $0.z }]
        var sizes: [Int] = []
        for ax in axes {
            let u = Array(Set(ax.map { ($0 * 1000).rounded() / 1000 })).sorted()
            if u.count <= 1 { continue }            // degenerate axis (e.g. slab): allowed
            let step = u[1] - u[0]
            if step < 1e-4 { return false }
            for i in 1..<u.count { if abs((u[i] - u[i - 1]) - step) > 1e-3 { return false } }
            sizes.append(u.count)
        }
        guard sizes.count >= 2 else { return false }   // need ≥ 2 non-degenerate axes
        let prod = sizes.reduce(1, *)
        guard prod == points.count else { return false }
        // Verify the product box is fully filled (reject same-size axes with gaps).
        let axisUniq: [[Float]] = axes.map { Array(Set($0.map { ($0 * 1000).rounded() / 1000 })).sorted() }
        var seen = Set<Int>()
        for p in points {
            // ignore degenerate axes in the key (their count is 1)
            let comps = [p.x, p.y, p.z]
            var key = 0, mul = 1
            for (ai, u) in axisUniq.enumerated() {
                if u.count <= 1 { continue }
                guard let ix = u.firstIndex(where: { abs($0 - comps[ai]) < 1e-3 }) else { return false }
                key += ix * mul
                mul *= 100
            }
            if !seen.insert(key).inserted { return false }
        }
        return seen.count == prod
    }

    /// General path: does `points` equal a complete lattice {p0 + Σ ni·bi} for some set of
    /// primitive basis vectors b1..bd (d = 2 or 3) and a filled n1×..×nd box? Uses incremental
    /// Gram-Schmidt to compute the true affine dimension (O(N), order-independent), then
    /// collects distinct directions from p0 until the direction set spans that dimension —
    /// guaranteeing the out-of-plane axis is always captured even when in-plane multiples
    /// dominate. The lattice check is O(K³·N) with K ≤ 16.
    private static func formsLatticeGrid(_ points: [SIMD3<Float>]) -> Bool {
        let p0 = points[0]
        func len2(_ v: SIMD3<Float>) -> Float { simd_dot(v, v) }
        func len(_ v: SIMD3<Float>) -> Float { sqrt(len2(v)) }
        let sinEps: Float = 0.05
        func independent2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            simd_length(simd_cross(a, b)) > sinEps * len(a) * len(b)
        }
        // Dimension spanned by a set of direction vectors.
        func span(_ vs: [SIMD3<Float>]) -> Int {
            guard !vs.isEmpty else { return 0 }
            for i in 0..<vs.count { for j in (i + 1)..<vs.count {
                if independent2(vs[i], vs[j]) {
                    for k in 0..<vs.count where k != i && k != j {
                        let triple = simd_dot(vs[k], simd_cross(vs[i], vs[j]))
                        if abs(triple) > sinEps * len(vs[i]) * len(vs[j]) * len(vs[k]) { return 3 }
                    }
                    return 2
                }
            } }
            return 1
        }

        // 1. Compute true affine dimension via Gram-Schmidt — O(N), order-independent.
        var gsBasis: [SIMD3<Float>] = []
        var targetDim = 0
        for p in points {
            var residual = p - p0
            for b in gsBasis {
                let proj = simd_dot(residual, b) / simd_dot(b, b)
                residual -= proj * b
            }
            if simd_dot(residual, residual) > 1e-8 {
                gsBasis.append(residual)
                targetDim += 1
                if targetDim >= 3 { break }
            }
        }
        guard targetDim >= 2 else { return false }

        // 2. Collect distinct directions from p0. Keep collecting until the direction set
        //    spans the GS-detected dimension — even when in-plane multiples dominate the
        //    first N directions. This is what makes the detection order-independent.
        var dirs: [SIMD3<Float>] = []
        var spanBasis: [SIMD3<Float>] = []
        var currentSpan = 0
        for q in points.dropFirst() {
            let d = q - p0
            if len2(d) < 1e-10 { continue }
            let nextSpan = span(spanBasis + [d])
            let addsDimension = nextSpan > currentSpan
            if addsDimension {
                spanBasis.append(d)
                currentSpan = nextSpan
            }
            let candidatePoolFull = dirs.count >= 200
            if !candidatePoolFull,
               !dirs.contains(where: { simd_length($0 - d) < 1e-4 * max(1, len($0)) }) {
                dirs.append(d)
            }
            // Once the ordinary candidate pool is full, retain only vectors that add
            // a missing dimension. This keeps work bounded without making point order
            // determine whether an out-of-plane direction is ever considered.
            if candidatePoolFull && addsDimension { dirs.append(d) }
            if dirs.count >= 24 && currentSpan >= targetDim { break }
        }
        guard dirs.count >= 2 else { return false }

        // 3. Rank-based candidate selection + short-direction fill.
        var byRank: [SIMD3<Float>] = []
        for d in dirs.sorted(by: { len2($0) < len2($1) }) {
            if span(byRank + [d]) > span(byRank) { byRank.append(d) }
            if span(byRank) >= targetDim { break }
        }
        var cand = byRank
        for d in dirs where !cand.contains(where: { simd_length($0 - d) < 1e-4 }) {
            if cand.count >= 16 { break }
            cand.append(d)
        }
        guard cand.count >= 2 else { return false }

        // 4. Lattice check — try 2D then 3D basis combinations.
        for i in 0..<cand.count {
            for j in (i + 1)..<cand.count {
                if !independent2(cand[i], cand[j]) { continue }
                if isLatticeBasis([cand[i], cand[j]], p0, points) { return true }
                for k in (j + 1)..<cand.count {
                    let triple = abs(simd_dot(cand[i], simd_cross(cand[j], cand[k])))
                    let denom = len(cand[i]) * len(cand[j]) * len(cand[k])
                    if triple < sinEps * denom { continue }
                    if isLatticeBasis([cand[i], cand[j], cand[k]], p0, points) { return true }
                }
            }
        }
        return false
    }

    /// True when every point equals p0 + Σ ri·basis[i] for integer ri that exactly fill an
    /// axis-aligned bounding box (product of per-axis counts == point count, no gaps/dupes).
    private static func isLatticeBasis(_ basis: [SIMD3<Float>], _ p0: SIMD3<Float>,
                                       _ points: [SIMD3<Float>]) -> Bool {
        let d = basis.count
        guard d == 2 || d == 3 else { return false }
        // Normal equations: ri = G^{-1} · (basis · (point - p0)), G_ij = bi·bj.
        var g = [[Float]](repeating: [Float](repeating: 0, count: d), count: d)
        for a in 0..<d { for b in 0..<d { g[a][b] = simd_dot(basis[a], basis[b]) } }
        let detG: Float = d == 2
            ? (g[0][0] * g[1][1] - g[0][1] * g[1][0])
            : (g[0][0] * (g[1][1] * g[2][2] - g[1][2] * g[2][1])
             - g[0][1] * (g[1][0] * g[2][2] - g[1][2] * g[2][0])
             + g[0][2] * (g[1][0] * g[2][1] - g[1][1] * g[2][0]))
        // SINGULARITY: a dependent basis has detG = 0. Use a RELATIVE cutoff so tiny meshes
        // (primitive spacing ~0.001, detG ~1e-12) aren't rejected as degenerate. detG equals
        // squared cell volume; compare against the product of the squared basis lengths (the
        // value for an orthogonal basis of those lengths), i.e. the squared-cosine of the cell.
        let lenSqProd = g[0][0] * (d == 2 ? g[1][1] : (g[1][1]*g[2][2] - g[1][2]*g[2][1]))
        if lenSqProd > 0, abs(detG) < 1e-6 * lenSqProd { return false }
        var gi = [[Float]](repeating: [Float](repeating: 0, count: d), count: d)
        if d == 2 {
            gi[0][0] = g[1][1] / detG; gi[0][1] = -g[0][1] / detG
            gi[1][0] = -g[1][0] / detG; gi[1][1] = g[0][0] / detG
        } else {
            gi[0][0] = (g[1][1]*g[2][2] - g[1][2]*g[2][1]) / detG
            gi[0][1] = (g[0][2]*g[2][1] - g[0][1]*g[2][2]) / detG
            gi[0][2] = (g[0][1]*g[1][2] - g[0][2]*g[1][1]) / detG
            gi[1][0] = (g[1][2]*g[2][0] - g[1][0]*g[2][2]) / detG
            gi[1][1] = (g[0][0]*g[2][2] - g[0][2]*g[2][0]) / detG
            gi[1][2] = (g[0][2]*g[2][0] - g[0][0]*g[1][2]) / detG
            gi[2][0] = (g[1][0]*g[2][1] - g[1][1]*g[2][0]) / detG
            gi[2][1] = (g[0][1]*g[2][0] - g[0][0]*g[2][1]) / detG
            gi[2][2] = (g[0][0]*g[1][1] - g[0][1]*g[1][0]) / detG
        }
        var coords: [[Int]] = []
        for q in points {
            let r = q - p0
            var c = [Float](repeating: 0, count: d)
            for i in 0..<d { c[i] = simd_dot(basis[i], r) }
            var f = [Float](repeating: 0, count: d)
            for i in 0..<d { for j in 0..<d { f[i] += gi[i][j] * c[j] } }
            guard f.allSatisfy(\.isFinite) else { return false }
            let converted = f.map { Int(exactly: $0.rounded()) }
            guard converted.allSatisfy({ $0 != nil }) else { return false }
            let ri = converted.map { $0! }
            // reconstruct & verify integer lattice maps back onto the real point.
            var recon = p0
            for i in 0..<d { recon += basis[i] * Float(ri[i]) }
            if simd_length(q - recon) > 2e-3 { return false }
            coords.append(ri)
        }
        var lo = coords[0], hi = coords[0]
        for cc in coords.dropFirst() { for i in 0..<d { lo[i] = min(lo[i], cc[i]); hi[i] = max(hi[i], cc[i]) } }
        var sizes = [Int](repeating: 0, count: d)
        var prod = 1
        for i in 0..<d {
            let span = hi[i].subtractingReportingOverflow(lo[i])
            guard !span.overflow else { return false }
            let size = span.partialValue.addingReportingOverflow(1)
            guard !size.overflow, size.partialValue > 0 else { return false }
            sizes[i] = size.partialValue
            let next = prod.multipliedReportingOverflow(by: sizes[i])
            guard !next.overflow else { return false }
            prod = next.partialValue
        }
        guard prod == points.count else { return false }
        var seen = Set<Int>()
        for cc in coords {
            var key = 0, mul = 1
            for i in 0..<d { key += (cc[i] - lo[i]) * mul; mul *= 1000 }
            if !seen.insert(key).inserted { return false }   // duplicate lattice coordinate
        }
        guard seen.count == prod else { return false }       // gap in the box
        return true
    }

    /// True if all points lie on a single line (within tolerance). Collinear points form
    /// a band path, never a mesh, even if spaced equally on multiple axes. Testable.
    static func areCollinear(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count > 2 else { return true }
        // SINE-BASED collinearity (scale-independent, consistent with `independent2` in
        // formsLatticeGrid). A point p lies on the line through p0 along d iff the sine of the
        // angle between (p-p0) and d — |(p-p0)×d|/|p-p0| — is below sinEps. This is immune to
        // aspect ratio: a high-aspect grid (0,0),(100,0),(0,0.5),(100,0.5) has sin≈0.05 for the
        // 0.5-offset points, correctly flagged non-collinear, where an absolute or diagonal-scaled
        // distance tolerance would wrongly accept them. Works regardless of point order.
        let sinEps: Float = 0.05   // ~3° from parallel still treated as collinear
        guard let p0 = points.first, let idx = points.firstIndex(where: { $0 != p0 }) else { return true }
        let p1 = points[idx]
        let dir = p1 - p0
        let len = simd_length(dir)
        guard len > 1e-6 else { return true }
        let d = dir / len
        for p in points {
            let v = p - p0
            let dist = simd_length(v)
            guard dist > 1e-6 else { continue }       // p coincides with p0 → on the line
            let sinAngle = simd_length(simd_cross(v, d)) / dist
            if sinAngle > sinEps { return false }
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
        return after.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            .flatMap { Float($0) }.flatMap { $0.isFinite ? $0 : nil }
    }

    /// True when the QE text indicates a calculation without time-reversal
    /// symmetry, where E(k) = E(-k) does not hold: magnetic (nonzero
    /// magnetization), spin-orbit/noncollinear, or field-driven runs. Such
    /// calculations must not have symmetry-reduced k-meshes unfolded.
    ///
    /// Marker presence alone is not definitive: QE echoes `lspinorb = .false.`
    /// and `total magnetization = 0.00` in runs that preserve TR, so echoed
    /// values are parsed rather than the bare phrases.
    private static func detectTimeReversalBreaking(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("noncollinear") || lower.contains("non-collinear") { return true }
        // The "magnetization (x)" per-atom moment table is printed only by
        // magnetic (nspin=2/4) runs.
        if lower.contains("magnetization (x)") { return true }
        // SOC flags: parse the echoed value — lspinorb = .true. breaks TR,
        // lspinorb = .false. does not. A bare "spin-orbit" mention without a
        // parseable value stays conservative (treated as breaking).
        if flagBooleanAfter(marker: "lspinorb", in: lower) == true { return true }
        if flagBooleanAfter(marker: "spin_orbit", in: lower) == true { return true }
        if lower.contains("spin-orbit") { return true }
        // Net magnetization: only a NONZERO value marks a magnetic calculation
        // (a compensated AFM or a forced-but-unpolarized run prints 0.00).
        if let mag = numericValueAfter(marker: "total magnetization", in: lower), mag != 0 {
            return true
        }
        // QE echoes "starting_magnetization(i)=0.0" even for non-magnetic runs,
        // so only a NONZERO value marks a magnetic calculation.
        var scan = lower.startIndex
        while let range = lower.range(of: "starting_magnetization", range: scan..<lower.endIndex) {
            scan = range.upperBound
            guard let eq = lower.range(of: "=", range: scan..<lower.endIndex) else { break }
            let tail = String(lower[eq.upperBound...]).prefix(24)
            // The value may be separated by spaces ("= 0.0000") or end the line
            // ("=0.7\n"); split on whitespace and newlines so the numeric token
            // never carries trailing whitespace.
            if let token = tail.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first,
               let value = Float(token), value != 0 {
                return true
            }
        }
        return false
    }

    /// The Fortran-boolean token echoed after `marker =` (e.g. "lspinorb = .true."):
    /// true → .true., false → .false., nil when absent or unparseable.
    private static func flagBooleanAfter(marker: String, in lower: String) -> Bool? {
        guard let m = lower.range(of: marker) else { return nil }
        guard let eq = lower.range(of: "=", range: m.upperBound..<lower.endIndex) else { return nil }
        let tail = lower[eq.upperBound...].prefix(24)
        guard let token = tail.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first?.lowercased() else {
            return nil
        }
        if token.contains("true") || token == "t" { return true }
        if token.contains("false") || token == "f" { return false }
        return nil
    }

    /// The first numeric token echoed after `marker =` (e.g. "total magnetization = 0.72 a.u."),
    /// or nil when the marker or a numeric value is absent.
    private static func numericValueAfter(marker: String, in lower: String) -> Float? {
        guard let m = lower.range(of: marker) else { return nil }
        guard let eq = lower.range(of: "=", range: m.upperBound..<lower.endIndex) else { return nil }
        let tail = lower[eq.upperBound...].prefix(48)
        for token in tail.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            if let value = Float(token) { return value }
        }
        return nil
    }

    /// Parse the reciprocal lattice vectors b1..b3 from the QE "reciprocal axes"
    /// block (in units of 2π/a_0). Returns nil if the block is absent/malformed.
    ///
    /// Restarted, concatenated, or variable-cell outputs can print several
    /// "reciprocal axes" blocks. Band parsing selects the FINAL band iteration
    /// and real-space parsing keeps the LAST complete cell, so the reciprocal
    /// basis must come from the LAST complete block too — an earlier block can
    /// describe a different (stale) lattice.
    private static func parseReciprocal(_ text: String) -> [SIMD3<Float>]? {
        let lines = text.components(separatedBy: "\n")
        var best: [SIMD3<Float>]? = nil
        for (marker, line) in lines.enumerated() where line.contains("reciprocal axes") {
            // The three vector rows follow the marker: "b(1) = ( x y z )".
            var vecs: [SIMD3<Float>] = []
            for offset in 1...3 {
                let idx = marker + offset
                guard idx < lines.count else { break }
                // Isolate the parenthesised triple.
                guard let lpar = lines[idx].firstIndex(of: "("),
                      let rpar = lines[idx].lastIndex(of: ")"), rpar > lpar else { break }
                let body = String(lines[idx][lines[idx].index(after: lpar)..<rpar])
                let nums = body.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).compactMap { Float($0) }
                guard nums.count >= 3, nums[0].isFinite, nums[1].isFinite, nums[2].isFinite else { break }
                vecs.append(SIMD3<Float>(nums[0], nums[1], nums[2]))
            }
            if vecs.count == 3 { best = vecs }
        }
        return best
    }

    /// Parse QE real-space lattice vectors into Angstroms. Modern PWscf output
    /// may provide either `crystal axes` in units of a_0 or a later
    /// `CELL_PARAMETERS` block; the last complete block wins, matching the C
    /// QE structure parser's treatment of updated cells.
    static func parseRealSpaceCell(_ text: String) -> Cell? {
        let lines = text.components(separatedBy: "\n")
        let bohrToAngstrom: Float = 0.52917721067
        var alatBohr: Float?
        var result: Cell?

        for index in lines.indices {
            let line = lines[index]
            let lower = line.lowercased()

            if lower.contains("lattice parameter") {
                if let equals = line.firstIndex(of: "=") {
                    let tail = String(line[line.index(after: equals)...])
                    if let value = finiteNumbers(in: tail).first, value > 0 {
                        alatBohr = value
                    }
                }
            }

            if lower.contains("crystal axes") {
                guard index + 3 < lines.count, let alat = alatBohr else { continue }
                var vectors: [SIMD3<Float>] = []
                for offset in 1...3 {
                    let row = lines[index + offset]
                    guard let lpar = row.lastIndex(of: "("),
                          let rpar = row.lastIndex(of: ")"), rpar > lpar else {
                        vectors.removeAll(); break
                    }
                    let body = String(row[row.index(after: lpar)..<rpar])
                    let values = finiteNumbers(in: body)
                    guard values.count >= 3 else { vectors.removeAll(); break }
                    vectors.append(SIMD3(values[0], values[1], values[2]) * (alat * bohrToAngstrom))
                }
                if vectors.count == 3 { result = Cell(a: vectors[0], b: vectors[1], c: vectors[2]) }
                continue
            }

            guard lower.trimmingCharacters(in: .whitespaces).hasPrefix("cell_parameters") else { continue }
            guard index + 3 < lines.count else { continue }
            let scale: Float
            if lower.contains("angstrom") {
                scale = 1
            } else if lower.contains("bohr") || lower.contains("a.u.") || lower.contains("atomic") {
                scale = bohrToAngstrom
            } else if let equals = lower.firstIndex(of: "=") {
                let tail = String(lower[lower.index(after: equals)...])
                guard let localAlat = finiteNumbers(in: tail).first, localAlat > 0 else { continue }
                scale = localAlat * bohrToAngstrom
            } else if let alat = alatBohr {
                scale = alat * bohrToAngstrom
            } else {
                continue
            }
            var vectors: [SIMD3<Float>] = []
            for offset in 1...3 {
                let values = finiteNumbers(in: lines[index + offset])
                guard values.count >= 3 else { vectors.removeAll(); break }
                vectors.append(SIMD3(values[0], values[1], values[2]) * scale)
            }
            if vectors.count == 3 { result = Cell(a: vectors[0], b: vectors[1], c: vectors[2]) }
        }
        guard let cell = result, cell.isFinite else { return nil }
        return cell
    }

    /// Infer the physical periodicity when QE states it explicitly. A normal
    /// QE cell is a 3D periodic crystal; `assume_isolated=2D`/`esm` denotes a
    /// slab, while molecule-style isolated corrections are treated as 0D.
    private static func parsePeriodicDimension(_ text: String, hasCell: Bool) -> Int {
        let lower = text.lowercased()
        if let range = lower.range(of: "assume_isolated") {
            let tail = String(lower[range.upperBound...]).prefix(160)
            if tail.contains("2d") || tail.contains("esm") { return 2 }
            if tail.contains("1d") { return 1 }
            if tail.contains("martyna") || tail.contains("tuckerman") ||
                tail.contains("parabolic") || tail.contains("'mt'") ||
                tail.contains("\"mt\"") {
                return 0
            }
        }
        return hasCell ? 3 : 0
    }

    private static func finiteNumbers(in text: String) -> [Float] {
        let pattern = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eEdD][+-]?\d+)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let token = String(text[range]).replacingOccurrences(of: "D", with: "e")
                .replacingOccurrences(of: "d", with: "e")
            guard let value = Float(token), value.isFinite else { return nil }
            return value
        }
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
        guard nums.count >= 3, nums[0].isFinite, nums[1].isFinite, nums[2].isFinite else { return nil }
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
        return Float(token).flatMap { $0.isFinite ? $0 : nil }
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
