import Foundation
import simd

/// Errors from surface-slab construction. Each carries a human-readable
/// `description` suitable for UI status text.
enum SurfaceCellBuilderError: Error, Equatable, CustomStringConvertible {
    case degenerateMiller
    case millerIndexTooLarge(Int)
    case degenerateCell
    case nonFiniteCell
    case nonFiniteAtom(Int)
    case degenerateSurfaceVector
    case surfaceNormalParallelToVector
    case zeroSurfaceArea
    case replicationTooLarge
    case candidateCountExceeded(Int, Int)
    case nonFiniteTransformedAtom
    case noCandidates
    case noPlanes
    case layersExceedPlaneCount(Int, Int)
    case allDeduplicated
    case nonFiniteSlabLength
    case invalidLayers(Int)
    case invalidVacuum
    case invalidStackCount(Int)
    case terminationOutOfRange(Int, Int)
    case notBulkCrystal

    var description: String {
        switch self {
        case .degenerateMiller:
            return "surface Miller indices (h k l) are all zero"
        case .millerIndexTooLarge(let cap):
            return "Miller index exceeds cap \(cap)"
        case .degenerateCell:
            return "unit cell is singular"
        case .nonFiniteCell:
            return "unit cell vectors are non-finite"
        case .nonFiniteAtom(let i):
            return "atom \(i) has non-finite coordinates"
        case .degenerateSurfaceVector:
            return "surface cell vector is degenerate"
        case .surfaceNormalParallelToVector:
            return "surface normal is parallel to a surface vector"
        case .zeroSurfaceArea:
            return "surface cell has zero area"
        case .replicationTooLarge:
            return "surface slab replication range exceeds practical cap"
        case .candidateCountExceeded(let count, let cap):
            return "surface slab candidate count \(count) exceeds cap \(cap)"
        case .nonFiniteTransformedAtom:
            return "atom position non-finite after surface transformation"
        case .noCandidates:
            return "no candidate atoms generated for surface slab"
        case .noPlanes:
            return "no atomic planes identified for surface slab"
        case .layersExceedPlaneCount(let requested, let found):
            return "requested \(requested) layers but only \(found) atomic planes found"
        case .allDeduplicated:
            return "all candidate atoms deduplicated away; no slab atoms remain"
        case .nonFiniteSlabLength:
            return "slab extent + vacuum is non-finite or non-positive"
        case .invalidLayers(let n):
            return "layer count \(n) is out of range (1...\(SurfaceCellBuilder.maxLayers))"
        case .invalidVacuum:
            return "vacuum thickness must be finite and in [0, \(SurfaceCellBuilder.maxVacuum)]"
        case .invalidStackCount(let n):
            return "stack count \(n) is out of range (1...\(SurfaceCellBuilder.maxStackCount))"
        case .terminationOutOfRange(let t, let available):
            return "termination \(t) out of range: only \(available) start positions available"
        case .notBulkCrystal:
            return "a 3D periodic crystal is required"
        }
    }
}

/// Request parameters for surface-slab construction.
struct SurfaceCellRequest: Equatable {
    var h: Int = 1
    var k: Int = 0
    var l: Int = 0
    var layers: Int = 4
    var vacuum: Float = 10
    var termination: Int = 0
    var stackCount: Int = 1
}

/// Result of a successful surface-slab construction.
struct SurfaceCellResult: Equatable {
    let atoms: [Atom]
    let cell: Cell
    let planeCount: Int
    let slabExtent: Float
}

/// CRYSCAL/YCrySDen slab construction from an expanded bulk crystal.
///
/// Construction uses exact integer-lattice algebra:
///   1. Reduce (h,k,l) by gcd.
///   2. Derive integer step s with h*s.a+k*s.b+l*s.c=1 (extended GCD).
///   3. Derive primitive in-plane kernel basis t1, t2 (exact Bezout).
///   4. Replicate expanded-bulk atoms along s to produce ≥layers planes.
///   5. Wrap into the primitive in-plane parallelogram.
///   6. Group into distinct atomic planes; keep `layers` consecutive.
///   7. Deduplicate periodically in-plane by species.
///   8. Shift z to nonnegative; set c = actual slab extent + user vacuum.
/// The `termination` parameter selects which consecutive block of planes to
/// keep; `stackCount` repeats the slab contiguously along the surface normal.
enum SurfaceCellBuilder {
    static let maxMillerIndex = 1_000_000
    static let maxLayers = 1000
    static let maxVacuum: Float = 10_000
    static let maxStackCount = 100
    static let candidateCap = 100_000

