import Foundation
import simd

/// Volume/distortion metrics for the first-shell coordination polyhedron of a
/// central atom. The polyhedron vertices are the positions of the atom's
/// first-shell neighbors (minimum-image displacement applied, so periodic
/// images are used when the coordination analysis was periodic).
///
/// Availability rules (all deliberate, never traps):
/// - `volume` requires at least 4 non-coplanar neighbors (a 3D hull).
/// - `bondLengthDistortion` requires at least 2 neighbors with a nonzero
///   mean bond length.
/// - `angleDeviation` requires at least 3 neighbors (one angle).
/// - Metrics that cannot be computed for the local geometry stay nil.
struct PolyhedronMetrics: Equatable {
    let neighborCount: Int
    /// Convex-hull volume (Å³) of the neighbor positions. nil when the
    /// neighbors are fewer than 4, coplanar, or non-finite.
    let volume: Float?
    /// Mean absolute bond-length distortion: mean(|dᵢ − d̄|) / d̄. 0 = perfectly
    /// regular bond lengths; nil for degenerate shells.
    let bondLengthDistortion: Float?
    /// RMS deviation (degrees) of the observed neighbor angles from the ideal
    /// angle of the coordination number (109.47° for CN 4, 90° for CN 6, …).
    /// When no ideal angle is defined for the CN, the mean observed angle is
    /// used as the reference (i.e. the metric measures angular spread).
    let angleDeviation: Float?
    /// The ideal angle used as the `angleDeviation` reference, when one is
    /// defined for this coordination number. nil for undefined CNs.
    let idealAngle: Float?
    /// Hull volume divided by the volume of the ideal regular polyhedron with
    /// the same coordination number and mean bond length. 1 = regular;
    /// nil when either volume is unavailable.
    let volumeRatio: Float?

    var isAvailable: Bool {
        volume != nil || bondLengthDistortion != nil || angleDeviation != nil
    }
}

/// Canonicalized plane key for grouping coplanar hull faces. The normal is
/// oriented so its first non-zero component is positive, and the offset is
/// adjusted accordingly, so (n, d) and (-n, -d) map to the same key.
///
/// Components are rounded Doubles (not scaled-to-Int) so the conversion is
/// provably nontrapping for any finite input: Double overflow yields infinity
/// rather than a trap, and finite coordinates never overflow the scale.
private struct HullPlane: Hashable {
    let nx, ny, nz: Double
    let offset: Double

    init(normal: SIMD3<Double>, offset: Double) {
        let flip = normal.x < -1e-12
            || (normal.x.magnitude < 1e-12 && normal.y < -1e-12)
            || (normal.x.magnitude < 1e-12 && normal.y.magnitude < 1e-12 && normal.z < -1e-12)
        let cn = flip ? -normal : normal
        let co = flip ? -offset : offset
        // Round to 1e-6 precision. Double arithmetic never traps: overflow
        // produces infinity, and finite unit-vector components times 1e6 are
        // far below Double.greatestFiniteMagnitude.
        let scale = 1_000_000.0
        self.nx = (cn.x * scale).rounded() / scale
        self.ny = (cn.y * scale).rounded() / scale
        self.nz = (cn.z * scale).rounded() / scale
        self.offset = (co * scale).rounded() / scale
    }
}

/// A convex-hull face: the participating vertex indices, the 2D-hull polygon
/// (indices into `vertexIndices`), and the outward unit normal.
private struct HullFace {
    let vertexIndices: [Int]
    let hullIndices: [Int]
    let outwardNormal: SIMD3<Double>
}

/// Ordered pair for edge deduplication.
private struct IntPair: Hashable {
    let a: Int
    let b: Int
}

enum PolyhedronAnalyzer {
    /// Analysis bound mirroring the coordination analyzer's documented 4,096
    /// base-atom cap. Larger inputs yield nil (unavailable), never partial data.
    static let maxAtoms = 4_096
    /// Hard cap on hull vertices. Real first shells are ≤ 24; the O(n⁴) face
    /// enumeration stays trivial at this bound.
    static let maxNeighborsPerAtom = 24
    /// Coordination-shell grouping tolerance, matching `CoordinationShell`.
    static let shellTolerance: Float = 0.05
    /// Coplanarity tolerance for the hull face test (relative to edge length).
    static let coplanarityTolerance: Float = 1e-4

