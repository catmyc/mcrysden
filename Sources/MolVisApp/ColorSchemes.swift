import Foundation
import simd

/// Per-atom colors for the non-elemental color schemes. The dominant color
/// source stays `ElementTable` + `scene.elementOverrides`; these helpers
/// compute auxiliary per-atom values the renderer needs once per scene:
///  - coordination numbers (for `.coordination`),
///  - slab fraction (position between slab planeA and planeB, 0…1),
///  - signed distance to the slab planeA (for `_distanceProportional`).
///
/// Contract (fixed):
///  - Inputs are the DISPLAYED atoms (`scene.atoms`) and the display cell.
///  - Caps: 64 000 atoms for coordination, 64 000 for slab maps; beyond cap the
///    function returns nil rather than blocking or trapping.
///  - Values are deterministic given the same scene (sorted neighbor search).
///  - `coordinationNumbers(scene:)` and `slabMetrics(scene:)` are thin,
///    allocation-free-in-loop helpers usable by the renderer per instance.
enum AtomSchemeMetrics {
    static let cap = 64_000

    /// Coordination number per displayed atom (periodic-image aware, using the
    /// covalent-distance rule), or nil over the cap.
    static func coordinationNumbers(scene: Scene) -> [Int]? {
        guard scene.atoms.count <= cap else { return nil }
        let periodicDim = scene.cell != nil ? scene.periodicDim : 0
        // radiusScale 1.0 ⇒ cutoff is exactly the sum of the two covalent radii.
        guard let analysis = CoordinationAnalyzer.analyze(atoms: scene.atoms,
                                                           cell: scene.cell,
                                                           periodicDim: periodicDim,
                                                           radiusScale: 1.0) else {
            return nil
        }
        return analysis.coordinationNumbers
    }

    struct SlabPoint {
        var fraction: Float   // 0 on planeA … 1 on planeB (clamped)
        var distance: Float   // signed distance to planeA in Å
    }
    /// Per-atom slab fraction + plane distance, or nil when no slab is active.
    static func slabMetrics(scene: Scene) -> [SlabPoint]? {
        guard scene.atoms.count <= cap else { return nil }
        guard let slab = scene.slab, let cell = scene.cell else { return nil }
        guard let planeA = SlicePlane.fromFractional(h: slab.planeA.h, k: slab.planeA.k, l: slab.planeA.l,
                                                     distance: slab.planeA.distance, cell: cell),
              let planeB = SlicePlane.fromFractional(h: slab.planeB.h, k: slab.planeB.k, l: slab.planeB.l,
                                                     distance: slab.planeB.distance, cell: cell) else {
            return nil
        }
        var out: [SlabPoint] = []
        out.reserveCapacity(scene.atoms.count)
        for atom in scene.atoms {
            let signedA = simd_dot(atom.coord - planeA.origin, planeA.normal)
            let signedB = simd_dot(atom.coord - planeB.origin, planeB.normal)
            // Geometrically correct slab parameterization: fraction rises from 0
            // at plane A to 1 at plane B. The denominator is the signed
            // thickness (signedA - signedB), positive for points between the
            // planes; degenerate slabs (≈0 thickness) collapse to fraction 0.
            let thickness = signedA - signedB
            let fraction = abs(thickness) > 1e-6 ? simd_clamp(signedA / thickness, 0, 1) : 0
            out.append(SlabPoint(fraction: fraction, distance: signedA))
        }
        return out
    }

    /// Static rainbow ramp used by slab-fraction and coordination schemes.
    static func ramp(_ t: Float) -> SIMD3<Float> {
        let clamped = max(0, min(1, t))
        // Blue → cyan → green → yellow → red (deterministic HSL sweep).
        let hue = (1.0 - clamped) * 240.0
        return hsvColor(hue: hue, saturation: 0.85, value: 1.0)
    }

    /// Deterministic HSV → RGB (hue in degrees; no Foundation dependency).
    static func hsvColor(hue: Float, saturation: Float, value: Float) -> SIMD3<Float> {
        let h = (hue.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0) / 60.0
        let c = value * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2.0) - 1))
        let m = value - c
        let rgb: SIMD3<Float>
        switch Int(h) % 6 {
        case 0: rgb = SIMD3(c, x, 0)
        case 1: rgb = SIMD3(x, c, 0)
        case 2: rgb = SIMD3(0, c, x)
        case 3: rgb = SIMD3(0, x, c)
        case 4: rgb = SIMD3(x, 0, c)
        default: rgb = SIMD3(c, 0, x)
        }
        return rgb + SIMD3(repeating: m)
    }

    /// Resolve an element's display color with the scene's per-element overrides
    /// applied (override color wins over the CPK table). Callers that already
    /// hold the scene should use this instead of `ElementTable.color` directly.
    static func elementColor(z: Int, overrides: [Int: ElementOverride]) -> SIMD3<Float> {
        if let o = overrides[z], let hex = o.colorHex {
            return ColorUtil.hexColor(hex) ?? ElementTable.color(z)
        }
        return ElementTable.color(z)
    }

    /// Resolve covalent radius with per-element override support.
    static func elementCovalentRadius(z: Int, overrides: [Int: ElementOverride]) -> Float {
        if let o = overrides[z], let r = o.covalentRadius { return max(0.05, r) }
        return ElementTable.covalentRadius(z)
    }

    /// Resolve the van der Waals radius with per-element override support.
    static func elementVdwRadius(z: Int, overrides: [Int: ElementOverride]) -> Float {
        if let o = overrides[z], let r = o.vdwRadius { return max(0.05, r) }
        return ElementTable.vdwRadius(z)
    }
}

enum ColorUtil {
    /// Parse a #RRGGBB hex string (same convention Scene.clearColor uses);
    /// nil when malformed.
    static func hexColor(_ hex: String) -> SIMD3<Float>? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return SIMD3<Float>(Float((v >> 16) & 0xFF) / 255.0,
                            Float((v >> 8) & 0xFF) / 255.0,
                            Float(v & 0xFF) / 255.0)
    }
}
