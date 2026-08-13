import Foundation
import simd

// Axis-aligned uniform k-point mesh detection and periodic trilinear interpolation.
//
// A band-structure mesh (Monkhorst-Pack sampling) is a COMPLETE multidimensional
// lattice: every integer combination of its per-axis node spacings. Detection
// normalizes each k-coordinate mod 1, finds the per-axis sorted unique node list,
// verifies uniform internal spacing AND a complete periodic closure (the closing
// gap between the last node and the wrapped-first node must equal the internal
// step), then builds a lattice-index -> source-index mapping so values can be
// interpolated by channel order regardless of how the source k-points were ordered.
//
// Meshes internally uniform but incomplete along exactly ONE axis may be a
// time-reversal-reduced half-grid (QE noinv): if the negated nodes complete it
// into a uniformly-spaced superset AND the structure is single-spin, the half axis
// is unfolded (doubled) and every new lattice point k reuses the channel index of
// its full time-reversal partner -k (E(k) = E(-k), applied on all coordinates).
// Other incomplete meshes throw .symmetryReducedMesh.

/// Errors thrown by band-mesh interpolation.
enum BandMeshInterpolationError: Error, CustomStringConvertible {
    case notMesh
    case notAxisAlignedGrid
    case malformedBandStructure
    case emptyRoute
    case nonFiniteRoute
    case invalidSampling
    case symmetryReducedMesh
    case missingReciprocalBasis

    var description: String {
        switch self {
        case .notMesh:
            return "band interpolation requires a uniform k-point mesh"
        case .notAxisAlignedGrid:
            return "band interpolation requires an axis-aligned Monkhorst-Pack-style mesh"
        case .malformedBandStructure:
            return "band structure has malformed or non-finite data"
        case .emptyRoute:
            return "interpolation route is empty"
        case .nonFiniteRoute:
            return "interpolation route contains non-finite coordinates"
        case .invalidSampling:
            return "invalid sampling density requested"
        case .symmetryReducedMesh:
            return "k-point mesh is symmetry-reduced (incomplete periodic grid); rerun the calculation with a full k-grid (nosym/noinv) or provide a single spin channel"
        case .missingReciprocalBasis:
            return "Cartesian k-points require a finite, nonsingular reciprocal lattice basis to convert to fractional coordinates"
        }
    }
}

/// Axis-aligned uniform mesh grid detected from ONE spin channel's k-points.
struct BandMeshGrid {
    /// Exactly 3 per-axis sample counts; degenerate axes are 1.
    let dims: [Int]
    /// Per-axis sorted unique node coordinates, normalized to [0,1).
    let nodes: [[Float]]

    /// Lattice-index key -> source (channel) index. Built at detection time so
    /// interpolate(values:at:) indexes `values` (in channel order) correctly no
    /// matter how the source k-points were ordered.
    private let indexMapping: [Int: Int]

    /// Number of source channel k-points (per-spin). After TR unfolding the
    /// grid has more lattice points than source points; interpolation indexes
    /// the channel `values` (length == sourcePointCount) via indexMapping.
    let sourcePointCount: Int

    /// Total mesh points (product of dims); >= sourcePointCount.
    var pointCount: Int { dims.reduce(1, *) }
    /// Indices of axes with count <= 1 (degenerate).
    var degenerateAxes: [Int] { (0..<3).filter { dims[$0] <= 1 } }

    init(dims: [Int], nodes: [[Float]], indexMapping: [Int: Int], sourcePointCount: Int) {
        self.dims = dims
        self.nodes = nodes
        self.indexMapping = indexMapping
        self.sourcePointCount = sourcePointCount
    }

