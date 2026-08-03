import simd

// Reciprocal-lattice + Brillouin-zone geometry.
//
// Port of XCrySDen's F/recvec.f (RecVec) and C/xcBz.c (BzInitBZ). mcrysden is
// fully Angstrom-based, so we drop the 0.529 Bohr conversion baked into the
// Fortran and work directly from the direct lattice vectors (Angstroms).
//
// Convention note: reciprocal vectors here INCLUDE the 2pi factor
//     a* = 2pi (b x c) / (a . (b x c))   (cyclic)
// which is the physics convention (a_i . a*_j = 2pi delta_ij). Some band codes
// use the crystallographer's convention (omit 2pi, a_i.a*_j = delta_ij) — the
// k-path export documents this and scales accordingly.

extension Cell {
    /// The 3×3 matrix [a b c] with the cell vectors as columns, in Double
    /// precision. Its inverse maps Cartesian coordinates to fractional.
    var inverseMatrix: simd_double3x3? {
        let components = [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]
        guard components.allSatisfy({ $0.isFinite }) else { return nil }
        let mat = simd_double3x3(
            columns: (SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z)),
                      SIMD3<Double>(Double(b.x), Double(b.y), Double(b.z)),
                      SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))))
        guard abs(mat.determinant) > 1e-18 else { return nil }
        return mat.inverse
    }

    /// Cell vectors in Double precision.
    var doubleVectors: (a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>) {
        (SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z)),
         SIMD3<Double>(Double(b.x), Double(b.y), Double(b.z)),
         SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z)))
    }
    /// Conventional reciprocal lattice vectors (including 2pi) from the DIRECT
    /// conventional cell: a* = 2pi (b x c) / volume, cyclic, volume = a.(bxc).
    /// Correct for primitive conventional cells; for centered cells (fcc/bcc)
    /// these form a SUPERSET of the true reciprocal lattice — use
    /// `primitiveReciprocal` (which needs the atomic centering) for the BZ.
    var reciprocalVectors: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let components = [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z]
        guard components.allSatisfy({ $0.isFinite }) else { return (.zero, .zero, .zero) }

        // Normalize before taking the determinant so both very small and very
        // large, but well-conditioned, cells use the same invertibility test.
        let scale = components.reduce(0.0) { max($0, abs(Double($1))) }
        guard scale.isFinite, scale > 0 else { return (.zero, .zero, .zero) }
        let directA = SIMD3<Double>(Double(a.x) / scale, Double(a.y) / scale, Double(a.z) / scale)
        let directB = SIMD3<Double>(Double(b.x) / scale, Double(b.y) / scale, Double(b.z) / scale)
        let directC = SIMD3<Double>(Double(c.x) / scale, Double(c.y) / scale, Double(c.z) / scale)
        let crossBC = cross(directB, directC)
        let crossCA = cross(directC, directA)
        let crossAB = cross(directA, directB)
        let normalizedVolume = dot(directA, crossBC)
        guard normalizedVolume.isFinite, abs(normalizedVolume) > 1e-12 else {
            return (.zero, .zero, .zero)
        }

        let multiplier = (2.0 * Double.pi / normalizedVolume) / scale
        guard multiplier.isFinite else { return (.zero, .zero, .zero) }

        func converted(_ vector: SIMD3<Double>) -> SIMD3<Float>? {
            let result = SIMD3<Float>(Float(vector.x * multiplier),
                                      Float(vector.y * multiplier),
                                      Float(vector.z * multiplier))
            return result.isFinite ? result : nil
        }
        guard let reciprocalA = converted(crossBC),
              let reciprocalB = converted(crossCA),
              let reciprocalC = converted(crossAB) else {
            return (.zero, .zero, .zero)
        }
        return (a: reciprocalA, b: reciprocalB, c: reciprocalC)
    }

    /// Build the direct cell vectors from lattice parameters (a,b,c in Å, angles
    /// alpha/beta/gamma in degrees). Standard convention: a along x, b in the xy
    /// plane, c completing the right-handed system.
    ///
    /// Malformed or numerically degenerate parameters return an all-zero cell.
    /// This is an intentional finite sentinel for the nonoptional API, rather
    /// than a fabricated valid-looking lattice; reciprocal geometry treats it
    /// as having no usable basis.
    static func fromLattice(a: Float, b: Float, c: Float,
                            alpha: Float, beta: Float, gamma: Float) -> Cell {
        let fallback = Cell(a: .zero, b: .zero, c: .zero)
        guard a.isFinite, b.isFinite, c.isFinite,
              alpha.isFinite, beta.isFinite, gamma.isFinite,
              a > 0, b > 0, c > 0,
              alpha > 0, alpha < 180,
              beta > 0, beta < 180,
              gamma > 0, gamma < 180 else {
            return fallback
        }

        // Use Double for the metric calculation: near-coplanar cells can lose
        // most of the significant bits when the Gram residual is formed.
        let alphaRadians = Double(alpha) * Double.pi / 180
        let betaRadians = Double(beta) * Double.pi / 180
        let gammaRadians = Double(gamma) * Double.pi / 180
        let cosAlpha = cos(alphaRadians)
        let cosBeta = cos(betaRadians)
        let cosGamma = cos(gammaRadians)
        let sinBeta = sin(betaRadians)
        let sinGamma = sin(gammaRadians)
        guard sinGamma > 1e-12 else { return fallback }

        let cYRatio = (cosAlpha - cosBeta * cosGamma) / sinGamma
        guard cYRatio.isFinite else { return fallback }

        // This is the normalized Gram determinant. Using sin(beta) directly
        // avoids an extra cancellation in 1 - cos(beta)^2.
        let sinBetaSquared = sinBeta * sinBeta
        let cYRatioSquared = cYRatio * cYRatio
        let residual = sinBetaSquared - cYRatioSquared
        guard residual.isFinite else { return fallback }

        // Only absorb negative error at Double roundoff scale. A larger
        // negative residual means the requested angles cannot form a cell.
        let residualScale = max(1, max(abs(sinBetaSquared), abs(cYRatioSquared)))
        let roundoff = 64 * Double.ulpOfOne * residualScale
        guard residual >= -roundoff else { return fallback }
        // A positive residual at the same scale is also roundoff: without this
        // strict margin an exactly coplanar metric can acquire a tiny c.z.
        guard residual > roundoff else { return fallback }

        let cZRatio = sqrt(residual)
        let aVec = SIMD3<Float>(a, 0, 0)
        let bVec = SIMD3<Float>(Float(Double(b) * cosGamma),
                                Float(Double(b) * sinGamma), 0)
        let cVec = SIMD3<Float>(Float(Double(c) * cosBeta),
                                Float(Double(c) * cYRatio),
                                Float(Double(c) * cZRatio))
        guard aVec.isFinite, bVec.isFinite, cVec.isFinite else { return fallback }
        return Cell(a: aVec, b: bVec, c: cVec)
    }

    /// Cartesian position of a fractional coordinate (frac in [0,1)) using this cell.
    func cartesian(_ frac: SIMD3<Float>) -> SIMD3<Float> {
        return a * frac.x + b * frac.y + c * frac.z
    }
}

