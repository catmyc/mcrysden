import Foundation
import simd

struct CoordinationNeighbor: Equatable {
    let atomIndex: Int
    let imageOffset: SIMD3<Int32>
    let displacement: SIMD3<Float>
    let distance: Float
}

struct CoordinationShell: Equatable {
    let distance: Float
    let neighbors: [CoordinationNeighbor]
}

struct CoordinationAnalysis: Equatable {
    let neighbors: [CoordinationNeighbor]
    let offsets: [Int]
    let coordinationNumbers: [Int]
    let candidateChecks: Int

    init(neighborsByAtom: [[CoordinationNeighbor]], candidateChecks: Int = 0) {
        precondition(candidateChecks >= 0)
        var offsets = [0]
        offsets.reserveCapacity(neighborsByAtom.count + 1)
        var records: [CoordinationNeighbor] = []
        var recordCapacity = 0
        for atomNeighbors in neighborsByAtom {
            let (next, overflow) = recordCapacity.addingReportingOverflow(atomNeighbors.count)
            guard !overflow else { preconditionFailure("coordination record count overflow") }
            recordCapacity = next
        }
        records.reserveCapacity(recordCapacity)
        for atomNeighbors in neighborsByAtom {
            records.append(contentsOf: atomNeighbors)
            offsets.append(records.count)
        }
        guard let analysis = CoordinationAnalysis(records: records,
                                                  offsets: offsets,
                                                  counts: neighborsByAtom.map(\.count),
                                                  candidateChecks: candidateChecks) else {
            preconditionFailure("invalid coordination analysis cardinality")
        }
        self = analysis
    }

    // This is the analyzer's storage initializer. Callers that need the old
    // nested representation should use the compatibility initializer above.
    init?(records: [CoordinationNeighbor], offsets: [Int], counts: [Int],
          candidateChecks: Int) {
        guard candidateChecks >= 0,
              counts.count < Int.max,
              offsets.count == counts.count + 1,
              offsets.first == 0,
              offsets.last == records.count,
              counts.allSatisfy({ $0 >= 0 }) else { return nil }

        var previous = 0
        for index in counts.indices {
            let start = offsets[index]
            let end = offsets[index + 1]
            guard start == previous,
                  start >= 0,
                  end >= start,
                  end <= records.count,
                  end - start == counts[index] else { return nil }
            previous = end
        }
        guard previous == records.count else { return nil }

        self.neighbors = records
        self.offsets = offsets
        self.coordinationNumbers = counts
        self.candidateChecks = candidateChecks
    }

    // Kept for source compatibility; this allocates only when explicitly read.
    var neighborsByAtom: [[CoordinationNeighbor]] {
        offsets.dropLast().indices.map { index in
            Array(neighbors[offsets[index]..<offsets[index + 1]])
        }
    }

    func neighbors(of atomIndex: Int) -> [CoordinationNeighbor] {
        guard offsets.dropLast().indices.contains(atomIndex) else { return [] }
        return Array(neighbors[offsets[atomIndex]..<offsets[atomIndex + 1]])
    }

    func shells(of atomIndex: Int, tolerance: Float = 0.05) -> [CoordinationShell] {
        guard offsets.dropLast().indices.contains(atomIndex),
              tolerance.isFinite, tolerance >= 0 else { return [] }

        let atomNeighbors = neighbors(of: atomIndex)
        guard !atomNeighbors.isEmpty else { return [] }

        var result: [CoordinationShell] = []
        var group: [CoordinationNeighbor] = []
        group.reserveCapacity(atomNeighbors.count)
        var previousDistance = atomNeighbors[0].distance

        for neighbor in atomNeighbors {
            if !group.isEmpty && abs(neighbor.distance - previousDistance) > tolerance {
                result.append(CoordinationShell(distance: shellMean(group), neighbors: group))
                group.removeAll(keepingCapacity: true)
            }
            group.append(neighbor)
            previousDistance = neighbor.distance
        }
        if !group.isEmpty {
            result.append(CoordinationShell(distance: shellMean(group), neighbors: group))
        }
        return result
    }

    static func == (lhs: CoordinationAnalysis, rhs: CoordinationAnalysis) -> Bool {
        lhs.neighbors == rhs.neighbors &&
        lhs.offsets == rhs.offsets &&
        lhs.coordinationNumbers == rhs.coordinationNumbers &&
        lhs.candidateChecks == rhs.candidateChecks
    }

    private func shellMean(_ neighbors: [CoordinationNeighbor]) -> Float {
        let sum = neighbors.reduce(0.0) { $0 + Double($1.distance) }
        return Float(sum / Double(neighbors.count))
    }
}

enum CoordinationAnalyzer {
    static let defaultRadiusScale: Float = 1.15
    static let defaultMaxNeighborRecords = 8_000_000
    static let defaultMaxGeneratedImages = 5_000_000
    static let defaultMaxCandidateChecks = 100_000_000
    static let defaultMaxStorageBytes = 512 * 1024 * 1024

    private static let minimumDistance: Double = 1e-7
    private static let independenceTolerance: Double = 1e-10
    private static let maxOffsetAttempts = 50_000_000
    private static let cancellationCheckpointInterval = 4_096

    struct BinKey: Hashable {
        let x: Int64
        let y: Int64
        let z: Int64
    }

    struct ImageRecord {
        let atomIndex: Int
        let canonicalOffset: SIMD3<Int64>
        let position: SIMD3<Double>
        let bin: BinKey
    }

    private struct CanonicalPoint {
        let position: SIMD3<Double>
        let quotient: SIMD3<Int64>
    }

