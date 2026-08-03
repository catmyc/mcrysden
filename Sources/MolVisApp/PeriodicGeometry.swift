import Foundation
import simd

/// Periodic minimum-image geometry.
///
/// Finds the displacement from a source point to the closest periodic image of
/// a target point, given a unit cell and the number of periodic dimensions.
///
/// The core problem: given displacement `d = target - source` and the `n`
/// periodic cell vectors `v₀..vₙ₋₁`, find the integer vector `k` minimizing
/// `||d - Σ kᵢvᵢ||`. Independent rounding of fractional coordinates is only
/// correct for orthogonal cells; for skew/triclinic cells it can select the
/// wrong image. This implementation uses a QR decomposition followed by sphere
/// decoding in Double precision to find the true closest lattice vector with
/// bounded, deterministic work. If finite inputs would require unrepresentable
/// integer coefficients or exceed an exact-search safety cap, the operation
/// returns nil rather than an approximate image.
enum PeriodicGeometry {
    /// Safety cap on the search window per sphere-decoding level. A window that
    /// exceeds this cap returns nil rather than an approximate image.
    private static let maxSpread = 50_000
    /// Safety cap on total nodes visited during sphere decoding. Hitting this
    /// cap returns nil rather than an approximate image.
    private static let maxNodes = 500_000
    /// Relative tolerance for the linear-independence check in Gram–Schmidt.
    private static let independenceTol: Double = 1e-10

    /// Returns the displacement from `source` to the closest periodic image of
    /// `target`. Returns nil for invalid or non-finite input, linearly dependent
    /// basis vectors, unrepresentable integer coefficients, or exact-search
    /// safety-cap exhaustion. Safety-cap exhaustion never returns an approximate
    /// image.
    static func minimumImageDisplacement(from source: SIMD3<Float>,
                                          to target: SIMD3<Float>,
                                          cell: Cell?,
                                          periodicDim: Int) -> SIMD3<Float>? {
        guard (0...3).contains(periodicDim) else { return nil }
        guard source.isFinite, target.isFinite else { return nil }

        let d = target.double - source.double
        guard d.isFinite else { return nil }

        // Non-periodic: direct displacement, regardless of whether a cell exists.
        if periodicDim == 0 || cell == nil {
            let result = d.float
            guard result.isFinite else { return nil }
            return result
        }
        guard let cell, cell.isFinite else { return nil }

        // Build the periodic basis in cell-vector order: a, then b, then c.
        let basis: [SIMD3<Double>]
        switch periodicDim {
        case 1: basis = [cell.a.double]
        case 2: basis = [cell.a.double, cell.b.double]
        default: basis = [cell.a.double, cell.b.double, cell.c.double]
        }

        guard let latticeVec = closestLatticeVector(basis: basis, target: d) else { return nil }
        let disp = d - latticeVec
        guard disp.isFinite else { return nil }
        let result = disp.float
        guard result.isFinite else { return nil }
        return result
    }

    /// Returns the distance (length of the minimum-image displacement) from
    /// `source` to the closest periodic image of `target`. Returns nil under the
    /// same conditions as `minimumImageDisplacement`, or for a non-finite result.
    static func minimumImageDistance(from source: SIMD3<Float>,
                                     to target: SIMD3<Float>,
                                     cell: Cell?,
                                     periodicDim: Int) -> Float? {
        guard let disp = minimumImageDisplacement(from: source, to: target,
                                                   cell: cell, periodicDim: periodicDim) else {
            return nil
        }
        let len = length(disp.double)
        guard len.isFinite else { return nil }
        let result = Float(len)
        guard result.isFinite else { return nil }
        return result
    }

    // MARK: - Closest lattice vector (QR + sphere decoding)