    /// Compute first-shell polyhedron metrics for every atom in `atoms`.
    /// The analysis must cover every atom (same atom ordering as the
    /// coordination analysis that produced it). Returns nil for non-finite
    /// input or when the atom count exceeds the analysis cap.
    static func analyze(analysis: CoordinationAnalysis,
                        atoms: [Atom],
                        isCancelled: (() -> Bool)? = nil) -> [PolyhedronMetrics]? {
        guard !cancelled(isCancelled) else { return nil }
        guard atoms.count <= maxAtoms,
              atoms.allSatisfy({ $0.coord.isFinite }) else { return nil }
        guard analysis.coordinationNumbers.count == atoms.count else { return nil }

        var result: [PolyhedronMetrics] = []
        result.reserveCapacity(atoms.count)
        for index in atoms.indices {
            guard !cancelled(isCancelled) else { return nil }
            let shell = firstShell(of: index, analysis: analysis, atoms: atoms)
            result.append(metrics(for: atoms[index].coord, shell: shell,
                                  isCancelled: isCancelled))
        }
        guard !cancelled(isCancelled) else { return nil }
        return result
    }

    /// The first coordination shell of `atomIndex` as absolute neighbor
    /// positions (source position + minimum-image displacement). Degenerate
    /// or non-finite entries are dropped.
    ///
    /// Only the first distance shell is ever returned: every candidate
    /// distance is compared against the fixed first-neighbor distance, so
    /// tolerance chaining cannot absorb later shells. Once a neighbor's
    /// distance jumps beyond `shellTolerance` from the reference, the
    /// enumeration stops unconditionally — the boundary is checked before
    /// displacement validation and without a group-nonempty gate, so a
    /// valid-distance record beyond the shell always terminates enumeration.
    /// Malformed records (non-finite or negative distance/displacement) are
    /// skipped safely without poisoning grouping.
    /// The actual neighbor count is preserved; `metrics(for:shell:)` enforces
    /// `maxNeighborsPerAtom` and reports the atom's metrics unavailable when
    /// the shell is too large, rather than fabricating a truncated CN.
    static func firstShell(of atomIndex: Int, analysis: CoordinationAnalysis,
                           atoms: [Atom]) -> [SIMD3<Float>] {
        guard atomIndex >= 0, atomIndex < atoms.count,
              atoms[atomIndex].coord.isFinite else { return [] }
        let neighbors = analysis.neighbors(of: atomIndex)
        guard !neighbors.isEmpty else { return [] }

        // Fixate the first neighbor's distance as the shell reference.
        // Validate it so a malformed first record cannot poison grouping.
        let referenceDistance = neighbors[0].distance
        guard referenceDistance.isFinite, referenceDistance >= 0 else { return [] }

        var group: [SIMD3<Float>] = []
        group.reserveCapacity(neighbors.count)

        for neighbor in neighbors {
            // Validate the distance first; a malformed distance record is
            // skipped rather than poisoning the shell grouping.
            guard neighbor.distance.isFinite, neighbor.distance >= 0 else { continue }

            // Boundary check: compare against the fixated reference distance
            // and break unconditionally before validating displacement or
            // appending. No group-nonempty gate — an out-of-shell distance
            // terminates the sorted first shell regardless of whether prior
            // records were skipped or had invalid displacements.
            if abs(neighbor.distance - referenceDistance) > shellTolerance {
                break
            }

            // Now validate displacement; skip records with malformed
            // displacements without terminating the shell.
            guard neighbor.displacement.isFinite else { continue }

            let position = atoms[atomIndex].coord + neighbor.displacement
            if position.isFinite {
                group.append(position)
            }
        }

        return group
    }

