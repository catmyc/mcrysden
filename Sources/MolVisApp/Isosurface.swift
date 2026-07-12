import simd

// Volumetric scalar field + marching-cubes isosurface. This is the keystone for
// the Tier A feature set: every one of DATAGRID_3D (XSF), Gaussian `.cube`,
// the Fermi surface (iso at the Fermi level from a BXSF), and color-planes (a
// field slice) feeds a grid into `ScalarField` and surfaces out of `MarchingCubes`.
// The mesh is drawn through the EXISTING lit poly pipeline, so no new Metal
// shader is required — the vertices match `Renderer.drawPolyhedral`'s layout
// (world position + normal + color).

/// A rectilinear 3D scalar grid in world (Cartesian, Å) space.
/// Codable so it flows through `Scene` (which is serialized in the state file);
/// all its members are plain value types.
///
/// The grid is defined by an `origin` corner and three span vectors
/// `vec[0..2]` that run along the i, j, k axes over `n` sample points, so the
/// world position of integer sample (i,j,k) is
///     origin + vec[0]*i/(nx-1) + vec[1]*j/(ny-1) + vec[2]*k/(nz-1).
/// This is exactly the XCrySDen `DATAGRID_3D` convention (`struct DATAGRID`
/// in `struct.h`: `orig`, `vec[3][3]`, `n[3]`).
struct ScalarField: Codable {
    let nx: Int, ny: Int, nz: Int
    let origin: SIMD3<Float>
    let vec: [SIMD3<Float>]          // [i-axis, j-axis, k-axis]
    let values: [Float]              // flat, index(ix,iy,iz) — x varies fastest
    let minValue: Float
    let maxValue: Float

    /// Flat index into `values`. x is the fastest-varying axis.
    @inline(__always)
    private func index(_ ix: Int, _ iy: Int, _ iz: Int) -> Int {
        ix + nx * (iy + ny * iz)
    }

    @inline(__always)
    func value(_ ix: Int, _ iy: Int, _ iz: Int) -> Float {
        values[index(ix, iy, iz)]
    }

    /// World position of integer sample (i,j,k). `vec` spans the full extent, so
    /// we divide by (n-1) to land on the boundary samples at the ends.
    func worldPosition(_ ix: Int, _ iy: Int, _ iz: Int) -> SIMD3<Float> {
        let fx = nx > 1 ? Float(ix) / Float(nx - 1) : 0
        let fy = ny > 1 ? Float(iy) / Float(ny - 1) : 0
        let fz = nz > 1 ? Float(iz) / Float(nz - 1) : 0
        return origin + vec[0] * fx + vec[1] * fy + vec[2] * fz
    }

    /// Central-difference field gradient at a fractional grid position, in WORLD
    /// units. This is what `gridNormals.c` computes; normalizing and negating it
    /// gives the outward surface normal (gradient points toward higher field).
    func worldGradient(_ fx: Float, _ fy: Float, _ fz: Float) -> SIMD3<Float> {
        func sample(_ i: Float, _ j: Float, _ k: Float) -> Float {
            let ix = max(0, min(nx - 1, Int((i * Float(nx - 1)).rounded())))
            let iy = max(0, min(ny - 1, Int((j * Float(ny - 1)).rounded())))
            let iz = max(0, min(nz - 1, Int((k * Float(nz - 1)).rounded())))
            return value(ix, iy, iz)
        }
        let gx = nx > 1 ? (sample(fx + 1.0/(Float(nx-1)), fy, fz) - sample(fx - 1.0/(Float(nx-1)), fy, fz)) : 0
        let gy = ny > 1 ? (sample(fx, fy + 1.0/(Float(ny-1)), fz) - sample(fx, fy - 1.0/(Float(ny-1)), fz)) : 0
        let gz = nz > 1 ? (sample(fx, fy, fz + 1.0/(Float(nz-1))) - sample(fx, fy, fz - 1.0/(Float(nz-1)))) : 0
        return SIMD3<Float>(gx, gy, gz)
    }
}

/// A triangle mesh produced by marching cubes, in the packed vertex layout the
/// existing lit poly pipeline consumes (position + normal + color).
struct IsoMesh {
    /// 9 floats per vertex: px,py,pz, nx,ny,nz, r,g,b.
    var vertices: [Float]
    var triangleCount: Int { vertices.count / 27 }

