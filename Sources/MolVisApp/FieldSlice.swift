import Foundation
import simd

// Field-slice sampling + triangle-clipping geometry.
//
// Two capabilities the volumetric-rendering feature needs:
//  1. Sample a `ScalarField` onto an arbitrary world-space plane, producing a
//     `SampledSlice` (a 2D grid a renderer can texture-map onto a quad).
//  2. Clip an IsoMesh-style packed triangle list against a plane, so the
//     isosurface can be sliced open and capped.

// MARK: - SlicePlane

/// A plane in world (Cartesian, Å) space defined by an `origin` point on the
/// plane and a unit `normal`. `isValid` is false when the normal is zero or
/// non-finite or the origin is non-finite.
struct SlicePlane: Codable, Equatable {
    var origin: SIMD3<Float>
    var normal: SIMD3<Float>

    init(origin: SIMD3<Float>, normal: SIMD3<Float>) {
        self.origin = origin
        let len = simd_length(normal)
        self.normal = len > 1e-12 ? normal / len : normal
    }

    /// Finite origin + non-zero finite normal.
    var isValid: Bool {
        origin.x.isFinite && origin.y.isFinite && origin.z.isFinite &&
        normal.x.isFinite && normal.y.isFinite && normal.z.isFinite &&
        simd_length(normal) > 1e-9
    }

    /// Build a `SlicePlane` from a fractional-plane (h,k,l)·f >= `distance`
    /// convention against the given unit cell.
    ///
    /// Derivation: a point with fractional coords f satisfies h·f = d. With
    /// f = A⁻¹ p (A = [a b c] as columns), this becomes (A⁻ᵀ h)·p = d. So the
    /// world-space normal is n_world = A⁻ᵀ (h,k,l), and the nearest point on
    /// the plane to the origin is p0 = n_world * d / |n_world|².
    ///
    /// Returns nil for a zero (h,k,l) or a singular cell (|det A| < 1e-6).
    static func fromFractional(h: Int, k: Int, l: Int, distance: Float, cell: Cell) -> SlicePlane? {
        let hkl = SIMD3<Float>(Float(h), Float(k), Float(l))
        if simd_length(hkl) < 1e-9 { return nil }

        // A = [a b c] as columns. A⁻ᵀ h = solution of Aᵀ x = hkl, i.e. x such that
        // a·x = h, b·x = k, c·x = l. Solve via Cramer's rule on Aᵀ.
        let a = cell.a, b = cell.b, c = cell.c
        // det(A) = a · (b × c)
        let det = simd_dot(a, simd_cross(b, c))
        guard abs(det) >= 1e-6 else { return nil }

        // Cramer's rule for Aᵀ x = hkl: x_i = det(Aᵀ with col i replaced by hkl) / det(Aᵀ)
        // det(Aᵀ) = det(A). Replacing column i of Aᵀ = replacing row i of A.
        // Row 0 of A is (a.x, b.x, c.x); replace with hkl → det = hkl.x*(b.y*c.z - c.y*b.z) - ...
        func detRow0(_ col1: SIMD3<Float>, _ col2: SIMD3<Float>) -> Float {
            return hkl.x * (col1.y * col2.z - col2.y * col1.z)
                 - col1.x * (hkl.y * col2.z - col2.y * hkl.z)
                 + col2.x * (hkl.y * col1.z - col1.y * hkl.z)
        }
        // For x: replace row 0 → use (b.y,b.z),(c.y,c.z) pairs
        let nx = detRow0(b, c) / det
        // For y: replace row 1 → (a.x,a.z),(c.x,c.z) with hkl
        func detRow1(_ col0: SIMD3<Float>, _ col2: SIMD3<Float>) -> Float {
            return col0.x * (hkl.y * col2.z - col2.y * hkl.z)
                 - hkl.x * (col0.y * col2.z - col2.y * col0.z)
                 + col2.x * (col0.y * hkl.z - hkl.y * col0.z)
        }
        let ny = detRow1(a, c) / det
        // For z: replace row 2 → (a.x,a.y),(b.x,b.y) with hkl
        func detRow2(_ col0: SIMD3<Float>, _ col1: SIMD3<Float>) -> Float {
            return col0.x * (col1.y * hkl.z - hkl.y * col1.z)
                 - col1.x * (col0.y * hkl.z - hkl.y * col0.z)
                 + hkl.x * (col0.y * col1.z - col1.y * col0.z)
        }
        let nz = detRow2(a, b) / det
        let nWorld = SIMD3<Float>(nx, ny, nz)

        let nLenSq = simd_length_squared(nWorld)
        guard nLenSq > 1e-12 else { return nil }
        // p0 = n_world * d / |n_world|²
        let p0 = nWorld * (distance / nLenSq)
        return SlicePlane(origin: p0, normal: nWorld)
    }
}

