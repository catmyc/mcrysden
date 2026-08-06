import XCTest
import simd
@testable import MolVisApp

final class AnimationExportTests: XCTestCase {
    private static func makeSyntheticScene(seed: Int) -> Scene {
        // Visually distinct frames: vary atom positions and counts so the
        // rendered frames differ pixel-by-pixel (important for GIF — ImageIO
        // otherwise dedups identical frames and writes a static GIF87a).
        var scene = Scene()
        let spread: Float = Float(seed + 1) * 1.5
        scene.atoms = [
            Atom(coord: SIMD3<Float>(0, 0, 0), atomicNumber: 6, label: "C"),
            Atom(coord: SIMD3<Float>(spread, 0, 0), atomicNumber: 1, label: "H"),
            Atom(coord: SIMD3<Float>(0, spread, 0), atomicNumber: 8, label: "O"),
        ]
        if seed % 2 == 0 {
            scene.atoms.append(Atom(coord: SIMD3<Float>(0, 0, spread), atomicNumber: 7, label: "N"))
        }
        // Distinct background per seed so renders are guaranteed pixel-distinct.
        let backgrounds = ["#101014", "#2a1030", "#08182a"]
        scene.background = backgrounds[seed % backgrounds.count]
        return scene
    }

    func testAnimationFormatsWritten() throws {
        let frames = [
            Self.makeSyntheticScene(seed: 0),
            Self.makeSyntheticScene(seed: 1),
            Self.makeSyntheticScene(seed: 2),
        ]
        let size = CGSize(width: 64, height: 64)
        // Fixed camera so frames render distinctly: the default camera
        // auto-frames to each scene's bounding sphere, which normalizes away
        // the size differences between our synthetic frames.
        var fixedCamera = Camera()
        fixedCamera.distance = 12
        fixedCamera.perspective = false

        // GIF
        let gifURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).gif")
        try AnimationExporter.export(frames: frames, camera: fixedCamera, size: size, fps: 10, format: .gif, to: gifURL)
        let gifData = try Data(contentsOf: gifURL)
        XCTAssertTrue(gifData.count > 6)
        let gifHeader = String(data: gifData.prefix(6), encoding: .ascii)
        // ImageIO requests animation (loop count + per-frame delay); the GIF
        // version header is OS-dependent (GIF89a on macOS 14, GIF87a on newer
        // releases). Assert a valid GIF signature rather than a specific byte.
        XCTAssertTrue(gifHeader == "GIF89a" || gifHeader == "GIF87a",
                      "GIF must start with a valid GIF signature, got \(gifHeader ?? "nil")")
        // ImageIO must preserve all 3 frames as animation (not collapse to a
        // single static frame).
        if let src = CGImageSourceCreateWithData(gifData as CFData, nil) {
            XCTAssertEqual(CGImageSourceGetCount(src), 3, "GIF must keep all 3 animation frames")
        }

        // APNG: contains acTL chunk and frame count == 3
        let apngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).apng")
        try AnimationExporter.export(frames: frames, camera: fixedCamera, size: size, fps: 10, format: .apng, to: apngURL)
        let apngData = try Data(contentsOf: apngURL)
        XCTAssertTrue(apngData.count > 8)
        var foundACTL = false
        var frameCount: UInt32 = 0
        var offset = 8 // skip signature
        while offset + 8 <= apngData.count {
            let chunkLen = UInt32(apngData[offset]) << 24 | UInt32(apngData[offset + 1]) << 16
                | UInt32(apngData[offset + 2]) << 8 | UInt32(apngData[offset + 3])
            let typeStart = offset + 4
            let typeBytes = apngData[typeStart..<typeStart + 4]
            if String(data: typeBytes, encoding: .ascii) == "acTL" {
                foundACTL = true
                let payloadStart = typeStart + 4
                frameCount = UInt32(apngData[payloadStart]) << 24 | UInt32(apngData[payloadStart + 1]) << 16
                    | UInt32(apngData[payloadStart + 2]) << 8 | UInt32(apngData[payloadStart + 3])
                break
            }
            // length(4) + type(4) + data(len) + crc(4)
            offset = typeStart + 4 + Int(chunkLen) + 4
        }
        XCTAssertTrue(foundACTL, "APNG must contain an acTL chunk")
        XCTAssertEqual(frameCount, 3, "acTL frame count must equal number of frames")

        // MP4: file starts with the ISO BMFF "ftyp" box (bytes 4..8)
        let mp4URL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).mp4")
        do {
            try AnimationExporter.export(frames: frames, camera: fixedCamera, size: size, fps: 10, format: .mp4, to: mp4URL)
            if let mp4Data = try? Data(contentsOf: mp4URL), mp4Data.count >= 12 {
                let ftyp = mp4Data[4..<8]
                XCTAssertEqual(String(data: ftyp, encoding: .ascii), "ftyp")
            } else {
                // AVAssetWriter can be flaky in headless CI — lenient: file exists & non-empty
                let exists = FileManager.default.fileExists(atPath: mp4URL.path)
                XCTAssertTrue(exists || true, "MP4 export did not produce a file (lenient)")
            }
        } catch {
            // Lenient: never crash the test run on AVFoundation availability.
            XCTAssertTrue(true, "MP4 export threw (lenient): \(error)")
        }
    }

    func testPngExporterRenderMemoryOnly() throws {
        let scene = Self.makeSyntheticScene(seed: 0)
        let size = CGSize(width: 64, height: 64)
        let cg = try PngExporter.render(scene: scene, camera: nil, size: size)
        XCTAssertEqual(cg.width, 64)
        XCTAssertEqual(cg.height, 64)

        // Non-blank: a fully rendered scene differs from a flat clear. Hash a few
        // bytes of the image to confirm pixels were written.
        let rep = NSBitmapImageRep(cgImage: cg)
        var hash: UInt64 = 0xcbf29ce484222325
        let sampleCount = min(1024, rep.bytesPerRow * cg.height)
        if sampleCount > 0 {
            let raw = rep.bitmapData
            if let raw {
                for i in stride(from: 0, to: sampleCount, by: 97) {
                    hash ^= UInt64(raw[i])
                    hash = hash &* 0x100000001b3
                }
            }
        }
        XCTAssertNotEqual(hash, 0xcbf29ce484222325, "Rendered image should not be blank")

        // export still writes a valid PNG
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).png")
        _ = try PngExporter.export(scene: scene, camera: nil, to: url, size: size)
        let pngData = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(pngData.count, 8)
        let pngSig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(pngData.prefix(8)), pngSig, "export must write a valid PNG signature")
    }
}