    /// Periodic trilinear interpolation of one value per mesh point. `values`
    /// MUST be in the same order as the channel k-points the grid was detected
    /// from (index = channel k-point index; values.count == sourcePointCount).
    /// `k` components are wrapped mod 1 first. Returns nil for non-finite input
    /// or an out-of-range value array.
    func interpolate(_ values: [Float], at k: SIMD3<Float>) -> Float? {
        guard values.count == sourcePointCount else { return nil }
        guard k.x.isFinite && k.y.isFinite && k.z.isFinite else { return nil }

        // Wrap k mod 1, mapping values within 1e-4 of 1 to 0.
        func wrap(_ x: Float) -> Float {
            var c = x - floor(x)
            if 1 - c < 1e-4 { c = 0 }
            return c
        }
        let kw = SIMD3<Float>(wrap(k.x), wrap(k.y), wrap(k.z))

        // Per-axis cell index and interpolation fraction. Cell computation is
        // relative to nodes[a][0] and unwrapped so that shifted Monkhorst-Pack
        // grids (first node != 0) interpolate correctly across the closing cell.
        var cellIndex: [Int] = []
        var frac: [Float] = []
        for a in 0..<3 {
            let n = dims[a]
            if n <= 1 {
                cellIndex.append(0)
                frac.append(0)
            } else {
                let v = nodes[a]
                let step = v[1] - v[0]
                var q = kw[a]
                if q + 1e-5 < v[0] { q += 1 }   // unwrap into [v[0], v[0]+1)
                let i = min(n - 1, max(0, Int(floor((q - v[0]) / step))))
                let f = min(1, max(0, (q - v[i]) / step))
                cellIndex.append(i)
                frac.append(f)
            }
        }

        // Trilinear over the 8 corners (periodic via (i+1) % n).
        var result: Float = 0
        for cx in 0...1 {
            for cy in 0...1 {
                for cz in 0...1 {
                    let ix = cx == 0 ? cellIndex[0] : (cellIndex[0] + 1) % dims[0]
                    let iy = cy == 0 ? cellIndex[1] : (cellIndex[1] + 1) % dims[1]
                    let iz = cz == 0 ? cellIndex[2] : (cellIndex[2] + 1) % dims[2]
                    let key = ix * 10_000_000 + iy * 10_000 + iz
                    guard let srcIdx = indexMapping[key] else { return nil }
                    let cornerValue = values[srcIdx]
                    guard cornerValue.isFinite else { return nil }
                    let w = (cx == 0 ? (1 - frac[0]) : frac[0])
                            * (cy == 0 ? (1 - frac[1]) : frac[1])
                            * (cz == 0 ? (1 - frac[2]) : frac[2])
                    result += cornerValue * w
                }
            }
        }
        return result.isFinite ? result : nil
    }
}

/// Mesh detection + interpolation entry points.
enum BandMeshInterpolator {

