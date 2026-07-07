import simd

struct Vertex { var position: SIMD3<Float>; var normal: SIMD3<Float> }
struct Mesh { let positions: [SIMD3<Float>]; let normals: [SIMD3<Float>]; let indices: [UInt16] }

enum Geometry {
    /// Standard UV unit sphere centred at the origin, radius 1.0.
    static func unitSphere(latSegments: Int = 12, lonSegments: Int = 20) -> Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for lat in 0...latSegments {
            let theta = Float.pi * Float(lat) / Float(latSegments)       // 0...pi
            let st = sin(theta); let ct = cos(theta)
            for lon in 0...lonSegments {
                let phi = 2.0 * Float.pi * Float(lon) / Float(lonSegments)
                let sp = sin(phi); let cp = cos(phi)
                let n = SIMD3<Float>(st * cp, ct, st * sp)
                normals.append(n); positions.append(n)                     // position == normal for unit sphere
            }
        }
        var indices: [UInt16] = []
        let stride = lonSegments + 1
        for lat in 0..<latSegments {
            for lon in 0..<lonSegments {
                let a = UInt16(lat * stride + lon)
                let b = UInt16(a + UInt16(stride))
                indices.append(a); indices.append(b); indices.append(a + 1)
                indices.append(b); indices.append(b + 1); indices.append(a + 1)
            }
        }
        return Mesh(positions: positions, normals: normals, indices: indices)
    }

    /// Unit cylinder along +Y, total height 1.0 (y in [-0.5,0.5]), radius 1.0,
    /// centred on the origin. Bonds are rotated from +Y onto the bond direction.
    static func unitCylinder(radialSegments: Int = 12) -> Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        let y0: Float = -0.5, y1: Float = 0.5
        for ring in 0...1 {
            let y = ring == 0 ? y0 : y1
            let ny: Float = ring == 0 ? -1 : 1
            for s in 0..<radialSegments {
                let phi = 2.0 * Float.pi * Float(s) / Float(radialSegments)
                let cp = cos(phi); let sp = sin(phi)
                positions.append(SIMD3<Float>(cp, y, sp))
                normals.append(SIMD3<Float>(cp, ny, sp))                  // flat caps: normal = +-Y
            }
        }
        var indices: [UInt16] = []
        let n = radialSegments
        // side wall
        for s in 0..<radialSegments {
            let s1 = (s + 1) % radialSegments
            let a = UInt16(s), b = UInt16(s1)
            let c = UInt16(s + n), d = UInt16(s1 + n)
            indices.append(a); indices.append(c); indices.append(b)
            indices.append(b); indices.append(c); indices.append(d)
        }
        // caps — triangulated ring
        let topStart = UInt16(positions.count)
        positions.append(SIMD3<Float>(0, y1, 0)); normals.append(SIMD3<Float>(0, 1, 0))
        let botStart = UInt16(positions.count)
        positions.append(SIMD3<Float>(0, y0, 0)); normals.append(SIMD3<Float>(0, -1, 0))
        for s in 0..<radialSegments {
            let s1 = (s + 1) % radialSegments
            // top cap
            indices.append(topStart); indices.append(UInt16(s + n)); indices.append(UInt16(s1 + n))
            // bottom cap (wound so normal points -Y)
            indices.append(botStart); indices.append(UInt16(s1)); indices.append(UInt16(s))
        }
        return Mesh(positions: positions, normals: normals, indices: indices)
    }

    /// Two vertices spanning +Y — basis for bond cylinders and line segments.
    static func unitLine() -> [SIMD3<Float>] { [SIMD3(0,0,0), SIMD3(0,1,0)] }
}
