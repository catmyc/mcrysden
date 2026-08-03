import Foundation
import simd

/// One matched source→target atom pair. `displacement` is the minimum-image
/// vector from the source atom to the matched target atom (Å); `distance` is
/// its length.
struct AtomMatch: Equatable {
    let sourceIndex: Int
    let targetIndex: Int
    let displacement: SIMD3<Float>
    let distance: Float
}

/// Result of comparing a source structure against a reference (target)
/// structure. Atom matching is per-element nearest-neighbor within a distance
/// cutoff; unmatched atoms on either side are reported explicitly.
struct StructureComparisonResult: Equatable {
    let matches: [AtomMatch]
    let unmatchedSourceIndices: [Int]
    let unmatchedTargetIndices: [Int]
    /// Root-mean-square displacement over matched pairs (Å). nil when no
    /// pairs matched.
    let rmsDisplacement: Float?
    /// Mean displacement over matched pairs (Å). nil when no pairs matched.
    let meanDisplacement: Float?
    /// Maximum displacement over matched pairs (Å). nil when no pairs matched.
    let maxDisplacement: Float?
    /// Per-element breakdown over matched pairs, sorted by element symbol.
    let perElement: [StructureComparisonElementResult]
    /// The cutoff used for matching (Å).
    let maxMatchDistance: Float
    /// True when the analysis covered every atom of both structures without
    /// hitting a safety cap.
    let isComplete: Bool

    var matchedPairCount: Int { matches.count }
}

struct StructureComparisonElementResult: Equatable {
    let atomicNumber: Int
    let matchedCount: Int
    let rmsDisplacement: Float?
}

enum StructureComparator {
    /// Default matching cutoff (Å): covalent-bond-scale tolerance used when
    /// the caller does not supply one.
    static let defaultMaxMatchDistance: Float = 2.5
    /// Hard caps mirroring the coordination analyzer's practical bounds.
    static let maxAtomsPerStructure = 100_000
    static let maxGeneratedImages = 5_000_000
    /// Per-axis coefficient spread cap. The integer coefficient range per
    /// periodic axis for a single target atom is bounded by this count;
    /// exceeding it yields an incomplete result. Prevents malformed
    /// tiny/skew cells from creating unbounded enumeration.
    static let maxCoefficientSpread = 20_000
    /// Global attempted-combination work cap independent of retained images.
    /// Bounds the total coefficient combinations enumerated (leaf visits in
    /// the image recursion) across all target atoms in one comparison.
    /// Exceeding it yields an incomplete result even when few images survive
    /// the box filter, so a huge-but-sparse coefficient lattice cannot bind
    /// the analysis indefinitely.
    static let maxAttemptedCombinations = 50_000_000
    /// Global candidate-inspection cap for the matching phase, independent of
    /// image-generation work. Bounds the total image records inspected across
    /// all source atoms; exceeding it yields an incomplete all-unmatched result
    /// so a degenerate bin (e.g. many images sharing one neighborhood) cannot
    /// bind matching indefinitely. Practical finite value, not a tuning knob.
    static let maxCandidateInspections = 100_000_000