    static func metrics(for center: SIMD3<Float>, shell: [SIMD3<Float>],
                        isCancelled: (() -> Bool)? = nil) -> PolyhedronMetrics {
        let count = shell.count
        guard center.isFinite else {
            return PolyhedronMetrics(neighborCount: count, volume: nil,
                                     bondLengthDistortion: nil, angleDeviation: nil,
                                     idealAngle: nil, volumeRatio: nil)
        }
        guard count >= 2 else {
            return PolyhedronMetrics(neighborCount: count, volume: nil,
                                     bondLengthDistortion: nil, angleDeviation: nil,
                                     idealAngle: nil, volumeRatio: nil)
        }

        // Enforce the per-atom cap: preserve the real count but make all
        // derived fields unavailable rather than entering expensive hull
        // work or fabricating a truncated coordination number.
        guard count <= maxNeighborsPerAtom else {
            return PolyhedronMetrics(neighborCount: count, volume: nil,
                                     bondLengthDistortion: nil, angleDeviation: nil,
                                     idealAngle: nil, volumeRatio: nil)
        }

        // Bond lengths from the central atom to each vertex.
        var bondLengths: [Float] = []
        bondLengths.reserveCapacity(count)
        var meanBondLength: Double = 0
        for vertex in shell {
            let d = length(vertex - center)
            guard d.isFinite, d > 1e-7 else {
                return PolyhedronMetrics(neighborCount: count, volume: nil,
                                         bondLengthDistortion: nil, angleDeviation: nil,
                                         idealAngle: nil, volumeRatio: nil)
            }
            bondLengths.append(d)
            meanBondLength += Double(d)
        }
        meanBondLength /= Double(count)

        let distortion: Float? = {
            guard meanBondLength > 1e-12 else { return nil }
            var sum = 0.0
            for d in bondLengths { sum += abs(Double(d) - meanBondLength) }
            let value = Float(sum / Double(count) / meanBondLength)
            return value.isFinite ? value : nil
        }()

        // Convex hull of the vertex set (3D hull only). The hull computation
        // is the expensive step; cancellation checkpoints live inside it.
        let doubleShell = shell.map { $0.double }
        var centroid = SIMD3<Double>.zero
        for p in doubleShell { centroid += p }
        centroid /= Double(count)

        let faces: [HullFace]? = count >= 4
            ? computeHullFaces(of: doubleShell, centroid: centroid, isCancelled: isCancelled)
            : nil

        // A nil return from computeHullFaces means the work was cancelled;
        // report the atom's metrics unavailable rather than partial.
        guard !cancelled(isCancelled) else {
            return PolyhedronMetrics(neighborCount: count, volume: nil,
                                     bondLengthDistortion: nil, angleDeviation: nil,
                                     idealAngle: nil, volumeRatio: nil)
        }

        // Volume from the triangulated hull faces.
        let volume: Float?
        if let faces, !faces.isEmpty {
            volume = hullVolumeFromFaces(faces, points: doubleShell)
        } else {
            volume = nil
        }

        // Angle deviation uses the actual convex-hull edge pairs: for CN ≥ 4
        // with a non-degenerate hull these are the polyhedron edges; for CN < 4
        // (or coplanar CN ≥ 4) there are no 3D hull edges and we fall back to
        // all vertex pairs. This keeps trans/skew/face-diagonal pairs out of
        // the metric for octahedral, cubic, and icosahedral shells.
        let hullEdges: [(Int, Int)]? = {
            guard let faces, !faces.isEmpty, count >= 4 else { return nil }
            return edges(of: faces)
        }()

        let angles: [Float]? = {
            // Angle deviation requires at least 3 neighbors; with fewer
            // there is no meaningful angular spread to measure.
            guard count >= 3 else { return nil }
            let edgePairs = hullEdges ?? allPairs(count)
            guard !edgePairs.isEmpty else { return nil }
            var values: [Float] = []
            values.reserveCapacity(edgePairs.count)
            for (i, j) in edgePairs {
                let vi = shell[i] - center
                let vj = shell[j] - center
                let li = length(vi), lj = length(vj)
                guard li > 1e-7, lj > 1e-7 else { return nil }
                let cosine = dot(vi, vj) / (li * lj)
                guard cosine.isFinite else { return nil }
                let angle = acos(min(max(cosine, -1), 1)) * 180 / .pi
                guard angle.isFinite else { return nil }
                values.append(angle)
            }
            return values
        }()

        let ideal = idealAngle(for: count)
        let angleDeviation: Float? = angles.flatMap { observed -> Float? in
            var sum = 0.0
            let meanAngle = observed.reduce(0.0) { $0 + Double($1) } / Double(observed.count)
            let reference: Double = ideal.map { Double($0) } ?? meanAngle
            for angle in observed {
                sum += pow(Double(angle) - reference, 2)
            }
            let value = Float(sqrt(sum / Double(observed.count)))
            return value.isFinite ? value : nil
        }

        // Volume ratio: hull volume over the ideal regular-polyhedron volume.
        let volumeRatio: Float?
        if let volume, volume > 1e-12,
           let idealVolume = idealPolyhedronVolume(coordination: count,
                                                   meanBondLength: Float(meanBondLength)),
           idealVolume > 1e-12 {
            let ratio = volume / idealVolume
            volumeRatio = ratio.isFinite ? ratio : nil
        } else {
            volumeRatio = nil
        }

        return PolyhedronMetrics(neighborCount: count,
                                 volume: volume,
                                 bondLengthDistortion: distortion,
                                 angleDeviation: angleDeviation,
                                 idealAngle: ideal,
                                 volumeRatio: volumeRatio)
    }

