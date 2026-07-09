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

    /// Build the BZ from the conventional cell + its base atoms. The atoms'
    /// fractional offsets reveal centering so the primitive reciprocal lattice
    /// (and hence the BZ shape) is correct for fcc/bcc, not just primitive
    /// conventional cells. `starRadius` shells of G-vectors (2 = {-2..2}, the
    /// wigner.f default) give the 14-face fcc truncated octahedron.
    static func build(cell: Cell, atoms: [SIMD3<Float>], starRadius: Int = 2,
                     shellCutoff: Float = 1.8) -> BrillouinZone? {
        // True reciprocal generator (primitive = respects centering).
        let (astar, bstar, cstar) = Lattice.primitiveReciprocal(cell: cell, atoms: atoms)
        guard astar != .zero else { return nil }

        // G-star: integer combinations of reciprocal vectors, excluding origin.
        // The Wigner-Seitz cell is defined by the nearest NEIGHBOR SHELL(S): a
        // bisector plane only bounds the cell for G up to the first shell or two.
        // We therefore COMPLETE whole shells (capped by a radius relative to the
        // shortest |G|), never truncate mid-shell — a truncated shell injects
        // stray bisectors that cut false corners (e.g. fcc 14 -> 12 faces).
        var gstar: [SIMD3<Float>] = []
        for i in -starRadius...starRadius {
            for j in -starRadius...starRadius {
                for k in -starRadius...starRadius {
                    if i == 0 && j == 0 && k == 0 { continue }
                    let g = Float(i)*astar + Float(j)*bstar + Float(k)*cstar
                    gstar.append(g)
                }
            }
        }
        gstar.sort { dot($0, $0) < dot($1, $1) }
        // Radius cap: keep all G within `shellCutoff`× the shortest |G|. The first
        // complete shell(s) fully define the cell; including partial next shells
        // is what corrupts the shape. starRadius=2 explores far enough that the
        // cutoff decides, not the enumeration bound.
        let shortest = length(gstar.first ?? .zero)
        guard shortest > 1e-6 else { return nil }
        let cutoff = shortest * shellCutoff
        gstar = gstar.filter { length($0) <= cutoff }
        // Bisector planes (outward normal n, offset cc) for the WS cell.
        var planes: [(n: SIMD3<Float>, cc: Float)] = []
        for g in gstar {
            let len = length(g)
            if len < 1e-6 { continue }
            planes.append((g / len, len * 0.5))
        }
        guard planes.count >= 4 else { return nil }

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
