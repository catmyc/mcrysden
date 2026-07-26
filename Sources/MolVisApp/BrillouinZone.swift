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

/// A single deterministic BZ landmark for the k-path editor: the fractional
/// coordinate (conventional reciprocal basis, in `point.frac`), the BZ-space
/// Cartesian coordinate it came from, and which kind of landmark it is.
struct BZCandidate {
    var point: KPoint
    var cartesian: SIMD3<Float>
    var type: BZPointType
}

extension BrillouinZone {
    /// Fractional (in the given reciprocal basis) -> Cartesian reciprocal position.
    static func cartesianFromFractional(_ frac: SIMD3<Float>,
                                        reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>))
        -> SIMD3<Float> {
        reciprocal.a * frac.x + reciprocal.b * frac.y + reciprocal.c * frac.z
    }

    /// Cartesian -> fractional in the given reciprocal basis. Returns nil if the
    /// basis is singular or the result is non-finite.
    static func fractionalFromCartesian(_ cart: SIMD3<Float>,
                                        reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>))
        -> SIMD3<Float>? {
        let m = simd_float3x3(columns: (reciprocal.a, reciprocal.b, reciprocal.c))
        guard isFiniteInvertible(m) else { return nil }
        let f = m.inverse * cart
        guard f.x.isFinite && f.y.isFinite && f.z.isFinite else { return nil }
        return f
    }

    /// Scale-relative invertibility test on a basis matrix. The dimensionless
    /// ratio `|det(M)| / (|c0||c1||c2|)` is the signed volume of the
    /// parallelepiped scaled to its enclosing rectangular box (bounded by 1); an
    /// absolute `|det|` floor would wrongly reject valid tiny reciprocal zones
    /// (huge real cells) and wrongly accept near-degenerate large ones. Require the
    /// ratio to be well above machine epsilon, with all lengths finite and >0.
    static func isFiniteInvertible(_ m: simd_float3x3, tol: Float = 1e-6) -> Bool {
        let la = length(m.columns.0), lb = length(m.columns.1), lc = length(m.columns.2)
        guard la.isFinite, lb.isFinite, lc.isFinite, la > 0, lb > 0, lc > 0 else { return false }
        let det = m.determinant
        return det.isFinite && abs(det) > tol * la * lb * lc
    }

    /// Deterministic BZ landmark candidates for the k-path editor: Gamma plus the
    /// unique vertices, edge midpoints, and face centers, de-duplicated within a
    /// scale-relative tolerance and labeled stably. Non-finite or singular
    /// Cartesian→fractional conversions are dropped rather than trapped.
    func candidates() -> [BZCandidate] {
        let basis = (a: reciprocal.a, b: reciprocal.b, c: reciprocal.c)
        func toFractional(_ p: SIMD3<Float>) -> SIMD3<Float>? {
            Self.fractionalFromCartesian(p, reciprocal: basis)
        }
        // Scale-relative de-dup tolerance: a fraction of the BZ extent with only
        // a tiny machine floor. A fixed floor would merge distinct landmarks of a
        // tiny reciprocal zone (large real cell) and is unnecessary for big zones,
        // where the relative term dominates.
        var extent: Float = 0
        for face in faces { for v in face { extent = max(extent, length(v)) } }
        let tol = max(1e-5, extent * 5e-3)
        func dedup(_ pts: [BZSpecialPoint]) -> [BZSpecialPoint] {
            var out: [BZSpecialPoint] = []
            for p in pts where !out.contains(where: { length($0.coord - p.coord) < tol }) {
                out.append(p)
            }
            return out
        }
        // Deterministic finite-Float lexicographic order — no Float-to-Int cast, so
        // arbitrarily large fractional values cannot trap.
        func sorted(_ pts: [(SIMD3<Float>, SIMD3<Float>)]) -> [(SIMD3<Float>, SIMD3<Float>)] {
            pts.sorted { a, b in
                if a.1.x != b.1.x { return a.1.x < b.1.x }
                if a.1.y != b.1.y { return a.1.y < b.1.y }
                return a.1.z < b.1.z
            }
        }
        var result: [BZCandidate] = []
        // Gamma (center) first.
        for sp in specialPoints where sp.type == .center {
            if let f = toFractional(sp.coord) {
                result.append(BZCandidate(point: KPoint(f, "\u{0393}"), cartesian: sp.coord, type: .center))
            }
        }
        // Vertices, edge midpoints, face centers: de-dup, sort, then label 1..n.
        func addGroup(_ type: BZPointType, _ prefix: String) {
            let fracs = dedup(specialPoints.filter { $0.type == type })
                .map { ($0.coord, toFractional($0.coord)) }
                .compactMap { cart, f in f.map { (cart, $0) } }
            for (i, (cart, f)) in sorted(fracs).enumerated() {
                result.append(BZCandidate(point: KPoint(f, "\(prefix)\(i+1)"), cartesian: cart, type: type))
            }
        }
        addGroup(.edge, "V")
        addGroup(.line, "E")
        addGroup(.polyface, "F")
        return result
    }
}

/// The shared BZ↔world mapping used by both picking (phase 2) and rendering
/// (later). Built once from an already-constructed BrillouinZone plus the
/// Scene, and reproduces the renderer's `drawBrillouinZone` mapping exactly.
struct BZPresentation {
    /// Scene centroid (the renderer's `sceneCentroid()`).
    let center: SIMD3<Float>
    /// World-units-per-BZ-unit scale = targetExtent / bzExtent.
    let inv: Float
    /// Conventional reciprocal vectors (Cartesian) for fractional -> Cartesian.
    let reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>)

    init(bz: BrillouinZone, scene: Scene) {
        var extent: Float = 0
        for face in bz.faces { for v in face { extent = max(extent, length(v)) } }
        let (_, radius) = scene.boundingSphere()
        let targetExtent = max(1.0, radius) * 0.45
        self.center = scene.centroid
        self.inv = extent > 1e-5 ? targetExtent / extent : 0
        self.reciprocal = bz.reciprocal
    }

    /// Map a BZ-space Cartesian coordinate to its rendered world position.
    func world(cartesian: SIMD3<Float>) -> SIMD3<Float> {
        center + cartesian * inv
    }

    /// Map a fractional k-point (conventional reciprocal basis) to its rendered
    /// world position, converting to Cartesian first.
    func world(frac: SIMD3<Float>) -> SIMD3<Float> {
        let cart = BrillouinZone.cartesianFromFractional(frac, reciprocal: reciprocal)
        return center + cart * inv
    }
}

private func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }
private func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v / (length(v) + 1e-12) }
