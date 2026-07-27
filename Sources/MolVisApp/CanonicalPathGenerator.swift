import Foundation
import simd

// HPKOT/SeekPath 2.1-compatible canonical high-symmetry k-paths for all extended
// Bravais variants.
//
// This file provides the CanonicalPathGenerator API used by the app. The actual
// SeekPath 2.1.0 algorithm and data live in HPKOT.swift (transcribed from
// seekpath/hpkot/band_path_data/ and seekpath/hpkot/__init__.py).
//
// Reference: Y. Hinuma, G. Pizzi, Y. Kumagai, F. Oba, I. Tanaka,
// "Band structure diagram paths based on crystallography",
// Computational Materials Science 128 (2017) 140-148.
//
// All paths are generated in the PRIMITIVE reciprocal fractional basis, then
// mapped to the INPUT reciprocal fractional basis using the transformation
// chain: primitive fractional -> conventional fractional -> Cartesian -> input
// fractional (see HPKOTGenerator.mapToInputReciprocal).

/// A labeled special k-point in the canonical path.
struct CanonicalKPoint {
    var frac: SIMD3<Float>
    var label: String
    init(_ frac: SIMD3<Float>, _ label: String) { self.frac = frac; self.label = label }
}

/// A canonical high-symmetry k-path: an ordered list of special points and the
/// indices where a disconnected segment begins (the break follows the point at
/// that index, i.e. no segment joins points[i] and points[i+1]).
struct CanonicalPath {
    var points: [CanonicalKPoint]
    /// Indices i such that there is NO segment between points[i] and points[i+1].
    var breaks: Set<Int>

    init(points: [CanonicalKPoint], breaks: Set<Int> = []) {
        self.points = points
        self.breaks = breaks
    }

    /// Convert to editor/export KPoints (drops break metadata; use `breaks` for that).
    var kPoints: [KPoint] { points.map { KPoint($0.frac, $0.label) } }
}

/// Generate HPKOT/SeekPath canonical high-symmetry k-paths for every extended
/// Bravais variant. Paths are returned in the primitive reciprocal fractional
/// basis; callers use `mapToInputReciprocal` to transform to the input cell.
enum CanonicalPathGenerator {

    /// Map a SeekPath ASCII label to the display label used by the editor.
    /// GAMMA → Γ; underscore subscripts (X_1, X_2, ...) are preserved as-is.
    static func displayLabel(_ seekpathLabel: String) -> String {
        if seekpathLabel == "GAMMA" { return "Γ" }
        return seekpathLabel
    }

    /// Generate the canonical high-symmetry path for the given symmetry.
    /// Returns the path in the PRIMITIVE reciprocal fractional basis.
    /// The variant is selected from the space group + standardized cell parameters
    /// following the SeekPath 2.1.0 rules.
    static func generate(for symmetry: CrystalSymmetry) -> CanonicalPath {
        guard let result = HPKOTGenerator.generate(for: symmetry) else {
            return CanonicalPath(points: [], breaks: [])
        }
        let points = result.points.map { hp in
            CanonicalKPoint(hp.frac, displayLabel(hp.label))
        }
        return CanonicalPath(points: points, breaks: Set(result.breaks))
    }

    /// Generate the canonical path and return it along with the
    /// input-oriented primitive reciprocal basis needed for correct input-cell
    /// mapping (important for aP lattices and rotated cells where the
    /// primitive reciprocal basis differs from the detected primitive lattice).
    static func generateWithBasis(for symmetry: CrystalSymmetry) -> (path: CanonicalPath, primRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>))? {
        guard let result = HPKOTGenerator.generate(for: symmetry) else {
            return nil
        }
        let points = result.points.map { hp in
            CanonicalKPoint(hp.frac, displayLabel(hp.label))
        }
        return (CanonicalPath(points: points, breaks: Set(result.breaks)), result.inputOrientedPrimRecip)
    }

    /// Compute the structure signature for k-path provenance tracking.
    /// Format: "spaceGroup|a|b|c|alpha|beta|gamma" from the standardized
    /// lattice (angles in degrees). Returns nil when symmetry is unavailable.
    static func structureSignature(for symmetry: CrystalSymmetry?) -> String? {
        guard let symmetry = symmetry else { return nil }
        let params = standardizedParams(symmetry)
        func deg(_ r: Double) -> Double { r * 180.0 / .pi }
        return String(format: "%d|%.6f|%.6f|%.6f|%.4f|%.4f|%.4f",
                      symmetry.spaceGroupNumber,
                      params.a, params.b, params.c,
                      deg(params.alpha), deg(params.beta), deg(params.gamma))
    }

    /// Map a canonical path from the primitive reciprocal basis to the input-cell
    /// reciprocal fractional basis. Preserves break metadata.
    /// Uses the input-oriented primitive reciprocal basis from
    /// `generateWithBasis` for correct aP lattice and rotated-cell mapping.
    static func mapToInputReciprocal(_ path: CanonicalPath,
                                     symmetry: CrystalSymmetry,
                                     inputCell: Cell) -> CanonicalPath {
        guard let basis = generateWithBasis(for: symmetry) else {
            return path
        }
        return mapToInputReciprocal(path, primRecip: basis.primRecip, inputCell: inputCell)
    }

    /// Map a canonical path from the primitive reciprocal basis to the input-cell
    /// reciprocal fractional basis using an explicit primitive reciprocal basis.
    /// Preserves break metadata. The basis must be the one returned by
    /// `generateWithBasis` (inputOrientedPrimRecip) for correct aP lattice
    /// and rotated-cell mapping.
    static func mapToInputReciprocal(_ path: CanonicalPath,
                                     primRecip: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>),
                                     inputCell: Cell) -> CanonicalPath {
        let hpkotPoints = path.points.map { HPKOTPath(label: $0.label, frac: $0.frac) }
        let result = HPKOTGenerator.mapToInputReciprocal(hpkotPoints, breaks: Array(path.breaks),
                                                          inputOrientedPrimRecip: primRecip, inputCell: inputCell)
        let mapped = result.points.map { hp in
            CanonicalKPoint(hp.frac, hp.label)
        }
        return CanonicalPath(points: mapped, breaks: Set(result.breaks))
    }

    /// Compute the standardized lattice parameters (a, b, c, alpha, beta, gamma).
    private static func standardizedParams(_ symmetry: CrystalSymmetry) -> (a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double) {
        let L = symmetry.standardizedLattice
        let va = SIMD3(L[0, 0], L[0, 1], L[0, 2])
        let vb = SIMD3(L[1, 0], L[1, 1], L[1, 2])
        let vc = SIMD3(L[2, 0], L[2, 1], L[2, 2])
        let a = sqrt(va.x*va.x + va.y*va.y + va.z*va.z)
        let b = sqrt(vb.x*vb.x + vb.y*vb.y + vb.z*vb.z)
        let c = sqrt(vc.x*vc.x + vc.y*vc.y + vc.z*vc.z)
        let alpha = angle(vb, vc)
        let beta = angle(va, vc)
        let gamma = angle(va, vb)
        return (a, b, c, alpha, beta, gamma)
    }

    private static func angle(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> Double {
        let cosA = min(1, max(-1, dot(u, v) / (max(1e-12, length(u)) * max(1e-12, length(v)))))
        return acos(cosA)
    }
}

private func length(_ v: SIMD3<Double>) -> Double { sqrt(dot(v, v)) }