    /// Ideal central angle (degrees) for a regular coordination polyhedron of
    /// the given coordination number. Returns nil for CNs without a unique
    /// regular reference (5, 7, 9, 10, 11).
    static func idealAngle(for coordination: Int) -> Float? {
        switch coordination {
        case 3: return 120.0
        case 4: return 109.47122063449069
        case 6: return 90.0
        case 8: return 70.52877936550931
        case 12: return 63.43494882292201
        default: return nil
        }
    }

    /// Volume of the ideal regular coordination polyhedron with the given
    /// coordination number and circumradius = mean bond length (the central
    /// atom sits at the polyhedron center).
    static func idealPolyhedronVolume(coordination: Int, meanBondLength: Float) -> Float? {
        guard meanBondLength.isFinite, meanBondLength > 1e-12 else { return nil }
        let r = Double(meanBondLength)
        let value: Double
        switch coordination {
        case 4:
            // Regular tetrahedron: edge a = r·√(8/3), V = a³/(6√2).
            let a = r * sqrt(8.0 / 3.0)
            value = a * a * a / (6.0 * sqrt(2.0))
        case 6:
            // Regular octahedron with circumradius r: V = 4r³/3.
            value = 4.0 * r * r * r / 3.0
        case 8:
            // Cube with circumradius r: V = (2r/√3)³.
            let a = 2.0 * r / sqrt(3.0)
            value = a * a * a
        case 12:
            // Regular icosahedron: edge a = 4r/√(10+2√5), V = (5/12)(3+√5)a³.
            let a = 4.0 * r / sqrt(10.0 + 2.0 * sqrt(5.0))
            value = (5.0 / 12.0) * (3.0 + sqrt(5.0)) * a * a * a
        default:
            return nil
        }
        guard value.isFinite, value > 0 else { return nil }
        let result = Float(value)
        return result.isFinite ? result : nil
    }

    /// Exact convex-hull volume of a small 3D point set. Coplanar facets are
    /// deduplicated and triangulated exactly once, so a regular cube at +/-1
    /// reports volume 8. Returns nil for fewer than 4 points, non-finite input,
    /// coplanar/degenerate sets, or when the computation is cancelled.
    static func hullVolume(of points: [SIMD3<Float>],
                           isCancelled: (() -> Bool)? = nil) -> Float? {
        guard points.count >= 4, points.allSatisfy({ $0.isFinite }) else { return nil }
        let doublePoints = points.map { $0.double }
        var centroid = SIMD3<Double>.zero
        for p in doublePoints { centroid += p }
        centroid /= Double(points.count)
        guard let faces = computeHullFaces(of: doublePoints, centroid: centroid,
                                            isCancelled: isCancelled) else { return nil }
        guard !faces.isEmpty else { return nil }
        return hullVolumeFromFaces(faces, points: doublePoints)
    }

    // MARK: - Convex hull face enumeration

    /// Characteristic linear scale of a point set: the bounding-box diagonal.
    /// Used to turn the dimensionless `coplanarityTolerance` into an absolute
    /// linear distance. O(n), never traps, zero only for a degenerate
    /// single-point set (which has no 3D hull regardless).
    private static func pointCloudExtent(_ points: [SIMD3<Double>]) -> Double {
        guard let first = points.first else { return 0.0 }
        var minB = first, maxB = first
        for p in points.dropFirst() {
            minB = min(minB, p)
            maxB = max(maxB, p)
        }
        return length(maxB - minB)
    }