// Centered-lattice handling.
//
// A conventional cell a,b,c may be centered (fcc/bcc): the true direct lattice
// points are NOT just integer combos of a,b,c — there are fractional offsets
// (e.g. fcc: (0,½,½),(½,0,½),(½,½,0)) carried by the atoms. We recover the
// primitive basis by shortest-vector reduction over (int combo + offset), then
// the primitive reciprocal generates the correct BZ G-star.

/// Conventional-lattice centering (Bravais type). Only P/I/F need primitive
/// reduction for the BZ; everything else (molecular, A/C/R/H) is treated as P.
enum LatticeCentering { case primitive, body, face }

private struct CenteringBin: Hashable {
    let species: Int
    let x: Int
    let y: Int
    let z: Int
}

private struct ConsumableCenteringLookup {
    var buckets: [CenteringBin: [Int]]
    var positions: [Int]

    init(fracs: [SIMD3<Float>], species: [Int], binIndex: (Float) -> Int) {
        var buckets: [CenteringBin: [Int]] = [:]
        buckets.reserveCapacity(fracs.count)
        positions = Array(repeating: -1, count: fracs.count)

        for (index, frac) in fracs.enumerated() {
            let bin = CenteringBin(species: species[index], x: binIndex(frac.x),
                                   y: binIndex(frac.y), z: binIndex(frac.z))
            positions[index] = buckets[bin, default: []].count
            buckets[bin, default: []].append(index)
        }
        self.buckets = buckets
    }

