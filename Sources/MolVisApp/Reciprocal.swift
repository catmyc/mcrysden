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
    /// Conventional reciprocal lattice vectors (including 2pi) from the DIRECT
    /// conventional cell: a* = 2pi (b x c) / volume, cyclic, volume = a.(bxc).
    /// Correct for primitive conventional cells; for centered cells (fcc/bcc)
    /// these form a SUPERSET of the true reciprocal lattice — use
    /// `primitiveReciprocal` (which needs the atomic centering) for the BZ.
    var reciprocalVectors: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        // Reciprocal basis as columns of v.inverse (NOT v.inverse.transpose).
        // For the physics convention a_i · a*_j = 2π δ_ij, the reciprocal
        // vectors are the columns of the inverse of the matrix whose rows are
        // the direct vectors. The old `.transpose` only agreed for orthogonal
        // (cubic) cells; skew cells gave b·a* ≠ 0.
        let v = simd_float3x3(rows: [a, b, c])
        let vol = v.determinant
        guard abs(vol) > 1e-12 else { return (.zero, .zero, .zero) }
        let inv = v.inverse
        let scale = Float(2.0 * Double.pi)
        return (a: inv.columns.0 * scale, b: inv.columns.1 * scale, c: inv.columns.2 * scale)
    }

    /// Build the direct cell vectors from lattice parameters (a,b,c in Å, angles
    /// alpha/beta/gamma in degrees). Standard convention: a along x, b in the xy
    /// plane, c completing the right-handed system.
    static func fromLattice(a: Float, b: Float, c: Float,
                            alpha: Float, beta: Float, gamma: Float) -> Cell {
        let ca = cos(alpha * .pi / 180), cb = cos(beta * .pi / 180), cg = cos(gamma * .pi / 180)
        let sa = sin(alpha * .pi / 180)
        let aVec = SIMD3<Float>(a, 0, 0)
        let bVec = SIMD3<Float>(b * cg, b * sa, 0)
        let cX = c * cb
        let cY = c * (ca - cb * cg) / sa
        let cZ = sqrt(max(0, c * c - cX * cX - cY * cY))
        let cVec = SIMD3<Float>(cX, cY, cZ)
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

/// Reduce a conventional cell to its primitive direct basis using the fractional
/// atomic offsets (the "basis") that reveal centering. Returns the conventional
/// basis unchanged if only the trivial (0,0,0) offset is present.
enum Lattice {
    /// Fractional coordinates of Cartesian `atoms` in the conventional cell.
    static func fractional(_ atoms: [SIMD3<Float>], cell: Cell) -> [SIMD3<Float>] {
        // Fractional f solves p = f_a*a + f_b*b + f_c*c, i.e. basis vectors as
        // COLUMNS (not rows) of the inverted matrix. Rows would only be correct
        // for orthogonal (cubic) cells; this is right for any lattice.
        let m = simd_float3x3(columns: (cell.a, cell.b, cell.c))
        guard abs(m.determinant) > 1e-9 else {
            return atoms.map { _ in SIMD3<Float>.zero }
        }
        return atoms.map { m.inverse * $0 }
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
        let fracs = fractional(atoms.map { $0.coord }, cell: cell).map(vfrac)
        let syms = atoms.map { $0.atomicNumber }
        let eps: Float = 1e-2
        // nearest offset modulo 1, wrapped into [-0.5, 0.5).
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            func d(_ x: Float) -> Float { var z = x - floor(x); if z > 0.5 { z -= 1 }; return z }
            return abs(d(a.x - b.x)) < eps && abs(d(a.y - b.y)) < eps && abs(d(a.z - b.z)) < eps
        }
        func isCentering(_ off: SIMD3<Float>) -> Bool {
            for (i, f) in fracs.enumerated() {
                let t = vfrac(f + off)
                guard fracs.enumerated().contains(where: { (j, g) in syms[j] == syms[i] && near(g, t) }) else { return false }
            }
            return true
        }
        if isCentering(SIMD3(0.5, 0.5, 0.5)) { return .body }
        if [SIMD3(0.5,0.5,0), SIMD3(0.5,0,0.5), SIMD3(0,0.5,0.5)].allSatisfy(isCentering) { return .face }
        return .primitive
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
}

private func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }
private func length2(_ v: SIMD3<Float>) -> Float { dot(v, v) }
