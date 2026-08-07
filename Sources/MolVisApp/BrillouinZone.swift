import simd

// Brillouin-zone polyhedron + special k-points.
//
// The BZ is the Wigner-Seitz cell of the reciprocal lattice, which is exactly
// what Geometry.polyhedronFaces already computes: intersect half-spaces bounded
// by the perpendicular bisectors of a G-vector star. Because the G-star must
// come from the PRIMITIVE reciprocal lattice, we reduce the conventional cell
// via the atoms' fractional offsets (Lattice) to recover centering (fcc/bcc).
//
// Reference: XCrySDen F/wigner.f (G-star in {-2..2}), C/xcBz.c (BzInitBZ:
// derives center/edge/line/face special points), C/bz.h (BZPointType).

/// A special k-point on/in the BZ, mirroring XCrySDen's bz.h bitflags.
enum BZPointType: Int {
    case center = 1     // origin = Gamma
    case edge = 2       // polyhedron vertex
    case line = 4       // edge midpoint
    case polyface = 8   // face (polygon) centroid
}

struct BZSpecialPoint {
    var coord: SIMD3<Float>     // Cartesian (reciprocal) coordinates
    var type: BZPointType
}

/// Counters for the bounded, synchronous BZ construction. This is internal so
/// budget tests can verify cumulative work without making the renderer depend
/// on diagnostic state.
struct BZConstructionDiagnostics {
    var candidateCount = 0
    var initialNeighborCount = 0
    var solverNeighborCounts: [Int] = []
    var cumulativeEstimatedOperations = 0
    var certificationPasses = 0
    var coefficientDomainExpansions = 0
    var coefficientBounds: SIMD3<Int> = .zero
    var candidateEnumerationWork = 0
    var geometryFailureCount = 0
    var certified = false
    var exteriorCertified = false
}