    /// Tolerance for grouping atoms into planes (fraction of interplanar spacing).
    private static let planeToleranceFraction = 1e-5
    /// Tolerance for in-plane dedup (dimensionless fractional).
    private static let dedupToleranceFraction = 0.001

    static func build(atoms: [Atom], cell: Cell, request: SurfaceCellRequest)
        -> Result<SurfaceCellResult, SurfaceCellBuilderError> {
        // Request-level validation.
        if request.h == 0 && request.k == 0 && request.l == 0 {
            return .failure(.degenerateMiller)
        }
        if abs(request.h) > Self.maxMillerIndex || abs(request.k) > Self.maxMillerIndex
            || abs(request.l) > Self.maxMillerIndex {
            return .failure(.millerIndexTooLarge(Self.maxMillerIndex))
        }
        if request.layers < 1 || request.layers > Self.maxLayers {
            return .failure(.invalidLayers(request.layers))
        }
        if !request.vacuum.isFinite || request.vacuum < 0 || request.vacuum > Self.maxVacuum {
            return .failure(.invalidVacuum)
        }
        if request.stackCount < 1 || request.stackCount > Self.maxStackCount {
            return .failure(.invalidStackCount(request.stackCount))
        }

        // Cell validation.
        guard cell.isFinite else {
            return .failure(.nonFiniteCell)
        }
        let cellA = SIMD3<Double>(Double(cell.a.x), Double(cell.a.y), Double(cell.a.z))
        let cellB = SIMD3<Double>(Double(cell.b.x), Double(cell.b.y), Double(cell.b.z))
        let cellC = SIMD3<Double>(Double(cell.c.x), Double(cell.c.y), Double(cell.c.z))
        let volume = abs(simd_dot(cellA, simd_cross(cellB, cellC)))
        guard volume > 1e-12 else {
            return .failure(.degenerateCell)
        }

        // Input-atom validation.
        guard !atoms.isEmpty else {
            return .failure(.noCandidates)
        }
        for (index, atom) in atoms.enumerated() {
            let p = SIMD3<Double>(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                return .failure(.nonFiniteAtom(index))
            }
        }

        // Reduce Miller indices by gcd.
        let g = gcd(abs(request.h), gcd(abs(request.k), abs(request.l)))
        let (h0, k0, l0) = (request.h / g, request.k / g, request.l / g)

        // Compute reciprocal vector G = h0 a* + k0 b* + l0 c* (physics convention).
        let recip = cell.reciprocalVectors
        let aStar = SIMD3<Double>(Double(recip.a.x), Double(recip.a.y), Double(recip.a.z))
        let bStar = SIMD3<Double>(Double(recip.b.x), Double(recip.b.y), Double(recip.b.z))
        let cStar = SIMD3<Double>(Double(recip.c.x), Double(recip.c.y), Double(recip.c.z))
        let gVec = SIMD3<Double>(Double(h0) * aStar.x + Double(k0) * bStar.x + Double(l0) * cStar.x,
                               Double(h0) * aStar.y + Double(k0) * bStar.y + Double(l0) * cStar.y,
                               Double(h0) * aStar.z + Double(k0) * bStar.z + Double(l0) * cStar.z)
        let gNorm = simd_length(gVec)
        guard gNorm.isFinite, gNorm > 1e-12 else {
            return .failure(.degenerateSurfaceVector)
        }
        let nVec = gVec / gNorm

        // Interplanar spacing d = 2π / |G|.
        let d = (2.0 * Double.pi) / gNorm
        guard d.isFinite, d > 1e-12 else {
            return .failure(.degenerateSurfaceVector)
        }

        // Step vector s in fractional coords: h0*s.a + k0*s.b + l0*s.c = 1.
        let sFrac: (Int, Int, Int)
        do { sFrac = try extendedGCD3(h: h0, k: k0, l: l0) }
        catch let error as SurfaceCellBuilderError { return .failure(error) }
        catch { return .failure(.degenerateSurfaceVector) }
        let sCart = Double(sFrac.0) * cellA + Double(sFrac.1) * cellB + Double(sFrac.2) * cellC

        // Primitive in-plane integer kernel basis t1, t2 (exact Bezout).
        let (t1Frac, t2Frac): ((Int, Int, Int), (Int, Int, Int))
        do { (t1Frac, t2Frac) = try kernelBasis(h: h0, k: k0, l: l0) }
        catch let error as SurfaceCellBuilderError { return .failure(error) }
        catch { return .failure(.degenerateSurfaceVector) }
        let surfA = Double(t1Frac.0) * cellA + Double(t1Frac.1) * cellB + Double(t1Frac.2) * cellC
        let surfB = Double(t2Frac.0) * cellA + Double(t2Frac.1) * cellB + Double(t2Frac.2) * cellC
        let surfALen = simd_length(surfA)
        let surfBLen = simd_length(surfB)
        guard surfALen > 1e-12, surfBLen > 1e-12 else {
            return .failure(.degenerateSurfaceVector)
        }

        // Build rotation mapping surface normal to z.
        let u = surfA / surfALen
        let w = nVec
        let vRaw = simd_cross(w, u)
        let vNorm = simd_length(vRaw)
        guard vNorm > 1e-12 else {
            return .failure(.surfaceNormalParallelToVector)
        }
        let v = vRaw / vNorm

        func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(simd_dot(u, p), simd_dot(v, p), simd_dot(w, p))
        }

