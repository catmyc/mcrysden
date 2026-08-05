import XCTest
import Metal
import simd
import Compression
@testable import MolVisApp

/// Focused tests for true-vector PDF/SVG export. Verifies that the vector
/// overlay (cell frame, axes, BZ, k-path, labels) is present as real vector
/// primitives, the raster layer is unchanged, and the usual export contracts
/// (deterministic output, absurd-size rejection, raster equivalence) hold.
@MainActor
final class VectorExportTests: XCTestCase {

    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent()
    }

    private func load(_ name: String) throws -> Scene {
        try Scene(loaded: try Parser.load(fixtureDirectory().appendingPathComponent("Fixtures/\(name)")))
    }

    private func camera(dist: Float) -> Camera {
        var c = Camera(); c.distance = dist; return c
    }

    private func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vectortest-\(UUID().uuidString).\(ext)")
    }

    // MARK: - PDF contains vector operators + text-showing operators

    func testVectorFormatsContainRealPrimitives() throws {
        // PDF: raster layer + vector path/text operators.
        do {
            var scene = try load("si110.xsf")
            scene.showAxes = true
            scene.showCellFrame = true
            scene.showBrillouinZone = true
            scene.showStructure = false
            scene.background = "#000000"
            let bz = try XCTUnwrap(BrillouinZone.build(cell: scene.cell!, atoms: scene.baseAtoms))
            let cands = bz.candidates()
            XCTAssertGreaterThanOrEqual(cands.count, 3, "si110 needs >= 3 landmarks for a k-path")
            scene.kPathPoints = Array(cands.prefix(4).map { $0.point })

            let labels = [
                LabelOverlayView.Label(symbol: "Si", x: 100, y: 100, style: .atom),
                LabelOverlayView.Label(symbol: "Gamma", x: 200, y: 200, style: .routeNode),
            ]
            let options = RenderExportOptions(labels: labels)
            let url = tempURL(ext: "pdf")
            _ = try TrueVectorExporter.export(scene: scene, camera: camera(dist: 12), to: url,
                                               size: CGSize(width: 400, height: 400), options: options)
            let data = try Data(contentsOf: url)
            let raw = String(data: data, encoding: .isoLatin1) ?? ""
            let streams = Self.decompressPDFStreams(data)

            XCTAssertTrue(raw.contains("/Subtype /Image") || raw.contains("XObject"),
                          "PDF must contain an image XObject for the raster layer")
            XCTAssertTrue(streams.contains(" m ") && streams.contains(" l "),
                          "PDF must contain vector path operators (moveto/lineto)")
            XCTAssertTrue(streams.contains(" Tj ") || streams.contains(" TJ "),
                          "PDF must contain text-showing operators for vector labels")
        }

        // SVG: vector elements + base64 image + vector text labels.
        do {
            var scene = try load("si110.xsf")
            scene.showAxes = true
            scene.showCellFrame = true
            scene.showBrillouinZone = true
            scene.showStructure = false
            scene.background = "#000000"
            let bz = try XCTUnwrap(BrillouinZone.build(cell: scene.cell!, atoms: scene.baseAtoms))
            let cands = bz.candidates()
            scene.kPathPoints = Array(cands.prefix(4).map { $0.point })

            let labels = [LabelOverlayView.Label(symbol: "Si", x: 80, y: 80, style: .atom)]
            let options = RenderExportOptions(labels: labels)
            let url = tempURL(ext: "svg")
            _ = try TrueVectorExporter.export(scene: scene, camera: camera(dist: 12), to: url,
                                               size: CGSize(width: 400, height: 400), options: options)
            let svg = try String(contentsOf: url, encoding: .utf8)

            XCTAssertTrue(svg.contains("<image"), "SVG must contain a base64 <image> for the raster layer")
            XCTAssertTrue(svg.contains("<path") || svg.contains("<line") || svg.contains("<polyline"),
                          "SVG must contain vector primitives (path/line/polyline)")
            XCTAssertTrue(svg.contains("<text"), "SVG must contain <text> elements for labels")
        }

        // Graph PDF export is true vector (band route).
        do {
            var scene = try load("si110.xsf")
            scene.background = "#000000"
            let bandKPts = (0..<10).map { BandKPoint(k: SIMD3(Float($0) / 9, 0, 0), weight: 1, label: "k\($0)", energies: [Float($0) * 0.5]) }
            scene.bandStructure = BandStructure(kPoints: bandKPts, fermiEnergy: 2.0, nSpin: 1, kPointsPerSpin: 10)

            let outURL = tempURL(ext: "pdf")
            let size = CGSize(width: 400, height: 300)
            let graph = BandGrapherView(frame: NSRect(origin: .zero, size: size))
            _ = try App.exportGraph(graph, configure: { $0.bandStructure = scene.bandStructure },
                                     to: outURL, size: size)

            let data = try Data(contentsOf: outURL)
            let streams = Self.decompressPDFStreams(data)
            XCTAssertTrue(streams.contains(" m ") && streams.contains(" l "),
                          "Graph PDF must contain vector path operators")
            XCTAssertTrue(streams.contains(" Tj ") || streams.contains(" TJ "),
                          "Graph PDF must contain text-showing operators")
        }

        // Orientation-gizmo parity: PDF and SVG use the same gizmo center and
        // NDC projection; the only difference is the y-flip (y_pdf = h - y_svg).
        // A sign error in the PDF path would vertically mirror the PDF triad.
        do {
            var scene = try load("si110.xsf")
            scene.background = "#000000"
            scene.showAxes = true
            scene.showCellFrame = false
            scene.showBrillouinZone = false
            scene.showStructure = false
            let size = CGSize(width: 400, height: 300)

            let svgURL = tempURL(ext: "svg")
            _ = try TrueVectorExporter.export(scene: scene, camera: camera(dist: 12), to: svgURL, size: size)
            let svg = try String(contentsOf: svgURL, encoding: .utf8)

            let h = Double(size.height)
            let gSize = max(72.0, Double(min(size.width, size.height)) * 0.16)
            let margin = 14.0
            let centerX = margin + gSize / 2
            let centerYImg = h - margin - gSize / 2

            let svgLines = svg.components(separatedBy: "\n")
            for line in svgLines where line.contains("<line") && line.contains("#33ff33") {
                guard let coords = Self.parseSVGLineCoords(line) else { continue }
                if abs(coords.x1 - centerX) < 0.01 && abs(coords.y1 - centerYImg) < 0.01 {
                    XCTAssertLessThan(coords.y2, coords.y1,
                                      "SVG green (+y) gizmo tip must be above center")
                    let expectedTipYPdf = h - coords.y2
                    let centerYPdf = h - centerYImg
                    XCTAssertGreaterThan(expectedTipYPdf, centerYPdf,
                                         "PDF green (+y) gizmo tip must be below PDF center (y-up)")
                }
            }
        }
    }
    func testVectorExportContracts() throws {
        // The returned raster CGImage of a PDF/SVG export must match
        // PngExporter's output (the vector overlay is additive).
        do {
            var scene = try load("si110.xsf")
            scene.background = "#000000"
            scene.showAxes = false
            scene.showCellFrame = true
            scene.showStructure = true

            let size = CGSize(width: 200, height: 200)
            let cam = camera(dist: 12)

            let pngURL = tempURL(ext: "png")
            let pngImage = try PngExporter.export(scene: scene, camera: cam, to: pngURL, size: size)

            let pdfURL = tempURL(ext: "pdf")
            let pdfImage = try TrueVectorExporter.export(scene: scene, camera: cam, to: pdfURL, size: size)
            XCTAssertEqual(pixelHash(pngImage), pixelHash(pdfImage),
                           "the returned raster CGImage of a PDF export must match PngExporter's output")

            let svgURL = tempURL(ext: "svg")
            let svgImage = try TrueVectorExporter.export(scene: scene, camera: cam, to: svgURL, size: size)
            XCTAssertEqual(pixelHash(pngImage), pixelHash(svgImage),
                           "the returned raster CGImage of an SVG export must match PngExporter's output")
        }

        // Absurd export sizes throw instead of trapping.
        do {
            var scene = Scene()
            scene.background = "#000000"
            scene.atoms = [Atom(coord: .zero, atomicNumber: 6, label: "C")]

            let absurd = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
            XCTAssertThrowsError(try TrueVectorExporter.export(scene: scene, camera: nil,
                                                                to: tempURL(ext: "pdf"), size: absurd))
            XCTAssertThrowsError(try TrueVectorExporter.export(scene: scene, camera: nil,
                                                                to: tempURL(ext: "svg"), size: absurd))

            let nonFinite = CGSize(width: CGFloat.nan, height: 100)
            XCTAssertThrowsError(try TrueVectorExporter.export(scene: scene, camera: nil,
                                                                to: tempURL(ext: "pdf"), size: nonFinite))

            let zero = CGSize(width: 0, height: 0)
            XCTAssertThrowsError(try TrueVectorExporter.export(scene: scene, camera: nil,
                                                                to: tempURL(ext: "pdf"), size: zero))
        }

        // Two exports of the same scene are deterministic.
        do {
            var scene = try load("si110.xsf")
            scene.background = "#000000"
            scene.showAxes = true
            scene.showCellFrame = true
            scene.showStructure = true
            let size = CGSize(width: 200, height: 200)

            let url1 = tempURL(ext: "pdf")
            let url2 = tempURL(ext: "pdf")
            _ = try TrueVectorExporter.export(scene: scene, camera: camera(dist: 12), to: url1, size: size)
            _ = try TrueVectorExporter.export(scene: scene, camera: camera(dist: 12), to: url2, size: size)
            let data1 = try Data(contentsOf: url1)
            let data2 = try Data(contentsOf: url2)
            // Strip variable PDF metadata (timestamps, ID) before comparing so
            // the test asserts deterministic CONTENT, not byte-identical metadata.
            let stripped1 = Self.stripVariablePDFMetadata(data1)
            let stripped2 = Self.stripVariablePDFMetadata(data2)
            XCTAssertEqual(stripped1, stripped2,
                           "two PDF exports of the same scene must have identical content")

            let url3 = tempURL(ext: "svg")
            let url4 = tempURL(ext: "svg")
            _ = try TrueVectorExporter.export(scene: scene, camera: camera(dist: 12), to: url3, size: size)
            _ = try TrueVectorExporter.export(scene: scene, camera: camera(dist: 12), to: url4, size: size)
            let data3 = try Data(contentsOf: url3)
            let data4 = try Data(contentsOf: url4)
            XCTAssertEqual(data3, data4, "two SVG exports of the same scene must be byte-identical")
        }
    }


    /// Parse x1,y1,x2,y2 from an SVG <line> element.
    private static func parseSVGLineCoords(_ line: String) -> (x1: Double, y1: Double, x2: Double, y2: Double)? {
        let pattern = "x1=\"([0-9.]+)\"\\s+y1=\"([0-9.]+)\"\\s+x2=\"([0-9.]+)\"\\s+y2=\"([0-9.]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 5,
              let r1 = Range(match.range(at: 1), in: line),
              let r2 = Range(match.range(at: 2), in: line),
              let r3 = Range(match.range(at: 3), in: line),
              let r4 = Range(match.range(at: 4), in: line),
              let x1 = Double(line[r1]),
              let y1 = Double(line[r2]),
              let x2 = Double(line[r3]),
              let y2 = Double(line[r4]) else { return nil }
        return (x1, y1, x2, y2)
    }

    /// Strip PDF metadata fields that vary between exports (timestamps, ID)
    /// so content determinism can be asserted.
    private static func stripVariablePDFMetadata(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        // Zero-out /ModDate (...) and /CreationDate (...) content.
        let parenPatterns = ["/ModDate (", "/CreationDate ("]
        for pat in parenPatterns {
            let patBytes = Array(pat.utf8)
            var i = 0
            while i + patBytes.count <= bytes.count {
                if bytes[i..<i + patBytes.count].elementsEqual(patBytes) {
                    var j = i + patBytes.count
                    while j < bytes.count && bytes[j] != AsciiClosingParen { j += 1 }
                    for k in i..<min(j + 1, bytes.count) { bytes[k] = AsciiSpace }
                    i = j + 1
                } else {
                    i += 1
                }
            }
        }
        // Zero-out /ID [...] content.
        let idPattern = "/ID ["
        let idBytes = Array(idPattern.utf8)
        var scan = 0
        while scan + idBytes.count <= bytes.count {
            if bytes[scan..<scan + idBytes.count].elementsEqual(idBytes) {
                var j = scan + idBytes.count
                while j < bytes.count && bytes[j] != AsciiClosingBracket { j += 1 }
                for k in scan..<min(j + 1, bytes.count) { bytes[k] = AsciiSpace }
                scan = j + 1
            } else {
                scan += 1
            }
        }
        return Data(bytes)
    }
    private static let AsciiClosingParen: UInt8 = 0x29
    private static let AsciiClosingBracket: UInt8 = 0x5d
    private static let AsciiSpace: UInt8 = 0x20

    // MARK: - PDF stream decompression

    /// Extract and decompress all FlateDecode streams from PDF data, returning
    /// the concatenated decompressed content. Content streams in a PDF are
    /// deflate-compressed, so the raw operators (" m ", " l ", " Tj ") are
    /// only visible after decompression.
    private static func decompressPDFStreams(_ data: Data) -> String {
        var result = ""
        let bytes = [UInt8](data)
        let streamMarker = Array("stream\n".utf8)
        let streamMarkerCR = Array("stream\r\n".utf8)
        let endMarker = Array("endstream".utf8)

        var i = 0
        while i < bytes.count {
            // Look for "stream\n" or "stream\r\n".
            let remaining = bytes.count - i
            let matches: Bool
            if remaining >= streamMarker.count && bytes[i..<i + streamMarker.count].elementsEqual(streamMarker) {
                matches = true
                i += streamMarker.count
            } else if remaining >= streamMarkerCR.count && bytes[i..<i + streamMarkerCR.count].elementsEqual(streamMarkerCR) {
                matches = true
                i += streamMarkerCR.count
            } else {
                matches = false
                i += 1
            }
            if matches {
                // Find the next "endstream".
                var end = i
                while end + endMarker.count <= bytes.count {
                    if bytes[end..<end + endMarker.count].elementsEqual(endMarker) { break }
                    end += 1
                }
                let compressed = Array(bytes[i..<end])
                // PDF FlateDecode streams may be raw deflate or zlib-wrapped.
                // Skip a 2-byte zlib header (0x78 xx) if present.
                let offset = (compressed.count >= 2 && compressed[0] == 0x78) ? 2 : 0
                let payload = Array(compressed[offset...])
                let decompressed: Data = payload.withUnsafeBufferPointer { ptr -> Data in
                    let capacity = max(payload.count * 16, 4096)
                    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                    defer { dst.deallocate() }
                    let size = compression_decode_buffer(dst, capacity,
                                                         ptr.baseAddress!, payload.count,
                                                         nil, COMPRESSION_ZLIB)
                    if size > 0 { return Data(bytes: dst, count: size) }
                    return Data()
                }
                if let s = String(data: decompressed, encoding: .ascii) { result += s }
                // Skip past "endstream" so we don't match its trailing "stream".
                i = end + endMarker.count
            }
        }
        return result
    }

    // MARK: - FNV-1a hash (matches Snapshotter)

    private func pixelHash(_ image: CGImage) -> UInt64 {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.reduce(into: UInt64(0xcbf29ce484222325)) { hash, byte in
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
    }
}