    func last(in bin: CenteringBin) -> Int? {
        buckets[bin]?.last
    }

    mutating func consume(_ index: Int, from bin: CenteringBin) {
        guard positions.indices.contains(index), var bucket = buckets[bin] else { return }
        let position = positions[index]
        guard position >= 0, position < bucket.count else { return }

        let last = bucket.removeLast()
        if last != index {
            bucket[position] = last
            positions[last] = position
        }
        positions[index] = -1
        if bucket.isEmpty {
            buckets.removeValue(forKey: bin)
        } else {
            buckets[bin] = bucket
        }
    }
}

/// Reduce a conventional cell to its primitive direct basis using the fractional
/// atomic offsets (the "basis") that reveal centering. Returns the conventional
/// basis unchanged if only the trivial (0,0,0) offset is present.
enum Lattice {
    /// Fractional coordinates of Cartesian `atoms` in the conventional cell.
    static func fractional(_ atoms: [SIMD3<Float>], cell: Cell) -> [SIMD3<Float>] {
        // Fractional f solves p = f_a*a + f_b*b + f_c*c, i.e. basis vectors as
        // COLUMNS (not rows) of the inverted matrix. Rows would only be correct
        // for orthogonal (cubic) cells; this is right for any lattice.
        let components = [cell.a.x, cell.a.y, cell.a.z,
                          cell.b.x, cell.b.y, cell.b.z,
                          cell.c.x, cell.c.y, cell.c.z]
        guard components.allSatisfy({ $0.isFinite }) else {
            return atoms.map { _ in SIMD3<Float>.zero }
        }
        // Scale both sides by the largest direct-cell component. This keeps the
        // determinant and the solve well-conditioned for uniformly tiny or huge
        // cells while preserving the physical Cartesian -> fractional equation.
        let scale = components.reduce(0.0) { max($0, abs(Double($1))) }
        guard scale.isFinite, scale > 0 else {
            return atoms.map { _ in SIMD3<Float>.zero }
        }
        let directA = SIMD3<Double>(Double(cell.a.x) / scale,
                                    Double(cell.a.y) / scale,
                                    Double(cell.a.z) / scale)
        let directB = SIMD3<Double>(Double(cell.b.x) / scale,
                                    Double(cell.b.y) / scale,
                                    Double(cell.b.z) / scale)
        let directC = SIMD3<Double>(Double(cell.c.x) / scale,
                                    Double(cell.c.y) / scale,
                                    Double(cell.c.z) / scale)
        let crossBC = cross(directB, directC)
        let crossCA = cross(directC, directA)
        let crossAB = cross(directA, directB)
        let determinant = dot(directA, crossBC)
        guard determinant.isFinite, abs(determinant) > 1e-12 else {
            return atoms.map { _ in SIMD3<Float>.zero }
        }

        return atoms.map { atom in
            let coordinates = [atom.x, atom.y, atom.z]
            guard coordinates.allSatisfy({ $0.isFinite }) else { return .zero }
            let cartesian = SIMD3<Double>(Double(atom.x) / scale,
                                          Double(atom.y) / scale,
                                          Double(atom.z) / scale)
            let fractional = SIMD3<Double>(dot(cartesian, crossBC) / determinant,
                                           dot(cartesian, crossCA) / determinant,
                                           dot(cartesian, crossAB) / determinant)
            guard fractional.x.isFinite, fractional.y.isFinite, fractional.z.isFinite else {
                return .zero
            }
            let result = SIMD3<Float>(Float(fractional.x), Float(fractional.y), Float(fractional.z))
            return result.isFinite ? result : .zero
        }
    }

    /// Fractional part in [0,1) via floor. NOT .rounded(): Swift sends 0.5->1,
    /// making centering offsets asymmetric and breaking centering detection.
    private static func vfrac(_ p: SIMD3<Float>) -> SIMD3<Float> { p - floor(p) }

