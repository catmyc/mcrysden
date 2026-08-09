import Foundation
import AVFoundation
import ImageIO
import Compression
import simd

enum AnimationExportFormat: String {
    case gif, apng, mp4
}

enum AnimationExportError: Error {
    case noFrames, invalidSize, renderFailed(Error?), encodeFailed, avFoundationFailed(Error?)
}

enum AnimationExporter {
    static func export(frames: [Scene], camera: Camera?, size: CGSize, fps: Int,
                       format: AnimationExportFormat, to url: URL) throws {
        guard !frames.isEmpty else { throw AnimationExportError.noFrames }
        guard fps >= 1, fps <= 600 else { throw AnimationExportError.invalidSize }
        guard frames.count <= 1000 else { throw AnimationExportError.invalidSize }
        switch format {
        case .gif: try exportGIF(frames: frames, camera: camera, size: size, fps: fps, to: url)
        case .apng: try exportAPNG(frames: frames, camera: camera, size: size, fps: fps, to: url)
        case .mp4: try exportMP4(frames: frames, camera: camera, size: size, fps: fps, to: url)
        }
    }

    // MARK: - GIF (ImageIO)

    private static func exportGIF(frames: [Scene], camera: Camera?, size: CGSize, fps: Int,
                                  to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, kUTTypeGIF, frames.count, nil) else {
            throw AnimationExportError.encodeFailed
        }
        // GIF-specific properties MUST be nested under kCGImagePropertyGIFDictionary
        // (top-level keys are ignored by ImageIO). Setting loop count here forces
        // the animated GIF89a header rather than the static GIF87a one.
        let gifProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let delay = Double(fps > 0 ? fps : 10)
        let frameProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / delay]]
        for frame in frames {
            let cg = try PngExporter.render(scene: frame, camera: camera, size: size)
            CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw AnimationExportError.encodeFailed }
    }

    // MARK: - APNG (manual chunk writer)

    private static func exportAPNG(frames: [Scene], camera: Camera?, size: CGSize, fps: Int,
                                   to url: URL) throws {
        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw AnimationExportError.invalidSize
        }
        let w = Int(rw), h = Int(rh)
        // Stream frames one at a time: render + deflate + append per frame so a
        // long trajectory never materializes every CGImage in memory at once.
        try ApngWriter.write(frameCount: frames.count, width: w, height: h, fps: fps, to: url) { index in
            try PngExporter.render(scene: frames[index], camera: camera, size: size)
        }
    }

    // MARK: - MP4 (AVFoundation)

    private static func exportMP4(frames: [Scene], camera: Camera?, size: CGSize, fps: Int,
                                  to url: URL) throws {
        let rw = size.width.rounded(), rh = size.height.rounded()
        guard rw.isFinite, rh.isFinite, rw >= 1, rh >= 1,
              rw <= CGFloat(Int.max), rh <= CGFloat(Int.max) else {
            throw AnimationExportError.invalidSize
        }
        let w = Int(rw), h = Int(rh)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { throw AnimationExportError.encodeFailed }
        writer.add(input)
        guard writer.startWriting() else { throw AnimationExportError.encodeFailed }
        writer.startSession(atSourceTime: .zero)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var index = 0
        var encodeError: Error?
        let finished = DispatchSemaphore(value: 0)
        // requestMediaDataWhenReady fires its block repeatedly until the input
        // stops accepting data. Each firing appends as many queued frames as the
        // input will take; when the queue is exhausted we signal completion.
        // We never re-register the handler from inside the block.
        input.requestMediaDataWhenReady(on: DispatchQueue.global()) {
            while input.isReadyForMoreMediaData && index < frames.count {
                let presentation = CMTimeMultiply(frameDuration, multiplier: Int32(index))
                do {
                    let cg = try PngExporter.render(scene: frames[index], camera: camera, size: size)
                    guard let buffer = MP4PixelBuffer.from(cg: cg, width: w, height: h) else {
                        throw AnimationExportError.encodeFailed
                    }
                    if !adaptor.append(buffer, withPresentationTime: presentation) {
                        if let error = writer.error { throw AnimationExportError.avFoundationFailed(error) }
                        throw AnimationExportError.encodeFailed
                    }
                } catch {
                    encodeError = error
                }
                index += 1
            }
            if index >= frames.count { finished.signal() }
        }
        finished.wait()
        if let encodeError { throw AnimationExportError.avFoundationFailed(encodeError) }
        input.markAsFinished()
        if let encodeError { throw AnimationExportError.avFoundationFailed(encodeError) }
        let done = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            if writer.status == .failed, let error = writer.error { finishError = error }
            done.signal()
        }
        done.wait()
        if let finishError { throw AnimationExportError.avFoundationFailed(finishError) }
        guard writer.status == .completed else { throw AnimationExportError.encodeFailed }
    }
}