        // Surface cell vectors in the rotated frame (z ≈ 0).
        let rotSurfA = rotate(surfA)
        let rotSurfB = rotate(surfB)
        let detM = rotSurfA.x * rotSurfB.y - rotSurfB.x * rotSurfA.y
        guard abs(detM) > 1e-12 else {
            return .failure(.zeroSurfaceArea)
        }
        let invM11 = rotSurfB.y / detM
        let invM12 = -rotSurfB.x / detM
        let invM21 = -rotSurfA.y / detM
        let invM22 = rotSurfA.x / detM

        func surfaceFractional(_ px: Double, _ py: Double) -> SIMD2<Double> {
            let alpha = invM11 * px + invM12 * py
            let beta = invM21 * px + invM22 * py
            return SIMD2(alpha - floor(alpha), beta - floor(beta))
        }

        // Compute replication range along s to produce ≥layers planes.
        var minZRaw = Double.greatestFiniteMagnitude
        var maxZRaw = -Double.greatestFiniteMagnitude
        for atom in atoms {
            let p = SIMD3<Double>(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
            let rp = rotate(p)
            minZRaw = min(minZRaw, rp.z)
            maxZRaw = max(maxZRaw, rp.z)
        }
        let bulkExtent = maxZRaw - minZRaw
        let rawExtraSteps = (bulkExtent / d).rounded(.up) + 2
        guard rawExtraSteps.isFinite, rawExtraSteps >= 0,
              rawExtraSteps <= Double(Self.candidateCap) else {
            return .failure(.replicationTooLarge)
        }
        let extraSteps = Int(rawExtraSteps)
        let repSum = request.layers.addingReportingOverflow(extraSteps)
        guard !repSum.overflow else {
            return .failure(.replicationTooLarge)
        }
        let nRep = repSum.partialValue
        let doubledRep = nRep.multipliedReportingOverflow(by: 2)
        guard !doubledRep.overflow else {
            return .failure(.replicationTooLarge)
        }
        let copyCount = doubledRep.partialValue.addingReportingOverflow(1)
        guard !copyCount.overflow else {
            return .failure(.replicationTooLarge)
        }
        let totalCandidates = atoms.count.multipliedReportingOverflow(by: copyCount.partialValue)
        guard !totalCandidates.overflow, totalCandidates.partialValue <= Self.candidateCap else {
            let count = totalCandidates.overflow ? Self.candidateCap + 1 : totalCandidates.partialValue
            return .failure(.candidateCountExceeded(count, Self.candidateCap))
        }

        // Replicate atoms along sCart and project into the surface cell.
        var candidates: [(frac: SIMD2<Double>, z: Double, atom: Atom)] = []
        candidates.reserveCapacity(totalCandidates.partialValue)

        for atom in atoms {
            let p0 = SIMD3<Double>(Double(atom.coord.x), Double(atom.coord.y), Double(atom.coord.z))
            for i in -nRep...nRep {
                let translation = Double(i) * sCart
                let rp = rotate(p0 + translation)
                guard rp.x.isFinite, rp.y.isFinite, rp.z.isFinite else {
                    return .failure(.nonFiniteTransformedAtom)
                }
                let frac = surfaceFractional(rp.x, rp.y)
                candidates.append((frac: frac, z: rp.z, atom: atom))
            }
        }

        guard !candidates.isEmpty else {
            return .failure(.noCandidates)
        }

        // Group into distinct atomic planes.
        let planeTol = planeToleranceFraction * d
        candidates.sort { $0.z < $1.z }

        struct Plane {
            var zMean: Double
            var members: [(frac: SIMD2<Double>, atom: Atom)]
        }
        var planes: [Plane] = []
        for cand in candidates {
            if let last = planes.last, abs(cand.z - last.zMean) < planeTol {
                let n = Double(last.members.count)
                planes[planes.count - 1].zMean = (last.zMean * n + cand.z) / (n + 1)
                planes[planes.count - 1].members.append((cand.frac, cand.atom))
            } else {
                planes.append(Plane(zMean: cand.z, members: [(cand.frac, cand.atom)]))
            }
        }

        guard !planes.isEmpty else {
            return .failure(.noPlanes)
        }
        let planeCount = planes.count

        // Select the requested consecutive block of planes by termination.
        guard request.layers <= planeCount else {
            return .failure(.layersExceedPlaneCount(request.layers, planeCount))
        }
        guard request.termination >= 0, request.termination <= planeCount - request.layers else {
            return .failure(.terminationOutOfRange(request.termination, planeCount - request.layers + 1))
        }
        let keptPlanes = Array(planes[request.termination ..< request.termination + request.layers])

        // Deduplicate within each plane by species at the same wrapped fractional
        // position using dimensionless fractional tolerance with 0/1 wrapping.
        let dedupTol = dedupToleranceFraction
        var kept: [Atom] = []
        var minZ = Double.greatestFiniteMagnitude
        var maxZ = -Double.greatestFiniteMagnitude

        func wrappedDelta(_ a: Double, _ b: Double) -> Double {
            let delta = abs(a - b)
            return min(delta, 1.0 - delta)
        }

        for plane in keptPlanes {
            var seen: [(frac: SIMD2<Double>, species: Int)] = []
            for member in plane.members {
                let isDup = seen.contains { existing in
                    existing.species == member.atom.atomicNumber &&
                        wrappedDelta(existing.frac.x, member.frac.x) < dedupTol &&
                        wrappedDelta(existing.frac.y, member.frac.y) < dedupTol
                }
                if !isDup {
                    seen.append((member.frac, member.atom.atomicNumber))
                    let cartX = member.frac.x * rotSurfA.x + member.frac.y * rotSurfB.x
                    let cartY = member.frac.x * rotSurfA.y + member.frac.y * rotSurfB.y
                    let z = plane.zMean
                    kept.append(Atom(coord: SIMD3<Float>(Float(cartX), Float(cartY), Float(z)),
                                     atomicNumber: member.atom.atomicNumber,
                                     label: member.atom.label))
                    minZ = min(minZ, z)
                    maxZ = max(maxZ, z)
                }
            }
        }

        guard !kept.isEmpty else {
            return .failure(.allDeduplicated)
        }

        // Shift z so the bottom of the slab is at z = 0.
        if minZ != 0 {
            for i in 0..<kept.count {
                kept[i].coord.z -= Float(minZ)
            }
        }
        let slabExtent = Double(maxZ - minZ)

        // Multi-slab stacking: replicate the slab contiguously along z. Vacuum is
        // appended once after the last repeat.
        var slabAtoms = kept
        var finalSlabExtent = slabExtent
        if request.stackCount > 1 {
            let totalStacked = kept.count.multipliedReportingOverflow(by: request.stackCount)
            guard !totalStacked.overflow, totalStacked.partialValue <= Self.candidateCap else {
                let count = totalStacked.overflow ? Self.candidateCap + 1 : totalStacked.partialValue
                return .failure(.candidateCountExceeded(count, Self.candidateCap))
            }
            let singleExtent = Float(slabExtent)
            for s in 1..<request.stackCount {
                let dz = Float(s) * singleExtent
                for atom in kept {
                    var copy = atom
                    copy.coord.z += dz
                    slabAtoms.append(copy)
                }
            }
            finalSlabExtent = slabExtent * Double(request.stackCount)
        }

        let requestedLength = finalSlabExtent + Double(request.vacuum)
        // c is a nonperiodic mathematical embedding. A one-plane, zero-vacuum
        // slab has zero geometric thickness, so retain one interplanar spacing
        // solely to keep Cell nonsingular; positive requested thickness/vacuum
        // is represented exactly.
        let cLength = requestedLength > 0 ? requestedLength : d
        guard cLength.isFinite, cLength > 0 else {
            return .failure(.nonFiniteSlabLength)
        }

        let slabCell = Cell(
            a: SIMD3<Float>(Float(rotSurfA.x), Float(rotSurfA.y), 0),
            b: SIMD3<Float>(Float(rotSurfB.x), Float(rotSurfB.y), 0),
            c: SIMD3<Float>(0, 0, Float(cLength)))
        return .success(SurfaceCellResult(atoms: slabAtoms, cell: slabCell,
                                          planeCount: planeCount,
                                          slabExtent: Float(finalSlabExtent)))
    }
}

