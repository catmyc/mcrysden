import simd

// k-path interpolation + export.
//
// Port of XCrySDen F/kPath.f (distance-weighted segment interpolation through a
// list of special k-points) and kPath.tcl (export to .kpf and QE K_POINTS crystal).
//
// All k-points here are fractional (crystal) coordinates. Reciprocal-lattice
// vectors include the 2pi factor (see Cell.reciprocalVectors); band codes that
// use the crystallographer's convention (no 2pi) divide accordingly on import.

extension KPath {
    /// Interpolate this path into a dense list of fractional k-points. Each
    /// consecutive pair of special points is allocated a number of samples
    /// proportional to its fractional-space length (the kPath.f scheme), with
    /// the shared endpoint of each segment emitted once.
    func interpolated() -> [SIMD3<Float>] {
        let pts = points.map { $0.frac }
        guard pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return [] }
        guard pts.count >= 2 else { return pts }
        var segLens: [Float] = []
        var total: Float = 0
        for i in 0..<pts.count - 1 {
            let d = sqrt(dot(pts[i+1] - pts[i], pts[i+1] - pts[i]))
            guard d.isFinite else { return [] }
            segLens.append(d); total += d
        }
        guard total.isFinite else { return [] }
        // This value is UI-controlled in normal use, but KPath is also constructed
        // programmatically. Bound it so a malformed value cannot trap during the
        // Float-to-Int conversion or request an effectively unbounded array.
        let perSeg = min(1_000_000, max(2, pointsPerSegment))
        let maxOutputPoints = 1_000_000
        var out: [SIMD3<Float>] = []
        for i in 0..<pts.count - 1 {
            guard out.count < maxOutputPoints else { return out }
            let apportioned = total > 0 ? round(Float(perSeg) * segLens[i] / total) : Float(perSeg)
            guard apportioned.isFinite else { return [] }
            var n = max(2, min(perSeg, Int(apportioned)))
            // Account for the shared point skipped on later segments while
            // enforcing a global output cap, including all-zero paths.
            let available = maxOutputPoints - out.count
            n = min(n, available + (i == 0 ? 0 : 1))
            guard n >= 2 else { return out }
            // Half-open segments: emit the start point only for the first
            // segment; subsequent segments skip j=0 (the shared endpoint that
            // closed the previous segment). No trailing append — the last
            // segment's j=n-1 already lands on pts.last.
            let j0 = (i == 0) ? 0 : 1
            for j in j0..<n {
                let t = Float(j) / Float(n - 1)
                out.append(pts[i] * (1 - t) + pts[i + 1] * t)
            }
        }
        return out
    }
}

extension KPath {
    /// Canonical high-symmetry k-path for the common cubic lattices (the routes
    /// XCrySDen's kLabels.tcl / F/pwKPath.f target). Fractional coords in the
    /// primitive reciprocal basis. Falls back to a trivial Gamma-X for unknown
    /// lattices so the editor always has a valid path to export.
    static func defaultPath(lattice: CubicLattice) -> KPath {
        switch lattice {
        case .fcc:
            // Gamma-X-W-K-Gamma-L (fcc truncated-octahedron BZ).
            return KPath(points: [
                KPoint(SIMD3(0,0,0), "G"),
                KPoint(SIMD3(0.5,0,0), "X"),
                KPoint(SIMD3(0.5,0.25,0.75), "W"),
                KPoint(SIMD3(0.375,0.375,0.75), "K"),
                KPoint(SIMD3(0,0,0), "G"),
                KPoint(SIMD3(0.5,0.5,0.5), "L"),
            ])
        case .bcc:
            // Gamma-H-N-Gamma-P.
            return KPath(points: [
                KPoint(SIMD3(0,0,0), "G"),
                KPoint(SIMD3(0.5,-0.5,0.5), "H"),
                KPoint(SIMD3(0,0,0.5), "N"),
                KPoint(SIMD3(0,0,0), "G"),
                KPoint(SIMD3(0.25,0.25,0.25), "P"),
            ])
        case .sc:
            // Gamma-X-M-Gamma-R.
            return KPath(points: [
                KPoint(SIMD3(0,0,0), "G"),
                KPoint(SIMD3(0.5,0,0), "X"),
                KPoint(SIMD3(0.5,0.5,0), "M"),
                KPoint(SIMD3(0,0,0), "G"),
                KPoint(SIMD3(0.5,0.5,0.5), "R"),
            ])
        }
    }
}

/// Minimal cubic-lattice classifier used to pick the default high-symmetry path.
enum CubicLattice { case fcc, bcc, sc }

/// k-path export formats offered in the UI k-path editor.
enum KPathExportFormat: String { case qe = "qe", kpf = "kpf" }

extension KPath {
    /// Detect the cubic Bravais type from the conventional cell + its atomic
    /// basis offsets and return the matching canonical k-path, expressed in
    /// CONVENTIONAL reciprocal fractional coordinates (the basis the editor and
    /// QE export use). `defaultPath(lattice:)` emits canonical primitive-basis
    /// coords; for fcc/bcc we map primitive fractional -> Cartesian reciprocal ->
    /// conventional fractional so the route's geometry is preserved. sc is
    /// unchanged (primitive == conventional). A singular/non-finite conversion
    /// falls back to the canonical primitive route so export always works.
    static func defaultPath(cell: Cell, atoms: [SIMD3<Float>]) -> KPath {
        guard let cubic = classifyCubic(cell: cell, atoms: atoms) else {
            return defaultPath(lattice: .sc)
        }
        let primitive = defaultPath(lattice: cubic)
        // sc: primitive and conventional reciprocal bases coincide.
        guard cubic != .sc else { return primitive }

        // Primitive direct basis from the classified centering, then its reciprocal.
        let centering: LatticeCentering = (cubic == .fcc) ? .face : .body
        let primDir = Lattice.primitiveDirect(centering: centering, cell)
        let primRecip = Cell(a: primDir.a, b: primDir.b, c: primDir.c).reciprocalVectors
        let convRecip = cell.reciprocalVectors

        let converted = primitive.points.compactMap { kp -> KPoint? in
            let cart = BrillouinZone.cartesianFromFractional(kp.frac, reciprocal: primRecip)
            guard let f = BrillouinZone.fractionalFromCartesian(cart, reciprocal: convRecip) else { return nil }
            return KPoint(f, kp.label)
        }
        // Drop no points: if any conversion failed, return the primitive route.
        guard converted.count == primitive.points.count else { return primitive }
        return KPath(points: converted, pointsPerSegment: primitive.pointsPerSegment)
    }
}