    /// Finds the lattice vector `L = Σ k[i]·basis[i]` closest to `target`.
    /// Returns nil for invalid or non-finite input, a linearly dependent basis,
    /// unrepresentable integer coefficients, or exact-search safety-cap
    /// exhaustion; it never returns an approximate vector.
    private static func closestLatticeVector(basis: [SIMD3<Double>],
                                             target: SIMD3<Double>) -> SIMD3<Double>? {
        let n = basis.count
        guard n >= 1, n <= 3 else { return nil }
        guard basis.allSatisfy({ $0.isFinite }), target.isFinite else { return nil }

        // Modified Gram–Schmidt: V = Q·R, columns of V are the basis vectors.
        // q[i] are orthonormal; R[i][j] (i ≤ j) upper triangular.
        var u = basis
        var R = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var q = [SIMD3<Double>](repeating: .zero, count: n)

        for j in 0..<n {
            u[j] = basis[j]
            for i in 0..<j {
                let projection = dot(u[j], q[i])
                guard projection.isFinite else { return nil }
                R[i][j] = projection
                let correction = projection * q[i]
                guard correction.isFinite else { return nil }
                u[j] -= correction
                guard u[j].isFinite else { return nil }
            }
            let norm = length(u[j])
            let inputLen = length(basis[j])
            guard inputLen > 0, norm.isFinite,
                  inputLen.isFinite,
                  independenceTol * inputLen < .infinity,
                  norm > independenceTol * inputLen else { return nil }
            R[j][j] = norm
            q[j] = u[j] / norm
            guard q[j].isFinite else { return nil }
        }

        // Transformed target: y[i] = target·q[i]. Minimizing ||target - V·k|| over
        // integer k is equivalent to minimizing ||y - R·k|| (the orthogonal
        // residual ||(I-QQᵀ)target|| is constant w.r.t. k).
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            y[i] = dot(target, q[i])
            guard y[i].isFinite else { return nil }
        }

        // Seed with the naive rounded (Babai round-off) solution to bound the
        // initial search radius.
        var f = [Double](repeating: 0, count: n)
        for i in (0..<n).reversed() {
            var s = y[i]
            for j in (i + 1)..<n {
                let term = R[i][j] * f[j]
                guard term.isFinite else { return nil }
                s -= term
                guard s.isFinite else { return nil }
            }
            let value = s / R[i][i]
            guard value.isFinite else { return nil }
            f[i] = value
        }
        var bestK = [Int]()
        bestK.reserveCapacity(n)
        for value in f {
            guard let coefficient = checkedInt(value.rounded()) else { return nil }
            bestK.append(coefficient)
        }
        guard var bestCost = residualNormSq(R: R, y: y, k: bestK, n: n) else { return nil }

        var residual = y
        var k = [Int](repeating: 0, count: n)
        var visited = 0