    /// Compare `source` against `target`. Matching uses greedy per-element
    /// nearest-neighbor assignment: every source atom claims the closest
    /// unmatched target atom of the same element within `maxMatchDistance`.
    ///
    /// Periodic structures (sourceCell + periodicDim > 0) match through
    /// minimum-image displacements: target atoms are replicated over the
    /// exact cell-image neighborhood intersecting the cutoff-expanded source
    /// bounding box and matched by direct distance to the replicated images.
    /// Candidate records are streamed directly from spatial bins (no per-source
    /// array materialization); cancellation is checked per record and a global
    /// candidate-inspection cap bounds total matching work independent of
    /// image-generation work. `candidateInspectionCap` overrides that cap
    /// (defaults to `maxCandidateInspections`); the default stays fixed for all
    /// normal callers. Returns nil for non-finite input, a singular source
    /// cell, invalid parameters, or cancellation. A safety-cap exhaustion
    /// (image or matching) returns a result flagged incomplete (isComplete
    /// false) with every atom unmatched.
    static func compare(source: [Atom], target: [Atom],
                        sourceCell: Cell?, periodicDim: Int,
                        maxMatchDistance: Float = defaultMaxMatchDistance,
                        isCancelled: (() -> Bool)? = nil,
                        candidateInspectionCap: Int = maxCandidateInspections) -> StructureComparisonResult? {
        guard !cancelled(isCancelled) else { return nil }
        guard source.count <= maxAtomsPerStructure,
              target.count <= maxAtomsPerStructure,
              (0...3).contains(periodicDim),
              maxMatchDistance.isFinite, maxMatchDistance > 0,
              candidateInspectionCap > 0,
              source.allSatisfy({ $0.coord.isFinite }),
              target.allSatisfy({ $0.coord.isFinite }) else { return nil }

        if source.isEmpty || target.isEmpty {
            return StructureComparisonResult(
                matches: [],
                unmatchedSourceIndices: Array(source.indices),
                unmatchedTargetIndices: Array(target.indices),
                rmsDisplacement: nil, meanDisplacement: nil, maxDisplacement: nil,
                perElement: [], maxMatchDistance: maxMatchDistance, isComplete: true)
        }

        // Periodicity: replicate target atoms over the exact cell-image
        // neighborhood intersecting the cutoff-expanded source bounding box.
        let periodic = periodicDim > 0 && sourceCell != nil
        var images: [ImageRecord] = []
        var imageComplete = true

        if periodic {
            guard let cell = sourceCell, cell.isFinite,
                  let setup = makePeriodicImages(source: source, target: target,
                                                  cell: cell, periodicDim: periodicDim,
                                                  maxMatchDistance: maxMatchDistance,
                                                  isCancelled: isCancelled) else { return nil }
            images = setup.images
            imageComplete = setup.complete
        } else {
            images.reserveCapacity(target.count)
            for (index, atom) in target.enumerated() {
                images.append(ImageRecord(targetIndex: index, position: atom.coord))
            }
        }

        // Cap exhaustion during image replication: report incomplete rather
        // than fabricating a result. A genuinely empty image set (no target
        // image intersects the box) falls through to the matching pass and
        // returns a complete, all-unmatched result.
        guard imageComplete else {
            return incompleteResult(sourceCount: source.count, targetCount: target.count,
                                    maxMatchDistance: maxMatchDistance)
        }

        // Spatial bins over the image positions (bin size = maxMatchDistance)
        // so candidate enumeration is O(neighborhood), not O(source × target).
        guard let bins = makeBins(images: images, maxMatchDistance: maxMatchDistance,
                                  isCancelled: isCancelled) else { return nil }

        var matches: [AtomMatch] = []
        matches.reserveCapacity(min(source.count, target.count))
        var usedTargets = [Bool](repeating: false, count: target.count)
        var usedSources = [Bool](repeating: false, count: source.count)
        // Global inspection counter shared across all source atoms. Bounds the
        // total candidate records inspected (not just retained) so a degenerate
        // bin cannot bind matching indefinitely; independent of image work.
        var candidateInspections = 0

        for sourceIndex in source.indices {
            guard !cancelled(isCancelled) else { return nil }
            let origin = source[sourceIndex].coord
            let element = source[sourceIndex].atomicNumber
            var best: AtomMatch?
            // Stream candidates directly from the spatial bins: no per-source
            // array is materialized, cancellation is checked per record, and
            // the shared inspection cap is enforced inside the stream.
            let streamResult = streamCandidates(
                near: origin, bins: bins, images: images,
                maxMatchDistance: maxMatchDistance,
                inspections: &candidateInspections,
                cap: candidateInspectionCap,
                isCancelled: isCancelled) { record in
                guard !usedTargets[record.targetIndex],
                      target[record.targetIndex].atomicNumber == element else { return }
                let displacement = record.position - origin
                let distance = length(displacement)
                guard distance.isFinite, distance <= maxMatchDistance else { return }
                if best == nil || distance < best!.distance {
                    best = AtomMatch(sourceIndex: sourceIndex,
                                     targetIndex: record.targetIndex,
                                     displacement: displacement,
                                     distance: distance)
                }
            }
            switch streamResult {
            case .cancelled:
                return nil
            case .capped:
                return incompleteResult(sourceCount: source.count, targetCount: target.count,
                                        maxMatchDistance: maxMatchDistance)
            case .completed:
                break
            }
            if let best {
                usedTargets[best.targetIndex] = true
                usedSources[sourceIndex] = true
                matches.append(best)
            }
        }

        // Order matches by source index (already true) and build the summary.
        let displacements = matches.map { Double($0.distance) }
        let rms: Float? = {
            guard !displacements.isEmpty else { return nil }
            let sum = displacements.reduce(0) { $0 + $1 * $1 }
            let value = Float(sqrt(sum / Double(displacements.count)))
            return value.isFinite ? value : nil
        }()
        let mean: Float? = {
            guard !displacements.isEmpty else { return nil }
            let value = Float(displacements.reduce(0, +) / Double(displacements.count))
            return value.isFinite ? value : nil
        }()
        let max: Float? = displacements.max().map { Float($0) }

        var byElement: [Int: [Double]] = [:]
        for match in matches {
            byElement[source[match.sourceIndex].atomicNumber, default: []]
                .append(Double(match.distance))
        }
        let perElement = byElement.keys.sorted { ElementTable.symbol($0) < ElementTable.symbol($1) }
            .map { z -> StructureComparisonElementResult in
                let values = byElement[z]!
                let sum = values.reduce(0) { $0 + $1 * $1 }
                let rmsValue = Float(sqrt(sum / Double(values.count)))
                return StructureComparisonElementResult(
                    atomicNumber: z, matchedCount: values.count,
                    rmsDisplacement: rmsValue.isFinite ? rmsValue : nil)
            }

        // O(n) unmatched bookkeeping via the matched flags, replacing the
        // O(source × matches) containment scan.
        let unmatchedSource = source.indices.filter { !usedSources[$0] }
        let unmatchedTarget = target.indices.filter { !usedTargets[$0] }

        return StructureComparisonResult(
            matches: matches,
            unmatchedSourceIndices: unmatchedSource,
            unmatchedTargetIndices: unmatchedTarget,
            rmsDisplacement: rms, meanDisplacement: mean, maxDisplacement: max,
            perElement: perElement, maxMatchDistance: maxMatchDistance, isComplete: true)
    }