    private struct PeriodicBasis {
        let vectors: [SIMD3<Double>]
        let inverseGram: [[Double]]

        var dimension: Int { vectors.count }

        static func make(cell: Cell, periodicDim: Int,
                         isCancelled: (() -> Bool)?) -> PeriodicBasis? {
            let vectors: [SIMD3<Double>]
            switch periodicDim {
            case 1: vectors = [doubleVector(cell.a)]
            case 2: vectors = [doubleVector(cell.a), doubleVector(cell.b)]
            case 3: vectors = [doubleVector(cell.a), doubleVector(cell.b), doubleVector(cell.c)]
            default: return nil
            }
            for vector in vectors {
                guard !CoordinationAnalyzer.cancelled(isCancelled), vector.isFinite else {
                    return nil
                }
            }

            // Gram-Schmidt supplies a scale-aware independence check. The
            // configured periodic vectors need not be orthogonal.
            var orthonormal: [SIMD3<Double>] = []
            for vector in vectors {
                guard !CoordinationAnalyzer.cancelled(isCancelled) else { return nil }
                let inputLength = length(vector)
                guard inputLength.isFinite, inputLength > 0 else { return nil }
                var residual = vector
                for q in orthonormal {
                    guard !CoordinationAnalyzer.cancelled(isCancelled) else { return nil }
                    residual -= dot(residual, q) * q
                }
                let residualLength = length(residual)
                guard residualLength.isFinite,
                      residualLength > independenceTolerance * inputLength else { return nil }
                orthonormal.append(residual / residualLength)
            }

            var gram = [[Double]](repeating: [Double](repeating: 0, count: vectors.count),
                                  count: vectors.count)
            for row in vectors.indices {
                guard !CoordinationAnalyzer.cancelled(isCancelled) else { return nil }
                for column in vectors.indices {
                    gram[row][column] = dot(vectors[row], vectors[column])
                }
            }
            guard let inverseGram = invert(gram, isCancelled: isCancelled),
                  inverseGram.flatMap({ $0 }).allSatisfy({ $0.isFinite }) else { return nil }

            return PeriodicBasis(vectors: vectors, inverseGram: inverseGram)
        }

        func coefficients(for point: SIMD3<Double>) -> [Double]? {
            guard point.isFinite else { return nil }
            var rhs = [Double](repeating: 0, count: dimension)
            for row in vectors.indices {
                rhs[row] = dot(vectors[row], point)
            }
            guard rhs.allSatisfy({ $0.isFinite }) else { return nil }

            var result = [Double](repeating: 0, count: dimension)
            for row in vectors.indices {
                for column in vectors.indices {
                    result[row] += inverseGram[row][column] * rhs[column]
                }
            }
            return result.allSatisfy({ $0.isFinite }) ? result : nil
        }

        func lattice(_ coefficients: SIMD3<Int64>) -> SIMD3<Double>? {
            var result = SIMD3<Double>.zero
            for index in 0..<dimension {
                let term = Double(coefficients[index]) * vectors[index]
                guard term.isFinite else { return nil }
                result += term
                guard result.isFinite else { return nil }
            }
            return result
        }

        func lattice(_ coefficients: [Double]) -> SIMD3<Double>? {
            guard coefficients.count == dimension else { return nil }
            var result = SIMD3<Double>.zero
            for index in vectors.indices {
                let term = coefficients[index] * vectors[index]
                guard term.isFinite else { return nil }
                result += term
                guard result.isFinite else { return nil }
            }
            return result
        }
    }