    /// Detect the axis-aligned grid from spin channel 0 of `bands`.
    /// Throws notMesh / malformedBandStructure / notAxisAlignedGrid.
    static func meshGrid(from bands: BandStructure) throws -> BandMeshGrid {
        guard bands.isMesh else { throw BandMeshInterpolationError.notMesh }
        guard bands.hasValidChannelLayout else { throw BandMeshInterpolationError.malformedBandStructure }
        let perSpin = bands.kPointsPerSpin
        let nBands = bands.nBands
        guard perSpin > 0, nBands > 0 else { throw BandMeshInterpolationError.malformedBandStructure }

        let channel = Array(bands.kPoints[0..<perSpin])
        for kp in channel {
            guard kp.k.x.isFinite && kp.k.y.isFinite && kp.k.z.isFinite else {
                throw BandMeshInterpolationError.malformedBandStructure
            }
        }

        // If the k-points are Cartesian (units of 2pi/a_0) we MUST convert to
        // fractional coordinates first: a mesh is axis-aligned in fractional
        // space but generally sheared in Cartesian. A missing or singular
        // reciprocal basis makes the coordinates uninterpretable — fail
        // explicitly rather than silently sampling raw Cartesian values as if
        // they were fractional.
        let rawPoints: [SIMD3<Float>]
        if bands.kPointsAreCrystal {
            rawPoints = channel.map { $0.k }
        } else {
            guard let recip = bands.reciprocal,
                  let converted = cartesianToFractional(channel.map { $0.k }, reciprocal: recip) else {
                throw BandMeshInterpolationError.missingReciprocalBasis
            }
            rawPoints = converted
        }
        for p in rawPoints {
            guard p.x.isFinite && p.y.isFinite && p.z.isFinite else {
                throw BandMeshInterpolationError.malformedBandStructure
            }
        }

        // Normalize each coordinate mod 1 (values within 1e-4 of 1 map to 0).
        func normalize(_ x: Float) -> Float {
            var c = x - floor(x)
            if 1 - c < 1e-4 { c = 0 }
            return c
        }
        let normPoints = rawPoints.map {
            SIMD3<Float>(normalize($0.x), normalize($0.y), normalize($0.z))
        }

        // Per-axis unique values: quantize to 1e-3 to identify buckets, but
        // store the mean ACTUAL coordinate per bucket (preserving precision
        // for interpolation). Sorted by the mean coordinate.
        var nodes: [[Float]] = []
        for a in 0..<3 {
            let coords = normPoints.map { $0[a] }
            // Map each coordinate to its quantized bucket key.
            let keys = coords.map { ($0 * 1000).rounded() / 1000 }
            // Group actual coordinates by bucket and average each group.
            var buckets: [Float: [Float]] = [:]
            for (key, val) in zip(keys, coords) {
                buckets[key, default: []].append(val)
            }
            let sortedBuckets = buckets.sorted { $0.key < $1.key }
            nodes.append(sortedBuckets.map { vals in
                vals.value.reduce(0, +) / Float(vals.value.count)
            })
        }

        var dims = nodes.map { $0.count }
        // A mesh spans >= 2 dimensions; a 1D point set is a path, not a mesh.
        guard dims.filter({ $0 > 1 }).count >= 2 else {
            throw BandMeshInterpolationError.notAxisAlignedGrid
        }

        // Uniform spacing check (count > 1 axes only).
        for a in 0..<3 {
            let n = dims[a]
            guard n >= 1 else { throw BandMeshInterpolationError.notAxisAlignedGrid }
            if n > 1 {
                let step = nodes[a][1] - nodes[a][0]
                guard step > 1e-4 else { throw BandMeshInterpolationError.notAxisAlignedGrid }
                for i in 1..<n {
                    let d = nodes[a][i] - nodes[a][i - 1]
                    guard abs(d - step) < 1e-3 else { throw BandMeshInterpolationError.notAxisAlignedGrid }
                }
            }
        }

        // Closing-gap (completeness) check: for every axis with n > 1 nodes, the
        // gap between the last node and the wrapped-first node must equal the
        // internal step. Degenerate axes (n <= 1) are always complete.
        var completeAxes: [Bool] = []
        for a in 0..<3 {
            let n = dims[a]
            if n <= 1 {
                completeAxes.append(true)
            } else {
                let step = nodes[a][1] - nodes[a][0]
                let closingGap = normalize(nodes[a][0] + 1 - nodes[a][n - 1])
                completeAxes.append(abs(closingGap - step) < 1e-3)
            }
        }
        let incompleteAxes = (0..<3).filter { !completeAxes[$0] }

        // Time-reversal half-grid unfolding: if exactly ONE axis is incomplete and
        // its negated nodes complete it into a uniformly-spaced superset AND the
        // structure is single-spin AND known to obey time reversal, unfold that
        // axis (double it). Magnetized calculations break TR even at nSpin == 1
        // (unmagnetized SOC/noncollinear runs still preserve it) and fall
        // through to the rejection below.
        var unfolded = false
        var unfoldedAxis: Int? = nil
        // For the unfolded axis: partnerIndex[k] = original node index whose value
        // (or negation) produced union node k; isNewUnionNode[k] = true for negated.
        var partnerIndex: [Int] = []
        var isNewUnionNode: [Bool] = []
        if incompleteAxes.count == 1, bands.nSpin == 1, bands.timeReversalSymmetric {
            let a = incompleteAxes[0]
            let n = dims[a]
            let step = nodes[a][1] - nodes[a][0]
            // Negated nodes, normalized mod 1.
            let neg = nodes[a].map { normalize(1 - $0) }
            // Sorted union of original + negated, quantized to merge near-duplicates.
            var buckets: [Float: Float] = [:]
            for v in nodes[a] { buckets[(v * 1000).rounded() / 1000] = v }
            for v in neg { buckets[(v * 1000).rounded() / 1000] = v }
            let union = buckets.sorted { $0.key < $1.key }.map { $0.value }
            // TR-half signature: union has exactly 2n uniformly-spaced nodes.
            if union.count == 2 * n {
                var uniform = true
                for i in 1..<union.count {
                    if abs(union[i] - union[i - 1] - step) >= 1e-3 { uniform = false; break }
                }
                if uniform {
                    // Map each union node back to its partner original node index.
                    // Defensive: a union node must be either an original node or the
                    // negation of one. If neither matches (should not happen by
                    // construction), leave a sentinel and reject below rather than trap.
                    partnerIndex = union.map { u in
                        if let j = nodes[a].firstIndex(where: { abs($0 - u) < 1e-3 }) {
                            return j
                        }
                        if let j = nodes[a].firstIndex(where: { abs(normalize(1 - $0) - u) < 1e-3 }) {
                            return j
                        }
                        return -1
                    }
                    guard !partnerIndex.contains(-1) else {
                        throw BandMeshInterpolationError.symmetryReducedMesh
                    }
                    isNewUnionNode = union.map { u in
                        !nodes[a].contains { abs($0 - u) < 1e-3 }
                    }
                    nodes[a] = union
                    dims[a] = union.count
                    unfolded = true
                    unfoldedAxis = a
                }
            }
        }

        // Incomplete mesh that could not be unfolded -> reject.
        if !incompleteAxes.isEmpty && !unfolded {
            throw BandMeshInterpolationError.symmetryReducedMesh
        }

        // Product of per-axis counts must equal the channel point count (times 2
        // if a single axis was unfolded: channel point count is unchanged but the
        // grid grew by the negated nodes).
        let prod = dims[0] * dims[1] * dims[2]
        guard prod == perSpin * (unfolded ? 2 : 1) else {
            throw BandMeshInterpolationError.notAxisAlignedGrid
        }

        // Map each k-point to a lattice index triple; require all combos present
        // exactly once (no dups, no gaps).
        var indexMapping: [Int: Int] = [:]
        var seenKeys: Set<Int> = []
        for (idx, p) in normPoints.enumerated() {
            var triple: [Int] = []
            for a in 0..<3 {
                let n = dims[a]
                if n <= 1 {
                    triple.append(0)
                } else {
                    // Position in the sorted unique array (with tolerance).
                    var found = -1
                    for (j, node) in nodes[a].enumerated() {
                        if abs(p[a] - node) < 1e-3 { found = j; break }
                    }
                    guard found >= 0 else { throw BandMeshInterpolationError.notAxisAlignedGrid }
                    triple.append(found)
                }
            }
            let key = triple[0] * 10_000_000 + triple[1] * 10_000 + triple[2]
            guard seenKeys.insert(key).inserted else {
                throw BandMeshInterpolationError.notAxisAlignedGrid  // duplicate combo
            }
            indexMapping[key] = idx
        }
        guard seenKeys.count == perSpin else {
            throw BandMeshInterpolationError.notAxisAlignedGrid  // gap in the box
        }

        // For the unfolded axis, fill in the negated lattice triples: time
        // reversal maps k -> -k on EVERY reciprocal coordinate, so the energy
        // partner of a new point (k_a, k_b, k_c) is the present point
        // (-k_a, -k_b, -k_c). Each newly added node on the unfolded axis reuses
        // the channel index of its negation partner; the OTHER axes must be
        // closed under negation too (a complete axis whose negated nodes are not
        // in the mesh cannot come from a time-reversal-reduced calculation).
        if unfolded, let a = unfoldedAxis {
            let others = (0..<3).filter { $0 != a }
            let b = others[0], c = others[1]
            func negationMapping(_ axis: Int) throws -> [Int] {
                let n = dims[axis]
                guard n > 1 else {
                    // A one-node axis is TR-invariant only when its sole coordinate
                    // satisfies k == -k (mod 1), i.e. ≈ 0 or ≈ 0.5. A slice at
                    // e.g. k = 0.25 maps to 0.75, which is absent from the mesh,
                    // so the unfolded grid would not be TR-closed — reject.
                    let node = nodes[axis][0]
                    guard abs(normalize(1 - node) - node) < 1e-3 else {
                        throw BandMeshInterpolationError.symmetryReducedMesh
                    }
                    return [0]
                }
                return try (0..<n).map { i in
                    let target = normalize(1 - nodes[axis][i])
                    if let j = nodes[axis].firstIndex(where: { abs($0 - target) < 1e-3 }) {
                        return j
                    }
                    throw BandMeshInterpolationError.symmetryReducedMesh
                }
            }
            let negB = try negationMapping(b)
            let negC = try negationMapping(c)
            for k in 0..<dims[a] where isNewUnionNode[k] {
                for ib in 0..<max(1, dims[b]) {
                    for ic in 0..<max(1, dims[c]) {
                        // The energy partner of the new point (k, ib, ic) is the
                        // present point (-k_a, -k_b, -k_c). Every component is
                        // assigned through the DYNAMIC axis indices — a, b, c are
                        // not necessarily x, y, z in that order.
                        var partnerTriple = [0, 0, 0]
                        partnerTriple[a] = partnerIndex[k]
                        partnerTriple[b] = negB[ib]
                        partnerTriple[c] = negC[ic]
                        let partnerKey = partnerTriple[0] * 10_000_000
                                       + partnerTriple[1] * 10_000 + partnerTriple[2]
                        if let srcIdx = indexMapping[partnerKey] {
                            // The new point keeps its own (ib, ic) indices; only the
                            // unfolded axis coordinate changes to k.
                            var newTriple = [0, 0, 0]
                            newTriple[a] = k
                            newTriple[b] = ib
                            newTriple[c] = ic
                            let newKey = newTriple[0] * 10_000_000
                                       + newTriple[1] * 10_000 + newTriple[2]
                            indexMapping[newKey] = srcIdx
                        }
                    }
                }
            }
        }

        return BandMeshGrid(dims: dims, nodes: nodes, indexMapping: indexMapping, sourcePointCount: perSpin)
    }