/// The Brillouin zone of a crystal: ordered face loops plus special points
/// (Gamma + edge/line/face) for k-path construction.
struct BrillouinZone {
    let faces: [[SIMD3<Float>]]         // face i = CCW-ordered vertex loop
    let normals: [SIMD3<Float>]         // per-face outward unit normals
    let specialPoints: [BZSpecialPoint]
    let reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)

    /// `Geometry.polyhedronFaces` performs one feasibility scan for every plane
    /// triple. This bound models its worst case as C(n, 3) * n and keeps a BZ
    /// construction comfortably below the synchronous main-thread budget.
    static let polyhedronFeasibilityOperationBudget = 500_000

    /// Total synchronous work allowed when a small prefix needs refinement.
    /// This permits a few bounded solves without allowing a large one-shot
    /// solve to move onto the UI thread.
    static let totalPolyhedronFeasibilityOperationBudget = 1_500_000

    /// A coefficient box is only a proof aid. It must not turn malformed input
    /// into an unbounded integer enumeration or a large synchronous scan.
    static let coefficientCandidateBudget = 4_096
    static let coefficientEnumerationWorkBudget = 250_000
    static let coefficientDomainExpansionBudget = 16

    /// Estimated feasibility checks performed by `Geometry.polyhedronFaces` for
    /// `neighborCount` usable planes. Nil means the estimate does not fit in an
    /// Int. This is intentionally internal so tests can assert the construction
    /// budget without invoking the geometry solver.
    static func estimatedPolyhedronFeasibilityOperations(forNeighborCount neighborCount: Int) -> Int? {
        guard neighborCount >= 0 else { return nil }
        let n = Int64(neighborCount)
        guard n >= 3 else { return 0 }
        let first = n.multipliedReportingOverflow(by: n - 1)
        guard !first.overflow else { return nil }
        let second = first.partialValue.multipliedReportingOverflow(by: n - 2)
        guard !second.overflow else { return nil }
        let triples = second.partialValue / 6
        let operations = triples.multipliedReportingOverflow(by: n)
        guard !operations.overflow,
              operations.partialValue <= Int64(Int.max) else { return nil }
        return Int(operations.partialValue)
    }

    /// Sum the estimated work for a sequence of bounded solver attempts.
    static func estimatedCumulativePolyhedronFeasibilityOperations(forNeighborCounts neighborCounts: [Int]) -> Int? {
        var total = 0
        for neighborCount in neighborCounts {
            guard let operations = estimatedPolyhedronFeasibilityOperations(forNeighborCount: neighborCount) else {
                return nil
            }
            let sum = total.addingReportingOverflow(operations)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    /// Build the BZ from the conventional cell + its base atoms. Centering is
    /// detected from the atoms' fractional offsets (P/I/F) and reduced to the
    /// true primitive direct basis, whose reciprocal generates the G-star. The
    /// finite star is adaptively expanded until both its current planes and all
    /// lattice vectors outside its coefficient box are certified. Correct for
    /// any lattice when the bounded proof completes: fcc -> 14, slab -> 6, etc.
    static func build(cell: Cell, atoms: [Atom]) -> BrillouinZone? {
        var diagnostics = BZConstructionDiagnostics()
        return build(cell: cell, atoms: atoms, diagnostics: &diagnostics)
    }

    /// Diagnostic overload used by budget and regression tests.
    static func build(cell: Cell, atoms: [Atom], diagnostics: inout BZConstructionDiagnostics) -> BrillouinZone? {
        diagnostics = BZConstructionDiagnostics()
        // Centering detection verifies candidate translations against the basis.
        // Bound that work for directly-constructed/pathological scenes; real unit
        // cells are far smaller, and omitting an optional overlay is safer than an
        // O(n²) UI stall on a massive atom list.
        guard atoms.count <= 4_096 else { return nil }
        // True reciprocal generator (primitive = respects centering), the dense
        // lattice whose Wigner-Seitz cell is the first BZ.
        // An empty basis carries no centering evidence; `detectCentering` would
        // otherwise treat every candidate translation as valid by vacuous truth.
        let (astar, bstar, cstar): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        if atoms.isEmpty {
            let reciprocal = cell.reciprocalVectors
            (astar, bstar, cstar) = (reciprocal.a, reciprocal.b, reciprocal.c)
        } else {
            let primitive = Lattice.primitiveReciprocal(cell: cell, atoms: atoms)
            (astar, bstar, cstar) = (primitive.a, primitive.b, primitive.c)
        }
        let vectors = [astar, bstar, cstar]
        guard vectors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return nil
        }

        // Work in a dimensionless reciprocal space. Physical reciprocal vectors
        // can be close to Float.greatestFiniteMagnitude, where even an integer
        // multiple overflows before it reaches the geometry solver.
        let reciprocalScale = vectors.reduce(0.0) { partial, vector in
            max(partial, abs(Double(vector.x)), abs(Double(vector.y)), abs(Double(vector.z)))
        }
        guard reciprocalScale.isFinite, reciprocalScale > 0 else { return nil }
        let normalizedVectors = vectors.map {
            SIMD3<Double>(Double($0.x) / reciprocalScale,
                          Double($0.y) / reciprocalScale,
                          Double($0.z) / reciprocalScale)
        }
        guard normalizedVectors.allSatisfy({ vector in
            vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
        }) else { return nil }

        func doubleLength(_ vector: SIMD3<Double>) -> Double {
            let componentScale = max(abs(vector.x), abs(vector.y), abs(vector.z))
            guard componentScale.isFinite, componentScale > 0 else { return 0 }
            let x = vector.x / componentScale
            let y = vector.y / componentScale
            let z = vector.z / componentScale
            return componentScale * sqrt(x * x + y * y + z * z)
        }

        // Start with the old ratio box, but do not treat it as a proof. A shortest
        // vector can be a cancellation of several primitive vectors and have a
        // coefficient outside this box for a skew basis. The box is expanded and
        // certified below.
        let nrm = normalizedVectors.map(doubleLength)
        guard nrm.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let longest = nrm.max() ?? 0
        let ratioValues = nrm.map { ceil(longest / $0) }
        // Keep candidate generation bounded as well as solver work. A malicious,
        // extremely anisotropic cell must disable only the optional BZ overlay.
        guard ratioValues.allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 16 }) else { return nil }
        struct GVector {
            let vector: SIMD3<Float>
            let length: Double
            let index: SIMD3<Int>
        }
        // Use one basis-relative scale for every domain. Re-scaling to the
        // current box would make Geometry's absolute tolerances depend on how
        // many proof shells happened to be needed.
        let geometryScale = longest
        guard geometryScale.isFinite, geometryScale > 0 else { return nil }

        func candidateCount(for radii: SIMD3<Int>) -> Int? {
            guard radii.x >= 1, radii.y >= 1, radii.z >= 1 else { return nil }
            let x = radii.x.multipliedReportingOverflow(by: 2)
            let y = radii.y.multipliedReportingOverflow(by: 2)
            let z = radii.z.multipliedReportingOverflow(by: 2)
            guard !x.overflow, !y.overflow, !z.overflow else { return nil }
            let cx = x.partialValue.addingReportingOverflow(1)
            let cy = y.partialValue.addingReportingOverflow(1)
            let cz = z.partialValue.addingReportingOverflow(1)
            guard !cx.overflow, !cy.overflow, !cz.overflow else { return nil }
            let xy = cx.partialValue.multipliedReportingOverflow(by: cy.partialValue)
            guard !xy.overflow else { return nil }
            let xyz = xy.partialValue.multipliedReportingOverflow(by: cz.partialValue)
            guard !xyz.overflow, xyz.partialValue > 1 else { return nil }
            let count = xyz.partialValue - 1
            return count <= coefficientCandidateBudget ? count : nil
        }

        func rawGStar(for radii: SIMD3<Int>) -> [(vector: SIMD3<Double>, index: SIMD3<Int>)]? {
            guard let count = candidateCount(for: radii) else { return nil }
            var result: [(vector: SIMD3<Double>, index: SIMD3<Int>)] = []
            result.reserveCapacity(count)
            for i in -radii.x...radii.x {
                for j in -radii.y...radii.y {
                    for k in -radii.z...radii.z {
                        if i == 0 && j == 0 && k == 0 { continue }
                        let g = Double(i) * normalizedVectors[0]
                            + Double(j) * normalizedVectors[1]
                            + Double(k) * normalizedVectors[2]
                        guard g.x.isFinite, g.y.isFinite, g.z.isFinite else { return nil }
                        result.append((g, SIMD3<Int>(i, j, k)))
                    }
                }
            }
            return result
        }

        func sortedGStar(_ raw: [(vector: SIMD3<Double>, index: SIMD3<Int>)]) -> [GVector]? {
            var result: [GVector] = []
            result.reserveCapacity(raw.count)
            for entry in raw {
                let rawLength = doubleLength(entry.vector)
                guard rawLength.isFinite, rawLength > 0 else { return nil }
                let normalizedDouble = entry.vector / geometryScale
                guard normalizedDouble.x.isFinite, normalizedDouble.y.isFinite,
                      normalizedDouble.z.isFinite else { return nil }
                let normalizedLength = rawLength / geometryScale
                // Geometry ignores neighbors shorter than 1e-6. Such a vector
                // could be a genuine first-zone plane, so certifying without it
                // would be unsound; fail the optional overlay instead.
                guard normalizedLength.isFinite, normalizedLength >= 1e-6 else { return nil }
                let normalized = SIMD3<Float>(Float(normalizedDouble.x),
                                              Float(normalizedDouble.y),
                                              Float(normalizedDouble.z))
                guard normalized.x.isFinite, normalized.y.isFinite, normalized.z.isFinite else {
                    return nil
                }
                result.append(GVector(vector: normalized,
                                      length: normalizedLength,
                                      index: entry.index))
            }
            return result.sorted {
                if $0.length != $1.length { return $0.length < $1.length }
                if $0.index.x != $1.index.x { return $0.index.x < $1.index.x }
                if $0.index.y != $1.index.y { return $0.index.y < $1.index.y }
                return $0.index.z < $1.index.z
            }
        }

        // For n outside a rectangular box, some |n_i| >= r_i+1. Since
        // n_i = row_i(B^-1) . (B n), |B n| >= (r_i+1)/|row_i(B^-1)|.
        // This per-row form is the rectangular-domain version of the usual
        // inverse-operator bound and is stronger than one global singular-value
        // estimate for anisotropic boxes.
        let inverseRows = [cross(normalizedVectors[1], normalizedVectors[2]),
                           cross(normalizedVectors[2], normalizedVectors[0]),
                           cross(normalizedVectors[0], normalizedVectors[1])]
        let determinant = dot(normalizedVectors[0], inverseRows[0])
        guard determinant.isFinite, abs(determinant) > 1024 * Double.ulpOfOne else { return nil }
        let inverseRowNorms = inverseRows.map { doubleLength($0) / abs(determinant) }
        guard inverseRowNorms.count == 3,
              inverseRowNorms.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }

        var radii = SIMD3<Int>(Int(ratioValues[0]), Int(ratioValues[1]), Int(ratioValues[2]))
        var finalSelected: [GVector] = []
        var finalTris: [SIMD3<Float>] = []
        var certified = false
        var domainAttempts = 0
        var candidateWork = 0

        domainLoop: while !certified {
            domainAttempts += 1
            guard domainAttempts <= coefficientDomainExpansionBudget,
                  let count = candidateCount(for: radii),
                  let raw = rawGStar(for: radii),
                  let sorted = sortedGStar(raw) else { return nil }
            let workAfterEnumeration = candidateWork.addingReportingOverflow(count)
            guard !workAfterEnumeration.overflow,
                  workAfterEnumeration.partialValue <= coefficientEnumerationWorkBudget else {
                return nil
            }
            candidateWork = workAfterEnumeration.partialValue
            diagnostics.candidateEnumerationWork = candidateWork
            diagnostics.candidateCount = count
            diagnostics.coefficientBounds = radii

            // Every domain starts from a deterministic six-plane prefix. Prefer
            // the shortest independent direction pairs over the primitive axes:
            // a highly skew primitive basis can make the axis-only six-plane
            // solve numerically unbounded even though the lattice is valid.
            // Refinement then adds the shortest violating shell and its opposite
            // as a unit, so no intermediate asymmetric solve occurs.
            func isPositiveIndex(_ index: SIMD3<Int>) -> Bool {
                index.x > 0 || (index.x == 0 && (index.y > 0 || (index.y == 0 && index.z > 0)))
            }
            let directions = sorted.filter { isPositiveIndex($0.index) }
            var initialDirections: [GVector] = []
            directionSearch: for i in 0..<directions.count {
                for j in (i + 1)..<directions.count {
                    for k in (j + 1)..<directions.count {
                        let determinant = dot(directions[i].vector,
                                              cross(directions[j].vector, directions[k].vector))
                        guard determinant.isFinite, abs(determinant) > 1e-4 else { continue }
                        initialDirections = [directions[i], directions[j], directions[k]]
                        break directionSearch
                    }
                }
            }
            guard initialDirections.count == 3 else { return nil }
            var selected = initialDirections
            for direction in initialDirections {
                guard let opposite = sorted.first(where: {
                    $0.index.x == -direction.index.x &&
                    $0.index.y == -direction.index.y &&
                    $0.index.z == -direction.index.z
                }) else { return nil }
                selected.append(opposite)
            }
            selected.sort {
                if $0.length != $1.length { return $0.length < $1.length }
                if $0.index.x != $1.index.x { return $0.index.x < $1.index.x }
                if $0.index.y != $1.index.y { return $0.index.y < $1.index.y }
                return $0.index.z < $1.index.z
            }
            guard selected.count >= 6 else { return nil }
            if diagnostics.initialNeighborCount == 0 {
                diagnostics.initialNeighborCount = selected.count
            }

            var tris: [SIMD3<Float>] = []
            var domainNeedsExpansion = false
            while true {
                guard let estimated = estimatedPolyhedronFeasibilityOperations(forNeighborCount: selected.count),
                      estimated <= polyhedronFeasibilityOperationBudget else {
                    return nil
                }
                let cumulative = diagnostics.cumulativeEstimatedOperations.addingReportingOverflow(estimated)
                guard !cumulative.overflow,
                      cumulative.partialValue <= totalPolyhedronFeasibilityOperationBudget else {
                    return nil
                }

                let selectedVectors = selected.map(\.vector)
                diagnostics.solverNeighborCounts.append(selected.count)
                diagnostics.cumulativeEstimatedOperations = cumulative.partialValue
                guard let currentTris = Geometry.polyhedronFaces(center: .zero,
                                                                  neighbors: selectedVectors,
                                                                  maxNeighbors: selectedVectors.count) else {
                    diagnostics.geometryFailureCount += 1
                    return nil
                }
                tris = currentTris
                diagnostics.certificationPasses += 1

                let selectedIndices = selected.map(\.index)
                let scanWork = candidateWork.addingReportingOverflow(sorted.count)
                guard !scanWork.overflow,
                      scanWork.partialValue <= coefficientEnumerationWorkBudget else {
                    return nil
                }
                candidateWork = scanWork.partialValue
                diagnostics.candidateEnumerationWork = candidateWork
                var violations: [GVector] = []
                for candidate in sorted where !selectedIndices.contains(candidate.index) {
                    let gLength = candidate.length
                    let normal = candidate.vector / Float(gLength)
                    let offset = Float(gLength * 0.5)
                    let validationTolerance = max(3e-5, Double(gLength) * 2e-4)
                    if tris.contains(where: { Double(dot($0, normal)) > Double(offset) + validationTolerance }) {
                        violations.append(candidate)
                    }
                }
                if let shortest = violations.first {
                    // Reciprocal symmetry makes adding a whole equal-length shell
                    // deterministic and prevents a one-sided intermediate cell.
                    let shellTolerance = max(shortest.length * 1e-7, 1e-12)
                    var additions: [GVector] = []
                    func appendAddition(_ candidate: GVector) {
                        guard !selectedIndices.contains(candidate.index),
                              !additions.contains(where: { $0.index == candidate.index }) else { return }
                        additions.append(candidate)
                    }
                    for candidate in violations where abs(candidate.length - shortest.length) <= shellTolerance {
                        appendAddition(candidate)
                        if let opposite = sorted.first(where: {
                            $0.index.x == -candidate.index.x &&
                            $0.index.y == -candidate.index.y &&
                            $0.index.z == -candidate.index.z
                        }) {
                            appendAddition(opposite)
                        }
                    }
                    guard !additions.isEmpty else { return nil }
                    selected.append(contentsOf: additions)
                    selected.sort {
                        if $0.length != $1.length { return $0.length < $1.length }
                        if $0.index.x != $1.index.x { return $0.index.x < $1.index.x }
                        if $0.index.y != $1.index.y { return $0.index.y < $1.index.y }
                        return $0.index.z < $1.index.z
                    }
                    continue
                }

                var extent: Double = 0
                for vertex in tris {
                    guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { return nil }
                    extent = max(extent, scaleSafeLength(vertex))
                }
                guard extent.isFinite, extent > 0 else { return nil }

                let outsideLowerBound = zip(inverseRowNorms, [radii.x, radii.y, radii.z])
                    .map { (threshold, radius) in Double(radius + 1) / threshold }
                    .min()!
                    / geometryScale
                guard outsideLowerBound.isFinite, outsideLowerBound > 0 else { return nil }
                // The strict margin absorbs Geometry's Float plane/vertex
                // tolerances. Without this test the finite box is not a proof:
                // an omitted vector outside it could still cut a returned vertex.
                let proofMargin = max(1e-5, extent * 2e-4)
                if outsideLowerBound * 0.5 > extent + proofMargin {
                    finalSelected = selected
                    finalTris = tris
                    diagnostics.exteriorCertified = true
                    diagnostics.certified = true
                    certified = true
                    break
                }
                domainNeedsExpansion = true
                break
            }

            if domainNeedsExpansion {
                guard domainAttempts < coefficientDomainExpansionBudget else { return nil }
                let next = SIMD3<Int>(radii.x.addingReportingOverflow(1).partialValue,
                                      radii.y.addingReportingOverflow(1).partialValue,
                                      radii.z.addingReportingOverflow(1).partialValue)
                guard !radii.x.addingReportingOverflow(1).overflow,
                      !radii.y.addingReportingOverflow(1).overflow,
                      !radii.z.addingReportingOverflow(1).overflow,
                      candidateCount(for: next) != nil else { return nil }
                radii = next
                diagnostics.coefficientDomainExpansions += 1
                continue domainLoop
            }
        }
        guard certified, !finalSelected.isEmpty, !finalTris.isEmpty else { return nil }
        let selected = finalSelected
        let tris = finalTris

        // Bisector planes in normalized coordinates (outward normal n, offset
        // cc = |G|/2) for the certified selected star.
        var planes: [(n: SIMD3<Float>, cc: Float)] = []
        planes.reserveCapacity(selected.count)
        for g in selected.map(\.vector) {
            let gLength = scaleSafeLength(g)
            guard gLength.isFinite, gLength >= 1e-6 else { return nil }
            let normal = g / Float(gLength)
            let offset = Float(gLength * 0.5)
            guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite,
                  offset.isFinite else { return nil }
            planes.append((n: normal, cc: offset))
        }

        var normalizedExtent: Double = 0
        for v in tris {
            guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
            normalizedExtent = max(normalizedExtent, scaleSafeLength(v))
        }
        guard normalizedExtent.isFinite, normalizedExtent > 0 else { return nil }

        // De-duplicate and group in normalized coordinates. The floor is tied to
        // normalized Float precision, not to physical reciprocal units.
        let epsDouble = max(normalizedExtent * 1e-3, Double(Float.ulpOfOne) * 32)
        guard epsDouble.isFinite, epsDouble > 0, epsDouble <= Double(Float.greatestFiniteMagnitude) else {
            return nil
        }
        let eps = Float(epsDouble)
        var uniq: [SIMD3<Float>] = []
        for v in tris {
            if !uniq.contains(where: { scaleSafeDistance($0, v) < epsDouble }) { uniq.append(v) }
        }
        // Group vertices into faces: a vertex belongs to a face plane iff it lies
        // ON that plane (within tolerance). Empty buckets are clipped-away
        /// bisectors of farther G-vectors, not real faces.
        var normalizedFaces: [[SIMD3<Float>]] = []
        var normals: [SIMD3<Float>] = []
        for pl in planes {
            let face = uniq.filter { abs(dot($0, pl.n) - pl.cc) < 3 * eps }
            guard face.count >= 3 else { continue }
            let nrm = pl.n
            let cen = face.reduce(SIMD3<Float>.zero, +) / Float(face.count)
            let tangent = abs(nrm.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let uf = normalize(cross(tangent, nrm))
            let vf = cross(nrm, uf)
            let sorted = face.sorted {
                atan2(dot($0 - cen, vf), dot($0 - cen, uf))
                    < atan2(dot($1 - cen, vf), dot($1 - cen, uf))
            }
            normalizedFaces.append(sorted)
            normals.append(nrm)
        }

        // Convert only after all tolerance-sensitive work is complete. Reject a
        // result if multiplication overflows or turns a representable normalized
        // component into zero through underflow.
        func physical(_ normalized: SIMD3<Float>) -> SIMD3<Float>? {
            return physical(SIMD3<Double>(Double(normalized.x),
                                          Double(normalized.y),
                                          Double(normalized.z)))
        }
        func physical(_ normalized: SIMD3<Double>) -> SIMD3<Float>? {
            let value = SIMD3<Double>(normalized.x * geometryScale * reciprocalScale,
                                      normalized.y * geometryScale * reciprocalScale,
                                      normalized.z * geometryScale * reciprocalScale)
            return physicalValue(value, original: normalized)
        }
        func physicalValue(_ value: SIMD3<Double>, original: SIMD3<Double>) -> SIMD3<Float>? {
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
                return nil
            }
            let result = SIMD3<Float>(Float(value.x), Float(value.y), Float(value.z))
            guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { return nil }
            // Plane intersections can leave a tiny normalized residual for an
            // exact zero coordinate. Do not turn that solver noise into a false
            // unrepresentability failure when the physical scale is subnormal.
            let zeroTolerance = 1e-6
            guard (original.x == 0 || result.x != 0 || abs(original.x) < zeroTolerance),
                  (original.y == 0 || result.y != 0 || abs(original.y) < zeroTolerance),
                  (original.z == 0 || result.z != 0 || abs(original.z) < zeroTolerance) else { return nil }
            return result
        }
        var faces: [[SIMD3<Float>]] = []
        faces.reserveCapacity(normalizedFaces.count)
        for normalizedFace in normalizedFaces {
            var face: [SIMD3<Float>] = []
            face.reserveCapacity(normalizedFace.count)
            for vertex in normalizedFace {
                guard let value = physical(vertex) else { return nil }
                face.append(value)
            }
            faces.append(face)
        }

        // Special points: Gamma (origin) + per-face vertex/edge-midpoint/centroid.
        var specials: [BZSpecialPoint] = [BZSpecialPoint(coord: .zero, type: .center)]
        for normalizedFace in normalizedFaces {
            var cen = SIMD3<Double>.zero
            for vertex in normalizedFace {
                cen += SIMD3<Double>(Double(vertex.x), Double(vertex.y), Double(vertex.z))
            }
            cen /= Double(normalizedFace.count)
            guard let physicalCenter = physical(cen) else { return nil }
            specials.append(BZSpecialPoint(coord: physicalCenter, type: .polyface))
            for vi in 0..<normalizedFace.count {
                guard let vertex = physical(normalizedFace[vi]) else { return nil }
                specials.append(BZSpecialPoint(coord: vertex, type: .edge))
                let vnext = normalizedFace[(vi + 1) % normalizedFace.count]
                let midpoint = (SIMD3<Double>(Double(normalizedFace[vi].x),
                                               Double(normalizedFace[vi].y),
                                               Double(normalizedFace[vi].z))
                    + SIMD3<Double>(Double(vnext.x), Double(vnext.y), Double(vnext.z))) * 0.5
                guard let physicalMidpoint = physical(midpoint) else {
                    return nil
                }
                specials.append(BZSpecialPoint(coord: physicalMidpoint, type: .line))
            }
        }
        // Report the CONVENTIONAL reciprocal (band-plot basis) alongside the
        // primitive-built geometry.
        let conv = cell.reciprocalVectors
        let conventional = [conv.a, conv.b, conv.c]
        guard conventional.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              conventional.allSatisfy({ scaleSafeLength($0) > 0 }) else { return nil }
        return BrillouinZone(faces: faces, normals: normals,
                             specialPoints: specials,
                             reciprocal: (conv.a, conv.b, conv.c))
    }
}