    static func analyze(atoms: [Atom], cell: Cell?, periodicDim: Int,
                        radiusScale: Float = defaultRadiusScale,
                        maxNeighborRecords: Int = defaultMaxNeighborRecords,
                        maxGeneratedImages: Int = defaultMaxGeneratedImages,
                        maxCandidateChecks: Int = defaultMaxCandidateChecks,
                        maxStorageBytes: Int = defaultMaxStorageBytes,
                        isCancelled: (() -> Bool)? = nil) -> CoordinationAnalysis? {
        guard !cancelled(isCancelled) else { return nil }
        guard (0...3).contains(periodicDim),
              radiusScale.isFinite, radiusScale >= 0.1, radiusScale <= 4,
              maxNeighborRecords >= 0, maxGeneratedImages >= 0,
              maxCandidateChecks >= 0, maxStorageBytes >= 0 else { return nil }

        for atom in atoms {
            guard !cancelled(isCancelled), atom.coord.isFinite else { return nil }
        }

        if atoms.isEmpty {
            guard !cancelled(isCancelled) else { return nil }
            return CoordinationAnalysis(records: [], offsets: [0], counts: [], candidateChecks: 0)
        }
        guard let initialEstimate = storageEstimate(atomCount: atoms.count,
                                                    imageCount: 0,
                                                    binCount: 0,
                                                    neighborCount: 0),
              initialEstimate <= maxStorageBytes else { return nil }

        let basis: PeriodicBasis?
        if periodicDim == 0 {
            basis = nil
        } else {
            guard let cell, cell.isFinite,
                  let periodicBasis = PeriodicBasis.make(cell: cell, periodicDim: periodicDim,
                                                         isCancelled: isCancelled) else {
                return nil
            }
            basis = periodicBasis
        }

        var radii = [Double](repeating: 0, count: atoms.count)
        var validAtoms: [Int] = []
        validAtoms.reserveCapacity(atoms.count)
        for index in atoms.indices {
            guard !cancelled(isCancelled) else { return nil }
            // ElementTable clamps out-of-range atomic numbers for rendering. An
            // analysis must not turn those unknown values into real elements.
            guard (1...118).contains(atoms[index].atomicNumber) else { continue }
            let radius = ElementTable.covalentRadius(atoms[index].atomicNumber)
            guard radius.isFinite, radius > 0 else { continue }
            radii[index] = Double(radius)
            validAtoms.append(index)
        }

        guard !validAtoms.isEmpty else {
            guard !cancelled(isCancelled) else { return nil }
            let offsets = Array(repeating: 0, count: atoms.count + 1)
            let counts = Array(repeating: 0, count: atoms.count)
            return CoordinationAnalysis(records: [], offsets: offsets, counts: counts,
                                        candidateChecks: 0)
        }

        let scale = Double(radiusScale)
        var largestRadius = 0.0
        for index in validAtoms {
            guard !cancelled(isCancelled) else { return nil }
            largestRadius = max(largestRadius, radii[index])
        }
        let maximumCutoff = scale * (largestRadius + largestRadius)
        guard maximumCutoff.isFinite, maximumCutoff > 0 else { return nil }
        guard maxGeneratedImages > 0 else { return nil }

        var points = [CanonicalPoint?](repeating: nil, count: atoms.count)
        for index in validAtoms {
            guard !cancelled(isCancelled) else { return nil }
            let point = SIMD3<Double>(Double(atoms[index].coord.x),
                                      Double(atoms[index].coord.y),
                                      Double(atoms[index].coord.z))
            if let basis {
                guard let coefficients = basis.coefficients(for: point),
                       let canonical = canonicalPoint(point, coefficients: coefficients,
                                                      basis: basis,
                                                      isCancelled: isCancelled) else { return nil }
                points[index] = canonical
            } else {
                points[index] = CanonicalPoint(position: point, quotient: .zero)
            }
        }

        guard let firstIndex = validAtoms.first,
              let firstPoint = points[firstIndex]?.position else { return nil }
        var minimum = firstPoint
        var maximum = firstPoint
        for index in validAtoms.dropFirst() {
            guard !cancelled(isCancelled), let point = points[index]?.position else { return nil }
            minimum = SIMD3<Double>(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
            maximum = SIMD3<Double>(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
        }
        let expandedMinimum = minimum - SIMD3<Double>(repeating: maximumCutoff)
        let expandedMaximum = maximum + SIMD3<Double>(repeating: maximumCutoff)
        guard expandedMinimum.isFinite, expandedMaximum.isFinite else { return nil }

        let origin = expandedMinimum
        let binSize = maximumCutoff
        var retainedImageCount = 0
        var attemptedOffsetCount = 0

        func enumerateImages(targetIndex: Int, countAttempts: Bool,
                             body: (SIMD3<Int64>, SIMD3<Double>, BinKey) -> Bool) -> Bool {
            guard let target = points[targetIndex] else { return false }
            if let basis {
                guard let offsetRanges = imageOffsetRanges(basis: basis,
                                                           target: target.position,
                                                           minimum: expandedMinimum,
                                                           maximum: expandedMaximum,
                                                           isCancelled: isCancelled),
                      let imageCombinationCount = rangeProduct(offsetRanges),
                      imageCombinationCount <= maxOffsetAttempts else {
                    return false
                }
                if countAttempts {
                    guard imageCombinationCount <= maxOffsetAttempts - attemptedOffsetCount else {
                        return false
                    }
                    attemptedOffsetCount += imageCombinationCount
                }
                var offset = SIMD3<Int64>.zero
                return enumerateOffsets(ranges: offsetRanges, dimension: 0,
                                        offset: &offset, body: { current in
                    guard !cancelled(isCancelled), let lattice = basis.lattice(current) else {
                        return false
                    }
                    let imagePosition = target.position + lattice
                    guard imagePosition.isFinite else { return false }
                    guard isInside(imagePosition, minimum: expandedMinimum, maximum: expandedMaximum) else {
                        return true
                    }
                    guard let key = binKey(imagePosition, origin: origin, binSize: binSize) else {
                        return false
                    }
                    return body(current, imagePosition, key)
                })
            }

            guard !cancelled(isCancelled),
                  let key = binKey(target.position, origin: origin, binSize: binSize) else {
                return false
            }
            return body(.zero, target.position, key)
        }

        // Count images before allocating their flat storage. This avoids
        // dictionary bucket arrays and gives the storage budget an exact size.
        for targetIndex in validAtoms {
            guard !cancelled(isCancelled),
                  enumerateImages(targetIndex: targetIndex, countAttempts: true,
                                  body: { _, _, _ in
                guard retainedImageCount < maxGeneratedImages else { return false }
                retainedImageCount += 1
                return true
            }) else { return nil }
            guard !cancelled(isCancelled) else { return nil }
        }

        guard let imageEstimate = storageEstimate(atomCount: atoms.count,
                                                   imageCount: retainedImageCount,
                                                   binCount: retainedImageCount,
                                                   neighborCount: 0),
              imageEstimate <= maxStorageBytes else { return nil }

        let emptyBin = BinKey(x: 0, y: 0, z: 0)
        let emptyImage = ImageRecord(atomIndex: 0, canonicalOffset: .zero,
                                    position: .zero, bin: emptyBin)
        var imageRecords = [ImageRecord](repeating: emptyImage, count: retainedImageCount)
        var imageWriteIndex = 0
        for targetIndex in validAtoms {
            guard !cancelled(isCancelled),
                  enumerateImages(targetIndex: targetIndex, countAttempts: false,
                                  body: { offset, position, key in
                guard imageWriteIndex < imageRecords.count else { return false }
                imageRecords[imageWriteIndex] = ImageRecord(atomIndex: targetIndex,
                                                            canonicalOffset: offset,
                                                            position: position,
                                                            bin: key)
                imageWriteIndex += 1
                return true
            }) else { return nil }
        }
        guard imageWriteIndex == imageRecords.count, !cancelled(isCancelled) else { return nil }

        guard !cancelled(isCancelled) else { return nil }
        guard checkpointedHeapSort(&imageRecords, range: 0..<imageRecords.count,
                                   by: imageRecordPrecedes,
                                   isCancelled: isCancelled) else { return nil }
        guard !cancelled(isCancelled) else { return nil }

        guard let binCount = countBins(in: imageRecords, isCancelled: isCancelled) else {
            return nil
        }
        guard let binEstimate = storageEstimate(atomCount: atoms.count,
                                                imageCount: retainedImageCount,
                                                binCount: binCount,
                                                neighborCount: 0),
              binEstimate <= maxStorageBytes else { return nil }

        guard let bins = makeBins(in: imageRecords, binCount: binCount,
                                  isCancelled: isCancelled) else { return nil }

        func makeNeighbor(sourceIndex: Int, record: ImageRecord,
                          invalid: inout Bool) -> CoordinationNeighbor? {
            let targetIndex = record.atomIndex
            let cutoff = scale * (radii[sourceIndex] + radii[targetIndex])
            guard cutoff.isFinite, cutoff > 0 else {
                invalid = true
                return nil
            }

            let imageOffset: SIMD3<Int32>
            let displacement: SIMD3<Float>
            let displacementDouble: SIMD3<Double>
            if let basis {
                guard let sourcePoint = points[sourceIndex],
                      let targetPoint = points[targetIndex],
                      let offset64 = relativeOffset(sourceQuotient: sourcePoint.quotient,
                                                     targetQuotient: targetPoint.quotient,
                                                     canonicalOffset: record.canonicalOffset,
                                                     dimension: basis.dimension),
                      let lattice = basis.lattice(offset64) else {
                    invalid = true
                    return nil
                }
                // An offset outside Int32 range cannot be recorded in the
                // SIMD3<Int32> imageOffset field. The old code set invalid=true on
                // conversion failure, which aborted the WHOLE analysis for one huge
                // offset. Treat such an image as "not a candidate" instead: skip the
                // record (return nil without setting invalid). The lattice above is
                // still valid; only the 32-bit offset can't round-trip, so this
                // periodic image is simply dropped from the neighbor list.
                guard let offset32 = int32Vector(offset64, dimension: basis.dimension) else {
                    return nil
                }
                imageOffset = offset32
                let sourceOriginal = SIMD3<Double>(Double(atoms[sourceIndex].coord.x),
                                                    Double(atoms[sourceIndex].coord.y),
                                                    Double(atoms[sourceIndex].coord.z))
                let targetOriginal = SIMD3<Double>(Double(atoms[targetIndex].coord.x),
                                                    Double(atoms[targetIndex].coord.y),
                                                    Double(atoms[targetIndex].coord.z))
                let d = targetOriginal + lattice - sourceOriginal
                guard d.isFinite, length(d).isFinite else {
                    invalid = true
                    return nil
                }
                let dFloat = d.float
                guard dFloat.isFinite else {
                    invalid = true
                    return nil
                }
                displacement = dFloat
                displacementDouble = d
            } else {
                imageOffset = SIMD3<Int32>(0, 0, 0)
                let d = SIMD3<Double>(Double(atoms[targetIndex].coord.x),
                                      Double(atoms[targetIndex].coord.y),
                                      Double(atoms[targetIndex].coord.z)) -
                    SIMD3<Double>(Double(atoms[sourceIndex].coord.x),
                                  Double(atoms[sourceIndex].coord.y),
                                  Double(atoms[sourceIndex].coord.z))
                guard d.isFinite, length(d).isFinite else {
                    invalid = true
                    return nil
                }
                let dFloat = d.float
                guard dFloat.isFinite else {
                    invalid = true
                    return nil
                }
                displacement = dFloat
                displacementDouble = d
            }

            let distanceDouble = length(displacementDouble)
            guard distanceDouble.isFinite,
                  distanceDouble > minimumDistance,
                  distanceDouble <= cutoff else { return nil }
            if sourceIndex == targetIndex && imageOffset == SIMD3<Int32>(0, 0, 0) {
                return nil
            }
            let distance = Float(distanceDouble)
            guard distance.isFinite, distance > 0 else { return nil }
            return CoordinationNeighbor(atomIndex: targetIndex,
                                        imageOffset: imageOffset,
                                        displacement: displacement,
                                        distance: distance)
        }

        var candidateChecks = 0
        func traverseCandidates(sourceIndex: Int, countChecks: Bool,
                                body: (CoordinationNeighbor?) -> Bool) -> Bool {
            guard !cancelled(isCancelled), let source = points[sourceIndex],
                  let lower = binKey(source.position - SIMD3<Double>(repeating: maximumCutoff),
                                     origin: origin, binSize: binSize),
                  let upper = binKey(source.position + SIMD3<Double>(repeating: maximumCutoff),
                                     origin: origin, binSize: binSize),
                  lower.x <= upper.x, lower.y <= upper.y, lower.z <= upper.z else {
                return false
            }

            for x in lower.x...upper.x {
                guard !cancelled(isCancelled) else { return false }
                for y in lower.y...upper.y {
                    guard !cancelled(isCancelled) else { return false }
                    for z in lower.z...upper.z {
                        guard !cancelled(isCancelled) else { return false }
                        guard let records = bins[BinKey(x: x, y: y, z: z)] else { continue }
                        for recordIndex in records {
                            guard !cancelled(isCancelled) else { return false }
                            if countChecks {
                                guard candidateChecks < maxCandidateChecks else { return false }
                                candidateChecks += 1
                            }
                            var invalid = false
                            let neighbor = makeNeighbor(sourceIndex: sourceIndex,
                                                        record: imageRecords[recordIndex],
                                                        invalid: &invalid)
                            guard !invalid, body(neighbor) else { return false }
                        }
                    }
                }
            }
            return true
        }

        var coordinationNumbers = Array(repeating: 0, count: atoms.count)
        var neighborRecordCount = 0
        for sourceIndex in validAtoms {
            guard traverseCandidates(sourceIndex: sourceIndex, countChecks: true,
                                     body: { neighbor in
                guard neighbor != nil else { return true }
                guard neighborRecordCount < maxNeighborRecords else { return false }
                neighborRecordCount += 1
                coordinationNumbers[sourceIndex] += 1
                return true
            }) else { return nil }
        }

        var offsets = Array(repeating: 0, count: atoms.count + 1)
        for index in atoms.indices {
            let (next, overflow) = offsets[index].addingReportingOverflow(coordinationNumbers[index])
            guard !overflow else { return nil }
            offsets[index + 1] = next
        }
        guard offsets.last == neighborRecordCount else { return nil }
        guard let neighborEstimate = storageEstimate(atomCount: atoms.count,
                                                      imageCount: retainedImageCount,
                                                      binCount: binCount,
                                                      neighborCount: neighborRecordCount),
              neighborEstimate <= maxStorageBytes else { return nil }

        let emptyNeighbor = CoordinationNeighbor(atomIndex: 0, imageOffset: .zero,
                                                 displacement: .zero, distance: 0)
        var flatNeighbors = [CoordinationNeighbor](repeating: emptyNeighbor,
                                                    count: neighborRecordCount)
        for sourceIndex in validAtoms {
            var writeIndex = offsets[sourceIndex]
            let end = offsets[sourceIndex + 1]
            guard traverseCandidates(sourceIndex: sourceIndex, countChecks: false,
                                     body: { neighbor in
                guard let neighbor else { return true }
                guard writeIndex < end else { return false }
                flatNeighbors[writeIndex] = neighbor
                writeIndex += 1
                return true
            }), writeIndex == end else { return nil }

            guard !cancelled(isCancelled) else { return nil }
            guard checkpointedHeapSort(&flatNeighbors, range: offsets[sourceIndex]..<end,
                                       by: neighborPrecedes,
                                       isCancelled: isCancelled) else { return nil }
            guard !cancelled(isCancelled) else { return nil }
        }
        guard !cancelled(isCancelled) else { return nil }

        // Same-atom deduplication: a lattice vector shorter than the cutoff can
        // place the SAME target atom (different periodic images) inside the cutoff
        // several times; the two passes above count each image independently,
        // inflating coordination numbers. Within each source's neighbor run (already
        // sorted by distance via `neighborPrecedes`), keep only the first — hence
        // minimum-distance — image per unique target atom. This keeps `coordination`
        // counting unique atoms and makes the stored displacement the minimum-image
        // one that downstream consumers (neighbor tables, bond-angle distribution)
        // rely on. The offsets/counts arrays are rebuilt to match the deduped list.
        let deduped = deduplicateSameAtomNeighbors(
            flatNeighbors, offsets: offsets, counts: coordinationNumbers)

        return CoordinationAnalysis(records: deduped.neighbors, offsets: deduped.offsets,
                                    counts: deduped.counts,
                                    candidateChecks: candidateChecks)
    }

    // These seams keep cancellation tests independent of scheduler timing.
    static func sortImageRecordsForTesting(_ records: inout [ImageRecord],
                                           isCancelled: (() -> Bool)? = nil) -> Bool {
        checkpointedHeapSort(&records, range: 0..<records.count,
                             by: imageRecordPrecedes, isCancelled: isCancelled)
    }

    static func sortNeighborsForTesting(_ records: inout [CoordinationNeighbor],
                                        isCancelled: (() -> Bool)? = nil) -> Bool {
        checkpointedHeapSort(&records, range: 0..<records.count,
                             by: neighborPrecedes, isCancelled: isCancelled)
    }

    static func buildBinIndexForTesting(
        _ imageRecords: [ImageRecord], isCancelled: (() -> Bool)? = nil,
        onConstructionCheckpoint: ((Int) -> Void)? = nil
    ) -> [BinKey: Range<Int>]? {
        guard let binCount = countBins(in: imageRecords, isCancelled: isCancelled) else {
            return nil
        }
        return makeBins(in: imageRecords, binCount: binCount,
                        isCancelled: isCancelled,
                        onConstructionCheckpoint: onConstructionCheckpoint)
    }

    private static func canonicalPoint(_ point: SIMD3<Double>, coefficients: [Double],
                                       basis: PeriodicBasis,
                                       isCancelled: (() -> Bool)?) -> CanonicalPoint? {
        guard coefficients.count == basis.dimension, coefficients.count <= 3 else { return nil }
        var quotient = SIMD3<Int64>.zero
        for index in coefficients.indices {
            let coefficient = coefficients[index]
            guard !cancelled(isCancelled) else { return nil }
            let floored = floor(coefficient)
            guard floored.isFinite,
                   floored > Double(Int64.min), floored < Double(Int64.max) else { return nil }
            quotient[index] = Int64(floored)
        }
        guard let lattice = basis.lattice(quotient) else { return nil }
        let canonical = point - lattice
        guard canonical.isFinite else { return nil }
        return CanonicalPoint(position: canonical, quotient: quotient)
    }

    private static func imageOffsetRanges(basis: PeriodicBasis, target: SIMD3<Double>,
                                          minimum: SIMD3<Double>, maximum: SIMD3<Double>,
                                          isCancelled: (() -> Bool)?) -> [ClosedRange<Int64>]? {
        guard target.isFinite, minimum.isFinite, maximum.isFinite,
              minimum.x <= maximum.x, minimum.y <= maximum.y, minimum.z <= maximum.z else {
            return nil
        }

        let xValues = [minimum.x, maximum.x]
        let yValues = [minimum.y, maximum.y]
        let zValues = [minimum.z, maximum.z]
        var lower = [Double](repeating: .infinity, count: basis.dimension)
        var upper = [Double](repeating: -.infinity, count: basis.dimension)
        for x in xValues {
            for y in yValues {
                for z in zValues {
                    guard !cancelled(isCancelled),
                          let coefficients = basis.coefficients(for: SIMD3<Double>(x, y, z) - target) else {
                        return nil
                    }
                    for index in coefficients.indices {
                        lower[index] = min(lower[index], coefficients[index])
                        upper[index] = max(upper[index], coefficients[index])
                    }
                }
            }
        }

        var result: [ClosedRange<Int64>] = []
        result.reserveCapacity(basis.dimension)
        for index in lower.indices {
            guard !cancelled(isCancelled), lower[index].isFinite, upper[index].isFinite else {
                return nil
            }
            guard let lowerInt = ceilInt64(lower[index].nextDown),
                  let upperInt = floorInt64(upper[index].nextUp),
                  lowerInt <= upperInt else { return nil }
            result.append(lowerInt...upperInt)
        }
        return result
    }

    private static func enumerateOffsets(ranges: [ClosedRange<Int64>], dimension: Int,
                                         offset: inout SIMD3<Int64>,
                                         body: (SIMD3<Int64>) -> Bool) -> Bool {
        guard dimension <= ranges.count, ranges.count <= 3 else { return false }
        if dimension == ranges.count {
            return body(offset)
        }
        let range = ranges[dimension]
        var value = range.lowerBound
        while true {
            offset[dimension] = Int64(value)
            if !enumerateOffsets(ranges: ranges, dimension: dimension + 1,
                                 offset: &offset, body: body) {
                return false
            }
            if value == range.upperBound { break }
            let (next, overflow) = value.addingReportingOverflow(1)
            guard !overflow else { return false }
            value = next
        }
        return true
    }

    private static func relativeOffset(sourceQuotient: SIMD3<Int64>,
                                       targetQuotient: SIMD3<Int64>,
                                       canonicalOffset: SIMD3<Int64>,
                                       dimension: Int) -> SIMD3<Int64>? {
        guard (0...3).contains(dimension) else { return nil }
        var result = SIMD3<Int64>.zero
        for index in 0..<dimension {
            let (first, firstOverflow) = canonicalOffset[index].subtractingReportingOverflow(targetQuotient[index])
            let (value, secondOverflow) = first.addingReportingOverflow(sourceQuotient[index])
            guard !firstOverflow, !secondOverflow else { return nil }
            result[index] = value
        }
        return result
    }

    private static func int32Vector(_ values: SIMD3<Int64>, dimension: Int) -> SIMD3<Int32>? {
        guard (0...3).contains(dimension) else { return nil }
        for index in 0..<dimension {
            guard values[index] >= Int64(Int32.min), values[index] <= Int64(Int32.max) else {
                return nil
            }
        }
        return SIMD3<Int32>(Int32(values.x), Int32(values.y), Int32(values.z))
    }

    private static func binKey(_ point: SIMD3<Double>, origin: SIMD3<Double>,
                               binSize: Double) -> BinKey? {
        guard point.isFinite, origin.isFinite, binSize.isFinite, binSize > 0 else { return nil }
        let scaled = (point - origin) / binSize
        guard scaled.isFinite,
              let x = floorInt64(scaled.x), let y = floorInt64(scaled.y),
              let z = floorInt64(scaled.z) else { return nil }
        return BinKey(x: x, y: y, z: z)
    }

    private static func ceilInt64(_ value: Double) -> Int64? {
        let ceiled = ceil(value)
        guard ceiled.isFinite,
              ceiled > Double(Int64.min), ceiled < Double(Int64.max) else { return nil }
        return Int64(ceiled)
    }

    private static func floorInt64(_ value: Double) -> Int64? {
        let floored = floor(value)
        guard floored.isFinite,
               floored > Double(Int64.min), floored < Double(Int64.max) else { return nil }
        return Int64(floored)
    }

    private static func countBins(in imageRecords: [ImageRecord],
                                  isCancelled: (() -> Bool)?) -> Int? {
        guard !cancelled(isCancelled) else { return nil }

        var binCount = 0
        var scanIndex = 0
        var recordsSinceCheckpoint = 0
        while scanIndex < imageRecords.count {
            binCount += 1
            let key = imageRecords[scanIndex].bin
            scanIndex += 1
            recordsSinceCheckpoint += 1
            if recordsSinceCheckpoint == cancellationCheckpointInterval {
                recordsSinceCheckpoint = 0
                guard !cancelled(isCancelled) else { return nil }
            }
            while scanIndex < imageRecords.count, imageRecords[scanIndex].bin == key {
                scanIndex += 1
                recordsSinceCheckpoint += 1
                if recordsSinceCheckpoint == cancellationCheckpointInterval {
                    recordsSinceCheckpoint = 0
                    guard !cancelled(isCancelled) else { return nil }
                }
            }
        }
        guard !cancelled(isCancelled) else { return nil }
        return binCount
    }

    private static func makeBins(in imageRecords: [ImageRecord], binCount: Int,
                                 isCancelled: (() -> Bool)?,
                                 onConstructionCheckpoint: ((Int) -> Void)? = nil
    ) -> [BinKey: Range<Int>]? {
        guard binCount >= 0 else { return nil }

        var bins: [BinKey: Range<Int>] = [:]
        bins.reserveCapacity(binCount)
        guard !cancelled(isCancelled) else { return nil }

        var scanIndex = 0
        var recordsSinceCheckpoint = 0
        while scanIndex < imageRecords.count {
            let key = imageRecords[scanIndex].bin
            let start = scanIndex
            scanIndex += 1
            recordsSinceCheckpoint += 1
            if recordsSinceCheckpoint == cancellationCheckpointInterval {
                recordsSinceCheckpoint = 0
                onConstructionCheckpoint?(scanIndex)
                guard !cancelled(isCancelled) else { return nil }
            }
            while scanIndex < imageRecords.count, imageRecords[scanIndex].bin == key {
                scanIndex += 1
                recordsSinceCheckpoint += 1
                if recordsSinceCheckpoint == cancellationCheckpointInterval {
                    recordsSinceCheckpoint = 0
                    onConstructionCheckpoint?(scanIndex)
                    guard !cancelled(isCancelled) else { return nil }
                }
            }
            bins[key] = start..<scanIndex
        }
        guard !cancelled(isCancelled) else { return nil }
        return bins
    }

    private static func isInside(_ point: SIMD3<Double>, minimum: SIMD3<Double>,
                                 maximum: SIMD3<Double>) -> Bool {
        point.x >= minimum.x && point.x <= maximum.x &&
        point.y >= minimum.y && point.y <= maximum.y &&
        point.z >= minimum.z && point.z <= maximum.z
    }

    private static func rangeProduct(_ ranges: [ClosedRange<Int64>]) -> Int? {
        var result = 1
        for range in ranges {
            let (span, spanOverflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
            guard !spanOverflow else { return nil }
            let (count, countOverflow) = span.addingReportingOverflow(1)
            guard !countOverflow, let count = Int(exactly: count) else { return nil }
            let (next, overflow) = result.multipliedReportingOverflow(by: count)
            guard !overflow else { return nil }
            result = next
        }
        return result
    }

    private static func checkpointedHeapSort<T>(
        _ values: inout [T], range: Range<Int>,
        by areInIncreasingOrder: (T, T) -> Bool,
        isCancelled: (() -> Bool)?) -> Bool {
        guard range.lowerBound >= 0,
              range.upperBound <= values.count,
              range.lowerBound <= range.upperBound,
              !cancelled(isCancelled) else { return false }

        let count = range.count
        guard count > 1 else {
            return !cancelled(isCancelled)
        }

        var start = count / 2
        while start > 0 {
            start -= 1
            guard heapSiftDown(&values, base: range.lowerBound, root: start, end: count,
                               by: areInIncreasingOrder, isCancelled: isCancelled) else {
                return false
            }
        }

        var end = count
        while end > 1 {
            guard !cancelled(isCancelled) else { return false }
            values.swapAt(range.lowerBound, range.lowerBound + end - 1)
            end -= 1
            guard heapSiftDown(&values, base: range.lowerBound, root: 0, end: end,
                               by: areInIncreasingOrder, isCancelled: isCancelled) else {
                return false
            }
        }
        return !cancelled(isCancelled)
    }

    private static func heapSiftDown<T>(
        _ values: inout [T], base: Int, root: Int, end: Int,
        by areInIncreasingOrder: (T, T) -> Bool,
        isCancelled: (() -> Bool)?) -> Bool {
        var root = root
        guard !cancelled(isCancelled) else { return false }
        while root < end / 2 {
            guard !cancelled(isCancelled) else { return false }
            let left = root * 2 + 1
            var candidate = root
            guard !cancelled(isCancelled) else { return false }
            if areInIncreasingOrder(values[base + candidate], values[base + left]) {
                candidate = left
            }
            if left + 1 < end {
                guard !cancelled(isCancelled) else { return false }
                if areInIncreasingOrder(values[base + candidate], values[base + left + 1]) {
                    candidate = left + 1
                }
            }
            guard !cancelled(isCancelled) else { return false }
            if candidate == root { break }
            values.swapAt(base + root, base + candidate)
            root = candidate
        }
        return !cancelled(isCancelled)
    }

    private static func storageEstimate(atomCount: Int, imageCount: Int,
                                        binCount: Int, neighborCount: Int) -> Int? {
        guard atomCount >= 0, imageCount >= 0, binCount >= 0, neighborCount >= 0 else {
            return nil
        }
        let (offsetCount, offsetOverflow) = atomCount.addingReportingOverflow(1)
        guard !offsetOverflow else { return nil }

        var total = 4_096 // Array and dictionary bookkeeping not represented by strides.
        func add(_ count: Int, _ stride: Int) -> Bool {
            let (bytes, multiplicationOverflow) = count.multipliedReportingOverflow(by: stride)
            guard !multiplicationOverflow else { return false }
            let (next, additionOverflow) = total.addingReportingOverflow(bytes)
            guard !additionOverflow else { return false }
            total = next
            return true
        }

        // These are the retained analysis work arrays. Valid atoms are
        // conservatively estimated at atomCount before element filtering.
        guard add(atomCount, MemoryLayout<Double>.stride),
              add(atomCount, MemoryLayout<Int>.stride),
              add(atomCount, MemoryLayout<CanonicalPoint?>.stride),
              add(offsetCount, MemoryLayout<Int>.stride),
              add(atomCount, MemoryLayout<Int>.stride),
              add(imageCount, MemoryLayout<ImageRecord>.stride),
              add(neighborCount, MemoryLayout<CoordinationNeighbor>.stride) else {
            return nil
        }

        let (rangeStride, rangeStrideOverflow) =
            MemoryLayout<Range<Int>>.stride.addingReportingOverflow(32)
        guard !rangeStrideOverflow else { return nil }
        let (binStride, binStrideOverflow) =
            MemoryLayout<BinKey>.stride.addingReportingOverflow(rangeStride)
        guard !binStrideOverflow, add(binCount, binStride) else { return nil }
        return total
    }

    private static func cancelled(_ isCancelled: (() -> Bool)?) -> Bool {
        isCancelled?() == true
    }

    /// Per-source, drop all but the first (minimum-distance) image of each unique
    /// target atom. `neighbors` must be grouped by source with each group sorted by
    /// distance ascending — which the caller guarantees via `neighborPrecedes`.
    /// Returns the compacted neighbor list plus offsets/counts that describe it,
    /// so the CoordinationAnalysis API surface (offsets/counts arrays) is preserved.
    private static func deduplicateSameAtomNeighbors(
        _ neighbors: [CoordinationNeighbor],
        offsets: [Int],
        counts: [Int]
    ) -> (neighbors: [CoordinationNeighbor], offsets: [Int], counts: [Int]) {
        // No early-out on cardinality: in a sparse system a single source with a
        // few periodic-image neighbors amid N other atoms (all zero-count) yields
        // neighbors.count < offsets.count-1 and would otherwise skip dedupe,
        // leaving the same-target double-count in place. Dedupe is O(n); always run.
        var out: [CoordinationNeighbor] = []
        out.reserveCapacity(neighbors.count)
        var newOffsets = Array(repeating: 0, count: offsets.count)
        var newCounts = Array(repeating: 0, count: counts.count)
        var writeIndex = 0
        let sourceCount = offsets.count - 1
        for source in 0..<sourceCount {
            let start = offsets[source]
            let end = offsets[source + 1]
            var seen = Set<Int>()
            seen.reserveCapacity(end - start)
            for i in start..<end {
                let n = neighbors[i]
                guard seen.insert(n.atomIndex).inserted else { continue }
                out.append(n)
                writeIndex += 1
            }
            newCounts[source] = seen.count
            newOffsets[source + 1] = writeIndex
        }
        for source in sourceCount..<counts.count {
            newOffsets[source + 1] = writeIndex
            newCounts[source] = 0
        }
        return (out, newOffsets, newCounts)
    }

    private static func imageRecordPrecedes(_ lhs: ImageRecord, _ rhs: ImageRecord) -> Bool {
        if lhs.bin.x != rhs.bin.x { return lhs.bin.x < rhs.bin.x }
        if lhs.bin.y != rhs.bin.y { return lhs.bin.y < rhs.bin.y }
        if lhs.bin.z != rhs.bin.z { return lhs.bin.z < rhs.bin.z }
        if lhs.atomIndex != rhs.atomIndex { return lhs.atomIndex < rhs.atomIndex }
        if lhs.canonicalOffset.x != rhs.canonicalOffset.x {
            return lhs.canonicalOffset.x < rhs.canonicalOffset.x
        }
        if lhs.canonicalOffset.y != rhs.canonicalOffset.y {
            return lhs.canonicalOffset.y < rhs.canonicalOffset.y
        }
        return lhs.canonicalOffset.z < rhs.canonicalOffset.z
    }

    private static func neighborPrecedes(_ lhs: CoordinationNeighbor,
                                         _ rhs: CoordinationNeighbor) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        if lhs.atomIndex != rhs.atomIndex { return lhs.atomIndex < rhs.atomIndex }
        if lhs.imageOffset.x != rhs.imageOffset.x { return lhs.imageOffset.x < rhs.imageOffset.x }
        if lhs.imageOffset.y != rhs.imageOffset.y { return lhs.imageOffset.y < rhs.imageOffset.y }
        return lhs.imageOffset.z < rhs.imageOffset.z
    }

    private static func doubleVector(_ vector: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(vector.x), Double(vector.y), Double(vector.z))
    }

    private static func invert(_ matrix: [[Double]], isCancelled: (() -> Bool)?) -> [[Double]]? {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var augmented = matrix.enumerated().map { row, values in
            values + (0..<n).map { $0 == row ? 1.0 : 0.0 }
        }
        for column in 0..<n {
            guard !cancelled(isCancelled) else { return nil }
            guard let pivot = (column..<n).max(by: {
                abs(augmented[$0][column]) < abs(augmented[$1][column])
            }) else { return nil }
            let pivotValue = augmented[pivot][column]
            guard pivotValue.isFinite, abs(pivotValue) > 0 else { return nil }
            if pivot != column { augmented.swapAt(pivot, column) }
            let divisor = augmented[column][column]
            for j in 0..<(2 * n) {
                guard !cancelled(isCancelled) else { return nil }
                augmented[column][j] /= divisor
            }
            for row in 0..<n where row != column {
                guard !cancelled(isCancelled) else { return nil }
                let factor = augmented[row][column]
                for j in 0..<(2 * n) {
                    guard !cancelled(isCancelled) else { return nil }
                    augmented[row][j] -= factor * augmented[column][j]
                }
            }
        }
        guard !cancelled(isCancelled) else { return nil }
        let result = augmented.map { Array($0[n..<(2 * n)]) }
        return result.flatMap({ $0 }).allSatisfy({ $0.isFinite }) ? result : nil
    }
}
