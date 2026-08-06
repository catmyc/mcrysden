import AppKit
import Metal

enum TimelineThumbnails {
    static let maxCount = 24

    static func render(frames: [Scene], camera: Camera?, size: CGSize) throws -> [CGImage] {
        guard !frames.isEmpty else { return [] }
        let count = frames.count
        if count <= maxCount {
            return try frames.map { try PngExporter.render(scene: $0, camera: camera, size: size) }
        }
        let stride = Int((Double(count) / Double(maxCount)).rounded(.up))
        var images: [CGImage] = []
        images.reserveCapacity(maxCount)
        var index = 0
        while index < count && images.count < maxCount {
            images.append(try PngExporter.render(scene: frames[index], camera: camera, size: size))
            index += stride
        }
        return images
    }
}
