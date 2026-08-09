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
/// A rectilinear 2D scalar grid (a `DATAGRID_2D` block read from an XSF file).
/// This is the color-plane source: `values` is row-major `values[row][col]`,
/// `row` == the slow axis (C index j), `col` == the fast axis (C index i). The
/// grid lives in a plane of world (Cartesian, Å) space spanned by `vec[0..1]`
/// from `origin`; the sample at (col,row) sits at
///     origin + vec[0]*col/(cols-1) + vec[1]*row/(rows-1).
struct Grid2D: Codable {
    let cols: Int, rows: Int
    let origin: SIMD3<Float>
    let vec: [SIMD3<Float>]          // [col-axis, row-axis] (2 span vectors)
    let values: [[Float]]            // [row][col] — matches ColorPlaneView.grid
    let minValue: Float
    let maxValue: Float
    let ident: String                // human-readable label from the block header
}

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

    /// Finite-difference field gradient at a fractional grid position, transformed
    /// into world space. If B has the three grid spans as columns, derivatives in
    /// fractional coordinates obey grad_f = B^T grad_world, hence
    /// grad_world = B^-T grad_f.
    func worldGradient(_ fx: Float, _ fy: Float, _ fz: Float) -> SIMD3<Float> {
        guard nx > 0, ny > 0, nz > 0, vec.count >= 3,
              fx.isFinite, fy.isFinite, fz.isFinite else { return .zero }
        let ix = max(0, min(nx - 1, Int((fx * Float(nx - 1)).rounded())))
        let iy = max(0, min(ny - 1, Int((fy * Float(ny - 1)).rounded())))
        let iz = max(0, min(nz - 1, Int((fz * Float(nz - 1)).rounded())))
        func derivative(_ axis: Int) -> Float {
            let count = [nx, ny, nz][axis]
            guard count > 1 else { return 0 }
            let at = [ix, iy, iz][axis]
            let lo = max(0, at - 1), hi = min(count - 1, at + 1)
            var p0 = [ix, iy, iz], p1 = p0
            p0[axis] = lo; p1[axis] = hi
            let dv = value(p1[0], p1[1], p1[2]) - value(p0[0], p0[1], p0[2])
            return dv * Float(count - 1) / Float(hi - lo)
        }
        let gradF = SIMD3<Float>(derivative(0), derivative(1), derivative(2))
        let a = vec[0], b = vec[1], c = vec[2]
        let det = simd_dot(a, simd_cross(b, c))
        guard abs(det) > 1e-12 else { return .zero }
        return (gradF.x * simd_cross(b, c)
              + gradF.y * simd_cross(c, a)
              + gradF.z * simd_cross(a, b)) / det
    }
}

/// A triangle mesh produced by marching cubes, in the packed vertex layout the
/// existing lit poly pipeline consumes (position + normal + color).
struct IsoMesh {
    /// 9 floats per vertex: px,py,pz, nx,ny,nz, r,g,b.
    var vertices: [Float]
    var triangleCount: Int { vertices.count / 27 }

    /// Set when marching cubes hit the practical output cap (`maxTriangles`): the
    /// mesh is a partial shell, not a complete surface. Renderer consults this to
    /// avoid drawing a silently-truncated surface.
    private(set) var overflow = false