enum MP4PixelBuffer {
    static func from(cg: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        // CGImage is top-left origin; CVPixelBuffer is bottom-left. Flip vertically.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - APNG writer

enum ApngWriter {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func write(frameCount: Int, width: Int, height: Int, fps: Int,
                      to url: URL, render: (Int) throws -> CGImage) throws {
        guard width > 0, height > 0, frameCount > 0 else { throw AnimationExportError.invalidSize }
        let data = NSMutableData()
        data.append(ApngWriter.signature, length: 8)
        // IHDR: 13-byte payload, serialized as big-endian bytes to avoid struct
        // alignment padding corrupting the wire format.
        writeChunk(data: data, type: "IHDR", bytes: ihdrBytes(width: width, height: height))
        // acTL: num_frames, num_plays
        writeChunk(data: data, type: "acTL", bytes: actlBytes(numFrames: UInt32(frameCount), numPlays: 0))
        // APNG spec: fcTL and fdAT chunks share one sequence-number space.
        // Frame 0: fcTL seq=0, then for frame i>=1: fcTL seq=2i-1, fdAT seq=2i.
        // IDAT (first frame) carries no sequence number. Delay = 1/fps seconds.
        let delayNum: UInt16 = 1
        let delayDen = fps > 0 ? UInt16(fps) : 1
        var seq = 0
        for i in 0..<frameCount {
            let isFirst = i == 0
            let cg = try render(i)
            let frameData = try frameRowData(cg: cg, width: width, height: height)
            let deflated = deflate(frameData)
            writeChunk(data: data, type: "fcTL", bytes: fcTLBytes(
                sequenceNumber: UInt32(seq),
                width: UInt32(width), height: UInt32(height),
                xOffset: 0, yOffset: 0,
                delayNum: delayNum, delayDen: delayDen,
                disposeOp: 0, blendOp: 0))
            seq += 1
            // IDAT for first frame (carries no sequence number), fdAT for rest.
            if isFirst {
                deflated.withUnsafeBytes { writeChunk(data: data, type: "IDAT", ptr: $0) }
            } else {
                let fdat = fdATData(sequenceNumber: UInt32(seq), frameData: deflated)
                fdat.withUnsafeBytes { writeChunk(data: data, type: "fdAT", ptr: $0) }
                seq += 1
            }
        }
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        writeChunk(data: data, type: "IEND", ptr: empty)
        try data.write(to: url, options: .atomic)
    }

    private static func frameRowData(cg: CGImage, width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw AnimationExportError.encodeFailed
        }
        // Prepend a 0 filter byte per scanline; CGImage is top-left origin so rows are in order.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var result = Data(capacity: (width * 4 + 1) * height)
        for y in 0..<height {
            result.append(0) // filter type: none
            let rowStart = y * width * 4
            result.append(contentsOf: bytes[rowStart..<rowStart + width * 4])
        }
        return result
    }

    private static func writeChunk(data: NSMutableData, type: String, bytes: [UInt8]) {
        bytes.withUnsafeBytes { writeChunk(data: data, type: type, ptr: $0) }
    }

    private static func writeChunk(data: NSMutableData, type: String, ptr: UnsafeRawBufferPointer) {
        let count = ptr.count
        var length = UInt32(count).bigEndian
        data.append(&length, length: 4)
        let typeBytes = Array(type.utf8)
        data.append(typeBytes, length: 4)
        if let base = ptr.baseAddress, count > 0 {
            data.append(base, length: count)
        }
        // CRC over type + data
        var crcInput = Data()
        crcInput.append(contentsOf: typeBytes)
        if let base = ptr.baseAddress, count > 0 {
            base.withMemoryRebound(to: UInt8.self, capacity: count) { bound in
                crcInput.append(bound, count: count)
            }
        }
        var crcBE = crc32(crcInput).bigEndian
        data.append(&crcBE, length: 4)
    }

    // MARK: - Chunk payload serializers (big-endian wire bytes)

    private static func ihdrBytes(width: Int, height: Int) -> [UInt8] {
        [
            UInt8((width >> 24) & 0xFF), UInt8((width >> 16) & 0xFF),
            UInt8((width >> 8) & 0xFF), UInt8(width & 0xFF),
            UInt8((height >> 24) & 0xFF), UInt8((height >> 16) & 0xFF),
            UInt8((height >> 8) & 0xFF), UInt8(height & 0xFF),
            8, 6, 0, 0, 0, // bit depth 8, color type 6 (RGBA), compression/filter/interlace 0
        ]
    }

    private static func actlBytes(numFrames: UInt32, numPlays: UInt32) -> [UInt8] {
        be32(numFrames) + be32(numPlays)
    }

    private static func fcTLBytes(sequenceNumber: UInt32, width: UInt32, height: UInt32,
                                  xOffset: UInt32, yOffset: UInt32,
                                  delayNum: UInt16, delayDen: UInt16,
                                  disposeOp: UInt8, blendOp: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(26)
        bytes.append(contentsOf: be32(sequenceNumber))
        bytes.append(contentsOf: be32(width))
        bytes.append(contentsOf: be32(height))
        bytes.append(contentsOf: be32(xOffset))
        bytes.append(contentsOf: be32(yOffset))
        bytes.append(contentsOf: be16(delayNum))
        bytes.append(contentsOf: be16(delayDen))
        bytes.append(disposeOp)
        bytes.append(blendOp)
        return bytes
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func be16(_ v: UInt16) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func fdATData(sequenceNumber: UInt32, frameData: Data) -> Data {
        var result = Data()
        var seq = sequenceNumber.bigEndian
        result.append(Data(bytes: &seq, count: 4))
        result.append(frameData)
        return result
    }

    // MARK: - Compression

    private static func deflate(_ input: Data) -> Data {
        let dstBufferSize = max(input.count + 64, 4096)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstBufferSize)
        defer { dst.deallocate() }
        let written = input.withUnsafeBytes { src -> Int in
            guard let base = src.baseAddress else { return 0 }
            return compression_encode_buffer(
                dst, dstBufferSize,
                base.assumingMemoryBound(to: UInt8.self), input.count,
                nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else {
            // Fallback: return raw input wrapped minimally. Should not happen.
            return input
        }
        return Data(bytes: dst, count: written)
    }

    // MARK: - CRC32 (table-based)

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
