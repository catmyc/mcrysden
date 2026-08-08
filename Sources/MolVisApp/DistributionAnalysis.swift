import Foundation
import simd

/// A histogram bin with a center value and raw count.
struct HistogramBin: Equatable {
    let center: Float
    let count: Int
}

/// A named histogram with axis metadata and CSV serialization.
struct Histogram: Equatable {
    let title: String
    let xLabel: String
    let yLabel: String
    let bins: [HistogramBin]
    let binWidth: Float

    var isEmpty: Bool { bins.allSatisfy { $0.count == 0 } }

    /// Serialize as CSV: `xLabel,yLabel` header, one row per bin.
    func csv() -> String {
        var lines: [String] = ["\(xLabel),\(yLabel)"]
        for bin in bins {
            lines.append("\(bin.center),\(bin.count)")
        }
        return lines.joined(separator: "\n")
    }
}

/// A single RDF bin with the raw pair count and the normalized g(r) value.
struct RDFBin: Equatable {
    let center: Float
    let g: Float
    let pairCount: Int
}

/// Radial distribution function result. Either available with actual g(r)
/// values, or unavailable with a reason.
struct RDFResult: Equatable {
    let bins: [RDFBin]
    let pairCount: Int
    let maxRadius: Float
    let wasCapped: Bool
    let unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }
    var isEmpty: Bool { bins.allSatisfy { $0.pairCount == 0 } }

    /// Serialize as CSV with actual g(r) values: `r (Å),g(r),count`.
    func csv() -> String {
        var lines: [String] = ["r (Å),g(r),count"]
        for bin in bins {
            lines.append("\(bin.center),\(bin.g),\(bin.pairCount)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Result of a distribution analysis derived from a coordination result.
/// All histograms avoid double-counting reciprocal pairs.
struct DistributionAnalysis: Equatable {
    let bondLengthHistogram: Histogram
    let bondAngleHistogram: Histogram
    let radialDistribution: RDFResult
    let uniquePairCount: Int
    let uniqueAngleCount: Int
}

/// Computes bond-length, bond-angle, and radial distribution analyses from a
/// coordination result. The bond-length and bond-angle histograms reuse the
/// existing neighbor records (already bounded by the covalent-radius cutoff).
/// The RDF performs a separate spatial-indexed pair enumeration up to a
/// cutoff capped at half the shortest cell height, with a hard candidate-check
/// limit that returns unavailable transactionally (never a partial result).
enum DistributionAnalyzer {
    static let defaultMaxHistogramBins = 200
    static let defaultHistogramBinCount = 100
    static let defaultMaxAngles = 5_000_000
    static let defaultMaxRDFBins = 500
    static let defaultRDFMaxRadius: Float = 20.0
    /// Maximum atoms for RDF enumeration. The cell-list spatial index keeps
    /// work proportional to n·k (average atoms in 27 neighbor cells), but we
    /// still cap n to bound worst-case memory and time.
    static let defaultMaxRDFAtoms = 5_000
    /// Hard cap on candidate distance evaluations. Exceeding this returns
    /// unavailable transactionally rather than a partial or hanging result.
    static let defaultMaxRDFCandidates = 10_000_000

    /// Cell volume |a · (b × c)|. Returns nil for a non-finite or singular cell.
    static func cellVolume(_ cell: Cell) -> Float? {
        guard cell.isFinite else { return nil }
        let a = SIMD3<Double>(Double(cell.a.x), Double(cell.a.y), Double(cell.a.z))
        let b = SIMD3<Double>(Double(cell.b.x), Double(cell.b.y), Double(cell.b.z))
        let c = SIMD3<Double>(Double(cell.c.x), Double(cell.c.y), Double(cell.c.z))
        guard a.isFinite, b.isFinite, c.isFinite else { return nil }
        let vol = abs(dot(a, cross(b, c)))
        guard vol.isFinite, vol > 1e-16 else { return nil }
        return Float(vol)
    }

    /// Shortest cell height (minimum distance between opposite faces). The RDF
    /// cutoff is capped at half this value: within that radius the
    /// minimum-image convention guarantees each atom has at most one image in
    /// any cell, so no self-image pair can appear.
    static func shortestCellHeight(_ cell: Cell) -> Float? {
        guard let volume = cellVolume(cell) else { return nil }
        let volumeD = Double(volume)
        let a = cell.a.double, b = cell.b.double, c = cell.c.double
        let bc = length(cross(b, c))
        let ca = length(cross(c, a))
        let ab = length(cross(a, b))
        guard bc > 1e-16, ca > 1e-16, ab > 1e-16 else { return nil }
        let hA = volumeD / bc
        let hB = volumeD / ca
        let hC = volumeD / ab
        let minHeight = Swift.min(hA, Swift.min(hB, hC))
        guard minHeight.isFinite, minHeight > 0 else { return nil }
        return Float(minHeight)
    }

    /// Canonical pair key: (sourceIndex, targetIndex, imageOffset). Returns
    /// the canonical form that should be counted exactly once. For the
    /// bond-length histogram (which uses the covalent-cutoff neighbor list)
    /// self-image bonds with nonzero offset are included when the offset is
    /// positive.
    private struct CanonicalPair: Hashable {
        let source: Int
        let target: Int
        let offset: SIMD3<Int32>

        init(source: Int, target: Int, offset: SIMD3<Int32>) {
            if source < target {
                self.source = source
                self.target = target
                self.offset = offset
            } else if source > target {
                self.source = target
                self.target = source
                self.offset = SIMD3<Int32>(-offset.x, -offset.y, -offset.z)
            } else {
                // source == target: canonicalize offset to positive half-space.
                if offset.x > 0 || (offset.x == 0 && offset.y > 0) ||
                    (offset.x == 0 && offset.y == 0 && offset.z > 0) {
                    self.source = source
                    self.target = target
                    self.offset = offset
                } else {
                    self.source = source
                    self.target = target
                    self.offset = SIMD3<Int32>(-offset.x, -offset.y, -offset.z)
                }
            }
        }

        var isZeroOffsetSelfPair: Bool {
            source == target && offset.x == 0 && offset.y == 0 && offset.z == 0
        }
    }

    /// Compute all distribution analyses from the coordination result.
    static func analyze(
        _ analysis: CoordinationAnalysis,
        atoms: [Atom],
        cell: Cell?,
        periodicDim: Int,
        binCount: Int = defaultHistogramBinCount,
        rdfBins: Int = defaultMaxRDFBins,
        rdfMaxRadius: Float = defaultRDFMaxRadius,
        isCancelled: (() -> Bool)? = nil
    ) -> DistributionAnalysis? {
        guard !atoms.isEmpty else { return nil }
        if isCancelled?() == true { return nil }
        let bondLength = bondLengthHistogram(analysis, atoms: atoms, binCount: binCount, isCancelled: isCancelled)
        if isCancelled?() == true { return nil }
        let bondAngle = bondAngleHistogram(analysis, atoms: atoms, binCount: binCount, isCancelled: isCancelled)
        if isCancelled?() == true { return nil }
        let rdf = radialDistribution(atoms: atoms, cell: cell,
                                      periodicDim: periodicDim, binCount: rdfBins,
                                      maxRadius: rdfMaxRadius, isCancelled: isCancelled)
        return DistributionAnalysis(
            bondLengthHistogram: bondLength.histogram,
            bondAngleHistogram: bondAngle.histogram,
            radialDistribution: rdf,
            uniquePairCount: bondLength.pairCount,
            uniqueAngleCount: bondAngle.angleCount
        )
    }

    // MARK: - Bond-length distribution (no double counting)

    private struct BondLengthResult {
        let histogram: Histogram
        let pairCount: Int
    }

    /// Collect unique neighbor distances with proper canonicalization and bin
    /// them into a histogram. Self-image bonds (same atom in a periodic image)
    /// are included when the offset is canonical.
    private static func bondLengthHistogram(
        _ analysis: CoordinationAnalysis,
        atoms: [Atom],
        binCount: Int,
        isCancelled: (() -> Bool)?
    ) -> BondLengthResult {
        let clampedBins = max(1, min(defaultMaxHistogramBins, binCount))
        var seen = Set<CanonicalPair>()
        seen.reserveCapacity(analysis.neighbors.count / 2)
        var uniqueDistances: [Float] = []
        uniqueDistances.reserveCapacity(analysis.neighbors.count / 2)
        var minDist = Float.greatestFiniteMagnitude
        var maxDist: Float = 0

        for sourceIndex in analysis.offsets.dropLast().indices {
            if isCancelled?() == true { break }
            let start = analysis.offsets[sourceIndex]
            let end = analysis.offsets[sourceIndex + 1]
            for i in start..<end {
                let neighbor = analysis.neighbors[i]
                let pair = CanonicalPair(source: sourceIndex, target: neighbor.atomIndex,
                                          offset: neighbor.imageOffset)
                // Skip the zero-offset self-pair (same atom, same cell).
                if pair.isZeroOffsetSelfPair { continue }
                guard seen.insert(pair).inserted else { continue }
                let d = neighbor.distance
                guard d.isFinite, d > 0 else { continue }
                uniqueDistances.append(d)
                if d < minDist { minDist = d }
                if d > maxDist { maxDist = d }
            }
        }

        guard !uniqueDistances.isEmpty else {
            let bins = makeEmptyBins(count: clampedBins, range: 0...1)
            return BondLengthResult(
                histogram: Histogram(title: "Bond-Length Distribution",
                                     xLabel: "distance (Å)", yLabel: "count",
                                     bins: bins, binWidth: 1),
                pairCount: 0
            )
        }

        let binWidth = (maxDist - minDist) / Float(clampedBins)
        if binWidth <= 0 {
            // All distances are identical: one bin holding the actual count.
            let center = uniqueDistances.reduce(0, +) / Float(uniqueDistances.count)
            let bins = [HistogramBin(center: center, count: uniqueDistances.count)]
            return BondLengthResult(
                histogram: Histogram(title: "Bond-Length Distribution",
                                     xLabel: "distance (Å)", yLabel: "count",
                                     bins: bins, binWidth: 0),
                pairCount: uniqueDistances.count
            )
        }

        var counts = [Int](repeating: 0, count: clampedBins)
        for d in uniqueDistances {
            var idx = Int((d - minDist) / binWidth)
            if idx >= clampedBins { idx = clampedBins - 1 }
            if idx < 0 { idx = 0 }
            counts[idx] += 1
        }

        let bins = (0..<clampedBins).map { i in
            HistogramBin(center: minDist + (Float(i) + 0.5) * binWidth, count: counts[i])
        }

        return BondLengthResult(
            histogram: Histogram(title: "Bond-Length Distribution",
                                 xLabel: "distance (Å)", yLabel: "count",
                                 bins: bins, binWidth: binWidth),
            pairCount: uniqueDistances.count
        )
    }

    // MARK: - Bond-angle distribution (uses stored minimum-image displacement)

    private struct BondAngleResult {
        let histogram: Histogram
        let angleCount: Int
    }

    /// For each atom (as central vertex), compute angles between all unique
    /// pairs of its neighbors. Uses the stored minimum-image displacement from
    /// the coordination analysis so periodic angles are correct.
    private static func bondAngleHistogram(
        _ analysis: CoordinationAnalysis,
        atoms: [Atom],
        binCount: Int,
        isCancelled: (() -> Bool)?
    ) -> BondAngleResult {
        let clampedBins = max(1, min(defaultMaxHistogramBins, binCount))
        let binWidth = 180.0 / Float(clampedBins)
        guard binWidth > 0 else {
            return BondAngleResult(
                histogram: Histogram(title: "Bond-Angle Distribution",
                                     xLabel: "angle (°)", yLabel: "count",
                                     bins: [], binWidth: 0),
                angleCount: 0
            )
        }

        var counts = [Int](repeating: 0, count: clampedBins)
        var angleCount = 0

        for centralIndex in analysis.offsets.dropLast().indices {
            if isCancelled?() == true { break }
            let start = analysis.offsets[centralIndex]
            let end = analysis.offsets[centralIndex + 1]
            guard end - start >= 2 else { continue }

            // Collect neighbor displacement vectors using the stored
            // minimum-image displacement from the coordination analysis.
            var neighborVectors: [(index: Int, displacement: SIMD3<Float>)] = []
            neighborVectors.reserveCapacity(end - start)
            for i in start..<end {
                let neighbor = analysis.neighbors[i]
                guard neighbor.atomIndex >= 0, neighbor.atomIndex < atoms.count else { continue }
                if neighbor.atomIndex == centralIndex &&
                    neighbor.imageOffset.x == 0 && neighbor.imageOffset.y == 0 &&
                    neighbor.imageOffset.z == 0 { continue }
                guard neighbor.displacement.isFinite else { continue }
                let len = length(neighbor.displacement)
                guard len.isFinite, len > 1e-8 else { continue }
                neighborVectors.append((neighbor.atomIndex, neighbor.displacement))
            }

            guard neighborVectors.count >= 2 else { continue }

            let maxPairs = defaultMaxAngles - angleCount
            guard maxPairs > 0 else { break }

            var pairsComputed = 0
            for i in 0..<(neighborVectors.count - 1) {
                if pairsComputed >= maxPairs { break }
                let vi = neighborVectors[i].displacement
                let lenI = length(vi)
                for j in (i + 1)..<neighborVectors.count {
                    if pairsComputed >= maxPairs { break }
                    let vj = neighborVectors[j].displacement
                    let lenJ = length(vj)
                    guard lenJ.isFinite, lenJ > 1e-8 else { continue }
                    let cosAngle = min(max(dot(vi / lenI, vj / lenJ), -1), 1)
                    let angle = acos(cosAngle) * 180 / .pi
                    guard angle.isFinite else { continue }
                    var idx = Int(angle / binWidth)
                    if idx >= clampedBins { idx = clampedBins - 1 }
                    if idx < 0 { idx = 0 }
                    counts[idx] += 1
                    angleCount += 1
                    pairsComputed += 1
                }
            }
        }

        let bins = (0..<clampedBins).map { i in
            HistogramBin(center: (Float(i) + 0.5) * binWidth, count: counts[i])
        }

        return BondAngleResult(
            histogram: Histogram(title: "Bond-Angle Distribution",
                                 xLabel: "angle (°)", yLabel: "count",
                                 bins: bins, binWidth: binWidth),
            angleCount: angleCount
        )
    }

    // MARK: - Radial distribution function (spatial-indexed pair enumeration)

    /// Compute the RDF using a cell-list spatial index so that only atoms in
    /// neighboring cells are evaluated as candidate pairs. The cutoff is
    /// capped at half the shortest cell height, which guarantees no
    /// self-image pair can fall within the cutoff. A hard candidate-check
    /// limit bounds worst-case work; exceeding it returns unavailable
    /// transactionally (never a partial result).
    ///
    /// Normalization: g(r) = (V / N²) · (2 · count) / shell_volume
    /// where shell_volume = (4/3)π · (rHi³ − rLo³).
    private static func radialDistribution(
        atoms: [Atom],
        cell: Cell?,
        periodicDim: Int,
        binCount: Int,
        maxRadius: Float,
        isCancelled: (() -> Bool)?
    ) -> RDFResult {
        guard periodicDim == 3 else {
            let reason: String
            switch periodicDim {
            case 0: reason = "RDF requires a 3D periodic cell (molecule)"
            case 1: reason = "RDF requires a 3D periodic cell (1D system)"
            case 2: reason = "RDF requires a 3D periodic cell (2D system)"
            default: reason = "RDF requires a 3D periodic cell"
            }
            return RDFResult(bins: [], pairCount: 0, maxRadius: 0,
                             wasCapped: false, unavailableReason: reason)
        }
        guard let cell, let volume = cellVolume(cell) else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: 0,
                             wasCapped: false,
                             unavailableReason: "RDF requires a valid 3D periodic cell")
        }
        guard volume > 0 else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: 0,
                             wasCapped: false,
                             unavailableReason: "RDF requires a non-zero cell volume")
        }
        let n = atoms.count
        guard n > 0 else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: 0,
                             wasCapped: false,
                             unavailableReason: "RDF requires at least one atom")
        }

        guard let shortestHeight = shortestCellHeight(cell) else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: 0,
                             wasCapped: false,
                             unavailableReason: "RDF requires a non-singular cell")
        }
        let volumeD = Double(volume)
        let maxAllowedRadius = shortestHeight / 2.0
        let actualRadius = min(maxRadius, maxAllowedRadius)
        let wasCapped = maxRadius > maxAllowedRadius
        guard actualRadius > 0 else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: 0,
                             wasCapped: wasCapped,
                             unavailableReason: "RDF cutoff radius is zero")
        }

        guard n <= defaultMaxRDFAtoms else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: actualRadius,
                             wasCapped: wasCapped,
                             unavailableReason: "RDF unavailable for \(n) atoms (cap \(defaultMaxRDFAtoms))")
        }

        let clampedBins = max(1, min(defaultMaxRDFBins, binCount))
        let binWidth = actualRadius / Float(clampedBins)
        guard binWidth > 0 else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: actualRadius,
                             wasCapped: wasCapped,
                             unavailableReason: "RDF bin width is zero")
        }

        // Build a fractional-torus cell list. The Cartesian-to-fractional
        // inverse maps each atom to wrapped [0,1) fractional coordinates.
        // Bin counts along each axis come from the perpendicular cell heights
        // so that one bin spans ≤ actualRadius in Cartesian space along its
        // axis. Neighbor bins are enumerated with wrap-around and
        // deduplicated, so minimum-image-close atoms across any boundary —
        // including skew/rotated cells — are never omitted.
        guard let inv = cell.inverseMatrix else {
            return RDFResult(bins: [], pairCount: 0, maxRadius: actualRadius,
                             wasCapped: wasCapped,
                             unavailableReason: "RDF requires an invertible cell")
        }
        let aD = cell.a.double, bD = cell.b.double, cD = cell.c.double
        let hA = volumeD / length(cross(bD, cD))
        let hB = volumeD / length(cross(cD, aD))
        let hC = volumeD / length(cross(aD, bD))
        let nA = max(1, Int(ceil(hA / Double(actualRadius))))
        let nB = max(1, Int(ceil(hB / Double(actualRadius))))
        let nC = max(1, Int(ceil(hC / Double(actualRadius))))

        // Conservative per-axis neighbor span: one bin covers ≤ actualRadius
        // along its axis, so ±1 bin in each direction covers the cutoff even
        // for skew cells where fractional axes are not Cartesian-orthogonal.
        let spanA = max(1, Int(ceil(Double(actualRadius) / (hA / Double(nA)))))
        let spanB = max(1, Int(ceil(Double(actualRadius) / (hB / Double(nB)))))
        let spanC = max(1, Int(ceil(Double(actualRadius) / (hC / Double(nC)))))

        // Compute wrapped fractional bin index for each atom.
        struct BinKey: Hashable {
            let a: Int; let b: Int; let c: Int
        }
        var binIndices: [BinKey] = []
        binIndices.reserveCapacity(n)
        for atom in atoms {
            let p = SIMD3<Double>(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
            let f = inv * p
            // Wrap to [0,1) then scale to bin index. A wrapped fractional that
            // rounds up to exactly 1.0 (fp edge: f.x - floor(f.x) ≈ 1-eps scaled
            // and rounded) would yield index == nA, silently dropping the atom out
            // of the bin array. Clamp to [0, nA-1] so every atom lands in-range.
            let fa = f.x - floor(f.x)
            let fb = f.y - floor(f.y)
            let fc = f.z - floor(f.z)
            binIndices.append(BinKey(
                a: min(nA - 1, Int(floor(fa * Double(nA)))),
                b: min(nB - 1, Int(floor(fb * Double(nB)))),
                c: min(nC - 1, Int(floor(fc * Double(nC))))))
        }

        // Group atoms by bin.
        var cellMap: [BinKey: [Int]] = [:]
        for idx in 0..<n {
            cellMap[binIndices[idx], default: []].append(idx)
        }

        var counts = [Int](repeating: 0, count: clampedBins)
        var pairCount = 0
        var candidates = 0
        let maxCandidates = defaultMaxRDFCandidates

        for i in 0..<n {
            if isCancelled?() == true { break }
            let ai = atoms[i].coord
            guard ai.isFinite else { continue }
            let bi = binIndices[i]

            // Enumerate wrapped neighbor bins with deduplication.
            var visited = Set<BinKey>()
            for da in -spanA...spanA {
                let na = ((bi.a + da) % nA + nA) % nA
                for db in -spanB...spanB {
                    let nb = ((bi.b + db) % nB + nB) % nB
                    for dc in -spanC...spanC {
                        let nc = ((bi.c + dc) % nC + nC) % nC
                        let key = BinKey(a: na, b: nb, c: nc)
                        guard visited.insert(key).inserted else { continue }
                        guard let cellAtoms = cellMap[key] else { continue }
                        for j in cellAtoms {
                            guard j > i else { continue }

                            candidates += 1
                            if candidates > maxCandidates {
                                return RDFResult(bins: [], pairCount: 0, maxRadius: actualRadius,
                                                 wasCapped: wasCapped,
                                                 unavailableReason: "RDF unavailable: exceeded \(maxCandidates) candidate pairs")
                            }

                            let aj = atoms[j].coord
                            guard aj.isFinite else { continue }

                            guard let d = PeriodicGeometry.minimumImageDistance(
                                from: ai, to: aj, cell: cell, periodicDim: 3) else {
                                continue
                            }
                            guard d > 0, d <= actualRadius else { continue }

                            var idx = Int(d / binWidth)
                            if idx >= clampedBins { idx = clampedBins - 1 }
                            if idx < 0 { idx = 0 }
                            counts[idx] += 1
                            pairCount += 1
                        }
                    }
                }
            }
        }

        // If cancellation fired mid-loop, return unavailable.
        if isCancelled?() == true {
            return RDFResult(bins: [], pairCount: 0, maxRadius: actualRadius,
                             wasCapped: wasCapped,
                             unavailableReason: "RDF cancelled")
        }

        let nF = Float(n)
        let factor = volume / (nF * nF)

        let rdfBins = (0..<clampedBins).map { i -> RDFBin in
            let rCenter = (Float(i) + 0.5) * binWidth
            let rLo = Float(i) * binWidth
            let rHi = Float(i + 1) * binWidth
            let shellVolume = (4.0 / 3.0) * .pi * (rHi * rHi * rHi - rLo * rLo * rLo)
            let g: Float
            if shellVolume > 0 {
                g = factor * (2.0 * Float(counts[i])) / shellVolume
            } else {
                g = 0
            }
            return RDFBin(center: rCenter, g: g, pairCount: counts[i])
        }

        return RDFResult(bins: rdfBins, pairCount: pairCount,
                         maxRadius: actualRadius, wasCapped: wasCapped,
                         unavailableReason: nil)
    }

    // MARK: - Helpers

    private static func makeEmptyBins(count: Int, range: ClosedRange<Float>) -> [HistogramBin] {
        guard count > 0 else { return [] }
        let width = (range.upperBound - range.lowerBound) / Float(count)
        guard width > 0 else { return [HistogramBin(center: range.lowerBound, count: 0)] }
        return (0..<count).map { i in
            HistogramBin(center: range.lowerBound + (Float(i) + 0.5) * width, count: 0)
        }
    }
}