        /// Recursive sphere decode from level `i` down to 0. `costSoFar` holds the
        /// squared contribution of levels > i (already fixed). `residual[l]` holds
        /// `y[l] - Σ_{j>l} R[l][j]·k[j]` for each level l.
        func search(_ i: Int, _ costSoFar: Double) -> Bool {
            guard visited < maxNodes else { return false }
            visited += 1
            if i < 0 {
                if isBetter(costSoFar, k, bestCost, bestK, n) {
                    bestCost = costSoFar
                    bestK = k
                }
                return true
            }
            let budget = bestCost - costSoFar
            guard budget.isFinite else { return false }
            if budget < 0 { return true }
            let bound = sqrt(max(budget, 0))
            guard bound.isFinite else { return false }
            let center = residual[i]
            let rii = R[i][i]
            guard center.isFinite, rii.isFinite, rii > 0 else { return false }
            let centerOverRii = center / rii
            guard centerOverRii.isFinite else { return false }
            let lowerBound = (center - bound) / rii
            let upperBound = (center + bound) / rii
            guard lowerBound.isFinite, upperBound.isFinite,
                  let lo = checkedInt(lowerBound.rounded(.up)),
                  let hi = checkedInt(upperBound.rounded(.down)) else {
                return false
            }
            guard lo <= hi else { return true }

            // Check the span before subtracting Int values, which may itself
            // overflow for pathological but finite inputs.
            let (spreadLimit, limitOverflow) = lo.addingReportingOverflow(maxSpread)
            if !limitOverflow, hi > spreadLimit { return false }
            let (spread, spreadOverflow) = hi.subtractingReportingOverflow(lo)
            guard !spreadOverflow, spread >= 0, spread <= maxSpread else { return false }

            var ki = lo
            while true {
                k[i] = ki
                let levelTerm = rii * Double(ki)
                guard levelTerm.isFinite else { return false }
                let levelCost = center - levelTerm
                guard levelCost.isFinite else { return false }
                let levelCostSq = levelCost * levelCost
                guard levelCostSq.isFinite else { return false }
                let nextCost = costSoFar + levelCostSq
                guard nextCost.isFinite else { return false }

                // Update residual for lower levels: k[i] contributes R[l][i]·k[i].
                var contributions = [Double](repeating: 0, count: i)
                for l in 0..<i {
                    let contribution = R[l][i] * Double(ki)
                    let updated = residual[l] - contribution
                    guard contribution.isFinite, updated.isFinite else { return false }
                    contributions[l] = contribution
                }
                for l in 0..<i { residual[l] -= contributions[l] }
                let completed = search(i - 1, nextCost)
                for l in 0..<i { residual[l] += contributions[l] }
                guard completed else { return false }
                if ki == hi { break }
                let (nextKi, incrementOverflow) = ki.addingReportingOverflow(1)
                guard !incrementOverflow else { return false }
                ki = nextKi
            }
            return true
        }

        guard search(n - 1, 0) else { return nil }