    /// one-sided surface: `sign > 0` renders faces where field > isoLevel.
    init(field: ScalarField, isoLevel: Float, sign: Float = 1, color: SIMD3<Float> = SIMD3<Float>(0.3, 0.6, 1.0)) {
        let maxTriangles = 5_000_000
        var out: [Float] = []
        // A degenerate geometry (fewer than 3 span vectors) would trap on the
        // `vec[0..2]` indexing in worldPosition/worldGradient and in IsoMesh's edge
        // interpolation. Reject it as an empty, non-overflowing mesh — the same safe
        // outcome as a shape mismatch — so a malformed field never traps inside
        // marching cubes.
        guard field.nx > 1, field.ny > 1, field.nz > 1, field.vec.count >= 3,
              isoLevel.isFinite, sign.isFinite, sign != 0,
              color.x.isFinite, color.y.isFinite, color.z.isFinite,
              field.origin.x.isFinite, field.origin.y.isFinite, field.origin.z.isFinite,
              field.vec.prefix(3).allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              field.values.allSatisfy(\.isFinite) else { vertices = out; return }

        // Overflow-checked product: a malicious grid whose (nx-1)(ny-1)(nz-1)*27
        // overflows Int must never pass a naive magnitude bound check. Allocate a
        // modest reserve and grow lazily instead of reserving hundreds of MB eagerly.
        let nx = field.nx, ny = field.ny, nz = field.nz
        let fx = Int64(nx - 1), fy = Int64(ny - 1), fz = Int64(nz - 1)
        guard fx > 0, fy > 0, fz > 0 else { vertices = out; return }
        let cubes64 = fx.multipliedReportingOverflow(by: fy)
        guard !cubes64.overflow else { overflow = true; vertices = out; return }
        let cubes64b = cubes64.partialValue.multipliedReportingOverflow(by: fz)
        guard !cubes64b.overflow else { overflow = true; vertices = out; return }
        let floats64 = cubes64b.partialValue.multipliedReportingOverflow(by: Int64(27))
        guard !floats64.overflow else { overflow = true; vertices = out; return }

        // Shape validation, overflow-safe: marching cubes indexes `values` by
        // ix + nx*(iy + ny*iz), i.e. over nx*ny*nz samples, so it would over-run
        // (or under-read) a buffer whose count doesn't equal nx*ny*nz and trap.
        // Reject a malformed field as an empty, non-overflowing mesh rather than
        // crash. The product is computed in Int64 with overflow reporting so an
        // astronomical dimension can never wrap to a value that matches the count
        // and slip past. Placed after the cubes/floats-overflow guard above (so a
        // grid whose cubes product genuinely overflows still trips that path and
        // reports overflow=true) but BEFORE reserveCapacity: a non-overflowing field
        // with a tiny values array would otherwise reserve up to maxTriangles*27
        // floats (~540 MB) here before being rejected.
        let cells64 = Int64(nx).multipliedReportingOverflow(by: Int64(ny))
        guard !cells64.overflow else { vertices = out; return }
        let cells64b = cells64.partialValue.multipliedReportingOverflow(by: Int64(nz))
        guard !cells64b.overflow else { vertices = out; return }
        guard cells64b.partialValue == Int64(field.values.count) else { vertices = out; return }

        if floats64.partialValue <= Int64(Int.max) {
            out.reserveCapacity(min(Int(floats64.partialValue), maxTriangles * 27))
        }

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
                            if vert[e] == nil {
                                let (w, f) = edgePoint(e, sign * isoLevel, ix, iy, iz)
                                vert[e] = w; frac[e] = f
                            }
                        }
                    }

                    // Emit triangles from the case table.
                    let tri = marchingCubeTriTable[cubeindex]
                    var ti = 0
                    while ti < 15 && tri[ti] >= 0 {
                        if out.count / 27 >= maxTriangles {
                            overflow = true; vertices = out; return
                        }
                        let i0 = Int(tri[ti]), i1 = Int(tri[ti+1]), i2 = Int(tri[ti+2])
                        let p0 = vert[i0]!, p1 = vert[i1]!, p2 = vert[i2]!
                        let f0 = frac[i0]!, f1 = frac[i1]!, f2 = frac[i2]!
                        let n0 = normalFromGradient(field, f0, sign: sign)
                        let n1 = normalFromGradient(field, f1, sign: sign)
                        let n2 = normalFromGradient(field, f2, sign: sign)
                        for (p, n) in [(p0,n0),(p1,n1),(p2,n2)] {
                            out.append(p.x); out.append(p.y); out.append(p.z)
                            out.append(n.x); out.append(n.y); out.append(n.z)
                            out.append(color.x); out.append(color.y); out.append(color.z)
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
private func normalFromGradient(_ field: ScalarField, _ f: SIMD3<Float>, sign: Float) -> SIMD3<Float> {
    let g = field.worldGradient(f.x, f.y, f.z)
    let len = simd_length(g)
    // Positive lobes face lower values; negative lobes face higher values.
    return len > 1e-9 ? -sign * g / len : SIMD3<Float>(0, 0, 1)
}

// MARK: - Fermi-surface parsing (BXSF)

/// A parsed Fermi-surface file: the Fermi energy (the iso level) plus one scalar
/// grid per band. Each band surfaces as an independent IsoMesh at `fermiEnergy`
/// (exactly the XCrySDen convention). BXSF's per-band grid shares the DATAGRID
/// layout — full-span `vec`, x-fastest values — so each band is a `ScalarField`.
struct FermiSurface: Codable {
    var fermiEnergy: Float
    var bands: [ScalarField]       // index == band number (parallel to orig file)

    /// Parse the "<index>" token of a "BAND:" <index> marker. The token may carry
    /// surrounding non-digits (e.g. a trailing ":"); only a pure non-empty digit
    /// sequence is accepted as a structural marker.
    private static func parseBANDIndex(_ s: String) -> Int? {
        let token = s.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !token.isEmpty, token.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(token)
    }

    /// Overflow-checked product of two non-negative Int64 factors; nil on overflow.
    private static func mulOrOverflow(_ a: Int64, _ b: Int64) -> Int64? {
        let (p, o) = a.multipliedReportingOverflow(by: b)
        return o ? nil : p
    }
    /// Overflow-checked triple product of three non-negative Int64 factors; nil on
    /// overflow. A raw Int64*Int64*Int64 can silently wrap to a positive value that
    /// would pass a magnitude bound, so grid-sizing calls go through this.
    private static func mulOrOverflow(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64? {
        guard let p = mulOrOverflow(a, b) else { return nil }
        return mulOrOverflow(p, c)
    }

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

        // 1) Fermi energy from the canonical "Fermi Energy:" header line. A BXSF
        // must declare one; a missing or non-finite value is malformed. Match the
        // canonical label (case-insensitive) rather than any incidental mention of
        // "fermi" + "energy" elsewhere in the file.
        var fermi: Float? = nil
        for line in lines {
            let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
            guard lower.hasPrefix("fermi energy:") else { continue }
            let toks = tokens(line)
            for t in toks.reversed() {
                let clean = t.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                if let v = Float(clean), v.isFinite { fermi = v; break }
            }
            break
        }
        guard let fermi = fermi else { throw E.malformed("BXSF missing Fermi energy") }

        // 2) Open the BANDGRID block and read the common header. Require both the
        // BEGIN marker and a matching END marker — a block that opens but never
        // closes is malformed, not an empty grid.
        guard let beginIdx = lines.firstIndex(where: {
            $0.contains("BEGIN_BLOCK_BANDGRID3D") || $0.contains("BEGIN_BLOCK_BANDGRID_3D")
        }) else { throw E.malformed("no BEGIN_BLOCK_BANDGRID_3D block") }
        guard beginIdx + 1 < lines.count, let endIdx = lines[(beginIdx+1)...].firstIndex(where: {
            $0.contains("END_BANDGRID_3D") || $0.contains("END_BANDGRID3D")
        }) else { throw E.malformed("no END_BANDGRID_3D block") }
        guard let identIdx = lines[(beginIdx+1)..<endIdx].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "BANDGRID_3D_BANDS"
        }) else { throw E.malformed("no BANDGRID_3D_BANDS marker") }

        // Build a stream of numeric tokens (and "BAND" markers) from the body,
        // skipping the comment line and the BANDGRID_3D_BANDS ident line. A line
        // that is neither a BAND marker nor fully numeric is malformed (reject
        // surplus tokens rather than silently dropping them).
        enum Tok { case num(Float); case band(Int) }
        var stream: [Tok] = []
        let cellCap = 5_000_000
        for line in lines[(identIdx+1)..<endIdx] {
            let toks = tokens(line)
            guard !toks.isEmpty else { continue }
            if toks[0].uppercased() == "BAND:" {
                // "BAND:" <index> — require a usable integer band index.
                guard toks.count == 2, let bi = parseBANDIndex(toks[1]) else {
                    throw E.malformed("bad BAND marker")
                }
                stream.append(.band(bi))
                guard stream.count <= cellCap + 2048 else {
                    throw E.malformed("BXSF data exceeds memory cap")
                }
                continue
            }
            // Every other non-empty line in the body must be fully numeric.
            let nums = toks.compactMap { Float($0) }
            guard nums.count == toks.count else {
                throw E.malformed("malformed numeric line in BANDGRID block")
            }
            guard stream.count + nums.count <= cellCap + 2048 else {
                throw E.malformed("BXSF data exceeds memory cap")
            }
            for v in nums { stream.append(.num(v)) }
        }

        var p = 0
        func nextNum() -> Float? { guard p < stream.count else { return nil }; defer { p += 1 };
            if case .num(let v) = stream[p] { return v } else { return nil } }
        // Integral Int from the stream without ever trapping: rejects NaN/Inf,
        // non-finite magnitudes, values with a fractional part, and anything
        // outside the Int range (Int(Float) would trap on the last case and
        // silently truncate on the fractional case).
        func nextInt(maximum: Int) -> Int? {
            guard let f = nextNum() else { return nil }
            guard f.isFinite, f == f.rounded(), f >= 0, f <= Float(maximum) else { return nil }
            return Int(f)
        }
        let dimCap = cellCap

        guard let nband = nextInt(maximum: 1024), nband > 0 else { throw E.malformed("bad nband") }
        guard let nx = nextInt(maximum: dimCap), let ny = nextInt(maximum: dimCap),
              let nz = nextInt(maximum: dimCap),
              nx > 0, ny > 0, nz > 0 else { throw E.malformed("bad dims") }
        // Overflow-checked product: a raw Int64*Int64*Int64 can wrap to a positive
        // value that would pass the magnitude check.
        guard let perBand = mulOrOverflow(Int64(nx), Int64(ny), Int64(nz)),
              perBand > 0, perBand <= Int64(cellCap) else { throw E.malformed("BXSF grid dimensions overflow") }
        // Practical aggregate memory cap: nband * perBand floats must not exceed
        // a sane ceiling (a malicious file could declare nband * perBand huge while
        // each factor individually passes its own bound).
        guard let totalBandCells = mulOrOverflow(perBand, Int64(nband)),
              totalBandCells > 0, totalBandCells <= Int64(cellCap) else {
            throw E.malformed("BXSF aggregate band-cell count overflow")
        }
        // Origin and span vectors must be finite — non-finite geometry would
        // silently corrupt every band's world positions.
        guard let ox = nextNum(), ox.isFinite,
              let oy = nextNum(), oy.isFinite,
              let oz = nextNum(), oz.isFinite else { throw E.malformed("bad origin") }
        var vec = [SIMD3<Float>](repeating: .zero, count: 3)
        for a in 0..<3 {
            guard let vx = nextNum(), vx.isFinite,
                  let vy = nextNum(), vy.isFinite,
                  let vz = nextNum(), vz.isFinite else { throw E.malformed("bad vec") }
            vec[a] = SIMD3<Float>(vx, vy, vz)
        }

        // 3) Per-band grids. The stream reads: [BAND i, <nx*ny*nz floats>]*.
        // Each declared band must be introduced by a BAND marker (structural marker)
        // and carry a complete grid; a file with zero usable bands, or whose usable
        // bands fall short of the declared count, fails rather than rendering at the
        // wrong Fermi level. Physical band indices may start above one, but must
        // be positive, unique, and contiguous.
        var bands: [ScalarField] = []
        let needed = Int(perBand)
        var previousBandIndex: Int?
        for _ in 0..<nband {
            // require an explicit BAND marker to start each band block
            guard p < stream.count, case .band(let bi) = stream[p], bi > 0,
                  previousBandIndex.map({ bi > $0 }) ?? true else { break }
            previousBandIndex = bi
            p += 1
            var vals: [Float] = []
            while vals.count < needed, p < stream.count {
                if case .num(let v) = stream[p] {
                    guard v.isFinite else { throw E.malformed("non-finite BXSF band value") }
                    vals.append(v); p += 1
                } else { break }
            }
            guard vals.count == needed else { break }
            var mn = vals[0], mx = vals[0]
            for v in vals { if v < mn { mn = v }; if v > mx { mx = v } }
            bands.append(ScalarField(nx: nx, ny: ny, nz: nz, origin: SIMD3<Float>(ox, oy, oz),
                                     vec: vec, values: vals, minValue: mn, maxValue: mx))
        }
        if bands.isEmpty { throw E.malformed("no usable bands in BXSF") }
        guard bands.count == nband else { throw E.malformed("BXSF truncated (\(bands.count)/\(nband) bands)") }
        guard p == stream.count else { throw E.malformed("surplus BXSF band data") }
        return FermiSurface(fermiEnergy: fermi, bands: bands)
    }
}