// MARK: - SampledSlice

/// A 2D scalar grid sampled from a `ScalarField` on a plane. `values` is
/// row-major (`values[row * cols + col]`), `row` = slow axis, matching the
/// app's `Grid2D` convention. The sample at (col,row) sits at
///     origin + vec[0]*col + vec[1]*row
/// (vec[0] and vec[1] are the world vectors for +1 col and +1 row, each
/// already divided by cols-1 / rows-1 internally).
///
/// `mask` is nil when every sample lies inside the field's world bounding
/// box (the common axis-aligned case). Otherwise it is a row-major
/// `[Bool]` parallel to `values`, where `false` marks samples whose lattice
/// point fell outside the polygon (plane ∩ field bbox) and were
/// border-clamped — a renderer can use this to discard corner smears that
/// would otherwise appear on a skew-cut textured quad. `values` still
/// carries the clamped number at every index; the mask is the source of
/// truth for whether that number is genuine.
struct SampledSlice: Codable, Equatable {
    var cols: Int
    var rows: Int
    var origin: SIMD3<Float>
    var vec: [SIMD3<Float>]          // [col-axis, row-axis]
    var values: [Float]              // row-major, count == rows*cols
    var minValue: Float
    var maxValue: Float
    var mask: [Bool]? = nil          // nil == all valid; else row-major rows*cols
}

// MARK: - FieldSlice

enum FieldSlice {

    // MARK: Orthonormal basis