extension Scene {
    /// Build a surface slab from this 3D periodic crystal. The pristine bulk
    /// (unwidened) atoms are used as the expansion source.
    func buildSurfaceCell(request: SurfaceCellRequest) -> Result<Scene, SurfaceCellBuilderError> {
        buildSurfaceCellWithInfo(request: request).map { $0.scene }
    }

    /// Build a surface slab and expose the underlying result (plane count, slab
    /// extent) alongside the scene. The UI needs `planeCount` to bound the
    /// termination selection, but the resulting Scene carries no build metadata.
    func buildSurfaceCellWithInfo(request: SurfaceCellRequest)
        -> Result<(scene: Scene, info: SurfaceCellResult), SurfaceCellBuilderError> {
        guard isCrystal, periodicDim == 3, let cell else {
            return .failure(.notBulkCrystal)
        }
        let bulk = baseAtoms.isEmpty ? atoms : baseAtoms
        switch SurfaceCellBuilder.build(atoms: bulk, cell: cell, request: request) {
        case .success(let result):
            var out = self
            out.atoms = result.atoms
            out.cell = result.cell
            out.bonds = Scene.rebond(result.atoms, cell: result.cell, isCrystal: true, periodicDim: 2)
            out.baseAtoms = result.atoms
            out.baseBonds = out.bonds
            out.preslabAtoms = result.atoms
            out.isCrystal = true
            out.periodicDim = 2
            out.superCell = SuperCell()
            out.slab = nil
            out.selectedAtoms = []
            out.measurementResult = nil
            out.kPathPoints = []
            out.kPathBreaks = []
            out.kPathProvenance = .generated
            out.kPathSignature = nil
            out.crystalSymmetry = CrystalSymmetryAnalyzer.analyze(
                cell: result.cell, atoms: result.atoms, isCrystal: true, periodicDim: 2)
            out.title = self.title + " (slab)"
            return .success((out, result))
        case .failure(let error):
            return .failure(error)
        }
    }
}