    /// Unique fractional offsets (mod 1, excluding ~0) that describe the basis.
    /// Accepts either Cartesian coords or `[Atom]`.
    static func basisCoords(_ atoms: [Atom], cell: Cell) -> [SIMD3<Float>] {
        return fractional(atoms.map { $0.coord }, cell: cell)
    }
    static func basisOffsets(_ atoms: [SIMD3<Float>], cell: Cell) -> [SIMD3<Float>] {
        let eps: Float = 1e-2
        var offs: [SIMD3<Float>] = []
        for f in fractional(atoms, cell: cell) {
            let g = vfrac(f)
            if length(g) < eps { continue }
            if !offs.contains(where: { length($0 - g) < eps }) { offs.append(g) }
        }
        return offs
    }

    /// Centering of a conventional lattice from its atoms: an offset is a genuine
    /// lattice translation iff shifting EVERY atom (mod 1) lands on an identical
    /// species. Basis atoms near ½ fail; only true centering passes. Molecules /
    /// unrecognized centering fall back to primitive (P).
    static func detectCentering(_ atoms: [Atom], cell: Cell) -> LatticeCentering {
        var candidateComparisons = 0
        return detectCentering(atoms, cell: cell, candidateComparisons: &candidateComparisons)
    }

    /// Diagnostic overload for bounding the spatial lookup work in tests.
    static func detectCentering(_ atoms: [Atom], cell: Cell,
                                candidateComparisons: inout Int) -> LatticeCentering {
        let fracs = fractional(atoms.map { $0.coord }, cell: cell).map(vfrac)
        let syms = atoms.map { $0.atomicNumber }
        let eps: Float = 1e-2
        // nearest offset modulo 1, wrapped into [-0.5, 0.5).
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            func d(_ x: Float) -> Float { var z = x - floor(x); if z > 0.5 { z -= 1 }; return z }
            return abs(d(a.x - b.x)) < eps && abs(d(a.y - b.y)) < eps && abs(d(a.z - b.z)) < eps
        }

        // A bin width no larger than eps makes a match possible only in the
        // current bin or one of its 26 periodic neighbors. The species is part
        // of the key so mixed-species bases never enter the candidate list.
        let binCount = max(1, Int(ceil(1 / Double(eps))))
        let binScale = Double(binCount)
        func binIndex(_ coordinate: Float) -> Int {
            let raw = Int(floor(Double(coordinate) * binScale))
            return min(binCount - 1, max(0, raw))
        }
        func wrappedBin(_ index: Int) -> Int {
            let remainder = index % binCount
            return remainder >= 0 ? remainder : remainder + binCount
        }

        // The number of exact checks is deliberately bounded independently of
        // bucket occupancy. The product is saturated before applying the
        // fixed cap so malformed or enormous inputs cannot overflow Int.
        let comparisonsPerAtom = 4 * 27
        let saturatedBudget: Int
        if fracs.count > Int.max / comparisonsPerAtom {
            saturatedBudget = Int.max
        } else {
            saturatedBudget = fracs.count * comparisonsPerAtom
        }
        let comparisonBudget = min(2_000_000, saturatedBudget)
        var comparisonBudgetExceeded = false

        func compare(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Bool? {
            guard candidateComparisons < comparisonBudget else {
                comparisonBudgetExceeded = true
                return nil
            }
            candidateComparisons += 1
            return near(lhs, rhs)
        }

        func isCentering(_ off: SIMD3<Float>) -> Bool {
            var lookup = ConsumableCenteringLookup(fracs: fracs, species: syms,
                                                    binIndex: binIndex)

            for (i, f) in fracs.enumerated() {
                let target = vfrac(f + off)
                let targetBin = (x: binIndex(target.x), y: binIndex(target.y), z: binIndex(target.z))

                // Every point in one bin is within eps in each coordinate. Try
                // the last occurrence first, then use swap-removal so large
                // duplicate clusters do not turn into quadratic scans.
                let sameBin = CenteringBin(species: syms[i], x: targetBin.x,
                                           y: targetBin.y, z: targetBin.z)
                if let candidate = lookup.last(in: sameBin) {
                    guard let matches = compare(fracs[candidate], target) else { return false }
                    guard matches else { return false }
                    lookup.consume(candidate, from: sameBin)
                    continue
                }

                var found = false
                for dx in -1...1 where !found {
                    for dy in -1...1 where !found {
                        for dz in -1...1 where !found {
                            if dx == 0 && dy == 0 && dz == 0 { continue }
                            let bin = CenteringBin(species: syms[i],
                                                   x: wrappedBin(targetBin.x + dx),
                                                   y: wrappedBin(targetBin.y + dy),
                                                   z: wrappedBin(targetBin.z + dz))
                            var matchingCandidate: Int?
                            if let candidates = lookup.buckets[bin] {
                                for candidate in candidates {
                                    guard let matches = compare(fracs[candidate], target) else { return false }
                                    if matches {
                                        matchingCandidate = candidate
                                        break
                                    }
                                }
                            }
                            if let matchingCandidate {
                                lookup.consume(matchingCandidate, from: bin)
                                found = true
                            }
                        }
                    }
                }
                guard found else { return false }
            }
            return true
        }

        if isCentering(SIMD3(0.5, 0.5, 0.5)) { return .body }
        if comparisonBudgetExceeded { return .primitive }
        for offset in [SIMD3<Float>(0.5,0.5,0), SIMD3<Float>(0.5,0,0.5),
                       SIMD3<Float>(0,0.5,0.5)] {
            if !isCentering(offset) {
                if comparisonBudgetExceeded { return .primitive }
                return .primitive
            }
        }
        if comparisonBudgetExceeded { return .primitive }
        return .face
    }

