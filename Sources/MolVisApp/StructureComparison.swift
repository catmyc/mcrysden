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

    /// Compare `source` against `target`. Matching uses greedy per-element
    /// nearest-neighbor assignment: every source atom claims the closest
    /// unmatched target atom of the same element within `maxMatchDistance`.
    ///
    /// Periodic structures (sourceCell + periodicDim > 0) match through
    /// minimum-image displacements: target atoms are replicated over the
    /// cell-image neighborhood of the source bounding box and matched by
    /// direct distance to the replicated images. Returns nil for non-finite
    /// input, a singular source cell, or when the caps are exceeded.
    static func compare(source: [Atom], target: [Atom],
                        sourceCell: Cell?, periodicDim: Int,
                        maxMatchDistance: Float = defaultMaxMatchDistance,
                        isCancelled: (() -> Bool)? = nil) -> StructureComparisonResult? {
        guard !cancelled(isCancelled) else { return nil }
        guard source.count <= maxAtomsPerStructure,
              target.count <= maxAtomsPerStructure,
              (0...3).contains(periodicDim),
              maxMatchDistance.isFinite, maxMatchDistance > 0,
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

        // Periodicity: replicate target atoms over the cell-image neighborhood
        // of the expanded source bounding box. The offset range per axis covers
        // every image that can fall within maxMatchDistance of the box.
        let periodic = periodicDim > 0 && sourceCell != nil
        var images: [ImageRecord] = []
        var usedTargets = [Bool](repeating: false, count: target.count)

        if periodic {
            guard let cell = sourceCell, cell.isFinite,
                  let imageSetup = makePeriodicImages(source: source, target: target,
                                                      cell: cell, periodicDim: periodicDim,
                                                      maxMatchDistance: maxMatchDistance,
                                                      isCancelled: isCancelled) else { return nil }
            images = imageSetup.images
            guard imageSetup.complete else {
                return partialResult(sourceCount: source.count, targetCount: target.count,
                                     maxMatchDistance: maxMatchDistance)
            }
        } else {
            for (index, atom) in target.enumerated() {
                images.append(ImageRecord(targetIndex: index, position: atom.coord))
            }
        }
        guard !images.isEmpty else {
            return partialResult(sourceCount: source.count, targetCount: target.count,
                                 maxMatchDistance: maxMatchDistance)
        }

        // Spatial bins over the image positions (bin size = maxMatchDistance)
        // so candidate enumeration is O(neighborhood), not O(source × target).
        guard let bins = makeBins(images: images, maxMatchDistance: maxMatchDistance,
                                  isCancelled: isCancelled) else { return nil }

        var matches: [AtomMatch] = []
        matches.reserveCapacity(min(source.count, target.count))
        for sourceIndex in source.indices {
            guard !cancelled(isCancelled) else { return nil }
            let origin = source[sourceIndex].coord
            let element = source[sourceIndex].atomicNumber
            var best: AtomMatch?
            for record in candidateImages(near: origin, bins: bins, images: images,
                                          maxMatchDistance: maxMatchDistance,
                                          isCancelled: isCancelled) {
                guard !usedTargets[record.targetIndex],
                      target[record.targetIndex].atomicNumber == element else { continue }
                let displacement = record.position - origin
                let distance = length(displacement)
                guard distance.isFinite, distance <= maxMatchDistance else { continue }
                if best == nil || distance < best!.distance {
                    best = AtomMatch(sourceIndex: sourceIndex,
                                     targetIndex: record.targetIndex,
                                     displacement: displacement,
                                     distance: distance)
                }
            }
            if let best {
                usedTargets[best.targetIndex] = true
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

        let unmatchedSource = source.indices.filter { index in
            !matches.contains { $0.sourceIndex == index }
        }
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
        /// False when the image cap was exceeded (the caller reports an
        /// incomplete result rather than a fabricated one).
        let complete: Bool
    }

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

        // Offset range per periodic axis: every image of a target atom that can
        // fall within the padded box. rᵢ = ⌈maxMatchDistance / |vᵢ|⌉ plus one
        // extra cell for the box padding so boundary atoms are covered.
        let vectors: [SIMD3<Double>] = {
            switch periodicDim {
            case 1: return [cell.a.double]
            case 2: return [cell.a.double, cell.b.double]
            default: return [cell.a.double, cell.b.double, cell.c.double]
            }
        }()
        var ranges: [ClosedRange<Int>] = []
        ranges.reserveCapacity(vectors.count)
        for vector in vectors {
            let length = simd_length(vector)
            guard length.isFinite, length > 1e-9 else { return nil }
            let radius = Int(ceil(Double(maxMatchDistance) / length)) + 1
            guard radius <= 64 else { return nil }
            ranges.append((-radius)...radius)
        }

        var images: [ImageRecord] = []
        var complete = true
        for (targetIndex, atom) in target.enumerated() {
            guard !cancelled(isCancelled) else { return nil }
            let p = atom.coord.double
            for i in ranges.indices.isEmpty ? [0] : Array(ranges[0]) {
                for j in (ranges.count >= 2 ? Array(ranges[1]) : [0]) {
                    for k in (ranges.count >= 3 ? Array(ranges[2]) : [0]) {
                        var image = p
                        if ranges.count >= 1 { image += Double(i) * vectors[0] }
                        if ranges.count >= 2 { image += Double(j) * vectors[1] }
                        if ranges.count >= 3 { image += Double(k) * vectors[2] }
                        guard image.isFinite else { return nil }
                        guard image.x >= minimum.x, image.x <= maximum.x,
                              image.y >= minimum.y, image.y <= maximum.y,
                              image.z >= minimum.z, image.z <= maximum.z else { continue }
                        let position = image.float
                        guard position.isFinite else { return nil }
                        if images.count >= maxGeneratedImages {
                            complete = false
                            break
                        }
                        images.append(ImageRecord(targetIndex: targetIndex, position: position))
                    }
                    if !complete { break }
                }
                if !complete { break }
            }
            if !complete { break }
        }
        return PeriodicImageSetup(images: images, complete: complete)
    }

    /// Build a result when the analysis could not be completed (image-cap
    /// exhaustion). No pairs were matched; every atom of both structures is
    /// reported unmatched and the result is flagged incomplete so callers can
    /// distinguish "no match found" from "analysis abandoned".
    private static func partialResult(sourceCount: Int, targetCount: Int,
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
        guard !images.isEmpty, maxMatchDistance.isFinite, maxMatchDistance > 0 else { return nil }
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

    private static func candidateImages(near point: SIMD3<Float>,
                                        bins: [BinKey: [Int]],
                                        images: [ImageRecord],
                                        maxMatchDistance: Float,
                                        isCancelled: (() -> Bool)?) -> [ImageRecord] {
        guard point.isFinite else { return [] }
        let binSize = Double(maxMatchDistance)
        let center = point.double
        guard let lower = binKey(center - SIMD3<Double>(repeating: binSize),
                                 binSize: binSize),
              let upper = binKey(center + SIMD3<Double>(repeating: binSize),
                                 binSize: binSize) else { return [] }

        var result: [ImageRecord] = []
        for x in lower.x...upper.x {
            guard !cancelled(isCancelled) else { return [] }
            for y in lower.y...upper.y {
                guard !cancelled(isCancelled) else { return [] }
                for z in lower.z...upper.z {
                    guard let indices = bins[BinKey(x: x, y: y, z: z)] else { continue }
                    for index in indices {
                        result.append(images[index])
                    }
                }
            }
        }
        return result
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

    private static func cancelled(_ isCancelled: (() -> Bool)?) -> Bool {
        isCancelled?() == true
    }
}