    /// Build an orthonormal (u, v) basis in the plane whose normal is `n`
    /// (assumed non-zero). Picks the reference axis least parallel to `n` for
    /// numerical stability.
    private static func planeBasis(_ n: SIMD3<Float>) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
        var ref = SIMD3<Float>(1, 0, 0)
        if ay < ax && ay < az { ref = SIMD3<Float>(0, 1, 0) }
        else if az < ax && az < ay { ref = SIMD3<Float>(0, 0, 1) }
        let u = simd_normalize(simd_cross(ref, n))
        let v = simd_cross(n, u)
        return (u, v)
    }

    // MARK: Trilinear interpolation

    /// Sample `field` at fractional grid coords (clamped to [0,1] on each axis)
    /// using trilinear interpolation. Returns nil for a malformed field.
    private static func sampleTrilinear(_ field: ScalarField,
                                        _ fx: Float, _ fy: Float, _ fz: Float) -> Float? {
        guard field.nx >= 2, field.ny >= 2, field.nz >= 2,
              field.vec.count >= 3,
              field.values.count == field.nx * field.ny * field.nz else { return nil }

        let cx = max(0.0, min(Float(field.nx - 1), fx * Float(field.nx - 1)))
        let cy = max(0.0, min(Float(field.ny - 1), fy * Float(field.ny - 1)))
        let cz = max(0.0, min(Float(field.nz - 1), fz * Float(field.nz - 1)))

        let ix0 = Int(floor(cx)), iy0 = Int(floor(cy)), iz0 = Int(floor(cz))
        let ix1 = min(ix0 + 1, field.nx - 1)
        let iy1 = min(iy0 + 1, field.ny - 1)
        let iz1 = min(iz0 + 1, field.nz - 1)

        let tx = cx - Float(ix0), ty = cy - Float(iy0), tz = cz - Float(iz0)

        func v(_ i: Int, _ j: Int, _ k: Int) -> Float {
            field.values[i + field.nx * (j + field.ny * k)]
        }
        let c000 = v(ix0, iy0, iz0), c100 = v(ix1, iy0, iz0)
        let c010 = v(ix0, iy1, iz0), c110 = v(ix1, iy1, iz0)
        let c001 = v(ix0, iy0, iz1), c101 = v(ix1, iy0, iz1)
        let c011 = v(ix0, iy1, iz1), c111 = v(ix1, iy1, iz1)

        let c00 = c000 + (c100 - c000) * tx
        let c10 = c010 + (c110 - c010) * tx
        let c01 = c001 + (c101 - c001) * tx
        let c11 = c011 + (c111 - c011) * tx
        let c0 = c00 + (c10 - c00) * ty
        let c1 = c01 + (c11 - c01) * ty
        let result = c0 + (c1 - c0) * tz
        return result.isFinite ? result : nil
    }

    // MARK: Point-in-convex-polygon (2D)

    /// Test whether a 2D point (px,py) lies inside a convex polygon defined
    /// by its vertices in order (the polygon from plane ∩ box is convex).
    /// Uses a signed cross-product half-plane test: for a CCW polygon the
    /// point is inside iff every edge's cross product is >= -epsilon.
    /// The polygon from `sample` is convex (plane ∩ convex box) but the
    /// winding is unknown, so we require all cross products to have the same
    /// sign (allowing a small epsilon tolerance on each edge).
    private static func pointInConvexPolygon(_ px: Float, _ py: Float,
                                              _ poly: [(Float, Float)],
                                              _ epsilon: Float = 1e-5) -> Bool {
        guard poly.count >= 3 else { return false }
        var sign: Float = 0
        for i in 0..<poly.count {
            let a = poly[i]
            let b = poly[(i + 1) % poly.count]
            // Edge vector: b - a. Vector to point: p - a.
            let cross = (b.0 - a.0) * (py - a.1) - (b.1 - a.1) * (px - a.0)
            if abs(cross) < epsilon { continue }  // on the edge, treat as inside
            if sign == 0 { sign = cross }
            else if sign * cross < 0 { return false }  // opposite signs → outside
        }
        return true
    }

    // MARK: Sample

    /// Sample `field` onto `plane` at the given `resolution` (clamped 2...512).
    /// Returns a `SampledSlice` whose patch covers the polygon formed by
    /// intersecting the plane with the field's world bounding box, or nil if
    /// the plane misses the field or the field is malformed.
    static func sample(field: ScalarField, plane: SlicePlane, resolution: Int = 96) -> SampledSlice? {
        guard plane.isValid else { return nil }
        guard field.nx >= 2, field.ny >= 2, field.nz >= 2, field.vec.count >= 3,
              field.values.count == field.nx * field.ny * field.nz,
              field.values.allSatisfy(\.isFinite),
              field.origin.x.isFinite, field.origin.y.isFinite, field.origin.z.isFinite,
              field.vec[0].x.isFinite, field.vec[0].y.isFinite, field.vec[0].z.isFinite,
              field.vec[1].x.isFinite, field.vec[1].y.isFinite, field.vec[1].z.isFinite,
              field.vec[2].x.isFinite, field.vec[2].y.isFinite, field.vec[2].z.isFinite
        else { return nil }

        let res = max(2, min(512, resolution))

        // 8 corners of the field's world bounding box.
        let nx1 = field.nx - 1, ny1 = field.ny - 1, nz1 = field.nz - 1
        var corners = [SIMD3<Float>]()
        corners.reserveCapacity(8)
        for i in [0, nx1] {
            for j in [0, ny1] {
                for k in [0, nz1] {
                    corners.append(field.origin
                                   + field.vec[0] * Float(i) / Float(nx1)
                                   + field.vec[1] * Float(j) / Float(ny1)
                                   + field.vec[2] * Float(k) / Float(nz1))
                }
            }
        }

        // Signed distance of each corner from the plane.
        let dists = corners.map { simd_dot($0 - plane.origin, plane.normal) }

        // 12 edges of the box (pairs of corner indices).
        let edges = [
            (0,1),(0,2),(0,4),(1,3),(1,5),(2,3),
            (2,6),(3,7),(4,5),(4,6),(5,7),(6,7),
        ]

        // Clip the box against the plane half-space (keep dist >= 0): collect
        // the polygon of intersection points. Only corners ON the plane
        // (dist ≈ 0) and edge-plane intersections become polygon vertices —
        // keep-side corners that are off the plane (dist > 0) must NOT be
        // included, or the polygon extends beyond the plane and the 2D
        // point-in-polygon test accepts samples outside the field bbox.
        var poly = [SIMD3<Float>]()
        for c in 0..<8 {
            if abs(dists[c]) < 1e-6 { poly.append(corners[c]) }
        }
        for (a, b) in edges {
            let da = dists[a], db = dists[b]
            if (da < 0) != (db < 0) {
                let t = da / (da - db)
                poly.append(corners[a] + t * (corners[b] - corners[a]))
            }
        }

        guard poly.count >= 3 else { return nil }

        // Build in-plane basis and project polygon to 2D.
        let (u, v) = planeBasis(plane.normal)
        var poly2D = [(Float, Float)]()
        poly2D.reserveCapacity(poly.count)
        var minU = Float.greatestFiniteMagnitude, maxU = -Float.greatestFiniteMagnitude
        var minV = Float.greatestFiniteMagnitude, maxV = -Float.greatestFiniteMagnitude
        for p in poly {
            let pu = simd_dot(p, u)
            let pv = simd_dot(p, v)
            poly2D.append((pu, pv))
            minU = min(minU, pu); maxU = max(maxU, pu)
            minV = min(minV, pv); maxV = max(maxV, pv)
        }

        // Deduplicate the polygon: drop vertices within ~1e-6 of the previous
        // distinct vertex, and drop the final vertex if it duplicates the
        // first. Corners that lie exactly on the plane coincide with the
        // edge-plane intersection of the two adjacent straddling edges, so
        // the raw polygon carries duplicates. Duplicates create zero-length
        // edges after sorting, which makes the PIP test fragile.
        let dedupEps: Float = 1e-5
        var deduped = [(Float, Float)]()
        for p in poly2D {
            if let last = deduped.last {
                let dx = p.0 - last.0, dy = p.1 - last.1
                if dx*dx + dy*dy < dedupEps*dedupEps { continue }
            }
            deduped.append(p)
        }
        // Drop final vertex if it duplicates the first.
        while deduped.count > 1 {
            let first = deduped[0]
            let last = deduped[deduped.count - 1]
            let dx = first.0 - last.0, dy = first.1 - last.1
            if dx*dx + dy*dy < dedupEps*dedupEps {
                deduped.removeLast()
            } else {
                break
            }
        }
        guard deduped.count >= 3 else { return nil }
        poly2D = deduped

        // Sort the convex polygon vertices by angle around their centroid so
        // the point-in-polygon half-plane test sees a consistent winding.
        // (The plane∩box polygon is guaranteed convex, but even after dedup
        // its vertices arrive in corner-index order followed by edge-list
        // order — not a cyclic traversal of the boundary.)
        var cuu: Float = 0
        var cvv: Float = 0
        for pt in poly2D { cuu += pt.0; cvv += pt.1 }
        cuu /= Float(poly2D.count)
        cvv /= Float(poly2D.count)
        poly2D.sort { (a, b) -> Bool in
            atan2(a.1 - cvv, a.0 - cuu) < atan2(b.1 - cvv, b.0 - cuu)
        }
        let spanU = maxU - minU, spanV = maxV - minV
        guard spanU > 1e-9, spanV > 1e-9 else { return nil }

        // Fit the sampling patch to the polygon's 2D bounding box. Use the
        // aspect ratio of the bbox to set cols/rows from the resolution, with
        // at least 2 samples per axis.
        let aspect = spanU / spanV
        let cols: Int
        let rows: Int
        if aspect >= 1 {
            cols = res
            rows = max(2, min(512, Int(Float(res) / aspect)))
        } else {
            rows = res
            cols = max(2, min(512, Int(Float(res) * aspect)))
        }
        guard cols * rows <= 1_048_576 else { return nil }

        // World vectors for +1 col and +1 row.
        let colVec = u * (spanU / Float(cols - 1))
        let rowVec = v * (spanV / Float(rows - 1))
        let patchOrigin = plane.origin + u * minU + v * minV

        // Sample the field at each lattice point.
        var values = [Float]()
        values.reserveCapacity(rows * cols)
        var minVal = Float.greatestFiniteMagnitude
        var maxVal = -Float.greatestFiniteMagnitude
        var mask = [Bool](repeating: true, count: rows * cols)
        var allValid = true

        let du = spanU / Float(cols - 1)
        let dv = spanV / Float(rows - 1)

        // Precompute the inverse mapping from world position to fractional
        // grid coords: p = origin + vec[0]*fx + vec[1]*fy + vec[2]*fz → solve
        // for f via Cramer's rule.
        let aa = field.vec[0], bb = field.vec[1], cc = field.vec[2]
        let det = simd_dot(aa, simd_cross(bb, cc))
        guard abs(det) > 1e-12 else { return nil }

        for row in 0..<rows {
            for col in 0..<cols {
                let pu = minU + Float(col) * du
                let pv = minV + Float(row) * dv
                let idx = row * cols + col
                // Test whether this lattice point lies inside the polygon
                // (plane ∩ field bbox). If not, mark as invalid.
                if !pointInConvexPolygon(pu, pv, poly2D) {
                    mask[idx] = false
                    allValid = false
                }
                let world = patchOrigin
                    + colVec * Float(col)
                    + rowVec * Float(row)
                let rel = world - field.origin
                // Cramer's rule: f.x = dot(rel, cross(b,c)) / det, etc.
                let fx = simd_dot(rel, simd_cross(bb, cc)) / det
                let fy = simd_dot(rel, simd_cross(cc, aa)) / det
                let fz = simd_dot(rel, simd_cross(aa, bb)) / det
                guard let s = sampleTrilinear(field, fx, fy, fz) else { return nil }
                values.append(s)
                if s < minVal { minVal = s }
                if s > maxVal { maxVal = s }
            }
        }

        return SampledSlice(cols: cols, rows: rows, origin: patchOrigin,
                            vec: [colVec, rowVec], values: values,
                            minValue: minVal, maxValue: maxVal,
                            mask: allValid ? nil : mask)
    }

    // MARK: Clip triangles

    /// Clip a packed IsoMesh-style triangle list (9 floats/vertex:
    /// px,py,pz, nx,ny,nz, r,g,b) against `plane`. Keeps the half-space where
    /// dot(p - origin, normal) * keepSide >= -1e-6. Interpolates position, normal
    /// (renormalized; zero-length → (0,0,1)), and color linearly. Returns the
    /// packed clipped list (may be empty; always a multiple of 9 floats).
    /// Malformed input (count % 9 != 0) → empty. Output capped at 5M triangles.
    static func clipTriangles(_ vertices: [Float], plane: SlicePlane, keepSide: Float = 1) -> [Float] {
        guard plane.isValid else { return [] }
        guard vertices.count % 9 == 0 else { return [] }
        let maxTriangles = 5_000_000
        let epsilon: Float = -1e-6

        // Signed distance of a vertex from the plane (scaled by keepSide).
        func signedDist(_ i: Int) -> Float {
            let px = vertices[i], py = vertices[i+1], pz = vertices[i+2]
            return (simd_dot(SIMD3<Float>(px, py, pz) - plane.origin, plane.normal)) * keepSide
        }

        // Interpolate vertex i→j at parameter t (0 at i, 1 at j).
        func lerp(_ i: Int, _ j: Int, _ t: Float, _ out: inout [Float], _ at: Int) {
            for k in 0..<9 {
                out[at + k] = vertices[i + k] + t * (vertices[j + k] - vertices[i + k])
            }
            // Renormalize the normal.
            let nx = out[at+3], ny = out[at+4], nz = out[at+5]
            let len = sqrt(nx*nx + ny*ny + nz*nz)
            if len > 1e-9 {
                out[at+3] = nx / len; out[at+4] = ny / len; out[at+5] = nz / len
            } else {
                out[at+3] = 0; out[at+4] = 0; out[at+5] = 1
            }
        }

        let triCount = vertices.count / 27
        var output = [Float]()
        var totalTriangles = 0

        for t in 0..<triCount {
            let base = t * 27
            let d0 = signedDist(base)
            let d1 = signedDist(base + 9)
            let d2 = signedDist(base + 18)

            let verts = [base, base + 9, base + 18]
            let ds = [d0, d1, d2]
            let ins = [d0 >= epsilon, d1 >= epsilon, d2 >= epsilon]

            // Sutherland-Hodgman for one triangle against one half-space:
            // walk edges (v0→v1, v1→v2, v2→v0), emit inside vertices and
            // intersection points.
            var clipped = [Float]()

            for e in 0..<3 {
                let a = verts[e]
                let b = verts[(e + 1) % 3]
                let da = ds[e]
                let db = ds[(e + 1) % 3]
                let aIn = ins[e]
                let bIn = ins[(e + 1) % 3]

                if aIn {
                    clipped.append(contentsOf: vertices[a..<(a + 9)])
                    if !bIn {
                        // Leaving: emit intersection a→b.
                        let param = da / (da - db)
                        let start = clipped.count
                        clipped.append(contentsOf: [Float](repeating: 0, count: 9))
                        lerp(a, b, param, &clipped, start)
                    }
                } else if bIn {
                    // Entering: emit intersection a→b.
                    let param = da / (da - db)
                    let start = clipped.count
                    clipped.append(contentsOf: [Float](repeating: 0, count: 9))
                    lerp(a, b, param, &clipped, start)
                }
            }

            let n = clipped.count / 9
            guard n >= 3 else { continue }
            let newTris = n - 2
            totalTriangles += newTris
            if totalTriangles > maxTriangles { return [] }

            // Fan-triangulate the clipped polygon.
            for i in 1..<(n - 1) {
                output.append(contentsOf: clipped[0..<9])
                output.append(contentsOf: clipped[(i * 9)..<((i + 1) * 9)])
                output.append(contentsOf: clipped[((i + 1) * 9)..<((i + 2) * 9)])
            }
        }

        return output
    }
}