    // MARK: - Periodic image replication

    private struct ImageRecord {
        let targetIndex: Int
        let position: SIMD3<Float>
    }

    private struct PeriodicImageSetup {
        let images: [ImageRecord]
        /// False when the image cap or coefficient spread cap was exceeded (the
        /// caller reports an incomplete result rather than a fabricated one).
        let complete: Bool
    }

    /// Replicate each target atom over the exact integer-image neighborhood of
    /// the cutoff-expanded source bounding box. The per-axis coefficient range
    /// is derived from the dual (reciprocal) basis so it is exact for
    /// arbitrarily skewed cells and atoms translated by any number of whole
    /// cells — a fixed offset radius is never used. Returns nil for a singular
    /// cell or non-finite input; `complete` is false when a safety cap is hit.
    private static func makePeriodicImages(source: [Atom], target: [Atom],
                                           cell: Cell, periodicDim: Int,
                                           maxMatchDistance: Float,
                                           isCancelled: (() -> Bool)?)
        -> PeriodicImageSetup? {
        // Expanded source bounding box: every matching image must lie inside.
        var minimum = source[0].coord.double
        var maximum = source[0].coord.double
        for atom in source.dropFirst() {
            let p = atom.coord.double
            minimum = SIMD3<Double>(min(minimum.x, p.x), min(minimum.y, p.y), min(minimum.z, p.z))
            maximum = SIMD3<Double>(max(maximum.x, p.x), max(maximum.y, p.y), max(maximum.z, p.z))
        }
        let pad = Double(maxMatchDistance)
        minimum -= SIMD3<Double>(repeating: pad)
        maximum += SIMD3<Double>(repeating: pad)
        guard minimum.isFinite, maximum.isFinite else { return nil }

        // Build the periodic basis in cell-vector order: a, then b, then c.
        let basis: [SIMD3<Double>] = {
            switch periodicDim {
            case 1: return [cell.a.double]
            case 2: return [cell.a.double, cell.b.double]
            default: return [cell.a.double, cell.b.double, cell.c.double]
            }
        }()

        // Compute the dual basis (wᵢ · vⱼ = δᵢⱼ) and validate linear
        // independence in one pass. The dual basis gives exact per-axis
        /// coefficient ranges; independence failure means a singular cell.
        let n = periodicDim
        let dual: [SIMD3<Double>]
        switch n {
        case 1:
            let len2 = dot(basis[0], basis[0])
            guard len2.isFinite, len2 > 0 else { return nil }
            dual = [SIMD3<Double>(basis[0].x / len2, basis[0].y / len2, basis[0].z / len2)]
        case 2:
            // Gram matrix G = VᵀV; dual rows = G⁻¹Vᵀ.
            let g00 = dot(basis[0], basis[0])
            let g01 = dot(basis[0], basis[1])
            let g11 = dot(basis[1], basis[1])
            let det = g00 * g11 - g01 * g01
            // Scale-invariant independence check: sin²θ = det/(g00·g11).
            guard det.isFinite, g00.isFinite, g11.isFinite, g00 > 0, g11 > 0,
                  det / (g00 * g11) > 1e-12 else { return nil }
            let invDet = 1.0 / det
            dual = [
                SIMD3<Double>(invDet * (g11 * basis[0].x - g01 * basis[1].x),
                              invDet * (g11 * basis[0].y - g01 * basis[1].y),
                              invDet * (g11 * basis[0].z - g01 * basis[1].z)),
                SIMD3<Double>(invDet * (g00 * basis[1].x - g01 * basis[0].x),
                              invDet * (g00 * basis[1].y - g01 * basis[0].y),
                              invDet * (g00 * basis[1].z - g01 * basis[0].z)),
            ]
        default:
            // Triple product = volume; dual rows are the reciprocal vectors.
            let det = dot(basis[0], cross(basis[1], basis[2]))
            let scale = length(basis[0]) * length(basis[1]) * length(basis[2])
            guard det.isFinite, scale.isFinite, scale > 0,
                  abs(det) / scale > 1e-12 else { return nil }
            let invDet = 1.0 / det
            dual = [
                cross(basis[1], basis[2]) * invDet,
                cross(basis[2], basis[0]) * invDet,
                cross(basis[0], basis[1]) * invDet,
            ]
        }
        guard dual.allSatisfy({ $0.isFinite }) else { return nil }

        // Per-axis box projection bounds onto each dual vector:
        // projMin[i] = Σⱼ min(wᵢⱼ·minⱼ, wᵢⱼ·maxⱼ)
        // projMax[i] = Σⱼ max(wᵢⱼ·minⱼ, wᵢⱼ·maxⱼ)
        let minC = [minimum.x, minimum.y, minimum.z]
        let maxC = [maximum.x, maximum.y, maximum.z]
        var projMin = [Double](repeating: 0, count: n)
        var projMax = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let d = [dual[i].x, dual[i].y, dual[i].z]
            var lo = 0.0, hi = 0.0
            for j in 0..<3 {
                let a = d[j] * minC[j]
                let b = d[j] * maxC[j]
                lo += min(a, b)
                hi += max(a, b)
            }
            projMin[i] = lo
            projMax[i] = hi
        }

