import simd

// MARK: - Camera transforms

extension Camera {
    func viewMatrix() -> float4x4 {
        let t = float4x4(translation: -center)
        let r = float4x4(rotation)
        let eye = SIMD3<Float>(0, 0, distance)
        let rotatedEye = (r * SIMD4<Float>(eye, 1)).xyz
        let T = float4x4(translation: -rotatedEye + center)
        return T * r * t
    }

    func projectionMatrix(aspect: Float) -> float4x4 {
        if perspective {
            return float4x4(projectionFov: .pi / 4, aspect: aspect, near: 0.1, far: 1000)
        }
        return float4x4(orthographicLeft: -10 * aspect, right: 10 * aspect,
                        bottom: -10, top: 10, near: 0.1, far: 1000)
    }

    var aspectFromViewport: Float { 1.0 }   // overridden by caller via viewport size
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
    static func rotation(fromYTo dir: SIMD3<Float>) -> float4x4 {
        let y = SIMD3<Float>(0, 1, 0)
        let v = cross(y, dir)
        let c = dot(y, dir)
        if length(v) < 1e-6 { return c > 0 ? matrix_identity_float4x4 : float4x4(diagonal: SIMD4(1, -1, 1, 1)) }
        let k = float4x4(rows: [SIMD4(0, v.z, -v.y, 0),
                                SIMD4(-v.z, 0, v.x, 0),
                                SIMD4(v.y, -v.x, 0, 0),
                                SIMD4(0, 0, 0, 1)])
        return matrix_identity_float4x4 + k + k * k * (1 / (1 + c))
    }
}
