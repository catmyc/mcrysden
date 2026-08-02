import Foundation

/// A named camera preset stored in a fixed set of viewer slots.
internal struct CameraBookmark: Codable {
    static let slotCount: Int = 3

    var name: String
    var camera: Camera
}
