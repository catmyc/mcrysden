import simd

// Brillouin-zone polyhedron + special k-points.
//
// The BZ is the Wigner-Seitz cell of the reciprocal lattice, which is exactly
// what Geometry.polyhedronFaces already computes: intersect half-spaces bounded
// by the perpendicular bisectors of a G-vector star. Because the G-star must
// come from the PRIMITIVE reciprocal lattice, we reduce the conventional cell
// via the atoms' fractional offsets (Lattice) to recover centering (fcc/bcc).
//
// Reference: XCrySDen F/wigner.f (G-star in {-2..2}), C/xcBz.c (BzInitBZ:
// derives center/edge/line/face special points), C/bz.h (BZPointType).

/// A special k-point on/in the BZ, mirroring XCrySDen's bz.h bitflags.
enum BZPointType: Int {
    case center = 1     // origin = Gamma
    case edge = 2       // polyhedron vertex
    case line = 4       // edge midpoint
    case polyface = 8   // face (polygon) centroid
}

struct BZSpecialPoint {
    var coord: SIMD3<Float>     // Cartesian (reciprocal) coordinates
    var type: BZPointType
}

/// The Brillouin zone of a crystal: ordered face loops plus special points
/// (Gamma + edge/line/face) for k-path construction.
struct BrillouinZone {
    let faces: [[SIMD3<Float>]]         // face i = CCW-ordered vertex loop
    let normals: [SIMD3<Float>]         // per-face outward unit normals
    let specialPoints: [BZSpecialPoint]
    let reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)

    /// Build the BZ from the conventional cell + its base atoms. Centering is
    /// detected from the atoms' fractional offsets (P/I/F) and reduced to the
    /// true primitive direct basis, whose reciprocal generates a COMPLETE
    /// per-direction G-star. No isotropic radius cap — the Wigner-Seitz cell is
    /// the intersection of the bisectors of ALL G up to the first complete shell
    /// in every direction. Correct for any lattice: fcc -> 14, slab -> 6, etc.
    static func build(cell: Cell, atoms: [Atom]) -> BrillouinZone? {
        // Centering detection verifies candidate translations against the basis.
        // Bound that work for directly-constructed/pathological scenes; real unit
        // cells are far smaller, and omitting an optional overlay is safer than an
        // O(n²) UI stall on a massive atom list.
        guard atoms.count <= 4_096 else { return nil }
        // True reciprocal generator (primitive = respects centering), the dense
        // lattice whose Wigner-Seitz cell is the first BZ.
        let (astar, bstar, cstar) = Lattice.primitiveReciprocal(cell: cell, atoms: atoms)
        let vectors = [astar, bstar, cstar]
        guard vectors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              vectors.allSatisfy({ length($0).isFinite && length($0) > 1e-9 }) else { return nil }

        // Complete per-direction G-star: along primitive reciprocal axis i we
        // enumerate enough integer multiples to reach (at least) the longest
        // primitive reciprocal |G| — guaranteeing a complete first shell in every
        // direction. An isotropic radius cut would discard the dense directions of
        // anisotropic cells (e.g. slabs) and leave too few planes to close the cell.
        let nrm = vectors.map(length)
        let longest = nrm.max() ?? 0
        let ratios = nrm.map { ceil(longest / $0) }
        // Geometry.polyhedronFaces is cubic in the plane count (with another
        // feasibility scan inside). A malicious, extremely anisotropic cell used
        // to turn these ratios into an unrepresentable Int or billions of loop
        // iterations. Refuse a BZ overlay that cannot be built promptly; the
        // structure itself remains renderable.
        guard ratios.allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 16 }) else { return nil }
        let radii = ratios.map(Int.init)
        let r0 = radii[0], r1 = radii[1], r2 = radii[2]
        let c0 = (2 * r0 + 1), c1 = (2 * r1 + 1), c2 = (2 * r2 + 1)
        let p01 = c0.multipliedReportingOverflow(by: c1)
        let p012 = p01.partialValue.multipliedReportingOverflow(by: c2)
        guard !p01.overflow, !p012.overflow, p012.partialValue - 1 <= 512 else { return nil }
        var gstar: [SIMD3<Float>] = []
        gstar.reserveCapacity(p012.partialValue - 1)
        for i in -r0...r0 { for j in -r1...r1 { for k in -r2...r2 {
            if i == 0 && j == 0 && k == 0 { continue }
            gstar.append(Float(i)*astar + Float(j)*bstar + Float(k)*cstar)
        }}}
        guard gstar.count >= 4 else { return nil }

        // Bisector planes (outward normal n, offset cc = |G|/2) for the WS cell.
        let planes: [(n: SIMD3<Float>, cc: Float)] = gstar.map { g in (g / length(g), length(g) * 0.5) }

        guard let tris = Geometry.polyhedronFaces(center: .zero, neighbors: gstar,
                                                   maxNeighbors: gstar.count) else {
            return nil
        }
        // De-duplicate triangle vertices.
        let eps: Float = 1e-3
        var uniq: [SIMD3<Float>] = []
        for v in tris {
            if !uniq.contains(where: { length($0 - v) < eps }) { uniq.append(v) }
        }
        // Group vertices into faces: a vertex belongs to a face plane iff it lies
        // ON that plane (within tolerance). Empty buckets are clipped-away
        /// bisectors of farther G-vectors, not real faces.
        var faces: [[SIMD3<Float>]] = []
        var normals: [SIMD3<Float>] = []
        for pl in planes {
            let face = uniq.filter { abs(dot($0, pl.n) - pl.cc) < 3 * eps }
            guard face.count >= 3 else { continue }
            let nrm = pl.n
            let cen = face.reduce(SIMD3<Float>.zero, +) / Float(face.count)
            let tangent = abs(nrm.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let uf = normalize(cross(tangent, nrm))
            let vf = cross(nrm, uf)
            let sorted = face.sorted {
                atan2(dot($0 - cen, vf), dot($0 - cen, uf))
                    < atan2(dot($1 - cen, vf), dot($1 - cen, uf))
            }
            faces.append(sorted)
            normals.append(nrm)
        }
        // Special points: Gamma (origin) + per-face vertex/edge-midpoint/centroid.
        var specials: [BZSpecialPoint] = [BZSpecialPoint(coord: .zero, type: .center)]
        for (fi, face) in faces.enumerated() {
            var cen: SIMD3<Float> = .zero
            for v in face { cen += v }
            cen /= Float(face.count)
            specials.append(BZSpecialPoint(coord: cen, type: .polyface))
            for vi in 0..<face.count {
                specials.append(BZSpecialPoint(coord: face[vi], type: .edge))
                let vnext = face[(vi + 1) % face.count]
                specials.append(BZSpecialPoint(coord: 0.5 * (face[vi] + vnext), type: .line))
            }
            _ = normals[fi]
        }
        // Report the CONVENTIONAL reciprocal (band-plot basis) alongside the
        // primitive-built geometry.
        let conv = cell.reciprocalVectors
        return BrillouinZone(faces: faces, normals: normals,
                             specialPoints: specials,
                             reciprocal: (conv.a, conv.b, conv.c))
    }
}

private func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }
private func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v / (length(v) + 1e-12) }
