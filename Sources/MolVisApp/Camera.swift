import Foundation
import simd

// MARK: - Standard crystal views

/// The crystallographic directions supported by the camera's standard-view
/// alignment.  The indices are direct-space coefficients: a view's direction
/// is `u * cell.a + v * cell.b + w * cell.c`.
enum StandardCrystalView: CaseIterable, Equatable, Hashable {
    case view100
    case view110
    case view111

    /// UI-facing Miller-index label.
    var label: String {
        switch self {
        case .view100: return "[100]"
        case .view110: return "[110]"
        case .view111: return "[111]"
        }
    }

    /// Direct-space coefficients for this standard view.
    var indices: SIMD3<Int> {
        switch self {
        case .view100: return SIMD3(1, 0, 0)
        case .view110: return SIMD3(1, 1, 0)
        case .view111: return SIMD3(1, 1, 1)
        }
    }
}

/// A localized failure from standard crystallographic camera alignment.
enum StandardCrystalViewError: Error, LocalizedError {
    case missingCell
    case nonFiniteCell
    case degenerateCell
    case unrepresentableDirection(String)
    case noUsableUpDirection(String)
    case invalidRotation(String)

    var errorDescription: String? {
        switch self {
        case .missingCell:
            return "standard crystal view requires a unit cell"
        case .nonFiniteCell:
            return "unit cell contains a non-finite lattice-vector component"
        case .degenerateCell:
            return "unit cell is singular or numerically degenerate"
        case .unrepresentableDirection(let label):
            return "standard crystal direction \(label) is zero, non-finite, or unrepresentable"
        case .noUsableUpDirection(let label):
            return "could not construct a finite camera up direction for \(label)"
        case .invalidRotation(let label):
            return "could not construct a finite normalized camera rotation for \(label)"
        }
    }
}

// MARK: - Camera validation

/// Thrown by `Camera.validated(_:)` when a decoded camera fails a geometric
/// sanity check (non-finite center/distance, non-positive distance,
/// non-finite or near-zero/overflowed quaternion). Kept as a plain
/// LocalizedError so callers can wrap it into a domain-specific error.
struct CameraValidationError: Error {
    let reason: String
    var errorDescription: String? { reason }
}

extension Camera {
    /// Geometric minimum: a valid unit quaternion must have a finite norm well
    /// above zero (rejects a zero / near-zero quaternion whose normalization
    /// flips to NaN) and well below infinity (rejects a float whose squared
    /// length overflows during normalization). Chosen to fit comfortably inside
    /// Float's dynamic range.
    static let minQuaternionNorm: Float = 1e-3
    static let maxQuaternionNorm: Float = 1e15

    /// Validate a decoded camera and return it with a NORMALIZED quaternion.
    /// Rejects:
    ///  - non-finite center, non-positive or non-finite distance,
    ///  - any non-finite quaternion component,
    ///  - near-zero quaternion norm (would normalize to NaN),
    ///    overflowed norm (components that would overflow on squaring).
    /// A valid but non-unit quaternion is normalized before commit so the
    /// rotation matrix stays orthonormal; a unit quaternion passes through.
    static func validated(_ camera: Camera) throws -> Camera {
        guard camera.distance.isFinite, camera.distance > 0 else {
            throw CameraValidationError(reason: "camera distance must be finite and positive")
        }
        guard camera.center.x.isFinite, camera.center.y.isFinite, camera.center.z.isFinite else {
            throw CameraValidationError(reason: "camera center must be finite")
        }
        let r = camera.rotation.vector
        guard r.x.isFinite, r.y.isFinite, r.z.isFinite, r.w.isFinite else {
            throw CameraValidationError(reason: "camera rotation components must be finite")
        }
        let norm = simd_length(r)
        guard norm.isFinite, norm >= minQuaternionNorm, norm <= maxQuaternionNorm else {
            throw CameraValidationError(reason: "camera rotation quaternion norm is invalid (\(norm))")
        }
        var result = camera
        result.rotation = simd_normalize(camera.rotation)
        return result
    }
}

// MARK: - Standard crystal camera alignment

private struct StandardCrystalCellGeometry {
    /// The lattice is divided by its largest component before any geometric
    /// operation.  Camera orientation is invariant under this common scale,
    /// and this avoids both overflow and underflow for extreme Float cells.
    let a: SIMD3<Double>
    let b: SIMD3<Double>
    let c: SIMD3<Double>
}

