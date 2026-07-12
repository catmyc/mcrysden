import Foundation
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
        // coords from the two endpoint corners. `ox,oy,oz` is the current cube's
        // origin in grid indices (the ix,iy,iz loop vars) so the corner is looked
        // up at its ABSOLUTE position and the vertex is placed in world space where
        // that cube actually sits — without this, every cube's surface collapses
        // into the first grid cell near the origin.
        func edgePoint(_ e: Int, _ iso: Float, _ ox: Int, _ oy: Int, _ oz: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let (a, b) = edgeEnds[e]
            let (ax, ay, az) = cornerPos[a]
            let (bx, by, bz) = cornerPos[b]
            let va = field.value(ox + ax, oy + ay, oz + az)
            let vb = field.value(ox + bx, oy + by, oz + bz)
            let denom = vb - va
            let t = (abs(denom) > 1e-9) ? (iso - va) / denom : 0.5
            let lx = Float(ax) + t * Float(bx - ax)
            let ly = Float(ay) + t * Float(by - ay)
            let lz = Float(az) + t * Float(bz - az)
            // fractional coord of the (possibly interpolated) grid index over the grid
            let frac = SIMD3<Float>((Float(ox) + lx) / Float(nx - 1),
                                    (Float(oy) + ly) / Float(ny - 1),
                                    (Float(oz) + lz) / Float(nz - 1))
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
                            if vert[e] == nil { let (w, f) = edgePoint(e, isoLevel, ix, iy, iz); vert[e] = w; frac[e] = f }
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

// MARK: - Fermi-surface parsing (BXSF)

/// A parsed Fermi-surface file: the Fermi energy (the iso level) plus one scalar
/// grid per band. Each band surfaces as an independent IsoMesh at `fermiEnergy`
/// (exactly the XCrySDen convention). BXSF's per-band grid shares the DATAGRID
/// layout — full-span `vec`, x-fastest values — so each band is a `ScalarField`.
struct FermiSurface: Codable {
    var fermiEnergy: Float
    var bands: [ScalarField]       // index == band number (parallel to orig file)

    /// Parse a text-format `.bxsf` file (NOT gzipped — decompress first; use
    /// `BXSFLoader.load(from:)` which shells out to `/usr/bin/gunzip` for `.gz`).
    /// The Fermi energy is read from the `Fermi Energy:` header line. The block
    /// after `BEGIN_BLOCK_BANDGRID_3D` follows XCrySDen's ReadBandGrid layout:
    ///    nband  nx ny nz  ox oy oz  v0  v1  v2  [BAND:<i> <nx*ny*nz floats>]*
    static func parse(_ raw: String) throws -> FermiSurface {
        enum E: Error { case malformed(String) }
        let lines = raw.components(separatedBy: "\n")
        func tokens(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }

        // 1) Fermi energy from the header line.
        var fermi: Float = 0
        for line in lines {
            guard line.lowercased().contains("fermi") && line.lowercased().contains("energy") else { continue }
            let toks = tokens(line)
            // the value is the last numeric token on the line
            for t in toks.reversed() {
                let clean = t.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                if let v = Float(clean) { fermi = v; break }
            }
            break
        }

        // 2) Open the BANDGRID block and read the common header.
        guard let beginIdx = lines.firstIndex(where: {
            $0.contains("BEGIN_BLOCK_BANDGRID3D") || $0.contains("BEGIN_BLOCK_BANDGRID_3D")
        }) else { throw E.malformed("no BEGIN_BLOCK_BANDGRID_3D block") }

        // Build a stream of numeric tokens (and "BAND" markers) from the body,
        // skipping the comment line and the BANDGRID_3D_BANDS ident line.
        enum Tok { case num(Float); case band(Int) }
        var stream: [Tok] = []
        for line in lines[(beginIdx+1)...] {
            if line.contains("END_BANDGRID") { break }   // END_BANDGRID_3D / END_BANDGRID3D
            let toks = tokens(line)
            guard !toks.isEmpty else { continue }
            if toks[0].hasPrefix("BAND") {
                // "BAND:" <index>
                if toks.count >= 2, let bi = Int(toks[1]) { stream.append(.band(bi)) }
                continue
            }
            // skip non-numeric lines (comment / ident)
            if toks.compactMap({ Float($0) }).count != toks.count { continue }
            for t in toks { if let v = Float(t) { stream.append(.num(v)) } }
        }

        var p = 0
        func nextNum() -> Float? { guard p < stream.count else { return nil }; defer { p += 1 };
            if case .num(let v) = stream[p] { return v } else { return nil } }

        guard let nband = nextNum().map(Int.init), nband > 0 else { throw E.malformed("bad nband") }
        guard let nx = nextNum().map(Int.init), let ny = nextNum().map(Int.init),
              let nz = nextNum().map(Int.init) else { throw E.malformed("bad dims") }
        guard let ox = nextNum(), let oy = nextNum(), let oz = nextNum() else { throw E.malformed("bad origin") }
        var vec = [SIMD3<Float>](repeating: .zero, count: 3)
        for a in 0..<3 {
            guard let vx = nextNum(), let vy = nextNum(), let vz = nextNum() else { throw E.malformed("bad vec") }
            vec[a] = SIMD3<Float>(vx, vy, vz)
        }

        // 3) Per-band grids. The stream now reads: [BAND i, <nx*ny*nz floats>]*.
        var bands: [ScalarField] = []
        let needed = nx * ny * nz
        while p < stream.count {
            // expect a BAND marker (and ignore any stray floats before it)
            if case .band(_) = stream[p] { p += 1 }
            var vals: [Float] = []
            while vals.count < needed, p < stream.count {
                if case .num(let v) = stream[p] { vals.append(v); p += 1 }
                else { break }
            }
            guard vals.count == needed else { break }
            var mn = vals[0], mx = vals[0]
            for v in vals { if v < mn { mn = v }; if v > mx { mx = v } }
            bands.append(ScalarField(nx: nx, ny: ny, nz: nz, origin: SIMD3<Float>(ox, oy, oz),
                                     vec: vec, values: vals, minValue: mn, maxValue: mx))
        }
        return FermiSurface(fermiEnergy: fermi, bands: bands)
    }
}

/// File-based BXSF loader that transparently decompresses `.gz` (shelling out to
/// `/usr/bin/gunzip`, matching XCrySDen's gunzipXSF) before parsing.
enum BXSFLoader {
    static func load(from url: URL) throws -> FermiSurface {
        enum E: Error { case decompress(String) }
        let needsGunzip = url.pathExtension.lowercased() == "gz"
        let text: String
        if needsGunzip {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            p.arguments = ["-c", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            // Read BEFORE waiting: a full pipe buffer would otherwise deadlock gunzip
            // (it blocks on write while we block on waitUntilExit) — the Rh fixture is
            // ~500KB, far past the pipe capacity.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw E.decompress("gunzip exit \(p.terminationStatus)") }
            text = String(data: data, encoding: .utf8) ?? ""
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        return try FermiSurface.parse(text)
    }
}

