import Foundation
import simd

// Metric-aware presentation region for 2D band surfaces.
//
// A band surface is sampled over a parallelogram in reciprocal fractional
// coordinates and its four corners carry human-readable labels. The full
// reciprocal primitive cell (corners Gamma, Gamma+b1, Gamma+b2, Gamma+b1+b2)
// is a valid domain, but its corners are all Gamma-equivalent and therefore
// uninformative. For the common high-symmetry lattices this library instead
// selects the standard 2D Brillouin-zone quadrant / wedge:
//
//   square/rectangular:  Gamma - X - X - M  (quadrant of the square BZ)
//   hexagonal:           the full reciprocal primitive cell (its corners are
//                        all Gamma-equivalent, so they are labeled Gamma plus
//                        the reciprocal-lattice steps that separate them)
//
// The hexagon Brillouin zone's irreducible wedge Gamma-M-K-M' is NOT a
// parallelogram, and band surfaces are defined over a parallelogram patch, so
// the full cell (a parallelogram under b1, b2) is the natural hexagonal
// domain; its interior M/K special points are not parallelogram corners.
//
// The classification is purely metric (in-plane reciprocal vector lengths and
// the angle between them); no spglib analysis is required, so it works for
// band-only inputs such as BXSF files that carry no atom list.

/// Metric-aware band-surface region derivation.
enum BandSurfaceRegion {

    /// Derive a presentation region for a 2D Brillouin zone from a real-space
    /// cell. Returns three parallelogram corners in fractional coordinates
    /// (p0, p1, p2; the fourth corner is p0 + (p1-p0) + (p2-p0)) plus exactly
    /// four corner labels. Returns nil for oblique/triclinic in-plane metrics,
    /// where the caller falls back to the full reciprocal primitive cell.
    static func presentationRegion(for cell: Cell) -> (region: [SIMD3<Float>], labels: [String])? {
        let rv = cell.reciprocalVectors
        let all = [rv.a, rv.b, rv.c]
        guard all.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return nil
        }
        // The two longest reciprocal vectors span the 2D BZ plane; the short
        // one is the vacuum direction of a slab cell.
        let order = all.indices.sorted { simd_length_squared(all[$0]) > simd_length_squared(all[$1]) }
        let b1 = all[order[0]]
        let b2 = all[order[1]]
        let l1 = simd_length(b1)
        let l2 = simd_length(b2)
        guard l1 > 1e-6, l2 > 1e-6 else { return nil }
        let cosAngle = simd_dot(b1, b2) / (l1 * l2)
        let equal = abs(l1 - l2) <= 1e-3 * max(l1, l2)

        let gamma = SIMD3<Float>(0, 0, 0)
        if abs(cosAngle) < 1e-3 {
            // Square (equal lengths) or rectangular (unequal lengths): the
            // quadrant Gamma-X-M is the standard irreducible representation
            // of the Brillouin zone of a 2D square/rectangular lattice.
            return (region: [gamma,
                             SIMD3<Float>(0.5, 0, 0),
                             SIMD3<Float>(0, 0.5, 0)],
                    labels: ["Γ", "X", "Y", "M"])
        }
        if equal && abs(abs(cosAngle) - 0.5) < 1e-3 {
            // Hexagonal: the in-plane primitive reciprocal basis is separated
            // by 60 degrees. Use the full reciprocal primitive cell; the
            // edge midpoints are the two M points (M at (1/2,0,0), M' at
            // (0,1/2,0)) and K = (1/3,2/3,0) lies inside the cell. The
            // corners are all Gamma-equivalent, so the labels distinguish the
            // reciprocal-lattice steps that separate them.
            return (region: [gamma,
                             SIMD3<Float>(1, 0, 0),
                             SIMD3<Float>(0, 1, 0)],
                    labels: ["Γ", "Γ+b₁", "Γ+b₂", "Γ+b₁+b₂"])
        }
        return nil
    }
}