        var images: [ImageRecord] = []
        var complete = true
        var attemptedCombinations = 0
        var wasCancelled = false
        for (targetIndex, atom) in target.enumerated() {
            guard !cancelled(isCancelled) else { return nil }
            let p = atom.coord.double
            guard p.isFinite else { return nil }

            // Per-axis integer coefficient range: kᵢ ∈ [projMinᵢ − wᵢ·p,
            // projMaxᵢ − wᵢ·p]. Independent of the other axes; exact for any
            // cell shape; center shifts with the atom position so atoms
            // translated by many whole cells are covered.
            var loHi: [(Int, Int)] = []
            loHi.reserveCapacity(n)
            var skipAtom = false
            for i in 0..<n {
                let center = dot(dual[i], p)
                guard center.isFinite else { return nil }
                // Expand the fractional bounds outward by one ULP before
                // ceiling/flooring: roundoff in the dual-basis projection
                // must never exclude a boundary image that truly intersects
                // the box. nextDown/nextUp keep the expansion tight.
                let lo = (projMin[i] - center).nextDown
                let hi = (projMax[i] - center).nextUp
                guard let loInt = checkedIntCeil(lo),
                      let hiInt = checkedIntFloor(hi) else { return nil }
                if loInt > hiInt { skipAtom = true; break }   // no image in box
                let diff = hiInt.subtractingReportingOverflow(loInt)
                guard !diff.overflow else { complete = false; break }
                let spread = diff.partialValue.addingReportingOverflow(1)
                guard !spread.overflow else { complete = false; break }
                let spreadValue = spread.partialValue
                guard spreadValue > 0, spreadValue <= maxCoefficientSpread else { complete = false; break }
                loHi.append((loInt, hiInt))
            }
            if skipAtom { continue }
            if !complete { break }
            guard loHi.count == n else { complete = false; break }

            // Guard against the per-atom image product exceeding the global cap
            // before enumerating. Every factor uses reporting-overflow
            // arithmetic for the integer hi-lo+1 terms so extreme
            // coefficient ranges cannot trap; the floating-point product
            // is checked for finiteness (overflow to infinity) each step.
            var product = 1.0
            for (lo, hi) in loHi {
                let diff = hi.subtractingReportingOverflow(lo)
                guard !diff.overflow else { complete = false; break }
                let count = diff.partialValue.addingReportingOverflow(1)
                guard !count.overflow, count.partialValue > 0 else { complete = false; break }
                product *= Double(count.partialValue)
                guard product.isFinite else { complete = false; break }
            }
            guard complete, product <= Double(maxGeneratedImages) else { complete = false; break }

            enumerateImages(loHi: loHi, basis: basis, p: p, targetIndex: targetIndex,
                            minimum: minimum, maximum: maximum,
                            images: &images, complete: &complete,
                            maxGeneratedImages: maxGeneratedImages,
                            attemptedCombinations: &attemptedCombinations,
                            wasCancelled: &wasCancelled,
                            isCancelled: isCancelled)
            if wasCancelled { return nil }
            if !complete { break }
        }