/// A single deterministic BZ landmark for the k-path editor: the fractional
/// coordinate (conventional reciprocal basis, in `point.frac`), the BZ-space
/// Cartesian coordinate it came from, and which kind of landmark it is.
struct BZCandidate {
    var point: KPoint
    var cartesian: SIMD3<Float>
    var type: BZPointType
}

extension BrillouinZone {
    /// Fractional (in the given reciprocal basis) -> Cartesian reciprocal position.
    static func cartesianFromFractional(_ frac: SIMD3<Float>,
                                        reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>))
        -> SIMD3<Float> {
        let values = [frac.x, frac.y, frac.z,
                      reciprocal.a.x, reciprocal.a.y, reciprocal.a.z,
                      reciprocal.b.x, reciprocal.b.y, reciprocal.b.z,
                      reciprocal.c.x, reciprocal.c.y, reciprocal.c.z]
        guard values.allSatisfy({ $0.isFinite }) else { return SIMD3(repeating: .nan) }
        // Keep products and cancellation in Double. This is still a nonoptional
        // API, so invalid/unrepresentable results remain visibly invalid for
        // route validation rather than becoming a false Gamma point.
        let cartesian = SIMD3<Double>(
            Double(reciprocal.a.x) * Double(frac.x)
                + Double(reciprocal.b.x) * Double(frac.y)
                + Double(reciprocal.c.x) * Double(frac.z),
            Double(reciprocal.a.y) * Double(frac.x)
                + Double(reciprocal.b.y) * Double(frac.y)
                + Double(reciprocal.c.y) * Double(frac.z),
            Double(reciprocal.a.z) * Double(frac.x)
                + Double(reciprocal.b.z) * Double(frac.y)
                + Double(reciprocal.c.z) * Double(frac.z))
        guard cartesian.x.isFinite, cartesian.y.isFinite, cartesian.z.isFinite else {
            return SIMD3(repeating: .nan)
        }
        let result = SIMD3<Float>(Float(cartesian.x), Float(cartesian.y), Float(cartesian.z))
        return result.isFinite ? result : SIMD3(repeating: .nan)
    }

    /// Cartesian -> fractional in the given reciprocal basis. Returns nil if the
    /// basis is singular or the result is non-finite.
    static func fractionalFromCartesian(_ cart: SIMD3<Float>,
                                        reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>))
        -> SIMD3<Float>? {
        let values = [cart.x, cart.y, cart.z,
                      reciprocal.a.x, reciprocal.a.y, reciprocal.a.z,
                      reciprocal.b.x, reciprocal.b.y, reciprocal.b.z,
                      reciprocal.c.x, reciprocal.c.y, reciprocal.c.z]
        guard values.allSatisfy({ $0.isFinite }) else { return nil }

        // Normalize the basis and the Cartesian point by the same physical
        // scale. The solve then never forms a Float inverse of a huge or tiny
        // reciprocal matrix.
        let scale = [reciprocal.a, reciprocal.b, reciprocal.c].reduce(0.0) { partial, vector in
            max(partial, abs(Double(vector.x)), abs(Double(vector.y)), abs(Double(vector.z)))
        }
        guard scale.isFinite, scale > 0 else { return nil }
        let a = SIMD3<Double>(Double(reciprocal.a.x) / scale,
                              Double(reciprocal.a.y) / scale,
                              Double(reciprocal.a.z) / scale)
        let b = SIMD3<Double>(Double(reciprocal.b.x) / scale,
                              Double(reciprocal.b.y) / scale,
                              Double(reciprocal.b.z) / scale)
        let c = SIMD3<Double>(Double(reciprocal.c.x) / scale,
                              Double(reciprocal.c.y) / scale,
                              Double(reciprocal.c.z) / scale)
        let cartesian = SIMD3<Double>(Double(cart.x) / scale,
                                      Double(cart.y) / scale,
                                      Double(cart.z) / scale)
        let crossBC = cross(b, c)
        let crossCA = cross(c, a)
        let crossAB = cross(a, b)
        let determinant = dot(a, crossBC)
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let fractional = SIMD3<Double>(dot(cartesian, crossBC) / determinant,
                                       dot(cartesian, crossCA) / determinant,
                                       dot(cartesian, crossAB) / determinant)
        guard fractional.x.isFinite, fractional.y.isFinite, fractional.z.isFinite else {
            return nil
        }
        let result = SIMD3<Float>(Float(fractional.x), Float(fractional.y), Float(fractional.z))
        guard result.isFinite else { return nil }
        return result
    }

    /// Scale-relative invertibility test on a basis matrix. The dimensionless
    /// ratio `|det(M)| / (|c0||c1||c2|)` is the signed volume of the
    /// parallelepiped scaled to its enclosing rectangular box (bounded by 1); an
    /// absolute `|det|` floor would wrongly reject valid tiny reciprocal zones
    /// (huge real cells) and wrongly accept near-degenerate large ones. Require the
    /// ratio to be well above machine epsilon, with all lengths finite and >0.
    static func isFiniteInvertible(_ m: simd_float3x3, tol: Float = 1e-6) -> Bool {
        guard tol.isFinite, tol >= 0 else { return false }
        let lengths = [m.columns.0, m.columns.1, m.columns.2].map(scaleSafeLength)
        guard lengths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return false }
        // Normalize each column in Double before taking the determinant. The
        // resulting determinant is dimensionless, so neither large reciprocal
        // components nor tiny ones can overflow or underflow the test.
        let columns = [m.columns.0, m.columns.1, m.columns.2].enumerated().map { index, column in
            SIMD3<Double>(Double(column.x) / lengths[index],
                          Double(column.y) / lengths[index],
                          Double(column.z) / lengths[index])
        }
        let determinant = dot(columns[0], cross(columns[1], columns[2]))
        return determinant.isFinite && abs(determinant) > Double(tol)
    }

    /// Deterministic BZ landmark candidates for the k-path editor: Gamma plus the
    /// unique vertices, edge midpoints, and face centers, de-duplicated within a
    /// scale-relative tolerance and labeled stably. Non-finite or singular
    /// Cartesian→fractional conversions are dropped rather than trapped.
    func candidates() -> [BZCandidate] {
        let basis = (a: reciprocal.a, b: reciprocal.b, c: reciprocal.c)
        func toFractional(_ p: SIMD3<Float>) -> SIMD3<Float>? {
            Self.fractionalFromCartesian(p, reciprocal: basis)
        }
        // Scale-relative de-dup tolerance: compare dimensionless coordinates after
        // dividing by the physical BZ extent. There is no fixed physical floor.
        var extent: Double = 0
        for face in faces { for v in face { extent = max(extent, scaleSafeLength(v)) } }
        let tol: Float = 5e-3
        func dedup(_ pts: [BZSpecialPoint]) -> [BZSpecialPoint] {
            var out: [BZSpecialPoint] = []
            for p in pts where !out.contains(where: { existing in
                guard extent.isFinite, extent > 0 else { return existing.coord == p.coord }
                return scaleSafeDistance(existing.coord, p.coord, scale: extent) < Double(tol)
            }) {
                out.append(p)
            }
            return out
        }
        // Deterministic finite-Float lexicographic order — no Float-to-Int cast, so
        // arbitrarily large fractional values cannot trap.
        // Dimensionless buckets prevent uniform physical rescaling from reordering
        // mathematically tied landmarks because of a few reciprocal-basis ulps.
        func sortBucket(_ value: Float) -> Float {
            guard value.isFinite else { return value }
            let scaled = value / 1e-4
            return scaled.isFinite ? scaled.rounded() : value
        }
        func sorted(_ pts: [(SIMD3<Float>, SIMD3<Float>)]) -> [(SIMD3<Float>, SIMD3<Float>)] {
            pts.sorted { a, b in
                let ax = sortBucket(a.1.x), bx = sortBucket(b.1.x)
                if ax != bx { return ax < bx }
                let ay = sortBucket(a.1.y), by = sortBucket(b.1.y)
                if ay != by { return ay < by }
                let az = sortBucket(a.1.z), bz = sortBucket(b.1.z)
                if az != bz { return az < bz }
                return a.1.x == b.1.x ? (a.1.y == b.1.y ? a.1.z < b.1.z : a.1.y < b.1.y) : a.1.x < b.1.x
            }
        }
        var result: [BZCandidate] = []
        // Gamma (center) first.
        for sp in specialPoints where sp.type == .center {
            if let f = toFractional(sp.coord) {
                result.append(BZCandidate(point: KPoint(f, "\u{0393}"), cartesian: sp.coord, type: .center))
            }
        }
        // Vertices, edge midpoints, face centers: de-dup, sort, then label 1..n.
        func addGroup(_ type: BZPointType, _ prefix: String) {
            let fracs = dedup(specialPoints.filter { $0.type == type })
                .map { ($0.coord, toFractional($0.coord)) }
                .compactMap { cart, f in f.map { (cart, $0) } }
            for (i, (cart, f)) in sorted(fracs).enumerated() {
                result.append(BZCandidate(point: KPoint(f, "\(prefix)\(i+1)"), cartesian: cart, type: type))
            }
        }
        addGroup(.edge, "V")
        addGroup(.line, "E")
        addGroup(.polyface, "F")
        return result
    }
}

