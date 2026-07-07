import XCTest
@testable import MolVisApp

final class SnapshotTests: Snapshotter {
    private func load(_ name: String) throws -> Scene {
        let dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        return Scene(loaded: try Parser.load(dir.appendingPathComponent("Fixtures/\(name)")))
    }
    private func camera(dist: Float) -> Camera {
        var c = Camera(); c.distance = dist; return c
    }
    func testSi110BallStick() throws {
        try hashImage(try load("si110.xsf"), camera: camera(dist: 12), name: "si110_ballstick")
    }
    func testH2OSpaceFill() throws {
        var s = try load("h2o.xyz")
        s.displayMode = .spaceFill
        try hashImage(s, camera: camera(dist: 8), name: "h2o_spacefill")
    }
}