    /// Canonical primitive direct vectors by centering type (crystallographic
    /// standard). Avoids greedy shortest-vector reduction, which over-reduces when
    /// basis atoms sit closer than a lattice translation (e.g. GaAsH slab).
    static func primitiveDirect(centering: LatticeCentering, _ conv: Cell)
        -> (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let a = conv.a, b = conv.b, c = conv.c
        switch centering {
        case .body:      return (0.5*(-a+b+c), 0.5*(a-b+c), 0.5*(a+b-c))
        case .face:      return (0.5*(b+c), 0.5*(a+c), 0.5*(a+b))
        case .primitive: return (a, b, c)
        }
    }

    /// Reciprocal vectors (2pi convention) of the primitive direct basis — the
    /// correct generator for the BZ G-star. Centering is detected from atoms.
    static func primitiveReciprocal(cell: Cell, atoms: [Atom]) -> (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let centering = detectCentering(atoms, cell: cell)
        let p = primitiveDirect(centering: centering, cell)
        return Cell(a: p.a, b: p.b, c: p.c).reciprocalVectors
    }
}

/// A k-point in fractional (crystal) coordinates, with an optional label
/// (Gamma/X/K/L/W...). Fractional coords are in the CONVENTIONAL reciprocal
/// basis (the band-plot basis the BZ reports).
struct KPoint: Codable, Equatable {
    var frac: SIMD3<Float>
    var label: String
    init(_ frac: SIMD3<Float>, _ label: String = "") { self.frac = frac; self.label = label }
}

/// A k-path: an ordered list of special k-points with per-segment interpolation.
struct KPath: Codable, Equatable {
    var points: [KPoint]
    // Number of interpolated points per segment (distance-weighted rounding).
    var pointsPerSegment: Int = 20
    /// Indices i such that there is NO segment between points[i] and points[i+1].
    /// A break at i means the path "jumps" from points[i] to points[i+1] without
    /// interpolating between them. Used to represent disconnected high-symmetry
    /// segments (e.g. Γ-H-N | Γ-P for bcc). Empty for a fully connected path.
    var breaks: Set<Int> = []

    init(points: [KPoint], pointsPerSegment: Int = 20, breaks: Set<Int> = []) {
        self.points = points
        self.pointsPerSegment = pointsPerSegment
        self.breaks = breaks
    }
}

/// Provenance of a k-path: whether it was auto-generated (canonical) or
/// deliberately edited by the user. Drives regeneration behavior.
enum KPathProvenance: String, Codable {
    /// Canonical high-symmetry path; can be regenerated when the structure changes.
    case generated
    /// User-edited path; must be preserved when the structure changes.
    case userEdited
}

private func length(_ v: SIMD3<Float>) -> Float {
    let scale = max(abs(Double(v.x)), abs(Double(v.y)), abs(Double(v.z)))
    guard scale.isFinite, scale > 0 else { return 0 }
    let x = Double(v.x) / scale
    let y = Double(v.y) / scale
    let z = Double(v.z) / scale
    let value = scale * sqrt(x * x + y * y + z * z)
    return value.isFinite && value <= Double(Float.greatestFiniteMagnitude) ? Float(value) : .infinity
}
private func length2(_ v: SIMD3<Float>) -> Float { dot(v, v) }