/// The shared BZ↔world mapping used by both picking (phase 2) and rendering
/// (later). Built once from an already-constructed BrillouinZone plus the
/// Scene, and reproduces the renderer's `drawBrillouinZone` mapping exactly.
struct BZPresentation {
    static let landmarkPickMinimumRadius: Float = 4
    static let landmarkScreenRadiusCap: Float = 512

    /// Scene centroid (the renderer's `sceneCentroid()`).
    let center: SIMD3<Float>
    /// World-units-per-BZ-unit scale = targetExtent / bzExtent.
    let inv: Float
    /// World-space half extent used when the BZ is displayed.
    let displayedHalfExtent: Float
    /// Conventional reciprocal vectors (Cartesian) for fractional -> Cartesian.
    let reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)

    /// Half-length of the editable landmark cross arms. Rendering, picking, and
    /// accessibility all derive their geometry from this value.
    var landmarkHalfExtent: Float {
        guard displayedHalfExtent.isFinite, displayedHalfExtent > 0 else { return 0 }
        return max(0.06, displayedHalfExtent * 0.10)
    }

    /// Fixed display half-extent for the BZ overlay, independent of the
    /// real-space structure size. The BZ lives in k-space; tying its on-screen
    /// size to the real-space bounding sphere makes it tiny for small cells
    /// and huge for large ones. A fixed extent keeps it a consistent, decently
    /// large cage centered on the structure for visualization and picking.
    static let fixedDisplayHalfExtent: Double = 2.0

    init(bz: BrillouinZone, scene: Scene) {
        var extent: Double = 0
        for face in bz.faces { for v in face { extent = max(extent, scaleSafeLength(v)) } }
        let targetExtent = BZPresentation.fixedDisplayHalfExtent
        self.center = scene.centroid
        let scale = extent.isFinite && extent > 0 ? Double(targetExtent) / extent : 0
        let floatScale = Float(scale)
        self.inv = scale.isFinite && floatScale.isFinite ? floatScale : 0
        self.displayedHalfExtent = targetExtent.isFinite && targetExtent > 0 ? Float(targetExtent) : 0
        self.reciprocal = bz.reciprocal
    }

    /// Map a BZ-space Cartesian coordinate to its rendered world position.
    func world(cartesian: SIMD3<Float>) -> SIMD3<Float> {
        center + cartesian * inv
    }

    /// Map a fractional k-point (conventional reciprocal basis) to its rendered
    /// world position, converting to Cartesian first.
    func world(frac: SIMD3<Float>) -> SIMD3<Float> {
        let cart = BrillouinZone.cartesianFromFractional(frac, reciprocal: reciprocal)
        return center + cart * inv
    }

    /// Return a camera that frames every BZ face vertex in this presentation.
    /// `padding` is the maximum absolute x/y NDC coordinate to use, so values
    /// below one leave a border around the fitted zone. The current rotation and
    /// projection mode are retained; only the center and orbit distance change.
    /// Returns nil when the geometry, camera, or resulting projection is invalid.
    func framedCamera(bz: BrillouinZone,
                      current: Camera,
                      viewport: SIMD2<Float>,
                      padding: Float = 0.9) -> Camera? {
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite,
              inv.isFinite, inv > 0,
              viewport.x.isFinite, viewport.y.isFinite,
              viewport.x > 0, viewport.y > 0,
              padding.isFinite, padding > 0, padding <= 1,
              !bz.faces.isEmpty else { return nil }

        guard let camera = try? Camera.validated(current) else { return nil }
        let rotation = float4x4(camera.rotation)
        let inverseRotation = rotation.transpose
        guard rotation.isFiniteMatrix, inverseRotation.isFiniteMatrix else { return nil }

        var localVertices: [SIMD3<Float>] = []

        for face in bz.faces {
            guard face.count >= 3 else { return nil }
            for cartesian in face {
                guard cartesian.x.isFinite, cartesian.y.isFinite, cartesian.z.isFinite else {
                    return nil
                }
                let world = center + cartesian * inv
                guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
                let relative = world - center
                guard relative.x.isFinite, relative.y.isFinite, relative.z.isFinite else {
                    return nil
                }
                let local4 = inverseRotation * SIMD4<Float>(relative.x, relative.y, relative.z, 0)
                let local = local4.xyz
                guard local4.w.isFinite,
                      local.x.isFinite, local.y.isFinite, local.z.isFinite else { return nil }
                localVertices.append(local)
            }
        }

        guard localVertices.count >= 3,
              Self.hasArea(localVertices) else { return nil }

        let aspect = viewport.x / viewport.y
        guard aspect.isFinite, aspect > 0 else { return nil }
        let horizontalNDC = aspect * padding
        guard horizontalNDC.isFinite, horizontalNDC > 0 else { return nil }

        let nearPlane: Float = 0.1
        let farPlane: Float = 1000
        let nearSafety: Float = 0.01
        let farSafety: Float = 1
        let safeNear = nearPlane + nearSafety
        let safeFar = farPlane - farSafety
        let focal = 1 / tan(Float.pi / 8)
        guard focal.isFinite, focal > 0 else { return nil }

        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude
        var requiredHalfHeight: Float = 0
        for local in localVertices {
            minZ = min(minZ, local.z)
            maxZ = max(maxZ, local.z)
            let xRequirement = abs(local.x) / horizontalNDC
            let yRequirement = abs(local.y) / padding
            guard xRequirement.isFinite, yRequirement.isFinite else { return nil }
            requiredHalfHeight = max(requiredHalfHeight, xRequirement, yRequirement)
        }
        guard minZ.isFinite, maxZ.isFinite,
              requiredHalfHeight.isFinite else { return nil }

        var framed = camera
        framed.center = center

        if camera.perspective {
            var distance = max(safeNear + maxZ, safeNear)
            for local in localVertices {
                let xDistance = focal * abs(local.x) / horizontalNDC
                let yDistance = focal * abs(local.y) / padding
                guard xDistance.isFinite, yDistance.isFinite else { return nil }
                distance = max(distance, local.z + xDistance, local.z + yDistance)
            }
            guard distance.isFinite, distance > 0,
                  distance - maxZ >= safeNear,
                  distance - minZ <= safeFar else { return nil }
            framed.distance = distance
        } else {
            var distance = max(1, requiredHalfHeight)
            distance = max(distance, safeNear + maxZ)
            guard distance.isFinite, distance >= 1,
                  distance - maxZ >= safeNear,
                  distance - minZ <= safeFar else { return nil }
            framed.distance = distance
        }

        guard framed.center.x.isFinite, framed.center.y.isFinite, framed.center.z.isFinite,
              framed.distance.isFinite, framed.distance > 0,
              framed.rotation.vector.x.isFinite, framed.rotation.vector.y.isFinite,
              framed.rotation.vector.z.isFinite, framed.rotation.vector.w.isFinite else {
            return nil
        }
        return framed
    }

    private static func hasArea(_ points: [SIMD3<Float>]) -> Bool {
        var scale: Float = 0
        for p in points {
            scale = max(scale, abs(p.x), abs(p.y), abs(p.z))
        }
        guard scale.isFinite, scale > 0 else { return false }

        let normalized = points.map { $0 / scale }
        let anchor = normalized[0]
        guard let first = normalized.dropFirst().first(where: {
            let d = $0 - anchor
            return length(d).isFinite && length(d) > Float.ulpOfOne * 8
        }) else { return false }
        let u = first - anchor

        var bestCrossLength: Float = 0
        for point in normalized.dropFirst() {
            let crossProduct = cross(u, point - anchor)
            let crossLength = length(crossProduct)
            guard crossLength.isFinite else { return false }
            if crossLength > bestCrossLength {
                bestCrossLength = crossLength
            }
        }
        guard bestCrossLength > Float.ulpOfOne * 8 else { return false }
        return true
    }
}

