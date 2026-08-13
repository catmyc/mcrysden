import Foundation
import simd

// Full-grid reconstruction of symmetry-reduced Quantum ESPRESSO k-meshes.
//
// A QE nscf run with symmetry enabled samples only the irreducible wedge of
// the Monkhorst-Pack grid. Band surfaces (and mesh interpolation) need every
// point of the full grid, so this module reconstructs it the same way QE's
// PP/src/fermisurface.f90 `fill_fs_grid` does: for each full-grid point, find
// an irreducible point equivalent under one of the space-group symmetry
// matrices S (k' = S k + t) and, when the run obeys time reversal, also under
// -k. The irreducible point's eigenvalues are then reused at the full point.
//
// The symmetry matrices are read from the standard PWscf output block:
//
//     24 Sym. Ops. (no inversion) found
//     ...
//       isym =  1     identity
//     cryst.   s( 1) = (     1          0          0      )
//                     (     0          1          0      )
//                     (     0          0          1      )
//     cart.    s( 1) = (  1.0000000  0.0000000  0.0000000 )
//
// Non-symmorphic operations carry an extra "f =( ... )" column on each
// crystal row; symmorphic ones leave it out (fractional translation 0).

/// One space-group symmetry operation in fractional coordinates.
struct QESymmetryOp: Equatable, Codable {
    /// Row-major 3x3 integer rotation matrix.
    var rotation: [SIMD3<Float>]
    /// Fractional translation (usually 0 or a lattice fraction).
    var translation: SIMD3<Float>
    /// True when the operation includes time reversal (printed as
    /// `Time Reversal 1` in magnetized noncollinear outputs).
    var timeReversal: Bool

    init(rotation: [SIMD3<Float>], translation: SIMD3<Float>, timeReversal: Bool = false) {
        self.rotation = rotation
        self.translation = translation
        self.timeReversal = timeReversal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try c.decode([SIMD3<Float>].self, forKey: .rotation)
        translation = try c.decode(SIMD3<Float>.self, forKey: .translation)
        timeReversal = try c.decodeIfPresent(Bool.self, forKey: .timeReversal) ?? false
    }
}

/// The explicit full-grid specification echoed by a QE K_POINTS card.
struct QEKGridSpec: Equatable, Codable {
    var dims: [Int]
    var shifts: [Float]
}

/// Errors thrown by full-grid reconstruction.
enum BandGridSymmetryError: Error, Equatable, CustomStringConvertible {
    case noSymmetryData
    case unrepresentableCoordinates
    case inconsistentOrbitSize
    case spinChannelMismatch
    case oversizedGrid

    var description: String {
        switch self {
        case .noSymmetryData:
            return "QE symmetry-reduced mesh cannot be expanded: no symmetry matrices were found in the output"
        case .unrepresentableCoordinates:
            return "QE symmetry-reduced mesh cannot be expanded: irreducible k-point coordinates do not lie on a uniform full grid"
        case .inconsistentOrbitSize:
            return "QE symmetry-reduced mesh cannot be expanded: symmetry orbit does not tile a product grid"
        case .spinChannelMismatch:
            return "QE symmetry-reduced mesh cannot be expanded: spin channels disagree on the k-point mesh"
        case .oversizedGrid:
            return "QE symmetry-reduced mesh cannot be expanded: reconstructed grid exceeds the 32^3 cap"
        }
    }
}

/// Symmetry parsing and full-grid reconstruction.
enum BandGridSymmetry {

    /// Parse the crystal symmetry matrices of the LAST calculation in `text`.
    /// Returns [] when no symmetry block is present (e.g. "No symmetry!").
    static func parseSymmetryOps(_ text: String) -> [QESymmetryOp] {
        let lines = text.components(separatedBy: "\n")
        let start = lastCalculationStart(lines)
        var ops: [QESymmetryOp] = []
        var pendingTimeReversal = false
        var i = start
        while i < lines.count {
            let lower = lines[i].lowercased()
            guard !lower.contains("sym. ops.") else { i += 1; continue }
            let trimmed = lower.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("time reversal") {
                // `Time Reversal 0|1` precedes the crystal rows of the same op.
                pendingTimeReversal = trimmed.contains("1")
                i += 1
                continue
            }
            guard let (matrix, translation) = parseCrystalSymmetryRow(lines, at: i) else {
                i += 1
                continue
            }
            ops.append(QESymmetryOp(rotation: matrix, translation: translation,
                                    timeReversal: pendingTimeReversal))
            pendingTimeReversal = false
            i += 3
        }
        return ops
    }

