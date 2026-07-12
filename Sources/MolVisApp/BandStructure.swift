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
    let weight: Float
    let label: String
    var energies: [Float]   // eV, per band index
}

/// A parsed band structure. `bands[ib][ik]` = energy of band ib at k-point ik.
/// `kDistances` is the cumulative path length in fractional-reciprocal units, used
/// as the x-coordinate of the Grapher.
struct BandStructure: Codable {
    var kPoints: [BandKPoint]
    var fermiEnergy: Float
    var nSpin: Int

    /// Number of bands (assume uniform across k-points).
    var nBands: Int { kPoints.first?.energies.count ?? 0 }
    var nKPoints: Int { kPoints.count }

    /// Cumulative path distance for each k-point (x-axis of the band plot).
    var kDistances: [Float] {
        var d: [Float] = [0]
        for i in 1..<kPoints.count {
            let dk = kPoints[i].k - kPoints[i - 1].k
            d.append(d.last! + sqrt(dot(dk, dk)))
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
        // First pass: split the file into per-iteration blocks. Every "the Fermi
        // energy is ..." line ends an iteration; the k-points preceding it (since
        // the previous delimiter, or file start) belong to that iteration.
        var iterations: [(kPoints: [BandKPoint], fermi: Float)] = []
        var current: [BandKPoint] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let f = parseFermiEnergy(line) {
                if !current.isEmpty { iterations.append((current, f)) }
                current = []
                i += 1; continue
            }
            guard let k = parseKHeader(line) else { i += 1; continue }
            // A k-point header: scan forward for its wrapped eigenvalue rows.
            i += 1
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            var energies: [Float] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if parseFermiEnergy(t) != nil { break }   // next iteration reached
                if parseKHeader(t) != nil { break }        // next k-point reached
                var row: [Float] = []
                for s in t.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    if let v = Float(s) { row.append(v) }
                }
                if row.isEmpty { break }
                energies.append(contentsOf: row)
                i += 1
            }
            if !energies.isEmpty {
                current.append(BandKPoint(k: k, weight: 0, label: "", energies: energies))
            }
        }
        // Choose the final complete iteration; a file with no Fermi line is one
        // iteration whose Fermi energy is unavailable.
        var chosen: ([BandKPoint], Float)?
        if iterations.isEmpty {
            chosen = (current, 0)
        } else {
            chosen = iterations.last
        }
        guard let (kPoints, fermi) = chosen, !kPoints.isEmpty else { return nil }

        // Deduce the band count from the MODE (most common length), and drop any
        // k-point whose record does NOT match it. Zero-padding short records would
        // fabricate bands that were never computed and distort the Fermi region.
        let counts = kPoints.map { $0.energies.count }
        let bandCount = modalValue(counts) ?? counts.max() ?? 0
        let filtered = kPoints.filter { $0.energies.count == bandCount }
        guard !filtered.isEmpty else { return nil }
        return BandStructure(kPoints: filtered, fermiEnergy: fermi, nSpin: 1)
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

    /// Parse "     the Fermi energy is     4.6669 ev" -> 4.6669.
    private static func parseFermiEnergy(_ line: String) -> Float? {
        // Require the literal QE phrase so a casual "Fermi" mention elsewhere (e.g.
        // a methods paragraph) does not false-positive.
        guard line.contains("the Fermi energy is") else { return nil }
        let pattern = #"[0-9]+\.[0-9]+"#
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        return Float(line[r])
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