/// Read a text file with a size cap, mirroring Parser.readCappedText but
/// defined privately here (that helper is fileprivate to Parser.swift).
/// Pre-checks the on-disk size, then reads through FileHandle so a malicious
/// file cannot allocate unbounded memory before the cap is detected.
private func readCappedBXSFText(_ url: URL, cap: Int = 200 * 1024 * 1024) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let fileSize = attributes[.size] as? Int, fileSize > cap {
        throw ParseError.io(path: url.path, reason: "file size \(fileSize) exceeds \(cap) byte limit")
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        throw ParseError.io(path: url.path, reason: "could not open file for reading")
    }
    defer { try? handle.close() }
    var data = Data()
    while true {
        guard let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty else { break }
        data.append(chunk)
        if data.count > cap {
            throw ParseError.io(path: url.path, reason: "file exceeds \(cap) byte limit")
        }
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw ParseError.io(path: url.path, reason: "file is not valid UTF-8")
    }
    return text
}

/// File-based BXSF loader that transparently decompresses `.gz` (shelling out to
/// `/usr/bin/gunzip`, matching XCrySDen's gunzipXSF) before parsing.
enum BXSFLoader {
    static func load(from url: URL) throws -> FermiSurface {
        let needsGunzip = url.pathExtension.lowercased() == "gz"
        let text: String
        if needsGunzip {
            let data = try gunzipData(url)
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw ParseError.io(path: url.path, reason: "decompressed BXSF is not UTF-8")
            }
            text = decoded
        } else {
            text = try readCappedBXSFText(url)
        }
        return try FermiSurface.parse(text)
    }
}
