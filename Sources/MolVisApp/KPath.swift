import Foundation
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
    /// Break indices that actually separate two nodes in the current route.
    /// The model is deliberately tolerant of programmatic malformed values so
    /// rendering and interpolation agree on treating out-of-range entries as
    /// inert. Persisted/editor state is validated more strictly at its boundary.
    var validBreaks: Set<Int> {
        Set(breaks.filter { $0 >= 0 && $0 < points.count - 1 })
    }

    /// Whether this route contains at least one real disconnected boundary.
    var hasDisconnectedSegments: Bool { !validBreaks.isEmpty }

    /// The connected segments of this path, expressed as half-open ranges
    /// [start, end) into `points`. Each segment is interpolated independently;
    /// there is NO interpolation across a break. A path with no breaks has a
    /// single segment covering all points. Singleton components are retained so
    /// a path such as A | B | C still preserves all three explicit k-points.
    /// Out-of-range breaks are ignored.
    func segments() -> [Range<Int>] {
        guard !points.isEmpty else { return [] }
        let breakSorted = validBreaks.sorted()
        var result: [Range<Int>] = []
        var start = 0
        for b in breakSorted {
            // A break at index b means no segment joins points[b] and points[b+1].
            // The current segment ends at b (inclusive), so the range is [start, b+1).
            if b >= start {
                result.append(start..<(b + 1))
            }
            start = b + 1
        }
        if start < points.count {
            result.append(start..<points.count)
        }
        return result
    }

    /// Interpolate this path into a dense list of fractional k-points.
    ///
    /// `pointsPerSegment` is the sampling budget for each connected component
    /// (path segment): within each component, samples are allocated across its
    /// individual edges proportional to that component's total length. This means
    /// each connected component gets approximately `pointsPerSegment` samples
    /// regardless of how many edges it contains.
    ///
    /// Breaks are respected: no interpolation occurs between disconnected
    /// segments. The first endpoint of every component is always included,
    /// including a singleton component. All-zero components (degenerate
    /// segments with zero total length) are handled deterministically: each
    /// edge gets exactly 2 samples (start+end).
    ///
    /// A global cap of 1,000,000 output points prevents unbounded allocation.
    func interpolated() -> [SIMD3<Float>] {
        let pts = points.map { $0.frac }
        guard pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return [] }
        guard pts.count >= 2 else { return pts }

        let segs = segments()
        guard !segs.isEmpty else { return [] }

        // Compute per-segment (connected component) lengths.
        var segLens: [(range: Range<Int>, length: Float)] = []
        for range in segs {
            var segLen: Float = 0
            for i in range.lowerBound..<(range.upperBound - 1) {
                let d = sqrt(dot(pts[i+1] - pts[i], pts[i+1] - pts[i]))
                guard d.isFinite else { return [] }
                segLen += d
            }
            guard segLen.isFinite else { return [] }
            segLens.append((range: range, length: segLen))
        }

        // This value is UI-controlled in normal use, but KPath is also constructed
        // programmatically. Bound it so a malformed value cannot trap during the
        // Float-to-Int conversion or request an effectively unbounded array.
        let perSeg = min(1_000_000, max(2, pointsPerSegment))
        let maxOutputPoints = 1_000_000
        var out: [SIMD3<Float>] = []
        // A component with E edges needs at least E+1 output points to retain
        // every one of its endpoints. Reserve those minima for later components
        // before spending the global cap on dense sampling of an earlier one.
        // For paths with more than one million nodes, the cap necessarily wins
        // and the route is emitted in order until it is full.
        var minimumPointsRemaining = pts.count

        for segInfo in segLens {
            let range = segInfo.range
            let componentLength = segInfo.length
            minimumPointsRemaining -= range.count
            let available = maxOutputPoints - out.count
            guard available > 0 else { return out }

            // When every component's minimum fits, reserve enough room for all
            // later components. If the route itself exceeds the cap, emit the
            // prefix that fits; no cap policy can retain every endpoint then.
            let componentCapacity: Int
            if minimumPointsRemaining <= available - range.count {
                componentCapacity = available - minimumPointsRemaining
            } else {
                componentCapacity = available
            }
            // If the explicit route alone is larger than the global cap, it is
            // mathematically impossible to retain every node.  Do not turn that
            // malformed/programmatic input into an empty export: emit the
            // ordered prefix that fits, which is also the only cap policy that
            // preserves route order without inventing a discontinuity.
            guard componentCapacity >= range.count else {
                let end = range.lowerBound + componentCapacity
                out.append(contentsOf: pts[range.lowerBound..<end])
                return out
            }

            // A disconnected singleton still has semantic value in an explicit
            // QE list, even though it has no edge to interpolate.
            guard range.count >= 2 else {
                out.append(pts[range.lowerBound])
                continue
            }

            // First choose the unconstrained per-edge allocation. Express it as
            // extras beyond the two endpoint samples: an E-edge component then
            // emits E+1+sum(extras) points after shared endpoints are de-duped.
            var desiredExtras: [Int] = []
            desiredExtras.reserveCapacity(range.count - 1)
            for i in range.lowerBound..<(range.upperBound - 1) {
                let d = sqrt(dot(pts[i+1] - pts[i], pts[i+1] - pts[i]))
                guard d.isFinite else { return [] }
                // Allocate samples for this edge proportional to its length
                // relative to the COMPONENT's total length (not a global total).
                // This is the per-component budget: each component gets ~perSeg
                // samples total, distributed across its edges.
                let apportioned: Float
                if componentLength > 0 {
                    apportioned = round(Float(perSeg) * d / componentLength)
                } else {
                    // All-zero component: each edge gets exactly 2 samples.
                    apportioned = 2
                }
                guard apportioned.isFinite else { return [] }
                // Clamp before conversion so even a numerically surprising but
                // finite intermediate can never overflow Int.
                let bounded = min(Float(perSeg), max(0, apportioned))
                desiredExtras.append(max(0, Int(bounded) - 2))
            }

            let basePoints = range.count
            let extraCapacity = componentCapacity - basePoints
            var extras = desiredExtras
            // Under the global cap, keep every edge's endpoints and spend any
            // remaining samples proportionally across edges. Normal routes take
            // this branch only when their requested allocation already fits
            // exactly.
            var totalExtras = 0
            for extra in desiredExtras {
                if extra > extraCapacity - totalExtras {
                    totalExtras = extraCapacity + 1
                    break
                }
                totalExtras += extra
            }
            if totalExtras > extraCapacity {
                let requestedExtras = desiredExtras.reduce(0.0) { $0 + Double($1) }
                let scale = Double(extraCapacity) / requestedExtras
                var allocated = 0
                var remainders: [(fraction: Double, index: Int)] = []
                extras = desiredExtras.enumerated().map { index, desired in
                    let raw = Double(desired) * scale
                    let granted = min(desired, Int(raw))
                    allocated += granted
                    remainders.append((raw - Double(granted), index))
                    return granted
                }
                // Largest-remainder apportionment preserves the proportional
                // allocation as closely as integral samples allow; index order
                // is the deterministic tie-break.
                remainders.sort {
                    $0.fraction == $1.fraction ? $0.index < $1.index : $0.fraction > $1.fraction
                }
                var remainingExtras = extraCapacity - allocated
                while remainingExtras > 0 {
                    var progressed = false
                    for remainder in remainders where remainingExtras > 0 {
                        guard extras[remainder.index] < desiredExtras[remainder.index] else { continue }
                        extras[remainder.index] += 1
                        remainingExtras -= 1
                        progressed = true
                    }
                    // Defensive escape for an unexpected rounding condition;
                    // it cannot exceed the global output cap either way.
                    guard progressed else { break }
                }
            }

            // Within a connected component, interpolate every actual edge once.
            for (offset, i) in (range.lowerBound..<(range.upperBound - 1)).enumerated() {
                let n = 2 + extras[offset]
                // Half-open sub-segments: emit the start point for the first
                // edge of EVERY connected component; subsequent edges within the
                // same component skip j=0 (the shared endpoint).
                let j0 = (i == range.lowerBound) ? 0 : 1
                for j in j0..<n {
                    let t = Float(j) / Float(n - 1)
                    out.append(pts[i] * (1 - t) + pts[i + 1] * t)
                }
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
    enum ExportError: Error, LocalizedError {
        case disconnectedKPF

        var errorDescription: String? {
            switch self {
            case .disconnectedKPF:
                return "KPF export requires a fully connected path (no breaks). Use QE format for disconnected paths."
            }
        }
    }

    /// Availability policy for the sidebar editor. QE accepts any nonempty
    /// explicit k-point list, including a singleton. KPF is useful only for an
    /// actual connected path and has no encoding for arbitrary breaks.
    static func isEnabledInEditor(_ path: KPath, as format: KPathExportFormat) -> Bool {
        switch format {
        case .qe:
            return !path.points.isEmpty
        case .kpf:
            return path.points.count >= 2 && !path.hasDisconnectedSegments
        }
    }

    static func editorHelp(_ path: KPath, as format: KPathExportFormat) -> String {
        switch format {
        case .qe where path.points.isEmpty:
            return "QE export requires at least one k-point."
        case .qe:
            return "Export explicit QE K_POINTS crystal data"
        case .kpf where path.points.count < 2:
            return "KPF export requires at least two route points."
        case .kpf where path.hasDisconnectedSegments:
            return "KPF export requires a fully connected path (no breaks). Use QE format for disconnected paths."
        case .kpf:
            return "Export as XCrySDen k-path file"
        }
    }

    /// QE `K_POINTS crystal` card: a count line followed by `kx ky kz w` lines
    /// (weight w = 1.0 for a uniform sampling).
    static func qeKPointsCrystal(_ path: KPath) -> String {
        let pts = path.interpolated()
        // QE input is machine-readable text and always requires '.' as the
        // decimal separator, independent of the user's UI locale.
        let posixLocale = Locale(identifier: "en_US_POSIX")
        var s = "\(pts.count)\n"
        for p in pts {
            s += String(format: "%.6f %.6f %.6f 1.0\n", locale: posixLocale,
                        arguments: [p.x, p.y, p.z])
        }
        return s
    }

    /// Export text for the given UI format: `.qe` => QE K_POINTS crystal,
    /// `.kpf` => XCrySDen native k-path file.
    /// KPF export throws if the path has breaks, since the format cannot
    /// represent disconnected segments unambiguously.
    static func export(_ path: KPath, as format: KPathExportFormat) throws -> String {
        switch format {
        case .qe: return qeKPointsCrystal(path)
        case .kpf: return try xcrysdnenKPF(path)
        }
    }

    /// XCrySDen native k-path file (.kpf): an integer ISS multiplier line, then
    /// `kx ky kz  label` lines for each special (high-symmetry) point. The
    /// multiplier clears any common denominator so band codes get exact rationals.
    ///
    /// KPF cannot represent disconnected segments: a repeated label only
    /// indicates a break when the shared endpoint happens to be that label,
    /// which is ambiguous. Throws `ExportError.disconnectedKPF` when the path
    /// has breaks; use QE format for disconnected paths.
    static func xcrysdnenKPF(_ path: KPath) throws -> String {
        if path.hasDisconnectedSegments {
            throw ExportError.disconnectedKPF
        }
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