        return PeriodicImageSetup(images: images, complete: complete)
    }

    /// Recursively enumerate all coefficient combinations for one target atom,
    /// appending images that fall inside the padded box. `complete` is set
    /// false if the global image cap is hit; recursion unwinds immediately.
    private static func enumerateImages(loHi: [(Int, Int)], basis: [SIMD3<Double>],
                                        p: SIMD3<Double>, targetIndex: Int,
                                        minimum: SIMD3<Double>, maximum: SIMD3<Double>,
                                        images: inout [ImageRecord], complete: inout Bool,
                                        maxGeneratedImages: Int,
                                        attemptedCombinations: inout Int,
                                        wasCancelled: inout Bool,
                                        isCancelled: (() -> Bool)?) {
        let n = loHi.count
        func step(_ axis: Int, _ acc: SIMD3<Double>) {
            if !complete { return }
            if axis == n {
                // Bounded checkpoint (one per leaf): cancellation, the global
                // attempted-combination work cap, then the box filter.
                if cancelled(isCancelled) { wasCancelled = true; complete = false; return }
                attemptedCombinations += 1
                if attemptedCombinations > maxAttemptedCombinations {
                    complete = false
                    return
                }
                guard acc.x >= minimum.x, acc.x <= maximum.x,
                      acc.y >= minimum.y, acc.y <= maximum.y,
                      acc.z >= minimum.z, acc.z <= maximum.z else { return }
                let pos = acc.float
                guard pos.isFinite else { complete = false; return }
                if images.count >= maxGeneratedImages {
                    complete = false
                    return
                }
                images.append(ImageRecord(targetIndex: targetIndex, position: pos))
                return
            }
            let (lo, hi) = loHi[axis]
            var k = lo
            while k <= hi {
                let next = acc + Double(k) * basis[axis]
                guard next.isFinite else { complete = false; return }
                step(axis + 1, next)
                if !complete { return }
                k += 1
            }
        }
        step(0, p)
    }

    /// Build a result when image replication hit a safety cap. No pairs were
    /// matched; every atom of both structures is reported unmatched and the
    /// result is flagged incomplete so callers can distinguish "analysis
    /// abandoned" from "no match found" (the latter is complete, all unmatched).
    private static func incompleteResult(sourceCount: Int, targetCount: Int,
                                          maxMatchDistance: Float) -> StructureComparisonResult {
        StructureComparisonResult(
            matches: [],
            unmatchedSourceIndices: Array(0..<sourceCount),
            unmatchedTargetIndices: Array(0..<targetCount),
            rmsDisplacement: nil, meanDisplacement: nil, maxDisplacement: nil,
            perElement: [], maxMatchDistance: maxMatchDistance, isComplete: false)
    }

    // MARK: - Spatial bins

    private struct BinKey: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    private static func makeBins(images: [ImageRecord], maxMatchDistance: Float,
                                 isCancelled: (() -> Bool)?) -> [BinKey: [Int]]? {
        guard maxMatchDistance.isFinite, maxMatchDistance > 0 else { return nil }
        // An empty image set (no target image intersects the box) is valid:
        // return empty bins so the matching pass yields a complete all-unmatched
        // result rather than trapping.
        if images.isEmpty { return [:] }
        let binSize = Double(maxMatchDistance)
        var bins: [BinKey: [Int]] = [:]
        bins.reserveCapacity(min(images.count, 1_048_576))
        for (index, record) in images.enumerated() {
            guard !cancelled(isCancelled) else { return nil }
            let p = record.position.double
            guard let key = binKey(p, binSize: binSize) else { return nil }
            bins[key, default: []].append(index)
        }
        return bins
    }

    /// Outcome of streaming candidate records from the spatial bins.
    private enum CandidateStreamResult {
        /// All candidates in the neighborhood were inspected.
        case completed
        /// The cancellation closure fired during record iteration.
        case cancelled
        /// The global candidate-inspection cap was exceeded.
        case capped
    }

    /// Stream candidate image records near `point` by iterating spatial bins
    /// in range, invoking `inspect` for each record. Unlike the old array
    /// materialization, this allocates nothing per source atom, checks
    /// cancellation per record (not just per bin layer), and stops with
    /// `.capped` once the shared `inspections` counter exceeds `cap`. Returns
    /// `.completed` only when the whole neighborhood is exhausted without
    /// tripping cancellation or the cap.
    private static func streamCandidates(
        near point: SIMD3<Float>,
        bins: [BinKey: [Int]],
        images: [ImageRecord],
        maxMatchDistance: Float,
        inspections: inout Int,
        cap: Int,
        isCancelled: (() -> Bool)?,
        inspect: (ImageRecord) -> Void) -> CandidateStreamResult {
        guard point.isFinite else { return .completed }
        let binSize = Double(maxMatchDistance)
        let center = point.double
        guard let lower = binKey(center - SIMD3<Double>(repeating: binSize), binSize: binSize),
              let upper = binKey(center + SIMD3<Double>(repeating: binSize), binSize: binSize) else {
            return .completed
        }
        for x in lower.x...upper.x {
            for y in lower.y...upper.y {
                for z in lower.z...upper.z {
                    guard let indices = bins[BinKey(x: x, y: y, z: z)] else { continue }
                    for index in indices {
                        guard !cancelled(isCancelled) else { return .cancelled }
                        inspections += 1
                        if inspections > cap { return .capped }
                        inspect(images[index])
                    }
                }
            }
        }
        return .completed
    }

    private static func binKey(_ point: SIMD3<Double>, binSize: Double) -> BinKey? {
        guard point.isFinite, binSize.isFinite, binSize > 0 else { return nil }
        let scaled = point / binSize
        guard scaled.isFinite,
              let x = floorInt(scaled.x), let y = floorInt(scaled.y),
              let z = floorInt(scaled.z) else { return nil }
        return BinKey(x: x, y: y, z: z)
    }

    private static func floorInt(_ value: Double) -> Int? {
        let floored = floor(value)
        guard floored.isFinite,
              floored > Double(Int.min), floored < Double(Int.max) else { return nil }
        return Int(floored)
    }

    private static func checkedIntCeil(_ value: Double) -> Int? {
        let ceiled = ceil(value)
        guard ceiled.isFinite,
              ceiled > Double(Int.min), ceiled < Double(Int.max) else { return nil }
        return Int(ceiled)
    }

    private static func checkedIntFloor(_ value: Double) -> Int? {
        let floored = floor(value)
        guard floored.isFinite,
              floored > Double(Int.min), floored < Double(Int.max) else { return nil }
        return Int(floored)
    }

    private static func cancelled(_ isCancelled: (() -> Bool)?) -> Bool {
        isCancelled?() == true
    }
}
