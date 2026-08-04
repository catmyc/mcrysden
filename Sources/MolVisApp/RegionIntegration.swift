import Foundation
import simd

// MARK: - Region shape

/// The shape of an integration region. A `box` is axis-aligned in world space; a
/// `sphere` is isotropic around `center`. A UI agent binds a shape picker to the
/// cases of this enum.
enum RegionShape: String, Codable, CaseIterable {
    case box
    case sphere

    var displayName: String {
        switch self {
        case .box: return "Box"
        case .sphere: return "Sphere"
        }
    }
}

// MARK: - Integration region

/// An axis-aligned (box) or isotropic (sphere) region in world (Cartesian, Å)
/// space. A UI agent binds sliders/pickers to `center`, `halfExtents`, and
/// `radius`; `contains`, `volume`, and `isValid` drive the integration.
struct IntegrationRegion: Codable, Equatable {
    var shape: RegionShape = .box
    var center: SIMD3<Float> = .zero
    var halfExtents: SIMD3<Float> = SIMD3<Float>(2, 2, 2)
    var radius: Float = 2

    /// True iff `p` is inside the region. Any non-finite component yields false.
    func contains(_ p: SIMD3<Float>) -> Bool {
        guard p.x.isFinite && p.y.isFinite && p.z.isFinite else { return false }
        switch shape {
        case .box:
            let d = p - center
            return abs(d.x) <= halfExtents.x
                && abs(d.y) <= halfExtents.y
                && abs(d.z) <= halfExtents.z
        case .sphere:
            let d = p - center
            return simd_dot(d, d) <= radius * radius
        }
    }

    /// World-space axis-aligned bounding box of the region.
    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>) {
        switch shape {
        case .box:
            return (center - halfExtents, center + halfExtents)
        case .sphere:
            let r = SIMD3<Float>(repeating: radius)
            return (center - r, center + r)
        }
    }

    /// Geometric volume in Å³. Returns 0 for degenerate / non-finite geometry.
    var volume: Float {
        switch shape {
        case .box:
            let hx = halfExtents.x, hy = halfExtents.y, hz = halfExtents.z
            guard hx.isFinite && hy.isFinite && hz.isFinite,
                  hx > 0, hy > 0, hz > 0 else { return 0 }
            return 8 * abs(hx * hy * hz)
        case .sphere:
            guard radius.isFinite, radius > 0 else { return 0 }
            return (4.0 / 3.0) * .pi * radius * radius * radius
        }
    }

    /// True iff the geometry is finite and the volume is strictly positive.
    var isValid: Bool { volume > 0 }
}

// MARK: - Integration result

/// The outcome of integrating a scalar field over a region. `summary` is a
/// compact, deterministic, single-line readout for display.
struct RegionIntegrationResult: Equatable {
    let integral: Float
    let mean: Float
    let volume: Float
    let sampleCount: Int
    let minValue: Float
    let maxValue: Float

    var summary: String {
        "∫ = \(Self.formatCompact(integral)) field·Å³ · mean \(Self.formatCompact(mean)) · vol \(Self.formatCompact(volume)) Å³ · \(Self.formatCount(sampleCount)) samples"
    }

    /// Compact scientific notation with 3 fractional digits (e.g. "1.234e+00").
    private static func formatCompact(_ v: Float) -> String {
        guard v.isFinite else { return "nan" }
        return String(format: "%.3e", v)
    }

    /// Comma-grouped decimal (e.g. 12345 -> "12,345").
    private static func formatCount(_ n: Int) -> String {
        let s = String(n)
        var result = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { result.append(",") }
            result.append(ch)
        }
        return result
    }
}

// MARK: - Integration engine

/// Integrates a `ScalarField` over an `IntegrationRegion` by uniform lattice
/// sampling with trilinear interpolation.
enum RegionIntegration {

    // SAMPLING RULE
    // -------------
    // A uniform 3D lattice is generated over the region's world-space bounding
    // box. Per-axis lattice counts are proportional to the bbox extents (so the
    // sampling is isotropic in world space) and the total point count is bounded
    // by `maxSamples` (clamped to 1...16,000,000). At least 2 samples per axis
    // are used whenever the extent allows. Each lattice point is skipped if it
    // falls outside the region (`contains == false`) or outside the field's
    // world bounding box; surviving points are evaluated by trilinear
    // interpolation of the grid values (fractional coords clamped to [0, 1]).
    // The mean is the average over sampled points; the integral is
    // `mean * region.volume` (points outside the region contribute nothing
    // because they are skipped). minValue/maxValue are the extrema over sampled
    // points.