private func scaleSafeLength(_ vector: SIMD3<Float>) -> Double {
    let scale = max(abs(Double(vector.x)), abs(Double(vector.y)), abs(Double(vector.z)))
    guard scale.isFinite, scale > 0 else { return 0 }
    let x = Double(vector.x) / scale
    let y = Double(vector.y) / scale
    let z = Double(vector.z) / scale
    return scale * sqrt(x * x + y * y + z * z)
}

private func scaleSafeDistance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, scale: Double? = nil) -> Double {
    let divisor = scale ?? 1
    guard divisor.isFinite, divisor > 0,
          lhs.x.isFinite, lhs.y.isFinite, lhs.z.isFinite,
          rhs.x.isFinite, rhs.y.isFinite, rhs.z.isFinite else { return .infinity }
    let x = (Double(lhs.x) - Double(rhs.x)) / divisor
    let y = (Double(lhs.y) - Double(rhs.y)) / divisor
    let z = (Double(lhs.z) - Double(rhs.z)) / divisor
    guard x.isFinite, y.isFinite, z.isFinite else { return .infinity }
    let componentScale = max(abs(x), abs(y), abs(z))
    guard componentScale > 0 else { return 0 }
    return componentScale * sqrt((x / componentScale) * (x / componentScale)
        + (y / componentScale) * (y / componentScale)
        + (z / componentScale) * (z / componentScale))
}

private func length(_ v: SIMD3<Float>) -> Float {
    let value = scaleSafeLength(v)
    return value.isFinite && value <= Double(Float.greatestFiniteMagnitude) ? Float(value) : .infinity
}

private func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let value = scaleSafeLength(v)
    guard value.isFinite, value > 0 else { return .zero }
    return v / Float(value)
}

private extension float4x4 {
    var isFiniteMatrix: Bool {
        columns.0.x.isFinite && columns.0.y.isFinite && columns.0.z.isFinite && columns.0.w.isFinite &&
        columns.1.x.isFinite && columns.1.y.isFinite && columns.1.z.isFinite && columns.1.w.isFinite &&
        columns.2.x.isFinite && columns.2.y.isFinite && columns.2.z.isFinite && columns.2.w.isFinite &&
        columns.3.x.isFinite && columns.3.y.isFinite && columns.3.z.isFinite && columns.3.w.isFinite
    }
}
