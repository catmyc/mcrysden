import Foundation
import simd
import AppKit

struct Atom: Codable { var coord: SIMD3<Float>; var atomicNumber: Int; var label: String }
struct Bond:  Codable { var i: Int; var j: Int }
struct Cell:  Codable { var a: SIMD3<Float>; var b: SIMD3<Float>; var c: SIMD3<Float> }

enum DisplayMode: String, Codable, CaseIterable {
    case ballStick, spaceFill, wireFrame, polyhedral, line2D, point2D, ballStick2D
    var label: String {
        switch self {
        case .ballStick: return "Ball & Stick"
        case .spaceFill: return "Space Fill (CPK)"
        case .wireFrame: return "Wireframe"
        case .polyhedral: return "Polyhedral"
        case .line2D: return "2D Line"
        case .point2D: return "2D Point"
        case .ballStick2D: return "2D Ball-Stick"
        }
    }
    var is2D: Bool { self == .line2D || self == .point2D || self == .ballStick2D }
}

struct SuperCell: Codable { var n1: Int = 1; var n2: Int = 1; var n3: Int = 1
    var total: Int { n1 * n2 * n3 }
}

struct Plane: Codable { var h: Int = 0; var k: Int = 1; var l: Int = 0; var distance: Float = 0 }

struct Slab: Codable { var planeA: Plane = Plane(); var planeB: Plane = Plane() }

struct Camera: Codable {
    var center: SIMD3<Float> = SIMD3(0,0,0)
    var distance: Float = 20
    var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var perspective: Bool = true
}

enum ProjectionMode: Codable { case perspective, ortho }

struct ColorScheme: Codable { var mode: String = "atomic" }

struct Scene: Codable {
    var atoms: [Atom] = []
    var bonds: [Bond] = []
    var cell: Cell?
    var title: String = ""
    var displayMode: DisplayMode = .ballStick
    var superCell: SuperCell = SuperCell()
    var slab: Slab?
    var background: String = "#101014"
    var showCellFrame: Bool = true
    var showAxes: Bool = true
    var atomScale: Float = 0.35
    var bondRadius: Float = 0.10
    var camera: Camera = Camera()
}

// simd_quatf is not Codable in the Swift stdlib (only SIMD vectors are),
// but Camera (and therefore Scene) declares Codable. This conformance lets
// the declared codability hold without altering Camera's verbatim definition.
extension simd_quatf: @retroactive Codable {
    private enum CodingKeys: String, CodingKey { case x, y, z, w }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vector.x, forKey: .x)
        try c.encode(vector.y, forKey: .y)
        try c.encode(vector.z, forKey: .z)
        try c.encode(vector.w, forKey: .w)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = simd_float4(try c.decode(Float.self, forKey: .x),
                            try c.decode(Float.self, forKey: .y),
                            try c.decode(Float.self, forKey: .z),
                            try c.decode(Float.self, forKey: .w))
        self.init(vector: v)
    }
}
