import XCTest
import Metal
@testable import MolVisApp

/// Renders a fixed scene+camera to an offscreen PNG and compares the pixel hash
/// against a committed golden. Override the module-level
/// `MCRYSDEN_REGENERATE=1` env var to regenerate goldens.
class Snapshotter: XCTestCase {
    /// Resize every render to this before hashing — small enough for sub-pixel
    /// MSAA nondeterminism to wash out, large enough to catch real changes.
    static let hashSize = CGSize(width: 64, height: 64)

    func hashImage(_ scene: Scene, camera: Camera, name: String) throws {
        let device = MTLCreateSystemDefaultDevice()!
        let renderer = try Renderer(device: device)
        renderer.scene = scene
        let w = Int(Self.hashSize.width), h = Int(Self.hashSize.height)
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba8Unorm
        desc.width = w; desc.height = h
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        let cb = device.makeCommandQueue()!.makeCommandBuffer()!
        renderer.encode(to: cb, target: tex, viewport: MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1), camera: camera)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w*h*4)
        tex.getBytes(&px, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0)
        // downsample to hashSize (already there) and compute FNV-1a hash
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in px {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let goldenURL = goldenDirectory.appendingPathComponent("\(name).hash")
        if ProcessInfo.processInfo.environment["MCRYSDEN_REGENERATE"] == "1" {
            try? FileManager.default.createDirectory(at: goldenDirectory, withIntermediateDirectories: true)
            try "\(hash)".write(to: goldenURL, atomically: true, encoding: .utf8)
            print("[snapshot] regenerated \(name) = \(hash)")
            return
        }
        guard let expected = try? String(contentsOf: goldenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), let exp = UInt64(expected) else {
            XCTFail("no golden for \(name) — run with MCRYSDEN_REGENERATE=1"); return
        }
        XCTAssertEqual(hash, exp, "snapshot \(name) drifted")
    }

    var goldenDirectory: URL {
        // Snapshot.swift lives in Support/, but the brief's CRITICAL requirement is
        // that goldens live in <MolVisAppTests>/Fixtures/golden, adjacent to the
        // public fixtures. Ascend one extra level past Support/.
        URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/golden")
    }
}
