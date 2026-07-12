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
// nil if no band data is found (caller falls back to the structure parser).
enum BandParser {
    static func parse(_ text: String) -> BandStructure? {
        let lines = text.components(separatedBy: "\n")
        var kPoints: [BandKPoint] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Match a k-point header:
            //   "  k =  .1250  .2165 -.1852 ( 6180 PWs)   bands (ev):"
            guard let k = parseKHeader(line) else { i += 1; continue }
            // Next line is blank; then wrapped eigenvalue lines until blank/EOF.
            i += 1
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            var energies: [Float] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                let toks = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
                var row: [Float] = []
                for s in toks { if let v = Float(s) { row.append(v) } }
                if row.isEmpty { break }   // next k-point header or section
                energies.append(contentsOf: row)
                i += 1
            }
            if !energies.isEmpty {
                kPoints.append(BandKPoint(k: k.k, weight: k.weight, label: "", energies: energies))
            }
        }
        guard !kPoints.isEmpty else { return nil }
        // Deduce a consistent band count from the mode (most common length).
        let counts = kPoints.map { $0.energies.count }
        let bandCount = counts.max() ?? 0
        for j in 0..<kPoints.count where kPoints[j].energies.count < bandCount {
            kPoints[j].energies.append(contentsOf: [Float](repeating: 0, count: bandCount - kPoints[j].energies.count))
        }
        return BandStructure(kPoints: kPoints, fermiEnergy: 0, nSpin: 1)
    }

    private struct KHeader { let k: SIMD3<Float>; let weight: Float }

    /// Parse "  k =  .1250  .2165 -.1852 ( 6180 PWs)   bands (ev):" ->
    /// (k=(0.125,0.2165,-0.1852), weight) using a relaxed regex-free scan.
    private static func parseKHeader(_ line: String) -> KHeader? {
        // Find the "k =" token.
        guard let eqRange = line.range(of: "k =") ?? line.range(of: "k=") else { return nil }
        let after = String(line[eqRange.upperBound...])
        let toks = after.split(whereSeparator: { $0 == " " || $0 == "\t" })
        var nums: [Float] = []
        for t in toks {
            if let v = Float(t) { nums.append(v) }
            if nums.count == 4 { break }   // kx,ky,kz then weight (wk)
        }
        guard nums.count >= 3 else { return nil }
        return KHeader(k: SIMD3<Float>(nums[0], nums[1], nums[2]), weight: nums.count > 3 ? nums[3] : 0)
    }
}