private extension Camera {
    static let standardCrystalDeterminantTolerance = 1e-12
    static let standardCrystalParallelTolerance = 1e-8

    static func standardCrystalCellGeometry(cell: Cell) throws -> StandardCrystalCellGeometry {
        let values = [Double(cell.a.x), Double(cell.a.y), Double(cell.a.z),
                      Double(cell.b.x), Double(cell.b.y), Double(cell.b.z),
                      Double(cell.c.x), Double(cell.c.y), Double(cell.c.z)]
        guard values.allSatisfy(\.isFinite) else {
            throw StandardCrystalViewError.nonFiniteCell
        }

        guard let scale = values.map({ abs($0) }).max(), scale.isFinite, scale > 0 else {
            throw StandardCrystalViewError.degenerateCell
        }

        let a = SIMD3<Double>(Double(cell.a.x) / scale,
                              Double(cell.a.y) / scale,
                              Double(cell.a.z) / scale)
        let b = SIMD3<Double>(Double(cell.b.x) / scale,
                              Double(cell.b.y) / scale,
                              Double(cell.b.z) / scale)
        let c = SIMD3<Double>(Double(cell.c.x) / scale,
                              Double(cell.c.y) / scale,
                              Double(cell.c.z) / scale)
        guard isFinite(a), isFinite(b), isFinite(c) else {
            throw StandardCrystalViewError.degenerateCell
        }

        let aLength = length(a)
        let bLength = length(b)
        let cLength = length(c)
        guard aLength.isFinite, bLength.isFinite, cLength.isFinite,
              aLength > 0, bLength > 0, cLength > 0 else {
            throw StandardCrystalViewError.degenerateCell
        }

        // Divide the scalar triple product by the three axis lengths before
        // testing it.  This is an angular (relative) determinant: unlike a
        // single global component scale, it accepts valid cells whose axes
        // have very different physical lengths while still rejecting nearly
        // coplanar lattice directions.
        let aUnit = a / aLength
        let bUnit = b / bLength
        let cUnit = c / cLength
        guard isFinite(aUnit), isFinite(bUnit), isFinite(cUnit) else {
            throw StandardCrystalViewError.degenerateCell
        }
        let angularDeterminant = dot(aUnit, cross(bUnit, cUnit))
        guard angularDeterminant.isFinite,
              abs(angularDeterminant) > standardCrystalDeterminantTolerance else {
            throw StandardCrystalViewError.degenerateCell
        }

        return StandardCrystalCellGeometry(a: a, b: b, c: c)
    }

    static func standardCrystalBasis(for view: StandardCrystalView,
                                     cell: StandardCrystalCellGeometry)
        throws -> (right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>) {
        let indices = view.indices
        let direction = cell.a * Double(indices.x)
            + cell.b * Double(indices.y)
            + cell.c * Double(indices.z)
        guard isFinite(direction) else {
            throw StandardCrystalViewError.unrepresentableDirection(view.label)
        }

        let directionLength = length(direction)
        guard directionLength.isFinite, directionLength > 0 else {
            throw StandardCrystalViewError.unrepresentableDirection(view.label)
        }
        let forward = direction / directionLength
        guard isFinite(forward) else {
            throw StandardCrystalViewError.unrepresentableDirection(view.label)
        }

        // Project direct-space axes into the image plane.  c, b, a is
        // deliberate: it makes the roll deterministic and gives conventional
        // views a stable vertical lattice direction whenever possible.
        let directCandidates = [cell.c, cell.b, cell.a]
        var up: SIMD3<Double>?
        for candidate in directCandidates {
            guard isFinite(candidate) else { continue }
            let candidateLength = length(candidate)
            guard candidateLength.isFinite, candidateLength > 0 else { continue }
            // Normalize each candidate before projection so a very short but
            // valid lattice axis is not lost merely because another axis is
            // much longer.
            let candidateUnit = candidate / candidateLength
            let projection = candidateUnit - forward * dot(candidateUnit, forward)
            let projectionLength = length(projection)
            guard projectionLength.isFinite,
                  projectionLength > standardCrystalParallelTolerance else {
                continue
            }
            up = projection / projectionLength
            break
        }

        // A valid nonsingular cell normally always supplies a usable projected
        // lattice axis.  Keep the fallback for extreme but accepted geometry,
        // and make its order deterministic as well.
        if up == nil {
            let worldCandidates = [SIMD3<Double>(0, 0, 1),
                                   SIMD3<Double>(0, 1, 0),
                                   SIMD3<Double>(1, 0, 0)]
            for candidate in worldCandidates {
                let projection = candidate - forward * dot(candidate, forward)
                let projectionLength = length(projection)
                guard projectionLength.isFinite,
                      projectionLength > standardCrystalParallelTolerance else {
                    continue
                }
                up = projection / projectionLength
                break
            }
        }

        guard let selectedUp = up, isFinite(selectedUp) else {
            throw StandardCrystalViewError.noUsableUpDirection(view.label)
        }

        // viewMatrix() treats the quaternion's columns as camera right, up,
        // and eye-forward.  Therefore right = up × forward, not forward × up;
        // this preserves the right-handed local camera frame.
        let rightVector = cross(selectedUp, forward)
        let rightLength = length(rightVector)
        guard rightLength.isFinite, rightLength > 0 else {
            throw StandardCrystalViewError.noUsableUpDirection(view.label)
        }
        let right = rightVector / rightLength
        let orthogonalUpVector = cross(forward, right)
        let orthogonalUpLength = length(orthogonalUpVector)
        guard orthogonalUpLength.isFinite, orthogonalUpLength > 0 else {
            throw StandardCrystalViewError.noUsableUpDirection(view.label)
        }
        let orthogonalUp = orthogonalUpVector / orthogonalUpLength
        guard isFinite(right), isFinite(orthogonalUp) else {
            throw StandardCrystalViewError.noUsableUpDirection(view.label)
        }

        return (right: right, up: orthogonalUp, forward: forward)
    }