    /// Integrate `field` over `region`. Returns nil for a malformed field,
    /// invalid region, or when no lattice point lands inside the region.
    static func integrate(field: ScalarField,
                          region: IntegrationRegion,
                          maxSamples: Int = 4_000_000) -> RegionIntegrationResult? {
        let maxS = max(1, min(16_000_000, maxSamples))

        // --- Field validation -------------------------------------------------
        guard field.nx >= 2, field.ny >= 2, field.nz >= 2,
              field.vec.count >= 3,
              field.origin.x.isFinite, field.origin.y.isFinite, field.origin.z.isFinite,
              field.vec[0].x.isFinite, field.vec[0].y.isFinite, field.vec[0].z.isFinite,
              field.vec[1].x.isFinite, field.vec[1].y.isFinite, field.vec[1].z.isFinite,
              field.vec[2].x.isFinite, field.vec[2].y.isFinite, field.vec[2].z.isFinite,
              field.values.allSatisfy(\.isFinite) else { return nil }

        // Overflow-checked shape consistency: a declared nx*ny*nz that overflows
        // Int64, or that disagrees with the buffer count, is malformed.
        let count64 = Int64(field.nx)
            .multipliedReportingOverflow(by: Int64(field.ny))
        guard !count64.overflow else { return nil }
        let count64b = count64.partialValue
            .multipliedReportingOverflow(by: Int64(field.nz))
        guard !count64b.overflow else { return nil }
        guard count64b.partialValue == Int64(field.values.count) else { return nil }

        // --- Region validation ------------------------------------------------
        guard region.isValid else { return nil }

        // --- Field world bounding box ----------------------------------------
        let fBBox = worldBoundingBox(field: field)
        guard fBBox.min.x.isFinite else { return nil }

        // --- Lattice sizing ---------------------------------------------------
        let rBox = region.boundingBox
        let ex = rBox.max.x - rBox.min.x
        let ey = rBox.max.y - rBox.min.y
        let ez = rBox.max.z - rBox.min.z
        guard ex > 0, ey > 0, ez > 0 else { return nil }

        // Per-axis counts are proportional to the bbox extents (isotropic in world
        // space) and bounded by maxS. The sizing is computed in Double to avoid
        // Float underflow/overflow (e.g. tiny extents make ex*ey*ez underflow Float
        // to 0, then `Float(maxS)/0` = +inf and `Int((inf*extent).rounded())`
        // TRAPS). Each count is capped at `maxPerAxis` before any product so
        // intermediate products never overflow Int64 and extreme aspect ratios
        // (e.g. 1e-30 x 1 x 1) cannot explode the lattice. A single-shot
        // proportional rescale with a guaranteed cube-root fallback replaces the
        // naive one-at-a-time decrement loop, which would take O(product)
        // iterations for skewed regions. Never loops; never traps.
        let maxPerAxis = Int64(100_000)
        let maxS64 = Int64(maxS)
        let volD = Double(ex) * Double(ey) * Double(ez)
        guard volD.isFinite, volD > 0 else { return nil }

        let kD = pow(Double(maxS) / volD, 1.0 / 3.0)
        guard kD.isFinite, kD > 0 else { return nil }

        func latticeCount(_ extent: Float) -> Int64 {
            let capped = min(kD * Double(extent), Double(maxPerAxis))
            return max(2, Int64(capped.rounded()))
        }

        var nx = latticeCount(ex)
        var ny = latticeCount(ey)
        var nz = latticeCount(ez)

        // Single-shot rescale if the product is over budget. The product is
        // computed in Int64 (the per-axis cap keeps it well under Int64.max).
        if nx * ny * nz > maxS64 {
            let scale = pow(Double(maxS) / Double(nx * ny * nz), 1.0 / 3.0)
            func rescale(_ n: Int64) -> Int64 {
                let capped = min(Double(n) * scale, Double(maxPerAxis))
                return max(2, Int64(capped.rounded()))
            }
            nx = rescale(nx)
            ny = rescale(ny)
            nz = rescale(nz)
            // Guaranteed within budget: equal cube-root split.
            if nx * ny * nz > maxS64 {
                var c = max(2, Int64(pow(Double(maxS), 1.0 / 3.0)))
                while c > 2 && c * c * c > maxS64 { c -= 1 }
                nx = c; ny = c; nz = c
            }
        }

        // Bounded by maxPerAxis (100_000), well within Int range.
        let inx = Int(nx)
        let iny = Int(ny)
        let inz = Int(nz)

        // --- Grid transform (world -> fractional) -----------------------------
        let a = field.vec[0], b = field.vec[1], c = field.vec[2]
        let det = simd_dot(a, simd_cross(b, c))
        guard abs(det) > 1e-12 else { return nil }

        let eps: Float = 1e-3
        let fMin = fBBox.min, fMax = fBBox.max

        var sum: Double = 0
        var minV: Float = .infinity
        var maxV: Float = -.infinity
        var count = 0

        for iiz in 0..<inz {
            let fz = inz > 1 ? Float(iiz) / Float(inz - 1) : 0
            let pz = rBox.min.z + fz * ez
            for iiy in 0..<iny {
                let fy = iny > 1 ? Float(iiy) / Float(iny - 1) : 0
                let py = rBox.min.y + fy * ey
                for iix in 0..<inx {
                    let fx = inx > 1 ? Float(iix) / Float(inx - 1) : 0
                    let px = rBox.min.x + fx * ex
                    let p = SIMD3<Float>(px, py, pz)

                    // Skip if outside the field's world bbox.
                    if p.x < fMin.x - eps || p.x > fMax.x + eps ||
                       p.y < fMin.y - eps || p.y > fMax.y + eps ||
                       p.z < fMin.z - eps || p.z > fMax.z + eps { continue }

                    // Skip if outside the region.
                    guard region.contains(p) else { continue }

                    let val = trilinear(field: field, world: p, a: a, b: b, c: c, det: det)
                    sum += Double(val)
                    if val < minV { minV = val }
                    if val > maxV { maxV = val }
                    count += 1
                }
            }
        }

        guard count > 0 else { return nil }

        let mean = Float(sum / Double(count))
        return RegionIntegrationResult(
            integral: mean * region.volume,
            mean: mean,
            volume: region.volume,
            sampleCount: count,
            minValue: minV,
            maxValue: maxV
        )
    }