/// Classify an orthogonal cell as sc/bcc/fcc by its fractional basis offsets:
/// fcc has (0,½,½)-type offsets; bcc has (½,½,½); sc has none. Returns nil for
/// non-orthogonal or unrecognized cells. Cubic checks are length-ratio + ~90°.
func classifyCubic(cell: Cell, atoms: [SIMD3<Float>]) -> CubicLattice? {
    let a = length(cell.a), b = length(cell.b), c = length(cell.c)
    let tol: Float = 0.05
    guard abs(a - b) < tol * a && abs(a - c) < tol * a else { return nil }
    // ~90° included angles.
    let cosAB = dot(cell.a, cell.b) / (a * b)
    let cosAC = dot(cell.a, cell.c) / (a * c)
    let cosBC = dot(cell.b, cell.c) / (b * c)
    guard abs(cosAB) < tol && abs(cosAC) < tol && abs(cosBC) < tol else { return nil }
    let offs = Lattice.basisOffsets(atoms, cell: cell)
    let hasHalfHalf = offs.contains { abs(abs($0.x) - 0.5) < tol && abs(abs($0.y) - 0.5) < tol && abs($0.z) < tol }
    let hasBody = offs.contains { abs(abs($0.x) - 0.5) < tol && abs(abs($0.y) - 0.5) < tol && abs(abs($0.z) - 0.5) < tol }
    if hasHalfHalf { return .fcc }
    if hasBody { return .bcc }
    return .sc
}

private func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }

/// Text exporters for a k-path (mirror XCrySDen's kPath.tcl targets). v1 ships
/// QE `K_POINTS crystal` and the native `.kpf`; PWscf/CRYSTAL/WIEN2k card formats
// are added by reusing these same interpolated points.
enum KPathExport {
    /// QE `K_POINTS crystal` card: a count line followed by `kx ky kz w` lines
    /// (weight w = 1.0 for a uniform sampling).
    static func qeKPointsCrystal(_ path: KPath) -> String {
        let pts = path.interpolated()
        var s = "\(pts.count)\n"
        for p in pts { s += String(format: "%.6f %.6f %.6f 1.0\n", p.x, p.y, p.z) }
        return s
    }

    /// Export text for the given UI format: `.qe` => QE K_POINTS crystal,
    /// `.kpf` => XCrySDen native k-path file.
    static func export(_ path: KPath, as format: KPathExportFormat) -> String {
        switch format {
        case .qe: return qeKPointsCrystal(path)
        case .kpf: return xcrysdnenKPF(path)
        }
    }

    /// XCrySDen native k-path file (.kpf): an integer ISS multiplier line, then
    /// `kx ky kz  label` lines for each special (high-symmetry) point. The
    /// multiplier clears any common denominator so band codes get exact rationals.
    static func xcrysdnenKPF(_ path: KPath) -> String {
        let mul = KPathExport.issMultiplier(path)
        var s = "\(mul)\n"
        func integer(_ value: Float) -> Int {
            guard value.isFinite else { return 0 }
            return Int(exactly: value.rounded()) ?? 0
        }
        for kp in path.points {
            let m = kp.frac * Float(mul)
            s += "\(integer(m.x)) \(integer(m.y)) \(integer(m.z))  \(kp.label)\n"
        }
        return s
    }

    /// ISS (integer-scaled special) multiplier: smallest integer M such that
    /// every special-point coordinate times M is (near-)integral. Port of
    /// XCrySDen C/xcBz.c BzGetISS: rational approx (denominator <= 100) then LCM.
    static func issMultiplier(_ path: KPath, maxDen: Int = 100) -> Int {
        let denominatorLimit = min(10_000, max(1, maxDen))
        func denominator(_ x: Float) -> Int {
            guard x.isFinite else { return 1 }
            let ax = abs(x)
            if ax < 1e-5 { return 1 }
            var best = 1
            var bestErr = Float.infinity
            for d in 1...denominatorLimit {
                let n = (ax * Float(d)).rounded()
                let err = abs(ax - n / Float(d))
                if err < bestErr { bestErr = err; best = d }
            }
            return best
        }
        func lcm(_ a: Int, _ b: Int) -> Int {
            let product = (a / gcd(a, b)).multipliedReportingOverflow(by: b)
            // KPF's multiplier is ultimately converted through Float and back to
            // Int. Keep it exactly representable and bounded if many unrelated
            // denominators would otherwise overflow.
            guard !product.overflow, product.partialValue <= 16_777_216 else { return 16_777_216 }
            return product.partialValue
        }
        func gcd(_ a: Int, _ b: Int) -> Int {
            var a = abs(a), b = abs(b)
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        var m = 1
        for kp in path.points {
            for c in [kp.frac.x, kp.frac.y, kp.frac.z] {
                m = lcm(m, denominator(c))
            }
        }
        return m
    }
}