    static func standardCrystalRotation(for view: StandardCrystalView,
                                        cell: StandardCrystalCellGeometry)
        throws -> simd_quatf {
        let basis = try standardCrystalBasis(for: view, cell: cell)
        let right = SIMD4<Float>(Float(basis.right.x), Float(basis.right.y), Float(basis.right.z), 0)
        let up = SIMD4<Float>(Float(basis.up.x), Float(basis.up.y), Float(basis.up.z), 0)
        let forward = SIMD4<Float>(Float(basis.forward.x), Float(basis.forward.y), Float(basis.forward.z), 0)
        let matrixValues = [right.x, right.y, right.z, up.x, up.y, up.z,
                            forward.x, forward.y, forward.z]
        guard matrixValues.allSatisfy(\.isFinite) else {
            throw StandardCrystalViewError.invalidRotation(view.label)
        }

        // The basis columns are camera right, up, and eye-forward.  Use the
        // platform's matrix-to-quaternion conversion after validating the
        // finite Float matrix, then explicitly normalize and validate its
        // result before committing it to the Camera.
        let matrix = float4x4(columns: (right, up, forward, SIMD4<Float>(0, 0, 0, 1)))
        let rawRotation = simd_quatf(matrix)
        let rawVector = rawRotation.vector
        guard rawVector.x.isFinite, rawVector.y.isFinite,
              rawVector.z.isFinite, rawVector.w.isFinite else {
            throw StandardCrystalViewError.invalidRotation(view.label)
        }
        let rawNorm = simd_length(rawVector)
        guard rawNorm.isFinite, rawNorm > 0 else {
            throw StandardCrystalViewError.invalidRotation(view.label)
        }

        let rotation = simd_normalize(rawRotation)
        let rotationVector = rotation.vector
        let rotationNorm = simd_length(rotationVector)
        guard rotationVector.x.isFinite, rotationVector.y.isFinite,
              rotationVector.z.isFinite, rotationVector.w.isFinite,
              rotationNorm.isFinite, rotationNorm > 0,
              abs(rotationNorm - 1) <= 1e-5 else {
            throw StandardCrystalViewError.invalidRotation(view.label)
        }
        return rotation
    }