// MARK: - Integer-lattice algebra helpers

/// Greatest common divisor (Euclidean algorithm).
private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = a, b = b
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

/// Extended GCD for 2 integers: returns (g, x, y) with x*a + y*b = g.
private func egcd2(_ a: Int, _ b: Int) -> (g: Int, x: Int, y: Int) {
    if b == 0 { return (abs(a), a >= 0 ? 1 : -1, 0) }
    let (g, x1, y1) = egcd2(b, a % b)
    return (g, y1, x1 - (a / b) * y1)
}

/// Extended GCD for 3 integers: find (a, b, c) such that a*h + b*k + c*l = gcd(h,k,l).
/// The caller reduces (h,k,l) by gcd first, so the result satisfies = 1.
private func extendedGCD3(h: Int, k: Int, l: Int) throws -> (Int, Int, Int) {
    let (g1, a, b) = egcd2(h, k)
    let (g2, c, d) = egcd2(g1, l)
    guard g2 == 1 else {
        throw SurfaceCellBuilderError.degenerateSurfaceVector
    }
    return (c * a, c * b, d)
}

/// Find a primitive integer kernel basis for the plane h*x + k*y + l*z = 0.
/// Uses an exact Bezout construction so that cross(t1, t2) = (h, k, l).
///
/// For h≠0 or k≠0: d=gcd(h,k), t1=(k/d,-h/d,0), find p,q with p*h+q*k=d
/// via extended GCD, t2=(p*l,q*l,-d). Then cross(t1,t2) = (h,k,l).
/// For h=k=0 (l=±1): t1=(1,0,0), t2=(0,1,0).
private func kernelBasis(h: Int, k: Int, l: Int) throws -> ((Int, Int, Int), (Int, Int, Int)) {
    if h == 0 && k == 0 {
        return ((1, 0, 0), (0, 1, 0))
    }
    let d = gcd(abs(h), abs(k))
    let t1 = (k / d, -h / d, 0)
    let (_, p, q) = egcd2(h, k)
    let t2 = (p * l, q * l, -d)
    let cx = t1.1 * t2.2 - t1.2 * t2.1
    let cy = t1.2 * t2.0 - t1.0 * t2.2
    let cz = t1.0 * t2.1 - t1.1 * t2.0
    if cx == h && cy == k && cz == l {
        return (t1, t2)
    }
    let t2n = (-t2.0, -t2.1, -t2.2)
    let cx2 = t1.1 * t2n.2 - t1.2 * t2n.1
    let cy2 = t1.2 * t2n.0 - t1.0 * t2n.2
    let cz2 = t1.0 * t2n.1 - t1.1 * t2n.0
    if cx2 == h && cy2 == k && cz2 == l {
        return (t1, t2n)
    }
    throw SurfaceCellBuilderError.degenerateSurfaceVector
}
