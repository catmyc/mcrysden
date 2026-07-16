import simd

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
