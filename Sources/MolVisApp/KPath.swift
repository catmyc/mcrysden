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

/// Physical reciprocal-space distances associated with one special k-point.
/// Nil values mean that the corresponding readout could not be computed safely.
struct KPathDistanceReadout: Equatable {
    let incomingDistance: Float?
    let cumulativeDistance: Float?
    let isComponentStart: Bool
}

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

    /// Return physical incoming and cumulative distances for each route node.
    /// Fractional route coordinates are mapped through the conventional
    /// reciprocal basis from `Cell.reciprocalVectors`, whose vectors include
    /// 2pi and therefore produce inverse-Angstrom distances.
    ///
    /// A break starts a new component: its node has no incoming distance and
    /// retains the cumulative value reached by the preceding component. The
    /// returned array always has one entry per route node, including invalid
    /// entries, so callers can keep readouts aligned with the editor rows.
    func reciprocalDistanceReadouts(cell: Cell) -> [KPathDistanceReadout] {
        guard !points.isEmpty else { return [] }

        let reciprocal = cell.reciprocalVectors
        let basis = [reciprocal.a, reciprocal.b, reciprocal.c]
        let basisFinite = basis.allSatisfy { vector in
            vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
        }

        // Check the reciprocal basis by a scale-relative determinant in Double.
        // This avoids accepting Cell.reciprocalVectors' zero fallback and avoids
        // Float overflow while validating very large but finite components.
        let basisValid: Bool = {
            guard basisFinite else { return false }
            let aa = basis[0], bb = basis[1], cc = basis[2]
            let ax = Double(aa.x), ay = Double(aa.y), az = Double(aa.z)
            let bx = Double(bb.x), by = Double(bb.y), bz = Double(bb.z)
            let cx = Double(cc.x), cy = Double(cc.y), cz = Double(cc.z)
            let la = sqrt(ax * ax + ay * ay + az * az)
            let lb = sqrt(bx * bx + by * by + bz * bz)
            let lc = sqrt(cx * cx + cy * cy + cz * cz)
            let determinant = ax * (by * cz - bz * cy)
                - ay * (bx * cz - bz * cx)
                + az * (bx * cy - by * cx)
            let scale = la * lb * lc
            return la.isFinite && lb.isFinite && lc.isFinite
                && la > 0 && lb > 0 && lc > 0
                && determinant.isFinite && scale.isFinite
                && abs(determinant) > 1e-12 * scale
        }()

        let validBreaks = self.validBreaks
        var result: [KPathDistanceReadout] = []
        result.reserveCapacity(points.count)

        var cumulative = 0.0
        var cumulativeValid = basisValid
        let maxFloat = Double(Float.greatestFiniteMagnitude)

        func finiteDistance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Double? {
            guard lhs.x.isFinite && lhs.y.isFinite && lhs.z.isFinite,
                  rhs.x.isFinite && rhs.y.isFinite && rhs.z.isFinite,
                  basisValid else { return nil }

            let dx = Double(rhs.x) - Double(lhs.x)
            let dy = Double(rhs.y) - Double(lhs.y)
            let dz = Double(rhs.z) - Double(lhs.z)
            let cartX = Double(reciprocal.a.x) * dx
                + Double(reciprocal.b.x) * dy
                + Double(reciprocal.c.x) * dz
            let cartY = Double(reciprocal.a.y) * dx
                + Double(reciprocal.b.y) * dy
                + Double(reciprocal.c.y) * dz
            let cartZ = Double(reciprocal.a.z) * dx
                + Double(reciprocal.b.z) * dy
                + Double(reciprocal.c.z) * dz
            let squared = cartX * cartX + cartY * cartY + cartZ * cartZ
            guard cartX.isFinite && cartY.isFinite && cartZ.isFinite,
                  squared.isFinite, squared >= 0 else { return nil }
            let distance = sqrt(squared)
            return distance.isFinite ? distance : nil
        }

        for index in points.indices {
            let startsComponent = index == 0 || validBreaks.contains(index - 1)
            let point = points[index].frac
            let pointFinite = point.x.isFinite && point.y.isFinite && point.z.isFinite
            var incoming: Float?
            var nodeCumulative: Float?

            if pointFinite {
                if startsComponent {
                    if cumulativeValid && cumulative.isFinite && cumulative <= maxFloat {
                        nodeCumulative = Float(cumulative)
                    }
                } else if let distance = finiteDistance(points[index - 1].frac, point),
                          distance <= maxFloat {
                    incoming = Float(distance)
                    if cumulativeValid {
                        let next = cumulative + distance
                        if next.isFinite && next <= maxFloat {
                            cumulative = next
                            nodeCumulative = Float(next)
                        } else {
                            cumulativeValid = false
                        }
                    }
                } else {
                    cumulativeValid = false
                }
            } else {
                cumulativeValid = false
            }

            result.append(KPathDistanceReadout(incomingDistance: incoming,
                                               cumulativeDistance: nodeCumulative,
                                               isComponentStart: startsComponent))
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
enum KPathExportFormat: String {
    case qe = "qe"
    case qeCrystalB = "qe-crystal-b"
    case qeTpibaB = "qe-tpiba-b"
    case kpf = "kpf"
    case vasp = "vasp"
    case wannier90 = "wannier90"

    /// Suggested filename for a freshly exported file of this format.
    var defaultFilename: String {
        switch self {
        case .qe: return "kpath.qe"
        case .qeCrystalB: return "kpath.crystal_b"
        case .qeTpibaB: return "kpath.tpiba_b"
        case .kpf: return "kpath.kpf"
        case .vasp: return "KPOINTS"
        case .wannier90: return "kpath.win"
        }
    }
}

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

/// Text exporters for a k-path (mirror XCrySDen's kPath.tcl targets): QE
/// `K_POINTS crystal` and `K_POINTS crystal_b` card bodies, Wannier90
/// `kpoint_path`, VASP line-mode KPOINTS, and the native `.kpf`.
enum KPathExport {
    /// Route-node cap for the pair-based exporters, matching the editor's and
    /// import parser's 1024-node route limit.
    static let maxRoutePoints = 1024

    enum ExportError: Error, LocalizedError {
        case disconnectedKPF
        case noConnectedEdge
        case tooFewPoints
        case tooManyPoints(Int)
        case nonFiniteRoute
        case unrepresentableRoute
        case orphanSingleton
        case missingCell
        case invalidCell

        var errorDescription: String? {
            switch self {
            case .disconnectedKPF:
                return "KPF export requires a fully connected path (no breaks). Use QE format for disconnected paths."
            case .noConnectedEdge:
                return "Export requires at least one connected pair of k-points."
            case .tooFewPoints:
                return "Export requires at least two k-points."
            case .tooManyPoints(let count):
                return "Export requires at most \(KPathExport.maxRoutePoints) route points; got \(count)."
            case .nonFiniteRoute:
                return "Export requires all k-point coordinates to be finite."
            case .unrepresentableRoute:
                return "QE tpiba_b export cannot represent the converted route coordinates."
            case .orphanSingleton:
                return "Wannier90 kpoint_path export requires every route point to belong to an edge (no orphan singleton nodes)."
            case .missingCell:
                return "QE tpiba_b export requires an active crystal cell."
            case .invalidCell:
                return "QE tpiba_b export requires a finite, non-degenerate active cell."
            }
        }
    }

    /// Availability policy for the sidebar editor. QE accepts any nonempty
    /// explicit k-point list, including a singleton. KPF is useful only for an
    /// actual connected path and has no encoding for arbitrary breaks. QE
    /// crystal_b and Wannier90 are pair-based line formats: crystal_b encodes
    /// any route with two or more points (breaks become official weight-0
    /// lines), while Wannier90 additionally rejects orphan singleton nodes.
    static func isEnabledInEditor(_ path: KPath, as format: KPathExportFormat) -> Bool {
        switch format {
        case .qe:
            return !path.points.isEmpty
        case .qeCrystalB, .qeTpibaB:
            return path.points.count >= 2
        case .kpf:
            return path.points.count >= 2 && !path.hasDisconnectedSegments
        case .vasp, .wannier90:
            // Pair-based line formats require at least one connected pair (two
            // points with no break between them) and no orphan singleton
            // components.
            let segs = path.segments()
            let hasPair = segs.contains(where: { $0.count >= 2 })
            let hasSingleton = segs.contains(where: { $0.count < 2 })
            return path.points.count >= 2 && hasPair && !hasSingleton
        }
    }

    static func editorHelp(_ path: KPath, as format: KPathExportFormat) -> String {
        switch format {
        case .qe where path.points.isEmpty:
            return "QE export requires at least one k-point."
        case .qe:
            return "Export explicit QE K_POINTS crystal data"
        case .qeCrystalB where path.points.count < 2:
            return "QE crystal_b export requires at least two k-points (one line)."
        case .qeCrystalB:
            return "Export explicit QE K_POINTS crystal_b card data"
        case .qeTpibaB where path.points.count < 2:
            return "QE tpiba_b export requires at least two k-points (one line); convention: alat = |cell.a|."
        case .qeTpibaB:
            return "Export explicit QE K_POINTS tpiba_b card data (Cartesian 2pi/alat; alat = |cell.a|)"
        case .kpf where path.points.count < 2:
            return "KPF export requires at least two route points."
        case .kpf where path.hasDisconnectedSegments:
            return "KPF export requires a fully connected path (no breaks). Use QE format for disconnected paths."
        case .kpf:
            return "Export as XCrySDen k-path file"
        case .vasp where path.points.count < 2:
            return "VASP line-mode requires at least two k-points (one segment)."
        case .vasp where path.segments().allSatisfy({ $0.count < 2 }):
            return "VASP line-mode requires at least one connected pair of k-points."
        case .vasp where path.segments().contains(where: { $0.count < 2 }):
            return "VASP line-mode requires a fully connected path (no orphan singleton nodes)."
        case .vasp:
            return "Export VASP line-mode KPOINTS file"
        case .wannier90 where path.points.count < 2:
            return "Wannier90 kpoint_path requires at least two k-points (one segment)."
        case .wannier90 where path.segments().allSatisfy({ $0.count < 2 }):
            return "Wannier90 kpoint_path requires at least one connected pair of k-points."
        case .wannier90 where path.segments().contains(where: { $0.count < 2 }):
            return "Wannier90 kpoint_path requires a fully connected path (no orphan singleton nodes)."
        case .wannier90:
            return "Export Wannier90 kpoint_path block"
        }
    }

    /// VASP line-mode KPOINTS file for a band-structure route. Format:
    ///   k-points for band structure       ! comment
    ///   N                                 ! points per segment (for VASP interpolation)
    ///   Line-mode
    ///   Reciprocal
    /// followed by endpoint PAIRS. Each pair defines one segment: VASP
    /// interpolates between its two points. Consecutive pairs within a
    /// connected component duplicate the shared endpoint. A blank line
    /// separates pairs. Singleton components are skipped.
    ///
    /// Uses reciprocal fractional coordinates and POSIX locale.
    static func vaspKPoints(_ path: KPath) throws -> String {
        let posixLocale = Locale(identifier: "en_US_POSIX")
        func fmt(_ kp: KPoint) -> String {
            String(format: "%.6f %.6f %.6f ! %@", locale: posixLocale,
                   arguments: [kp.frac.x, kp.frac.y, kp.frac.z, kp.label])
        }
        let segs = path.segments()
        if segs.contains(where: { $0.count < 2 }) {
            throw ExportError.noConnectedEdge
        }
        var pairs: [[String]] = []
        for range in segs {
            for i in range.lowerBound..<(range.upperBound - 1) {
                pairs.append([fmt(path.points[i]), fmt(path.points[i + 1])])
            }
        }
        guard !pairs.isEmpty else {
            throw ExportError.noConnectedEdge
        }
        var lines: [String] = [
            "k-points for band structure",
            "\(path.pointsPerSegment)",
            "Line-mode",
            "Reciprocal",
        ]
        for (idx, pair) in pairs.enumerated() {
            if idx > 0 { lines.append("") }
            lines.append(contentsOf: pair)
        }
        lines.append("")
        return lines.joined(separator: "\n")
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

    /// QE `K_POINTS crystal_b` card body (a `'bands'`-calculation path card).
    ///
    /// Official syntax (QE 7.x `Modules/read_cards.f90` and `Doc/brillouin_zones.pdf`):
    /// the count line gives the number of rows; each row is the START of one
    /// line in reciprocal space, written `kx ky kz w`. `generate_k_along_lines`
    /// emits the first row's point once, separately, then `wkaux(i)` subsequent
    /// increments per line — w subdivisions through the next endpoint
    /// (t = 1/w ... 1). So w is NOT an endpoint-inclusive point count: the
    /// line's start is carried over from the previous line (or the path start),
    /// consecutive lines share their junction point, and a line together with
    /// its carried start carries w+1 = n endpoint-inclusive samples.
    /// Coordinates are crystal (fractional) coordinates, same basis as
    /// `qeKPointsCrystal`.
    ///
    /// Policy implemented here (matching the route editor):
    /// - One row per route point, in order. The desired endpoint-inclusive
    ///   sample count per edge is `n = max(2, round(perSeg * d / L))` for an
    ///   edge of length d in a component of total length L (zero-length edges
    ///   get 2) — exactly the allocation `interpolated()` uses, bounded
    ///   2...200. Because `generate_k_along_lines` emits the line start
    ///   separately, the exported fourth column is the number of subdivisions
    ///   `w = n - 1` (bounded 1...199), which makes QE's output point count
    ///   exactly match the editor's interpolation for every edge.
    /// - A line crossing a route break gets weight 0. QE 7.x officially treats
    ///   a zero weight as a jump that emits only the next row's point (the
    ///   count formula in `read_cards.f90` compensates for such lines), so
    ///   disconnected components are NOT silently connected.
    /// - The final row's weight is ignored by QE (no line follows it); we
    ///   write 0.
    /// - Routes with more than `maxRoutePoints` (1024) nodes are rejected
    ///   before any output is constructed, matching the editor and import cap.
    /// - A route with fewer than two points or non-finite coordinates is
    ///   rejected rather than emitting bogus data.
    ///
    /// Like `qeKPointsCrystal`, this returns the card BODY only, not the card
    /// line: the text must be pasted or written immediately after a
    /// `K_POINTS crystal_b` card line (the UI save writes the body as-is).
    /// Uses POSIX locale.
    /// Validate a QE line-path and calculate the per-edge subdivision weights
    /// shared by `crystal_b` and `tpiba_b`. Keeping this in one helper makes the
    /// two cards differ only in their coordinate convention, never in sampling
    /// or break handling.
    private static func qeBandRouteData(_ path: KPath) throws -> (points: [KPoint], weights: [Int]) {
        let pts = path.points
        guard pts.count >= 2 else { throw ExportError.tooFewPoints }
        guard pts.count <= KPathExport.maxRoutePoints else { throw ExportError.tooManyPoints(pts.count) }
        guard pts.allSatisfy({ $0.frac.x.isFinite && $0.frac.y.isFinite && $0.frac.z.isFinite }) else {
            throw ExportError.nonFiniteRoute
        }
        let perSeg = min(200, max(2, path.pointsPerSegment))

        // Desired endpoint-inclusive samples per edge in Double math (Float
        // coordinates are finite, so a Double distance is always finite and
        // NaN-free), then convert to QE line weights n-1.
        var weights = Array(repeating: 0, count: pts.count)
        for range in path.segments() {
            var lengths: [Double] = []
            var componentLength = 0.0
            for i in range.lowerBound..<(range.upperBound - 1) {
                let p = pts[i].frac, q = pts[i + 1].frac
                let dx = Double(q.x) - Double(p.x)
                let dy = Double(q.y) - Double(p.y)
                let dz = Double(q.z) - Double(p.z)
                let d = sqrt(dx * dx + dy * dy + dz * dz)
                guard d.isFinite else { throw ExportError.nonFiniteRoute }
                lengths.append(d)
                componentLength += d
            }
            guard componentLength.isFinite else { throw ExportError.nonFiniteRoute }
            for (offset, d) in lengths.enumerated() {
                let apportioned: Double
                if componentLength > 0 {
                    apportioned = Double(perSeg) * d / componentLength
                } else {
                    apportioned = 2
                }
                guard apportioned.isFinite else { throw ExportError.nonFiniteRoute }
                let samples = min(200.0, max(2.0, apportioned.rounded()))
                weights[range.lowerBound + offset] = Int(samples) - 1
            }
        }
        return (points: pts, weights: weights)
    }

    static func qeKPointsCrystalB(_ path: KPath) throws -> String {
        let data = try qeBandRouteData(path)
        let posixLocale = Locale(identifier: "en_US_POSIX")
        var lines = ["\(data.points.count)"]
        for (i, kp) in data.points.enumerated() {
            let w = (i < data.points.count - 1) ? data.weights[i] : 0
            lines.append(String(format: "%.6f %.6f %.6f %d", locale: posixLocale,
                                arguments: [kp.frac.x, kp.frac.y, kp.frac.z, w]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Validate the active direct cell and return its conventional reciprocal
    /// basis together with QE's `alat`. The convention is deliberately stable:
    /// `alat = length(cell.a)`, irrespective of cell shape or which parser
    /// supplied the active cell.
    private static func qeTpibaBasis(for cell: Cell) throws -> (reciprocal: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>), alat: Double) {
        let directValues = [cell.a.x, cell.a.y, cell.a.z,
                            cell.b.x, cell.b.y, cell.b.z,
                            cell.c.x, cell.c.y, cell.c.z]
        guard directValues.allSatisfy({ $0.isFinite }) else { throw ExportError.invalidCell }
        let directScale = directValues.reduce(0.0) { max($0, abs(Double($1))) }
        guard directScale.isFinite, directScale > 0 else { throw ExportError.invalidCell }

        // Normalize before testing the determinant, matching Cell's reciprocal
        // construction and keeping the validity check scale-safe.
        let directA = SIMD3<Double>(Double(cell.a.x) / directScale,
                                    Double(cell.a.y) / directScale,
                                    Double(cell.a.z) / directScale)
        let directB = SIMD3<Double>(Double(cell.b.x) / directScale,
                                    Double(cell.b.y) / directScale,
                                    Double(cell.b.z) / directScale)
        let directC = SIMD3<Double>(Double(cell.c.x) / directScale,
                                    Double(cell.c.y) / directScale,
                                    Double(cell.c.z) / directScale)
        let normalizedVolume = dot(directA, cross(directB, directC))
        guard normalizedVolume.isFinite, abs(normalizedVolume) > 1e-12 else {
            throw ExportError.invalidCell
        }

        // QE's tpiba unit is 2pi/alat. Use Double for the norm and conversion
        // so the explicit `length(cell.a)` convention does not depend on Float
        // overflow or intermediate rounding.
        let alat = sqrt(Double(cell.a.x) * Double(cell.a.x)
                        + Double(cell.a.y) * Double(cell.a.y)
                        + Double(cell.a.z) * Double(cell.a.z))
        guard alat.isFinite, alat > 0 else { throw ExportError.invalidCell }

        let reciprocal = cell.reciprocalVectors
        let reciprocalValues = [reciprocal.a.x, reciprocal.a.y, reciprocal.a.z,
                                reciprocal.b.x, reciprocal.b.y, reciprocal.b.z,
                                reciprocal.c.x, reciprocal.c.y, reciprocal.c.z]
        guard reciprocalValues.allSatisfy({ $0.isFinite }) else { throw ExportError.invalidCell }
        let reciprocalScale = reciprocalValues.reduce(0.0) { max($0, abs(Double($1))) }
        guard reciprocalScale.isFinite, reciprocalScale > 0 else { throw ExportError.invalidCell }
        let reciprocalA = SIMD3<Double>(Double(reciprocal.a.x) / reciprocalScale,
                                        Double(reciprocal.a.y) / reciprocalScale,
                                        Double(reciprocal.a.z) / reciprocalScale)
        let reciprocalB = SIMD3<Double>(Double(reciprocal.b.x) / reciprocalScale,
                                        Double(reciprocal.b.y) / reciprocalScale,
                                        Double(reciprocal.b.z) / reciprocalScale)
        let reciprocalC = SIMD3<Double>(Double(reciprocal.c.x) / reciprocalScale,
                                        Double(reciprocal.c.y) / reciprocalScale,
                                        Double(reciprocal.c.z) / reciprocalScale)
        let reciprocalVolume = dot(reciprocalA, cross(reciprocalB, reciprocalC))
        guard reciprocalVolume.isFinite, abs(reciprocalVolume) > 1e-12 else {
            throw ExportError.invalidCell
        }
        return (reciprocal: reciprocal, alat: alat)
    }

    /// Convert a conventional reciprocal-fraction route node to Cartesian QE
    /// `tpiba_b` coordinates: Cartesian reciprocal `1/Å` coordinates are scaled
    /// by `alat / 2pi`, yielding the dimensionless units `2pi/alat`.
    static func qeKPointsTpibaB(_ path: KPath, cell: Cell) throws -> String {
        let data = try qeBandRouteData(path)
        let basis = try qeTpibaBasis(for: cell)
        let unitScale = basis.alat / (2.0 * Double.pi)
        guard unitScale.isFinite, unitScale > 0 else { throw ExportError.invalidCell }

        let coordinates = try data.points.map { point -> SIMD3<Float> in
            let frac = point.frac
            let cartesian = SIMD3<Double>(
                Double(basis.reciprocal.a.x) * Double(frac.x)
                    + Double(basis.reciprocal.b.x) * Double(frac.y)
                    + Double(basis.reciprocal.c.x) * Double(frac.z),
                Double(basis.reciprocal.a.y) * Double(frac.x)
                    + Double(basis.reciprocal.b.y) * Double(frac.y)
                    + Double(basis.reciprocal.c.y) * Double(frac.z),
                Double(basis.reciprocal.a.z) * Double(frac.x)
                    + Double(basis.reciprocal.b.z) * Double(frac.y)
                    + Double(basis.reciprocal.c.z) * Double(frac.z))
            let tpiba = cartesian * unitScale
            guard tpiba.x.isFinite, tpiba.y.isFinite, tpiba.z.isFinite else {
                throw ExportError.unrepresentableRoute
            }
            let result = SIMD3<Float>(Float(tpiba.x), Float(tpiba.y), Float(tpiba.z))
            guard result.x.isFinite, result.y.isFinite, result.z.isFinite else {
                throw ExportError.unrepresentableRoute
            }
            return result
        }

        let posixLocale = Locale(identifier: "en_US_POSIX")
        var lines = ["\(data.points.count)"]
        for (i, point) in coordinates.enumerated() {
            let w = (i < coordinates.count - 1) ? data.weights[i] : 0
            lines.append(String(format: "%.6f %.6f %.6f %d", locale: posixLocale,
                                arguments: [point.x, point.y, point.z, w]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Wannier90 `kpoint_path` block for a band-structure route. Official
    /// syntax:
    ///   begin kpoint_path
    ///   label1 x1 y1 z1 label2 x2 y2 z2
    ///   ...
    ///   end kpoint_path
    /// One row per connected EDGE; disconnected components yield non-sharing
    /// rows, so breaks are preserved without any special encoding.
    ///
    /// Policy implemented here:
    /// - Routes with fewer than two points, with more than `maxRoutePoints`
    ///   (1024) nodes (rejected before any output is constructed, matching the
    ///   editor and import cap), with no connected edge at all, or with orphan
    ///   singleton components (route points belonging to no edge) are
    ///   rejected; non-finite coordinates are rejected.
    /// - Labels are sanitized to a single whitespace-free token capped at 64
    ///   characters; blank/whitespace labels get deterministic generated labels
    ///   "K1", "K2", ... by stable route index, so a shared endpoint carries
    ///   the same generated label in both adjacent rows.
    ///
    /// Uses POSIX locale.
    static func wannier90KPointPath(_ path: KPath) throws -> String {
        let pts = path.points
        guard pts.count >= 2 else { throw ExportError.tooFewPoints }
        guard pts.count <= KPathExport.maxRoutePoints else { throw ExportError.tooManyPoints(pts.count) }
        guard pts.allSatisfy({ $0.frac.x.isFinite && $0.frac.y.isFinite && $0.frac.z.isFinite }) else {
            throw ExportError.nonFiniteRoute
        }
        let segs = path.segments()
        guard segs.contains(where: { $0.count >= 2 }) else { throw ExportError.noConnectedEdge }
        guard !segs.contains(where: { $0.count < 2 }) else { throw ExportError.orphanSingleton }

        let posixLocale = Locale(identifier: "en_US_POSIX")
        func fmt(_ frac: SIMD3<Float>) -> String {
            String(format: "%.6f %.6f %.6f", locale: posixLocale,
                   arguments: [frac.x, frac.y, frac.z])
        }
        var s = "begin kpoint_path\n"
        for range in segs {
            for i in range.lowerBound..<(range.upperBound - 1) {
                s += "\(wannier90Label(pts[i].label, routeIndex: i)) \(fmt(pts[i].frac)) "
                s += "\(wannier90Label(pts[i + 1].label, routeIndex: i + 1)) \(fmt(pts[i + 1].frac))\n"
            }
        }
        s += "end kpoint_path\n"
        return s
    }

    /// Deterministic Wannier90 label for a route node: a blank/whitespace
    /// label becomes "K<routeIndex+1>"; otherwise whitespace is removed so the
    /// label is a single token, Wannier90 comment characters `!` and `#` are
    /// replaced with `_` so they can never start a comment in the exported
    /// file, and the result is capped at 64 characters.
    static func wannier90Label(_ raw: String, routeIndex: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "K\(routeIndex + 1)" }
        let sanitized = String(trimmed
            .filter { !$0.isWhitespace }
            .map { ($0 == "!" || $0 == "#") ? "_" : $0 }
            .prefix(64))
        return sanitized.isEmpty ? "K\(routeIndex + 1)" : sanitized
    }

    /// Export text for the given UI format: `.qe` => QE K_POINTS crystal card
    /// body, `.qeCrystalB` => QE K_POINTS crystal_b card body,
    /// `.qeTpibaB` => QE K_POINTS tpiba_b card body (requires `cell`),
    /// `.kpf` => XCrySDen native k-path file, `.vasp` => VASP line-mode
    /// KPOINTS, and `.wannier90` => Wannier90 kpoint_path block. Formats that
    /// cannot represent the path (e.g. KPF with breaks) throw a precise
    /// ExportError.
    static func export(_ path: KPath, as format: KPathExportFormat, cell: Cell? = nil) throws -> String {
        switch format {
        case .qe: return qeKPointsCrystal(path)
        case .qeCrystalB: return try qeKPointsCrystalB(path)
        case .qeTpibaB:
            guard let cell else { throw ExportError.missingCell }
            return try qeKPointsTpibaB(path, cell: cell)
        case .kpf: return try xcrysdnenKPF(path)
        case .vasp: return try vaspKPoints(path)
        case .wannier90: return try wannier90KPointPath(path)
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