    /// Enumerate the convex hull faces of a 3D point set, grouping coplanar
    /// triples into single faces and computing the 2D-hull polygon for each.
    /// Returns nil if cancelled, an empty array if the points are coplanar or
    /// otherwise degenerate (no 3D face), or one `HullFace` per hull facet.
    private static func computeHullFaces(of points: [SIMD3<Double>],
                                         centroid: SIMD3<Double>,
                                         isCancelled: (() -> Bool)?) -> [HullFace]? {
        let n = points.count
        guard n >= 4 else { return [] }

        // Scale-aware linear tolerance: the dimensionless coplanarityTolerance
        // multiplied by the point-cloud extent gives an absolute distance
        // threshold consistent with the linear distance `dot(unit, p) - offset`.
        let extent = pointCloudExtent(points)
        let linearTolerance = Double(coplanarityTolerance) * extent

        // Fast coplanarity reject: if every point lies on a single plane the
        // set has no 3D hull. This also avoids the degenerate face grouping
        // below, which would otherwise merge all coplanar triples into one.
        if areAllCoplanar(points, linearTolerance: linearTolerance) { return [] }

        // Canonical plane key → group index. Coplanar triples (same plane,
        // same side of the polyhedron) collapse into one group.
        var planeToGroup: [HullPlane: Int] = [:]
        var planeGroups: [Int: Set<Int>] = [:]
        var groupNormals: [Int: SIMD3<Double>] = [:]

        for i in 0..<n {
            guard !cancelled(isCancelled) else { return nil }
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    let a = points[i], b = points[j], c = points[k]
                    let normal = cross(b - a, c - a)
                    let normalLength = length(normal)
                    guard normalLength > 1e-12 else { continue }
                    let unit = normal / normalLength
                    let offset = dot(unit, a)

                    // All remaining points must lie on one side (within the
                    // scale-aware linear tolerance).
                    var side = 0.0
                    var isFace = true
                    for (m, p) in points.enumerated() where m != i && m != j && m != k {
                        let d = dot(unit, p) - offset
                        guard abs(d) <= linearTolerance else {
                            if side == 0 {
                                side = d
                            } else if d * side < 0 {
                                isFace = false
                                break
                            }
                            continue
                        }
                    }
                    guard isFace else { continue }

                    let plane = HullPlane(normal: unit, offset: offset)
                    let groupIndex: Int
                    if let existing = planeToGroup[plane] {
                        groupIndex = existing
                    } else {
                        groupIndex = planeToGroup.count
                        planeToGroup[plane] = groupIndex
                        groupNormals[groupIndex] = unit
                    }
                    if planeGroups[groupIndex] == nil {
                        planeGroups[groupIndex] = Set()
                    }
                    planeGroups[groupIndex]!.insert(i)
                    planeGroups[groupIndex]!.insert(j)
                    planeGroups[groupIndex]!.insert(k)
                }
            }
        }
        guard !cancelled(isCancelled) else { return nil }

        // Build a HullFace per plane group.
        var result: [HullFace] = []
        result.reserveCapacity(planeGroups.count)
        for (groupIndex, vertexSet) in planeGroups {
            guard !cancelled(isCancelled) else { return nil }
            let vertexIndices = Array(vertexSet).sorted()
            guard vertexIndices.count >= 3 else { continue }
            let facePoints = vertexIndices.map { points[$0] }
            let rawNormal = groupNormals[groupIndex]!

            // Orient the normal outward (away from the polyhedron centroid).
            let faceCentroid = facePoints.reduce(SIMD3<Double>.zero) { $0 + $1 } / Double(facePoints.count)
            let outwardNormal = dot(rawNormal, faceCentroid - centroid) >= 0 ? rawNormal : -rawNormal

            // 2D convex hull of the face polygon, counterclockwise when viewed
            // from outside.
            let hullIndices = faceHull2D(facePoints, outwardNormal: outwardNormal)
            guard hullIndices.count >= 3 else { continue }

            result.append(HullFace(vertexIndices: vertexIndices,
                                   hullIndices: hullIndices,
                                   outwardNormal: outwardNormal))
        }
        return result
    }

    /// Signed volume of a closed triangulated surface from the origin: sum of
    /// dot(a, cross(b, c)) / 6 over every triangle. The caller takes abs().
    private static func hullVolumeFromFaces(_ faces: [HullFace], points: [SIMD3<Double>]) -> Float? {
        var signedVolume = 0.0
        for face in faces {
            let hull = face.hullIndices
            guard hull.count >= 3 else { continue }
            for m in 1..<(hull.count - 1) {
                let a = points[face.vertexIndices[hull[0]]]
                let b = points[face.vertexIndices[hull[m]]]
                let c = points[face.vertexIndices[hull[m + 1]]]
                signedVolume += dot(a, cross(b, c)) / 6.0
            }
        }
        let volume = abs(signedVolume)
        guard volume.isFinite, volume > 1e-12 else { return nil }
        let result = Float(volume)
        return result.isFinite ? result : nil
    }

    /// Deduplicated hull edges from triangulated faces. Each edge is the
    /// pair of original point indices, ordered (min, max) for dedup.
    private static func edges(of faces: [HullFace]) -> [(Int, Int)] {
        var edgeSet = Set<IntPair>()
        for face in faces {
            let hull = face.hullIndices
            guard hull.count >= 2 else { continue }
            for i in 0..<hull.count {
                let j = (i + 1) % hull.count
                let vi = face.vertexIndices[hull[i]]
                let vj = face.vertexIndices[hull[j]]
                let a = min(vi, vj), b = max(vi, vj)
                edgeSet.insert(IntPair(a: a, b: b))
            }
        }
        return edgeSet.map { ($0.a, $0.b) }
    }

    /// True when all points lie on a single plane (within the scale-aware
    /// linear tolerance). Uses the same contract as the face test in
    /// `computeHullFaces`: `linearTolerance = coplanarityTolerance * extent`.
    private static func areAllCoplanar(_ points: [SIMD3<Double>], linearTolerance: Double) -> Bool {
        let n = points.count
        guard n >= 4 else { return true }
        for i in 0..<n {
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    let normal = cross(points[j] - points[i], points[k] - points[i])
                    let normalLength = length(normal)
                    guard normalLength > 1e-12 else { continue }
                    let unit = normal / normalLength
                    let offset = dot(unit, points[i])
                    var allOnPlane = true
                    for p in points {
                        if abs(dot(unit, p) - offset) > linearTolerance {
                            allOnPlane = false
                            break
                        }
                    }
                    return allOnPlane
                }
            }
        }
        return true
    }

    // MARK: - 2D convex hull on a face plane

    /// 2D convex hull of coplanar 3D points projected onto their plane,
    /// returning indices into `points` in counterclockwise order when viewed
    /// from the direction of `outwardNormal`. Andrew's monotone chain.
    private static func faceHull2D(_ points: [SIMD3<Double>],
                                   outwardNormal: SIMD3<Double>) -> [Int] {
        let n = points.count
        guard n >= 3 else { return Array(0..<n) }

        // Right-handed (u, v, outwardNormal) basis for the plane.
        let arbitrary = abs(outwardNormal.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = normalize(cross(outwardNormal, arbitrary))
        let v = cross(outwardNormal, u)

        let projected = points.map { (dot($0, u), dot($0, v)) }
        let hull = convexHull2D(projected)

        // Ensure counterclockwise (positive signed area).
        var signedArea = 0.0
        for i in 0..<hull.count {
            let j = (i + 1) % hull.count
            signedArea += projected[hull[i]].0 * projected[hull[j]].1
                - projected[hull[j]].0 * projected[hull[i]].1
        }
        return signedArea > 0 ? hull : hull.reversed()
    }

    /// Andrew's monotone chain convex hull for 2D points. Returns indices into
    /// `points` in counterclockwise order.
    private static func convexHull2D(_ points: [(Double, Double)]) -> [Int] {
        let n = points.count
        guard n >= 3 else { return Array(0..<n) }

        let sorted = (0..<n).sorted { a, b in
            if points[a].0 != points[b].0 { return points[a].0 < points[b].0 }
            return points[a].1 < points[b].1
        }

        func cross2D(_ o: Int, _ a: Int, _ b: Int) -> Double {
            let oa0 = points[a].0 - points[o].0
            let oa1 = points[a].1 - points[o].1
            let ob0 = points[b].0 - points[o].0
            let ob1 = points[b].1 - points[o].1
            return oa0 * ob1 - oa1 * ob0
        }

        var lower: [Int] = []
        for idx in sorted {
            while lower.count >= 2
                    && cross2D(lower[lower.count - 2], lower[lower.count - 1], idx) <= 1e-10 {
                lower.removeLast()
            }
            lower.append(idx)
        }

        var upper: [Int] = []
        for idx in sorted.reversed() {
            while upper.count >= 2
                    && cross2D(upper[upper.count - 2], upper[upper.count - 1], idx) <= 1e-10 {
                upper.removeLast()
            }
            upper.append(idx)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    // MARK: - Helpers

    /// All C(n, 2) unordered pairs, used as the angle source for CN < 4 where
    /// no 3D hull edges exist.
    private static func allPairs(_ n: Int) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        result.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<n {
            for j in (i + 1)..<n {
                result.append((i, j))
            }
        }
        return result
    }

    private static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let len = length(v)
        guard len > 1e-12 else { return v }
        return v / len
    }

    private static func cancelled(_ isCancelled: (() -> Bool)?) -> Bool {
        isCancelled?() == true
    }
}