    /// one-sided surface: `sign > 0` renders faces where field > isoLevel.
    init(field: ScalarField, isoLevel: Float, sign: Float = 1, color: SIMD3<Float> = SIMD3<Float>(0.3, 0.6, 1.0)) {
        var out: [Float] = []
        guard field.nx > 1, field.ny > 1, field.nz > 1 else { vertices = out; return }
        let nx = field.nx, ny = field.ny, nz = field.nz

        // 12 edges of the cube: each connects two of the 8 corner indices.
        // Corner layout matches MarchCubes.c: 0=(0,0,0) bottom layer, then around.
        let cornerPos: [(Int, Int, Int)] = [
            (0,0,0),(0,1,0),(1,1,0),(1,0,0),  // bottom (z=0)
            (0,0,1),(0,1,1),(1,1,1),(1,0,1),  // top    (z=1)
        ]
        // Edge endpoints (index into cornerPos).
        let edgeEnds: [(Int, Int)] = [
            (0,1),(1,2),(2,3),(3,0),  // bottom ring
            (4,5),(5,6),(6,7),(7,4),  // top ring
            (0,4),(1,5),(2,6),(3,7),  // verticals
        ]
        // For each edge, how to interpolate a world position + fractional grid
        // coords from the two endpoint corners.
        func edgePoint(_ e: Int, _ iso: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            let (a, b) = edgeEnds[e]
            let (ax, ay, az) = cornerPos[a]
            let (bx, by, bz) = cornerPos[b]
            let va = field.value(ax, ay, az)
            let vb = field.value(bx, by, bz)
            let denom = vb - va
            let t = (abs(denom) > 1e-9) ? (iso - va) / denom : 0.5
            let cx = Float(ax) + t * Float(bx - ax)
            let cy = Float(ay) + t * Float(by - ay)
            let cz = Float(az) + t * Float(bz - az)
            let frac = SIMD3<Float>(cx / Float(nx - 1), cy / Float(ny - 1), cz / Float(nz - 1))
            let world = field.origin
                + field.vec[0] * frac.x
                + field.vec[1] * frac.y
                + field.vec[2] * frac.z
            return (world, frac)
        }

        var cube = [Float](repeating: 0, count: 8)
        var vert = [SIMD3<Float>?](repeating: nil, count: 12)
        var frac = [SIMD3<Float>?](repeating: nil, count: 12)

        for iz in 0..<(nz - 1) {
            for iy in 0..<(ny - 1) {
                for ix in 0..<(nx - 1) {
                    // Load the 8 corner values of this cube.
                    cube[0] = field.value(ix,   iy,   iz)
                    cube[1] = field.value(ix,   iy+1, iz)
                    cube[2] = field.value(ix+1, iy+1, iz)
                    cube[3] = field.value(ix+1, iy,   iz)
                    cube[4] = field.value(ix,   iy,   iz+1)
                    cube[5] = field.value(ix,   iy+1, iz+1)
                    cube[6] = field.value(ix+1, iy+1, iz+1)
                    cube[7] = field.value(ix+1, iy,   iz+1)

                    // Build the 8-bit case index.
                    var cubeindex = 0
                    if sign * cube[0] < isoLevel { cubeindex |= 1 }
                    if sign * cube[1] < isoLevel { cubeindex |= 2 }
                    if sign * cube[2] < isoLevel { cubeindex |= 4 }
                    if sign * cube[3] < isoLevel { cubeindex |= 8 }
                    if sign * cube[4] < isoLevel { cubeindex |= 16 }
                    if sign * cube[5] < isoLevel { cubeindex |= 32 }
                    if sign * cube[6] < isoLevel { cubeindex |= 64 }
                    if sign * cube[7] < isoLevel { cubeindex |= 128 }

                    let edges = marchingCubeEdgeTable[cubeindex]
                    if edges == 0 { continue }

                    // Interpolate (and cache) the vertices on the cut edges.
                    for e in 0..<12 {
                        if edges & (1 << UInt16(e)) != 0 {
                            if vert[e] == nil { let (w, f) = edgePoint(e, isoLevel); vert[e] = w; frac[e] = f }
                        }
                    }

                    // Emit triangles from the case table.
                    let tri = marchingCubeTriTable[cubeindex]
                    var ti = 0
                    while ti < 15 && tri[ti] >= 0 {
                        let i0 = Int(tri[ti]), i1 = Int(tri[ti+1]), i2 = Int(tri[ti+2])
                        let p0 = vert[i0]!, p1 = vert[i1]!, p2 = vert[i2]!
                        let f0 = frac[i0]!, f1 = frac[i1]!, f2 = frac[i2]!
                        let n0 = normalFromGradient(field, f0)
                        let n1 = normalFromGradient(field, f1)
                        let n2 = normalFromGradient(field, f2)
                        for (p, n) in [(p0,n0),(p1,n1),(p2,n2)] {
                            out += [p.x, p.y, p.z, n.x, n.y, n.z, color.x, color.y, color.z]
                        }
                        ti += 3
                    }
                    // clear edge cache for next cube
                    for e in 0..<12 { vert[e] = nil; frac[e] = nil }
                }
            }
        }
        vertices = out
    }
}

/// Outward normal from the world-space field gradient at fractional coords `f`.
private func normalFromGradient(_ field: ScalarField, _ f: SIMD3<Float>) -> SIMD3<Float> {
    let g = field.worldGradient(f.x, f.y, f.z)
    let len = simd_length(g)
    // Negate: gradient points toward higher field; the surface's "outward" side
    // (field > iso) faces lower field, so the visible normal opposes the gradient.
    return len > 1e-9 ? -g / len : SIMD3<Float>(0, 0, 1)
}

// Float literals can't be appended to `[Float]` without coercion in some
// contexts; `+= [Float]()` friendly helpers live above via explicit typing.
private extension Array where Element == Float {
    static func += (lhs: inout [Float], rhs: [Float]) { lhs.append(contentsOf: rhs) }
}
