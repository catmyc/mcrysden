import simd

struct Vertex { var position: SIMD3<Float>; var normal: SIMD3<Float> }
struct Mesh { let positions: [SIMD3<Float>]; let normals: [SIMD3<Float>]; let indices: [UInt16] }

enum Geometry {
    /// Standard UV unit sphere centred at the origin, radius 1.0.
    static func unitSphere(latSegments: Int = 12, lonSegments: Int = 20) -> Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for lat in 0...latSegments {
            let theta = Float.pi * Float(lat) / Float(latSegments)       // 0...pi
            let st = sin(theta); let ct = cos(theta)
            for lon in 0...lonSegments {
                let phi = 2.0 * Float.pi * Float(lon) / Float(lonSegments)
                let sp = sin(phi); let cp = cos(phi)
                let n = SIMD3<Float>(st * cp, ct, st * sp)
                normals.append(n); positions.append(n)                     // position == normal for unit sphere
            }
        }
        var indices: [UInt16] = []
        let stride = lonSegments + 1
        for lat in 0..<latSegments {
            for lon in 0..<lonSegments {
                let a = UInt16(lat * stride + lon)
                let b = UInt16(a + UInt16(stride))
                indices.append(a); indices.append(b); indices.append(a + 1)
                indices.append(b); indices.append(b + 1); indices.append(a + 1)
            }
        }
        return Mesh(positions: positions, normals: normals, indices: indices)
    }

    /// Unit cylinder along +Y, total height 1.0 (y in [-0.5,0.5]), radius 1.0,
    /// centred on the origin. Bonds are rotated from +Y onto the bond direction.
    static func unitCylinder(radialSegments: Int = 12) -> Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        let y0: Float = -0.5, y1: Float = 0.5
        for ring in 0...1 {
            let y = ring == 0 ? y0 : y1
            for s in 0..<radialSegments {
                let phi = 2.0 * Float.pi * Float(s) / Float(radialSegments)
                let cp = cos(phi); let sp = sin(phi)
                positions.append(SIMD3<Float>(cp, y, sp))
                normals.append(SIMD3<Float>(cp, 0, sp))
            }
        }
        var indices: [UInt16] = []
        let n = radialSegments
        // side wall
        for s in 0..<radialSegments {
            let s1 = (s + 1) % radialSegments
            let a = UInt16(s), b = UInt16(s1)
            let c = UInt16(s + n), d = UInt16(s1 + n)
            indices.append(a); indices.append(c); indices.append(b)
            indices.append(b); indices.append(c); indices.append(d)
        }
        // Caps need their own ring vertices: sharing the wall vertices would
        // blend axial cap normals into the radial wall and create a fixed
        // dark/bright split along every bond.
        let topStart = UInt16(positions.count)
        positions.append(SIMD3<Float>(0, y1, 0)); normals.append(SIMD3<Float>(0, 1, 0))
        let botStart = UInt16(positions.count)
        positions.append(SIMD3<Float>(0, y0, 0)); normals.append(SIMD3<Float>(0, -1, 0))
        let topRingStart = UInt16(positions.count)
        for s in 0..<radialSegments {
            let phi = 2.0 * Float.pi * Float(s) / Float(radialSegments)
            positions.append(SIMD3<Float>(cos(phi), y1, sin(phi)))
            normals.append(SIMD3<Float>(0, 1, 0))
        }
        let botRingStart = UInt16(positions.count)
        for s in 0..<radialSegments {
            let phi = 2.0 * Float.pi * Float(s) / Float(radialSegments)
            positions.append(SIMD3<Float>(cos(phi), y0, sin(phi)))
            normals.append(SIMD3<Float>(0, -1, 0))
        }
        for s in 0..<radialSegments {
            let s1 = (s + 1) % radialSegments
            // top cap
            indices.append(topStart); indices.append(topRingStart + UInt16(s1)); indices.append(topRingStart + UInt16(s))
            // bottom cap (wound so normal points -Y)
            indices.append(botStart); indices.append(botRingStart + UInt16(s)); indices.append(botRingStart + UInt16(s1))
        }
        return Mesh(positions: positions, normals: normals, indices: indices)
    }

    /// Unit cone along +Y: base radius 1 at y = 0, tip at y = 1. Used for the
    /// orientation-gizmo arrowheads (reused by the lit atom pipeline).
    static func unitCone(radialSegments: Int = 16) -> Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        let n = radialSegments
        // side-wall ring (base, y = 0)
        for s in 0..<n {
            let phi = 2.0 * Float.pi * Float(s) / Float(n)
            let cp = cos(phi); let sp = sin(phi)
            positions.append(SIMD3<Float>(cp, 0, sp))
            // slant normal: outward + up (cone rises 1 per radius 1)
            normals.append(normalize(SIMD3<Float>(cp, 1.0, sp)))
        }
        let tip = UInt16(positions.count)
        positions.append(SIMD3<Float>(0, 1, 0)); normals.append(SIMD3<Float>(0, 1, 0))
        // base cap centre
        let base = UInt16(positions.count)
        positions.append(SIMD3<Float>(0, 0, 0)); normals.append(SIMD3<Float>(0, -1, 0))
        var indices: [UInt16] = []
        for s in 0..<n {
            let s1 = (s + 1) % n
            indices.append(UInt16(s)); indices.append(tip); indices.append(UInt16(s1))     // side
            indices.append(base); indices.append(UInt16(s1)); indices.append(UInt16(s))     // base cap
        }
        return Mesh(positions: positions, normals: normals, indices: indices)
    }

    /// Two vertices spanning +Y — basis for bond cylinders and line segments.
    static func unitLine() -> [SIMD3<Float>] { [SIMD3(0,0,0), SIMD3(0,1,0)] }

    // MARK: - Polyhedral cells (Voronoi-like half-space intersection)

    /// Build the convex polyhedron around `center` formed by intersecting, for
    /// each neighbor, the half-space of points nearer to `center` than to that
    /// neighbor (the perpendicular bisector plane). Returns a flat list of
    /// triangle vertices (groups of 3) in world space, or nil if the cell is
    /// degenerate (fewer than 3 usable neighbors, or unbounded within the
    /// clamped neighbor set).
    ///
    /// Algorithm: a vertex lies at the intersection of three bisector planes
    /// that satisfies ALL half-space constraints. We enumerate triples of planes,
    /// solve the 3x3 system, keep the feasible points, then for each plane gather
    /// the vertices lying on it and fan-triangulate the convex polygon they form.
    /// This avoids a full 3D convex-hull pass. Neighbor count is clamped to
    /// `maxNeighbors` (nearest first) to bound the O(n^3) triple loop to a few
    /// hundred solves per atom — fine for the common few-hundred-atom case.
    static func polyhedronFaces(center: SIMD3<Float>, neighbors: [SIMD3<Float>],
                                maxNeighbors: Int = 12) -> [SIMD3<Float>]? {
        let k = min(neighbors.count, maxNeighbors)
        guard k >= 3 else { return nil }

        // Plane i: dot(x, n_i) <= c_i, where n_i points toward neighbor i and
        // c_i = dot(mid_i, n_i) = dot(center, n_i) + |neighbor-center|/2.
        var planes: [(n: SIMD3<Float>, c: Float)] = []
        planes.reserveCapacity(k)
        var maxDist: Float = 0
        for idx in 0..<k {
            let d = neighbors[idx] - center
            let len = length(d)
            if len < 1e-6 { continue }
            let n = d / len
            planes.append((n, dot(center, n) + len * 0.5))
            maxDist = max(maxDist, len)
        }
        guard planes.count >= 3 else { return nil }

        let bound = maxDist * 3.0 + 1.0
        let eps: Float = 1e-3
        var verts: [SIMD3<Float>] = []
        let m = planes.count
        for a in 0..<m {
            for b in (a + 1)..<m {
                for c in (b + 1)..<m {
                    let mat = simd_float3x3(rows: [planes[a].n, planes[b].n, planes[c].n])
                    let det = mat.determinant
                    if abs(det) < 1e-6 { continue }               // nearly coplanar planes
                    let p = mat.inverse * SIMD3(planes[a].c, planes[b].c, planes[c].c)
                    if length(p - center) > bound { continue }     // reject unbounded outliers
                    // Feasibility: must satisfy every half-space (with slack).
                    var ok = true
                    for q in 0..<m {
                        if dot(p, planes[q].n) > planes[q].c + eps { ok = false; break }
                    }
                    if ok { verts.append(p) }
                }
            }
        }
        // De-duplicate vertices that appear in multiple triples.
        var uniq: [SIMD3<Float>] = []
        for v in verts {
            if !uniq.contains(where: { length($0 - v) < eps }) { uniq.append(v) }
        }
        guard uniq.count >= 4 else { return nil }

        // Fan-triangulate each plane's face: gather the vertices lying on it,
        // sort angularly around the face centroid in the plane's 2D basis, and
        // emit a triangle fan. The plane normal is the (outward) face normal.
        var tris: [SIMD3<Float>] = []
        for i in 0..<m {
            let nrm = planes[i].n
            let cc = planes[i].c
            let face = uniq.filter { abs(dot($0, nrm) - cc) < 3 * eps }
            guard face.count >= 3 else { continue }
            // Build an orthonormal 2D basis (u, v) spanning the plane.
            let tangent = abs(nrm.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let u = normalize(cross(tangent, nrm))
            let v = cross(nrm, u)
            let cen = face.reduce(SIMD3<Float>.zero, +) / Float(face.count)
            let sorted = face.sorted {
                atan2(dot($0 - cen, v), dot($0 - cen, u)) < atan2(dot($1 - cen, v), dot($1 - cen, u))
            }
            for j in 1..<(sorted.count - 1) {
                tris.append(sorted[0]); tris.append(sorted[j]); tris.append(sorted[j + 1])
            }
        }
        return tris.isEmpty ? nil : tris
    }
}