    /// Interpolate every band along `path`; returns a NEW non-mesh BandStructure.
    static func interpolateAlongPath(
        bands: BandStructure,
        path: KPath,
        pointsPerSegment: Int
    ) throws -> BandStructure {
        guard bands.isMesh else { throw BandMeshInterpolationError.notMesh }
        guard bands.hasValidChannelLayout else { throw BandMeshInterpolationError.malformedBandStructure }
        let perSpin = bands.kPointsPerSpin
        let nBands = bands.nBands
        let nSpin = bands.nSpin
        guard perSpin > 0, nBands > 0 else { throw BandMeshInterpolationError.malformedBandStructure }

        // Finite k-points and energies (prefix nBands) guard.
        for kp in bands.kPoints {
            guard kp.k.x.isFinite && kp.k.y.isFinite && kp.k.z.isFinite else {
                throw BandMeshInterpolationError.malformedBandStructure
            }
            for e in kp.energies.prefix(nBands) {
                guard e.isFinite else { throw BandMeshInterpolationError.malformedBandStructure }
            }
        }

        guard pointsPerSegment >= 2, pointsPerSegment <= 200 else {
            throw BandMeshInterpolationError.invalidSampling
        }
        guard !path.points.isEmpty else { throw BandMeshInterpolationError.emptyRoute }
        for p in path.points {
            guard p.frac.x.isFinite && p.frac.y.isFinite && p.frac.z.isFinite else {
                throw BandMeshInterpolationError.nonFiniteRoute
            }
        }

        let samples = KPath(points: path.points, pointsPerSegment: pointsPerSegment, breaks: path.breaks)
            .interpolated()
        guard samples.count >= 1 else { throw BandMeshInterpolationError.emptyRoute }

        let grid = try meshGrid(from: bands)

        // Route labels: for each sample, the label of the first route point
        // within 1e-5 (fractional, max-abs). interpolated() emits exact route
        // endpoints, so this resolves them cleanly.
        func maxabs(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
        }
        let sampleLabels: [String] = samples.map { sample in
            for p in path.points {
                if maxabs(sample, p.frac) < 1e-5 { return p.label }
            }
            return ""
        }

        var resultKP: [BandKPoint] = []
        for s in 0..<nSpin {
            let channelStart = s * perSpin
            let channel = Array(bands.kPoints[channelStart..<channelStart + perSpin])
            for (j, sample) in samples.enumerated() {
                var energies: [Float] = []
                for b in 0..<nBands {
                    let values = channel.map { $0.energies[b] }
                    guard let v = grid.interpolate(values, at: sample), v.isFinite else {
                        throw BandMeshInterpolationError.malformedBandStructure
                    }
                    energies.append(v)
                }
                resultKP.append(BandKPoint(k: sample, weight: 0, label: sampleLabels[j], energies: energies))
            }
        }

        return BandStructure(
            kPoints: resultKP,
            fermiEnergy: bands.fermiEnergy,
            nSpin: nSpin,
            reciprocal: bands.reciprocal,
            // The output samples are ALWAYS fractional (crystal) coordinates:
            // Cartesian sources were converted through the reciprocal basis by
            // meshGrid. Marking them crystal lets kDistances apply the reciprocal
            // metric instead of treating fractional values as plain lengths.
            kPointsAreCrystal: true,
            kPointsPerSpin: samples.count,
            isMesh: false,
            cell: bands.cell,
            periodicDim: bands.periodicDim
        )
    }
}

// MARK: - Coordinate conversion

/// Convert Cartesian k-points (units of 2pi/a_0) to fractional coordinates using
/// the reciprocal lattice. k_cart = B * k_frac, so k_frac = B^{-1} * k_cart.
/// Returns nil if the reciprocal matrix is absent/singular.
private func cartesianToFractional(
    _ points: [SIMD3<Float>],
    reciprocal: [SIMD3<Float>]
) -> [SIMD3<Float>]? {
    guard reciprocal.count == 3 else { return nil }
    let B = simd_float3x3(columns: (reciprocal[0], reciprocal[1], reciprocal[2]))
    guard B.determinant.isFinite, abs(B.determinant) > 1e-12 else { return nil }
    let Binv = B.inverse
    return points.map { Binv * $0 }
}
