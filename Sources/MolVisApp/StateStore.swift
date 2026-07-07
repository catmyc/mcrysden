import Foundation

enum StateStore {
    static func save(_ scene: Scene, camera: Camera?, to url: URL) throws { try Data().write(to: url) }
    static func load(_ scene: inout Scene, _ camera: inout Camera, from url: URL) throws { /* Task 11 */ }
}
