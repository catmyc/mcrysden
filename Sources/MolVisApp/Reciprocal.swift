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
        let v = simd_float3x3(rows: [a, b, c])
        let vol = v.determinant
        guard abs(vol) > 1e-12 else { return (.zero, .zero, .zero) }
        let invT = v.inverse.transpose
        let scale = Float(2.0 * Double.pi)
        return (a: invT.columns.0 * scale, b: invT.columns.1 * scale, c: invT.columns.2 * scale)
    }
}

// Centered-lattice handling.
//
// A conventional cell a,b,c may be centered (fcc/bcc): the true direct lattice
// points are NOT just integer combos of a,b,c — there are fractional offsets
// (e.g. fcc: (0,½,½),(½,0,½),(½,½,0)) carried by the atoms. We recover the
// primitive basis by shortest-vector reduction over (int combo + offset), then
// the primitive reciprocal generates the correct BZ G-star.

/// Reduce a conventional cell to its primitive direct basis using the fractional
/// atomic offsets (the "basis") that reveal centering. Returns the conventional
/// basis unchanged if only the trivial (0,0,0) offset is present.
enum Lattice {
    /// Fractional coordinates of Cartesian `atoms` in the conventional cell.
    static func fractional(_ atoms: [SIMD3<Float>], cell: Cell) -> [SIMD3<Float>] {
        let inv = simd_float3x3(rows: [cell.a, cell.b, cell.c]).inverse
        guard abs(simd_float3x3(rows: [cell.a, cell.b, cell.c]).determinant) > 1e-9 else {
            return atoms.map { _ in SIMD3<Float>.zero }
        }
        return atoms.map { inv * $0 }
    }

    /// Unique fractional offsets (mod 1, excluding ~0) that describe the basis.
    static func basisOffsets(_ atoms: [SIMD3<Float>], cell: Cell) -> [SIMD3<Float>] {
        let eps: Float = 1e-2
        var offs: [SIMD3<Float>] = []
        for f in fractional(atoms, cell: cell) {
            var g = f
            g.x -= g.x.rounded(); g.y -= g.y.rounded(); g.z -= g.z.rounded()
            if length(g) < eps { continue }
            if !offs.contains(where: { length($0 - g) < eps }) { offs.append(g) }
        }
        return offs
    }

    /// Primitive direct basis found by shortest-vector reduction over lattice
    /// points = (int combo of a,b,c) + offset, for each fractional offset.
    static func primitiveBasis(cell: Cell, offsets: [SIMD3<Float>]) -> (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let a = cell.a, b = cell.b, c = cell.c
        var cand: [SIMD3<Float>] = []
        for i in -2...2 { for j in -2...2 { for k in -2...2 {
            let base = Float(i)*a + Float(j)*b + Float(k)*c
            cand.append(base)                                 // offset 0
            for o in offsets {
                // fractional offset in Cartesian: o.x*a + o.y*b + o.z*c
                cand.append(base + o.x*a + o.y*b + o.z*c)
            }
        }}}
        cand = cand.filter { length($0) > 1e-3 }
        cand.sort { length2($0) < length2($1) }
        // Greedy shortest non-coplanar triple.
        var picked: [SIMD3<Float>] = []
        for v in cand {
            picked.append(v)
            if picked.count == 3 {
                if abs(simd_float3x3(rows: picked).determinant) > 1e-3 { break }
                picked.removeLast()
            }
        }
        if picked.count != 3 { return (a, b, c) }
        return (picked[0], picked[1], picked[2])
    }

    /// Reciprocal vectors (2pi convention) of the primitive direct basis from
    /// the atomic centering — the correct generator for the BZ G-star.
    static func primitiveReciprocal(cell: Cell, atoms: [SIMD3<Float>]) -> (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let offs = basisOffsets(atoms, cell: cell)
        let p = primitiveBasis(cell: cell, offsets: offs)
        return Cell(a: p.a, b: p.b, c: p.c).reciprocalVectors
    }
}

/// A k-point in fractional (crystal) coordinates, with an optional label
/// (Gamma/X/K/L/W...).
struct KPoint {
    var frac: SIMD3<Float>
    var label: String
    init(_ frac: SIMD3<Float>, _ label: String = "") { self.frac = frac; self.label = label }
}

/// A k-path: an ordered list of special k-points with per-segment interpolation.
struct KPath {
    var points: [KPoint]
    // Number of interpolated points per segment (distance-weighted rounding).
    var pointsPerSegment: Int = 20
}

private func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }
private func length2(_ v: SIMD3<Float>) -> Float { dot(v, v) }