    /// Parse an echoed K_POINTS {automatic|gamma} card, when present.
    static func parseKGridSpec(_ text: String) -> QEKGridSpec? {
        let lines = text.components(separatedBy: "\n")
        // Scope to the LAST calculation like the symmetry parse, so a
        // concatenated output never adopts an earlier run's grid card.
        let scoped = Array(lines[lastCalculationStart(lines)...])
        guard let kp = scoped.firstIndex(where: { $0.contains("K_POINTS") }) else { return nil }
        // The variant may share the K_POINTS line or sit within the next lines.
        var variantIdx: Int? = nil
        for offset in 0..<3 {
            let idx = kp + offset
            guard idx < scoped.count else { break }
            let lower = scoped[idx].lowercased()
            if lower.contains("automatic") || lower.contains("gamma") {
                variantIdx = idx
                break
            }
        }
        guard let variantIdx else { return nil }
        let variantLine = scoped[variantIdx].lowercased()
        let specIdx = variantIdx + 1
        guard specIdx < scoped.count else { return nil }
        let numbers = scoped[specIdx].split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { Int($0) }
        if variantLine.contains("automatic") {
            // QE echoes either 6 numbers (dims + shifts) or 4 (dims only;
            // unshifted); a bare 3-number dims line is also accepted with zero
            // shifts. All are valid automatic cards.
            guard numbers.count >= 3 else { return nil }
            let dims = Array(numbers[0..<3])
            let rawShifts = numbers.count >= 6 ? Array(numbers[3..<6]) : [0, 0, 0]
            guard dims.allSatisfy({ (1...32).contains($0) }),
                  rawShifts.allSatisfy({ $0 == 0 || $0 == 1 }) else { return nil }
            // QE convention: s_i = 1 offsets the grid by HALF a step, so the
            // first node sits at s_i / (2 n_i).
            return QEKGridSpec(dims: dims, shifts: zip(dims, rawShifts).map {
                Float($0.1) / (2 * Float($0.0))
            })
        }
        if variantLine.contains("gamma") {
            guard numbers.count >= 3 else { return nil }
            let dims = Array(numbers[0..<3])
            guard dims.allSatisfy({ (1...32).contains($0) }) else { return nil }
            // {gamma} grids are Gamma-centered: first node at 1/(2n).
            return QEKGridSpec(dims: dims, shifts: dims.map { 0.5 / Float($0) })
        }
        return nil
    }