        var result = SIMD3<Double>.zero
        for i in 0..<n {
            let term = Double(bestK[i]) * basis[i]
            guard term.isFinite else { return nil }
            result += term
            guard result.isFinite else { return nil }
        }
        return result
    }

    private static func checkedInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value)
    }

    /// Squared norm ||y - R·k|| for the upper-triangular system.
    private static func residualNormSq(R: [[Double]], y: [Double], k: [Int], n: Int) -> Double? {
        var sum = 0.0
        for i in 0..<n {
            var s = y[i]
            for j in i..<n {
                let term = R[i][j] * Double(k[j])
                guard term.isFinite else { return nil }
                s -= term
                guard s.isFinite else { return nil }
            }
            let square = s * s
            guard square.isFinite else { return nil }
            sum += square
            guard sum.isFinite else { return nil }
        }
        return sum
    }

    /// Deterministic ordering for exact cost ties: smaller ||k||₂ wins; on tie,
    /// lexicographically smaller k wins.
    private static func isBetter(_ costA: Double, _ kA: [Int],
                                 _ costB: Double, _ kB: [Int], _ n: Int) -> Bool {
        if costA != costB { return costA < costB }
        var normA = 0.0, normB = 0.0
        for i in 0..<n {
            let coefficientA = Double(kA[i])
            let coefficientB = Double(kB[i])
            normA += coefficientA * coefficientA
            normB += coefficientB * coefficientB
        }
        if normA != normB { return normA < normB }
        for i in 0..<n where kA[i] != kB[i] { return kA[i] < kB[i] }
        return false
    }

    /// Returns the angle (in degrees) at vertex `b` between atoms a-b-c,
    /// using minimum-image displacements for periodic cells. Returns nil for
    /// invalid/non-finite input or degenerate (zero-length) vectors.
    static func minimumImageAngle(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>,
                                   cell: Cell?, periodicDim: Int) -> Float? {
        guard (0...3).contains(periodicDim) else { return nil }
        guard a.isFinite, b.isFinite, c.isFinite else { return nil }

        let d0: SIMD3<Float>
        let d2: SIMD3<Float>

        if periodicDim == 0 || cell == nil {
            d0 = a - b
            d2 = c - b
        } else {
            guard let cell, cell.isFinite,
                  let disp0 = minimumImageDisplacement(from: b, to: a, cell: cell,
                                                        periodicDim: periodicDim),
                  let disp2 = minimumImageDisplacement(from: b, to: c, cell: cell,
                                                        periodicDim: periodicDim) else {
                return nil
            }
            d0 = disp0
            d2 = disp2
        }

        let len0 = length(d0)
        let len2 = length(d2)
        guard len0.isFinite, len0 > 1e-8, len2.isFinite, len2 > 1e-8 else { return nil }

        let cosAngle = min(max(dot(d0 / len0, d2 / len2), -1), 1)
        let angle = acos(cosAngle) * 180 / .pi
        guard angle.isFinite else { return nil }
        return angle
    }

    /// Returns the unsigned dihedral angle (in degrees, 0–180) for atoms
    /// a-b-c-d, using minimum-image displacements for periodic cells.
    /// Returns nil for invalid/non-finite input or degenerate vectors.
    /// The result is unsigned (acos-based) to match the non-periodic path in
    /// Scene.computeMeasurement.
    static func minimumImageDihedral(a: SIMD3<Float>, b: SIMD3<Float>,
                                      c: SIMD3<Float>, d: SIMD3<Float>,
                                      cell: Cell?, periodicDim: Int) -> Float? {
        guard (0...3).contains(periodicDim) else { return nil }
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { return nil }

        let ba: SIMD3<Float>
        let cbVec: SIMD3<Float>
        let dc: SIMD3<Float>

        if periodicDim == 0 || cell == nil {
            ba = a - b
            cbVec = b - c
            dc = c - d
        } else {
            guard let cell, cell.isFinite,
                  let dispBA = minimumImageDisplacement(from: b, to: a, cell: cell,
                                                         periodicDim: periodicDim),
                  let dispCB = minimumImageDisplacement(from: c, to: b, cell: cell,
                                                         periodicDim: periodicDim),
                  let dispDC = minimumImageDisplacement(from: d, to: c, cell: cell,
                                                         periodicDim: periodicDim) else {
                return nil
            }
            ba = dispBA
            cbVec = dispCB
            dc = dispDC
        }

        let lenBA = length(ba)
        let lenCB = length(cbVec)
        let lenDC = length(dc)
        guard lenBA.isFinite, lenBA > 1e-8, lenCB.isFinite, lenCB > 1e-8,
              lenDC.isFinite, lenDC > 1e-8 else { return nil }

        let n1 = cross(ba, cbVec)
        let n2 = cross(cbVec, dc)
        let lenN1 = length(n1)
        let lenN2 = length(n2)
        guard lenN1.isFinite, lenN1 > 1e-8, lenN2.isFinite, lenN2 > 1e-8 else { return nil }

        // Unsigned dihedral (0-180°), matching the non-periodic convention.
        let cosDihedral = min(max(dot(n1 / lenN1, n2 / lenN2), -1), 1)
        let dihedral = acos(cosDihedral) * 180 / .pi
        guard dihedral.isFinite else { return nil }
        return dihedral
    }
}

extension SIMD3 where Scalar == Float {
    var double: SIMD3<Double> { SIMD3<Double>(Double(x), Double(y), Double(z)) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

extension SIMD3 where Scalar == Double {
    var float: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

extension Cell {
    var isFinite: Bool { a.isFinite && b.isFinite && c.isFinite }

    /// True when the cell has a nonzero volume (the three vectors are linearly
    /// independent) AND all components are finite. A singular (zero-volume)
    /// cell has no well-defined fractional coordinates.
    var isNonsingular: Bool {
        guard isFinite else { return false }
        let det = a.x * (b.y * c.z - c.y * b.z)
                - b.x * (a.y * c.z - c.y * a.z)
                + c.x * (a.y * b.z - b.y * a.z)
        // Normalize by the product of the vector lengths so the threshold is
        // scale-invariant (matches the fractional-conversion convention).
        func length(_ v: SIMD3<Float>) -> Float {
            sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        }
        let scale = length(a) * length(b) * length(c)
        guard scale.isFinite, scale > 0 else { return false }
        let relative = abs(det) / scale
        return relative.isFinite && relative > 1e-12
    }
}