    /// Integrate over the field's entire world bounding box.
    static func integrateAll(field: ScalarField,
                             maxSamples: Int = 4_000_000) -> RegionIntegrationResult? {
        let bbox = worldBoundingBox(field: field)
        let c = 0.5 * (bbox.min + bbox.max)
        let h = 0.5 * (bbox.max - bbox.min)
        let region = IntegrationRegion(shape: .box,
                                       center: SIMD3<Float>(c.x, c.y, c.z),
                                       halfExtents: SIMD3<Float>(h.x, h.y, h.z),
                                       radius: 2)
        return integrate(field: field, region: region, maxSamples: maxSamples)
    }

    // MARK: - Private helpers

    /// World-space axis-aligned bounding box of the field (8 grid corners).
    private static func worldBoundingBox(field: ScalarField) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        var mn = SIMD3<Float>(repeating: .infinity)
        var mx = SIMD3<Float>(repeating: -.infinity)
        for iz in 0...1 {
            for iy in 0...1 {
                for ix in 0...1 {
                    let wp = field.worldPosition(ix * (field.nx - 1),
                                                 iy * (field.ny - 1),
                                                 iz * (field.nz - 1))
                    mn = min(mn, wp)
                    mx = max(mx, wp)
                }
            }
        }
        return (mn, mx)
    }

    /// Evaluate the field at a world position by inverting the grid transform to
    /// fractional coords and trilinear-interpolating the 8 surrounding nodes.
    private static func trilinear(field: ScalarField,
                                  world: SIMD3<Float>,
                                  a: SIMD3<Float>,
                                  b: SIMD3<Float>,
                                  c: SIMD3<Float>,
                                  det: Float) -> Float {
        let d = world - field.origin
        let fx = simd_dot(simd_cross(b, c), d) / det
        let fy = simd_dot(simd_cross(c, a), d) / det
        let fz = simd_dot(simd_cross(a, b), d) / det

        let gx = max(0, min(1, fx)) * Float(field.nx - 1)
        let gy = max(0, min(1, fy)) * Float(field.ny - 1)
        let gz = max(0, min(1, fz)) * Float(field.nz - 1)

        let ix = min(field.nx - 2, max(0, Int(gx)))
        let iy = min(field.ny - 2, max(0, Int(gy)))
        let iz = min(field.nz - 2, max(0, Int(gz)))

        let tx = gx - Float(ix)
        let ty = gy - Float(iy)
        let tz = gz - Float(iz)

        let c000 = field.value(ix,     iy,     iz)
        let c100 = field.value(ix + 1, iy,     iz)
        let c010 = field.value(ix,     iy + 1, iz)
        let c110 = field.value(ix + 1, iy + 1, iz)
        let c001 = field.value(ix,     iy,     iz + 1)
        let c101 = field.value(ix + 1, iy,     iz + 1)
        let c011 = field.value(ix,     iy + 1, iz + 1)
        let c111 = field.value(ix + 1, iy + 1, iz + 1)

        let c00 = c000 * (1 - tx) + c100 * tx
        let c10 = c010 * (1 - tx) + c110 * tx
        let c01 = c001 * (1 - tx) + c101 * tx
        let c11 = c011 * (1 - tx) + c111 * tx
        let c0 = c00 * (1 - ty) + c10 * ty
        let c1 = c01 * (1 - ty) + c11 * ty
        return c0 * (1 - tz) + c1 * tz
    }
}