    /// Expand a symmetry-reduced mesh to the full Monkhorst-Pack grid.
    static func expand(_ bands: BandStructure,
                       operations: [QESymmetryOp]? = nil,
                       gridSpec: QEKGridSpec? = nil) throws -> BandStructure {
        let ops = operations ?? bands.symmetryOperations
        guard !ops.isEmpty else { throw BandGridSymmetryError.noSymmetryData }

        guard bands.hasValidChannelLayout else {
            throw BandGridSymmetryError.spinChannelMismatch
        }
        let perSpin = bands.kPointsPerSpin
        let nSpin = bands.nSpin
        let nBands = bands.nBands
        guard perSpin > 0, nBands > 0, perSpin <= 32 * 32 * 32 else {
            throw BandGridSymmetryError.oversizedGrid
        }

        // Fractional source coordinates (converting Cartesian through the
        // reciprocal basis when needed).
        let source: [SIMD3<Float>]
        if bands.kPointsAreCrystal {
            source = Array(bands.kPoints[0..<perSpin]).map { $0.k }
        } else {
            guard let reciprocal = bands.reciprocal, reciprocal.count == 3,
                  let converted = cartesianToFractionalPoints(
                    Array(bands.kPoints[0..<perSpin]).map { $0.k },
                    reciprocal: reciprocal) else {
                throw BandGridSymmetryError.unrepresentableCoordinates
            }
            source = converted
        }

        // Orbit closure under every symmetry operation (+ time reversal when
        // applicable). Each orbit point remembers the source channel index it
        // came from (quantized dedup keeps the first).
        struct OrbitPoint {
            let frac: SIMD3<Float>
            let sourceIndex: Int
        }
        var orbit: [OrbitPoint] = []
        var orbitKeys: Set<Int> = []
        func orbitKey(_ p: SIMD3<Float>) -> Int {
            let q = quantize(p)
            return Int(q.x) * 1_000_000 + Int(q.y) * 1_000 + Int(q.z)
        }
        func addOrbit(_ p: SIMD3<Float>, sourceIndex: Int) {
            let wrapped = wrapFraction(p)
            let key = orbitKey(wrapped)
            if orbitKeys.insert(key).inserted {
                orbit.append(OrbitPoint(frac: wrapped, sourceIndex: sourceIndex))
            }
        }
        for (idx, k) in source.enumerated() {
            for op in ops {
                var image = apply(op, to: k)
                if op.timeReversal { image = -image }
                addOrbit(image, sourceIndex: idx)
                if bands.timeReversalSymmetric {
                    addOrbit(-image, sourceIndex: idx)
                }
            }
        }
        guard orbit.count <= 32 * 32 * 32 else { throw BandGridSymmetryError.oversizedGrid }
        // A complete mesh is its own orbit closure: keep it unchanged so the
        // expansion is idempotent for callers that retry after reconstruction.
        if orbit.count == perSpin { return bands }
        guard orbit.count > perSpin else { throw BandGridSymmetryError.inconsistentOrbitSize }

        // Infer the full grid dimensions when no explicit spec is present:
        // the smallest per-axis count on which every orbit coordinate lands.
        let dims: [Int]
        let shifts: [Float]
        if let spec = gridSpec {
            guard spec.dims.count == 3, spec.shifts.count == 3,
                  spec.dims.allSatisfy({ (1...32).contains($0) }) else {
                throw BandGridSymmetryError.inconsistentOrbitSize
            }
            dims = spec.dims
            shifts = spec.shifts
        } else {
            var inferred: [Int] = []
            var inferredShifts: [Float] = []
            for axis in 0..<3 {
                let coordinates = orbit.map { $0.frac[axis] }
                guard let n = inferGridCount(coordinates) else {
                    throw BandGridSymmetryError.unrepresentableCoordinates
                }
                inferred.append(n)
                // Shift of the inferred grid: the smallest fractional part of
                // coordinate * n among the orbit points (0 when the grid is
                // Gamma-centered).
                var shift = Float.greatestFiniteMagnitude
                for c in coordinates {
                    let scaled = c * Float(n)
                    let frac = scaled - floor(scaled)
                    if frac < shift { shift = frac }
                }
                inferredShifts.append(shift / Float(n))
            }
            dims = inferred
            shifts = inferredShifts
        }
        if gridSpec == nil {
            // Only the inferred path needs the orbit to BE the full product
            // grid; an explicit grid spec is authoritative and the matching
            // loop below validates its coverage instead.
            guard dims.reduce(1, *) == orbit.count else {
                throw BandGridSymmetryError.inconsistentOrbitSize
            }
        }

        // Full grid in lattice order with one node per orbit point.
        func node(_ i: Int, _ axis: Int) -> Float {
            Float(i) / Float(dims[axis]) + shifts[axis]
        }
        var fullFrac: [SIMD3<Float>] = []
        var fullSource: [Int] = []
        fullFrac.reserveCapacity(orbit.count)
        fullSource.reserveCapacity(orbit.count)
        for iz in 0..<dims[2] {
            for iy in 0..<dims[1] {
                for ix in 0..<dims[0] {
                    let k = wrapFraction(SIMD3<Float>(node(ix, 0), node(iy, 1), node(iz, 2)))
                    let match = orbit.min { lhs, rhs in
                        simd_distance_squared(lhs.frac, k) < simd_distance_squared(rhs.frac, k)
                    }
                    guard let match, simd_distance_squared(match.frac, k) < 1e-5 else {
                        throw BandGridSymmetryError.inconsistentOrbitSize
                    }
                    fullFrac.append(k)
                    fullSource.append(match.sourceIndex)
                }
            }
        }

        // Spin channels must sample the same fractional mesh; energies come
        // from each channel's matching source index.
        var out: [BandKPoint] = []
        out.reserveCapacity(nSpin * orbit.count)
        for s in 0..<nSpin {
            let base = s * perSpin
            guard base + perSpin <= bands.kPoints.count else {
                throw BandGridSymmetryError.spinChannelMismatch
            }
            let channel = Array(bands.kPoints[base..<base + perSpin])
            for i in 0..<fullFrac.count {
                let src = fullSource[i]
                guard src >= 0, src < channel.count,
                      channel[src].energies.count == nBands else {
                    throw BandGridSymmetryError.spinChannelMismatch
                }
                out.append(BandKPoint(k: fullFrac[i], weight: 0, label: "",
                                      energies: channel[src].energies))
            }
        }

        return BandStructure(
            kPoints: out,
            fermiEnergy: bands.fermiEnergy,
            nSpin: nSpin,
            reciprocal: bands.reciprocal,
            kPointsAreCrystal: true,
            kPointsPerSpin: orbit.count,
            isMesh: true,
            cell: bands.cell,
            periodicDim: bands.periodicDim,
            timeReversalSymmetric: bands.timeReversalSymmetric,
            symmetryOperations: ops,
            kGridSpec: QEKGridSpec(dims: dims, shifts: shifts)
        )
    }

    // MARK: - Helpers

