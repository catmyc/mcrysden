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
        // Pre-existing destination exercises the atomic replace path; the old
        // remove-then-move implementation could lose this file on a failed move.
        try Data("stale".utf8).write(to: gifURL)
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
        let src = try XCTUnwrap(CGImageSourceCreateWithData(gifData as CFData, nil),
                                "GIF data must decode via ImageIO")
        XCTAssertEqual(CGImageSourceGetCount(src), 3, "GIF must keep all 3 animation frames")

        // APNG: contains acTL chunk and frame count == 3
        let apngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).apng")
        try Data("stale".utf8).write(to: apngURL)
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
        try Data("stale".utf8).write(to: mp4URL)
        do {
            try AnimationExporter.export(frames: frames, camera: fixedCamera, size: size, fps: 10, format: .mp4, to: mp4URL)
            let mp4Data = try Data(contentsOf: mp4URL)
            XCTAssertGreaterThanOrEqual(mp4Data.count, 12, "MP4 export produced an empty/truncated file")
            let ftyp = mp4Data[4..<8]
            XCTAssertEqual(String(data: ftyp, encoding: .ascii), "ftyp")
        } catch {
            XCTFail("MP4 export threw: \(error)")
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

    /// Parse the APNG chunk stream and return the (type, sequenceNumber?) for
    /// each fcTL/fdAT chunk in order. Sequence numbers are extracted from the
    /// chunk payload (fcTL: first 4 bytes; fdAT: first 4 bytes after the type).
    private static func apngSequence(_ data: Data) -> [(type: String, seq: UInt32)] {
        var result: [(String, UInt32)] = []
        var offset = 8 // skip signature
        while offset + 8 <= data.count {
            let chunkLen = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
            let typeStart = offset + 4
            let typeBytes = data[typeStart..<typeStart + 4]
            guard let type = String(data: typeBytes, encoding: .ascii) else { break }
            let payloadStart = typeStart + 4
            if type == "fcTL" || type == "fdAT" {
                let seq = UInt32(data[payloadStart]) << 24 | UInt32(data[payloadStart + 1]) << 16
                    | UInt32(data[payloadStart + 2]) << 8 | UInt32(data[payloadStart + 3])
                result.append((type, seq))
            }
            // length(4) + type(4) + data(len) + crc(4)
            offset = payloadStart + Int(chunkLen) + 4
        }
        return result
    }

    func testApngSequenceNumbersAndDelay() throws {
        let frames = [
            Self.makeSyntheticScene(seed: 0),
            Self.makeSyntheticScene(seed: 1),
            Self.makeSyntheticScene(seed: 2),
        ]
        let size = CGSize(width: 64, height: 64)
        var fixedCamera = Camera()
        fixedCamera.distance = 12
        fixedCamera.perspective = false

        let apngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).apng")
        try AnimationExporter.export(frames: frames, camera: fixedCamera, size: size, fps: 10,
                                     format: .apng, to: apngURL)
        let data = try Data(contentsOf: apngURL)
        let seq = Self.apngSequence(data)

        // 3 frames → fcTL/fdAT sequence: fcTL=0, fcTL=1, fdAT=2, fcTL=3, fdAT=4
        // (first frame's pixels go in IDAT, not fdAT).
        XCTAssertEqual(seq.count, 5, "3 frames → 5 sequenced chunks (fcTL×3 + fdAT×2)")
        XCTAssertEqual(seq[0].type, "fcTL"); XCTAssertEqual(seq[0].seq, 0)
        XCTAssertEqual(seq[1].type, "fcTL"); XCTAssertEqual(seq[1].seq, 1)
        XCTAssertEqual(seq[2].type, "fdAT"); XCTAssertEqual(seq[2].seq, 2)
        XCTAssertEqual(seq[3].type, "fcTL"); XCTAssertEqual(seq[3].seq, 3)
        XCTAssertEqual(seq[4].type, "fdAT"); XCTAssertEqual(seq[4].seq, 4)

        // Sequence numbers must be strictly increasing.
        for i in 1..<seq.count {
            XCTAssertGreaterThan(seq[i].seq, seq[i - 1].seq,
                                  "APNG sequence numbers must be strictly increasing")
        }

        // Delay must be 1/fps (delayNum=1, delayDen=10), not the old 100/fps.
        // fcTL payload: seq(4) + w(4) + h(4) + x(4) + y(4) + delayNum(2) + delayDen(2) + dispose(1) + blend(1)
        // Find the first fcTL and read its delay.
        var offset = 8
        var foundDelay = false
        while offset + 8 <= data.count {
            let chunkLen = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
            let typeStart = offset + 4
            let typeBytes = data[typeStart..<typeStart + 4]
            if String(data: typeBytes, encoding: .ascii) == "fcTL" {
                let p = typeStart + 4 + 20 // skip seq+w+h+x+y = 20 bytes
                let delayNum = UInt16(data[p]) << 8 | UInt16(data[p + 1])
                let delayDen = UInt16(data[p + 2]) << 8 | UInt16(data[p + 3])
                XCTAssertEqual(delayNum, 1, "APNG delay numerator must be 1 (1/fps seconds)")
                XCTAssertEqual(delayDen, 10, "APNG delay denominator must equal fps")
                foundDelay = true
                break
            }
            offset = typeStart + 4 + Int(chunkLen) + 4
        }
        XCTAssertTrue(foundDelay, "must find at least one fcTL chunk to verify delay")
    }

    /// Consolidated: fps bounds enforcement and frame-count cap.
    func testFpsBoundsAndFrameCountCapEnforced() throws {
        let frames = [Self.makeSyntheticScene(seed: 0)]
        let size = CGSize(width: 64, height: 64)

        // fps > 600 must be rejected (would overflow UInt16 in APNG, overflow
        // Int32 in MP4 CMTimeMultiply).
        do {
            try AnimationExporter.export(frames: frames, camera: nil, size: size, fps: 601,
                                         format: .apng, to: URL(fileURLWithPath: "/dev/null"))
            XCTFail("fps=601 should have thrown")
        } catch AnimationExportError.invalidSize {
            // expected
        }

        // fps = 0 must be rejected.
        do {
            try AnimationExporter.export(frames: frames, camera: nil, size: size, fps: 0,
                                         format: .apng, to: URL(fileURLWithPath: "/dev/null"))
            XCTFail("fps=0 should have thrown")
        } catch AnimationExportError.invalidSize {
            // expected
        }

        // fps = 600 is the upper bound and must be accepted (no throw).
        let apngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).apng")
        try AnimationExporter.export(frames: frames, camera: nil, size: size, fps: 600,
                                     format: .apng, to: apngURL)
        XCTAssertGreaterThan(try Data(contentsOf: apngURL).count, 8)

        // --- Frame-count cap ---
        // Build 1001 single-atom scenes. The exporter must refuse before
        // materializing them all into CGImages.
        var scenes: [Scene] = []
        for i in 0..<1001 {
            var s = Scene()
            s.atoms = [Atom(coord: SIMD3<Float>(Float(i), 0, 0), atomicNumber: 1, label: "H")]
            scenes.append(s)
        }
        let smallSize = CGSize(width: 32, height: 32)
        do {
            try AnimationExporter.export(frames: scenes, camera: nil, size: smallSize, fps: 10,
                                         format: .apng, to: URL(fileURLWithPath: "/dev/null"))
            XCTFail("1001 frames should have thrown")
        } catch AnimationExportError.invalidSize {
            // expected
        }

        // Exactly 1000 frames must be accepted.
        scenes.removeLast()
        let apngURL2 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcrysden_test_\(UUID().uuidString).apng")
        try AnimationExporter.export(frames: scenes, camera: nil, size: smallSize, fps: 10,
                                     format: .apng, to: apngURL2)
        XCTAssertGreaterThan(try Data(contentsOf: apngURL2).count, 8)
    }
}
