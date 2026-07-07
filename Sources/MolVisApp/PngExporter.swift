import Foundation
import Metal

enum PngExporter {
    static func export(scene: Scene, camera: Camera, to url: URL, size: CGSize) throws {
        // Task 12 implements. v1 stub: write a 1x1 placeholder PNG so the headless path links.
        let data = Data()  // empty; Task 12 replaces
        try data.write(to: url)
    }
}
