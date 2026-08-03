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
            result.append(metrics(for: atoms[index].coord, shell: shell))
        }
        guard !cancelled(isCancelled) else { return nil }
        return result
    }

    /// The first coordination shell of `atomIndex` as absolute neighbor
    /// positions (source position + minimum-image displacement). Degenerate
    /// or non-finite entries are dropped.
    static func firstShell(of atomIndex: Int, analysis: CoordinationAnalysis,
                           atoms: [Atom]) -> [SIMD3<Float>] {
        guard atomIndex >= 0, atomIndex < atoms.count,
              atoms[atomIndex].coord.isFinite else { return [] }
        let neighbors = analysis.neighbors(of: atomIndex)
        guard !neighbors.isEmpty else { return [] }

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(neighbors.count)
        var group: [SIMD3<Float>] = []
        var previousDistance = neighbors[0].distance

        for neighbor in neighbors {
            if !group.isEmpty && abs(neighbor.distance - previousDistance) > shellTolerance {
                positions.append(contentsOf: group.prefix(maxNeighborsPerAtom))
                group.removeAll(keepingCapacity: true)
            }
            let position = atoms[atomIndex].coord + neighbor.displacement
            if position.isFinite, group.count < maxNeighborsPerAtom {
                group.append(position)
            }
            previousDistance = neighbor.distance
        }
        if !group.isEmpty {
            positions.append(contentsOf: group.prefix(maxNeighborsPerAtom))
        }
        return positions
    }

    static func metrics(for center: SIMD3<Float>, shell: [SIMD3<Float>]) -> PolyhedronMetrics {
        guard center.isFinite else {
            return PolyhedronMetrics(neighborCount: 0, volume: nil,
                                     bondLengthDistortion: nil, angleDeviation: nil,
                                     idealAngle: nil, volumeRatio: nil)
        }
        let count = shell.count
        guard count >= 2 else {
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

        // Angles at the central atom between every pair of neighbors.
        let angles: [Float]? = {
            guard count >= 3 else { return nil }
            var values: [Float] = []
            values.reserveCapacity(count * (count - 1) / 2)
            for i in 0..<count {
                for j in (i + 1)..<count {
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
            }
            return values
        }()

        let ideal = idealAngle(for: count)
        let angleDeviation: Float? = angles.flatMap { observed -> Float? in
            var sum = 0.0
            var kept = 0
            let meanAngle = observed.reduce(0.0) { $0 + Double($1) } / Double(observed.count)
            let reference: Double
            if let ideal {
                reference = Double(ideal)
            } else {
                reference = meanAngle
            }
            // Regular polyhedra with antipodal vertices (octahedron, cube,
            // icosahedron) also contain trans/skew angle classes (180° and the
            // cube's 109.47°) that are not part of the ideal-angle comparison.
            // They are separated by the midpoint between the ideal angle and
            // 180°: a regular octahedron's 12 cis angles (90°) are kept while
            // its 3 trans angles (180°) are excluded.
            let exclusionThreshold = ideal.map { 180.0 - Double($0) * 0.5 } ?? .infinity
            for angle in observed where Double(angle) < exclusionThreshold {
                sum += pow(Double(angle) - reference, 2)
                kept += 1
            }
            guard kept > 0 else { return nil }
            let value = Float(sqrt(sum / Double(kept)))
            return value.isFinite ? value : nil
        }

        // Convex hull volume of the vertex set (3D hull only).
        let volume = hullVolume(of: shell)
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

    /// Exact convex-hull volume of a small 3D point set via outward-oriented
    /// face enumeration. O(n⁴) with an early-out coplanarity check; callers
    /// bound n via `maxNeighborsPerAtom`. Returns nil for fewer than 4 points,
    /// non-finite input, or a degenerate (coplanar) set. Coplanar points on a
    /// face are tolerated, so slightly noisy shells still produce a volume.
    static func hullVolume(of points: [SIMD3<Float>]) -> Float? {
        guard points.count >= 4, points.allSatisfy({ $0.isFinite }) else { return nil }

        // Centroid is used only to orient faces outward.
        var centroid = SIMD3<Double>.zero
        for p in points { centroid += p.double }
        centroid /= Double(points.count)

        var signedVolume = 0.0
        let n = points.count
        let tolerance = coplanarityTolerance

        for i in 0..<n {
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    let a = points[i].double, b = points[j].double, c = points[k].double
                    let normal = cross(b - a, c - a)
                    let normalLength = length(normal)
                    guard normalLength > 1e-12 else { continue }   // degenerate triple
                    let unit = normal / normalLength

                    // All remaining points must lie on one side (within tolerance).
                    var side = 0.0
                    var isFace = true
                    for (m, p) in points.enumerated() where m != i && m != j && m != k {
                        let d = dot(unit, p.double - a)
                        let limit = Double(tolerance) * max(1.0, normalLength)
                        guard abs(d) <= limit else {
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

                    // Orient the face outward (away from the centroid) and
                    // accumulate the signed tetrahedron volume.
                    var face = (a, b, c)
                    if dot(unit, a - centroid) < 0 {
                        face = (a, c, b)
                    }
                    signedVolume += dot(face.0, cross(face.1, face.2)) / 6.0
                }
            }
        }

        let volume = abs(signedVolume)
        guard volume.isFinite, volume > 1e-12 else { return nil }
        let result = Float(volume)
        return result.isFinite ? result : nil
    }

    private static func cancelled(_ isCancelled: (() -> Bool)?) -> Bool {
        isCancelled?() == true
    }
}