    static func isFinite(_ vector: SIMD3<Double>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}

extension Camera {
    /// Returns nil exactly when the supplied cell can support all three
    /// standard direct-space directions.  The reason is suitable for display
    /// in a disabled menu or an error alert.
    static func standardCrystalViewUnavailableReason(cell: Cell?) -> String? {
        guard let cell else {
            return StandardCrystalViewError.missingCell.errorDescription
        }
        do {
            let geometry = try standardCrystalCellGeometry(cell: cell)
            for view in StandardCrystalView.allCases {
                _ = try standardCrystalRotation(for: view, cell: geometry)
            }
            return nil
        } catch let error as LocalizedError {
            return error.errorDescription ?? error.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    /// Align the eye with a direct-space standard crystallographic direction.
    /// Only the rotation is changed: center, distance, and projection mode are
    /// intentionally left untouched.
    mutating func align(to view: StandardCrystalView, cell: Cell) throws {
        let geometry = try Self.standardCrystalCellGeometry(cell: cell)
        let newRotation = try Self.standardCrystalRotation(for: view, cell: geometry)
        rotation = newRotation
    }
}

// MARK: - Camera transforms

extension Camera {
    func viewMatrix() -> float4x4 {
        // Orbit camera: sit  from , oriented by .
        // view = R^T * translate(-eye), eye = center + R*(0,0,distance).
        let r = float4x4(rotation)
        let eye = center + (r * SIMD4<Float>(0, 0, distance, 1)).xyz
        let rt = r.transpose                   // R is orthonormal, so R^-1 = R^T
        var m = rt
        m.columns.3 = rt * SIMD4<Float>(-eye.x, -eye.y, -eye.z, 1)
        return m
    }

    func projectionMatrix(aspect: Float) -> float4x4 {
        if perspective {
            return float4x4(projectionFov: .pi / 4, aspect: aspect, near: 0.1, far: 1000)
        }
        let half = max(1.0, distance)
        return float4x4(orthographicLeft: -half * aspect, right: half * aspect,
                        bottom: -half, top: half, near: 0.1, far: 1000)
    }

    var aspectFromViewport: Float { 1.0 }   // overridden by caller via viewport size

    /// World-space camera position (the "eye"): center + R*(0,0,distance). The
    /// Blinn-Phong specular term needs this to build the view vector V.
    func eyePosition() -> SIMD3<Float> {
        let r = float4x4(rotation)
        return center + (r * SIMD4<Float>(0, 0, distance, 1)).xyz
    }
}

// MARK: - float4x4 extensions (synthesized; named ctors absent on this SDK)

extension SIMD4 {
    var xyz: SIMD3<Scalar> { SIMD3(x, y, z) }
}

extension float4x4 {
    /// Identity with the translation column set to `(x, y, z)`.
    init(translation t: SIMD3<Float>) {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        self = m
    }

    /// Identity scaled by `(sx, sy, sz)`.
    init(scale s: SIMD3<Float>) {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x
        m.columns.1.y = s.y
        m.columns.2.z = s.z
        self = m
    }

    /// Right-handed Metal-rendering perspective (NDC z in [0, 1]).
    init(projectionFov fov: Float, aspect: Float, near: Float, far: Float) {
        let f = 1 / tan(fov / 2)
        let A = far / (near - far)
        let B = near * far / (near - far)
        self = matrix_identity_float4x4
        columns.0 = SIMD4(f / aspect, 0, 0, 0)
        columns.1 = SIMD4(0, f, 0, 0)
        columns.2 = SIMD4(0, 0, A, -1)
        columns.3 = SIMD4(0, 0, B, 0)
    }

    /// Right-handed Metal-rendering orthographic (NDC z in [0, 1]).
    init(orthographicLeft l: Float, right: Float, bottom: Float, top: Float,
         near: Float, far: Float) {
        let sx = 2 / (right - l)
        let sy = 2 / (top - bottom)
        let A = 1 / (near - far)
        let B = near / (near - far)
        self = matrix_identity_float4x4
        columns.0 = SIMD4(sx, 0, 0, 0)
        columns.1 = SIMD4(0, sy, 0, 0)
        columns.2 = SIMD4(0, 0, A, 0)
        columns.3 = SIMD4((right + l) / (l - right), (top + bottom) / (bottom - top), B, 1)
    }

    /// Rotation matrix that maps +Y onto `dir` (unit). Used for bond cylinders.
    /// Built on simd's minimal-rotation quaternion (verified: maps +Y->+X for dir=+X).
    static func rotation(fromYTo dir: SIMD3<Float>) -> float4x4 {
        let from = SIMD3<Float>(0, 1, 0)
        if length(dir) < 1e-8 { return matrix_identity_float4x4 }
        return float4x4(simd_quatf(from: from, to: dir))
    }
}