    /// Start of the last calculation: the last real "Program PWSCF" banner.
    private static func lastCalculationStart(_ lines: [String]) -> Int {
        var start = 0
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard lower.contains("program pwscf"), !lower.contains("stops") else { continue }
            guard let range = lower.range(of: "program pwscf"),
                  let token = lower[range.upperBound...]
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { continue }
            if token.first?.isNumber == true || token.hasPrefix("v") { start = i }
        }
        return start
    }

    /// Parse a `cryst. s(N) = (...)` 3-row matrix plus optional f column.
    private static func parseCrystalSymmetryRow(_ lines: [String], at index: Int) -> ([SIMD3<Float>], SIMD3<Float>)? {
        guard index + 2 < lines.count else { return nil }
        let first = lines[index].lowercased().trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("cryst."), first.contains("s(") else { return nil }
        var matrix: [SIMD3<Float>] = []
        var translationRow = [Float](repeating: 0, count: 3)
        var hasTranslation = false
        for row in 0..<3 {
            let line = lines[index + row]
            // Everything before the "=" is the `s( N)` index or indentation;
            // parse parenthesized groups only after it so the index number is
            // never mistaken for a matrix entry.
            let afterEquals: String
            if let eq = line.firstIndex(of: "=") {
                afterEquals = String(line[line.index(after: eq)...])
            } else {
                afterEquals = line
            }
            let groups = parenthesizedNumberGroups(afterEquals)
            guard let matrixGroup = groups.first, matrixGroup.count >= 3 else { return nil }
            matrix.append(SIMD3<Float>(matrixGroup[0], matrixGroup[1], matrixGroup[2]))
            if groups.count >= 2, let f = groups[1].first {
                translationRow[row] = f
                hasTranslation = true
            }
        }
        return (matrix, hasTranslation
                ? SIMD3<Float>(translationRow[0], translationRow[1], translationRow[2])
                : .zero)
    }

    /// Numeric values of each parenthesized group in a QE symmetry row. The
    /// matrix sits in the first `( ... )` group; the optional `f =(...)`
    /// translation column is a second group. Text outside parentheses (the
    /// `s( N)` index, `cryst.`, `f =`) is ignored.
    private static func parenthesizedNumberGroups(_ line: String) -> [[Float]] {
        var groups: [[Float]] = []
        var current: [Float] = []
        var buffer = ""
        var inGroup = false
        func flushNumber() {
            if let value = Float(buffer), value.isFinite { current.append(value) }
            buffer = ""
        }
        for ch in line {
            if ch == "(" {
                inGroup = true
                current = []
            } else if ch == ")" {
                flushNumber()
                if inGroup, !current.isEmpty { groups.append(current) }
                inGroup = false
            } else if inGroup {
                if ch.isWhitespace {
                    flushNumber()
                } else {
                    buffer.append(ch)
                }
            }
        }
        return groups
    }

    private static func apply(_ op: QESymmetryOp, to k: SIMD3<Float>) -> SIMD3<Float> {
        guard op.rotation.count == 3 else { return k }
        var components = [Float](repeating: 0, count: 3)
        for row in 0..<3 {
            // fs.x maps k-points with the rotational part only (S k): a
            // fractional translation shifts real-space atoms, not k-points.
            components[row] = simd_dot(op.rotation[row], k)
        }
        return SIMD3<Float>(components[0], components[1], components[2])
    }

    private static func wrapFraction(_ p: SIMD3<Float>) -> SIMD3<Float> {
        func wrap(_ x: Float) -> Float {
            var c = x - floor(x)
            if 1 - c < 1e-4 { c = 0 }
            return c
        }
        return SIMD3<Float>(wrap(p.x), wrap(p.y), wrap(p.z))
    }

    /// Quantize a fractional vector to integer milli-coordinates for a dedup key.
    private static func quantize(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>((p.x * 1000).rounded(), (p.y * 1000).rounded(), (p.z * 1000).rounded())
    }

    /// Smallest n in 1...32 such that every coordinate is (m/n) mod 1 within 1e-3.
    private static func inferGridCount(_ coordinates: [Float]) -> Int? {
        for n in 1...32 {
            var fits = true
            for c in coordinates {
                let scaled = c * Float(n)
                if abs(scaled - scaled.rounded()) > 1e-3 {
                    fits = false
                    break
                }
            }
            if fits { return n }
        }
        return nil
    }

    private static func cartesianToFractionalPoints(
        _ points: [SIMD3<Float>],
        reciprocal: [SIMD3<Float>]
    ) -> [SIMD3<Float>]? {
        guard reciprocal.count == 3 else { return nil }
        let b = simd_float3x3(columns: (reciprocal[0], reciprocal[1], reciprocal[2]))
        guard b.determinant.isFinite, abs(b.determinant) > 1e-12 else { return nil }
        let inv = b.inverse
        return points.map { inv * $0 }
    }
}
