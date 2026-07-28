import AppKit
import XCTest

@testable import MolVisApp

final class ExportOptionsTests: XCTestCase {
    func testDefaultsAreSensible() {
        let opts = ExportOptions()
        XCTAssertEqual(opts.width, 800)
        XCTAssertEqual(opts.height, 800)
        XCTAssertFalse(opts.isTransparent)
    }

    func testValidatesWithinRange() {
        let opts = ExportOptions()
        XCTAssertNoThrow(try opts.validate())

        opts.width = 64; opts.height = 64
        XCTAssertNoThrow(try opts.validate())

        opts.width = 2048; opts.height = 2048
        XCTAssertNoThrow(try opts.validate())
    }

    func testRejectsWidthOutOfRange() {
        let opts = ExportOptions()
        opts.width = 63
        XCTAssertThrowsError(try opts.validate()) { error in
            XCTAssertTrue(error is ExportOptionsError)
        }

        opts.width = 16385
        XCTAssertThrowsError(try opts.validate())
    }

    func testRejectsHeightOutOfRange() {
        let opts = ExportOptions()
        opts.height = 1
        XCTAssertThrowsError(try opts.validate())

        opts.height = 20000
        XCTAssertThrowsError(try opts.validate())
    }

    func testPixelCount() {
        let opts = ExportOptions()
        opts.width = 1920; opts.height = 1080
        XCTAssertEqual(opts.pixelCount, 2_073_600)
    }

    func testClearColorOpaque() {
        let opts = ExportOptions()
        opts.backgroundColor = NSColor(deviceRed: 0.5, green: 0.25, blue: 0.75, alpha: 1.0)
        opts.isTransparent = false
        let c = opts.clearColor
        XCTAssertEqual(c.r, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.g, 0.25, accuracy: 0.001)
        XCTAssertEqual(c.b, 0.75, accuracy: 0.001)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testClearColorOpaqueForcesAlphaOne() {
        let opts = ExportOptions()
        opts.backgroundColor = NSColor(deviceRed: 0.5, green: 0.25, blue: 0.75, alpha: 0.3)
        opts.isTransparent = false
        let c = opts.clearColor
        XCTAssertEqual(c.r, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.g, 0.25, accuracy: 0.001)
        XCTAssertEqual(c.b, 0.75, accuracy: 0.001)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testClearColorTransparent() {
        let opts = ExportOptions()
        opts.backgroundColor = NSColor.white
        opts.isTransparent = true
        let c = opts.clearColor
        XCTAssertEqual(c.a, 0.0)
    }

    func testHexInitValid() {
        let color = NSColor(hex: "#FF8800")
        XCTAssertNotNil(color)
        let c = color!.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(c.redComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(c.greenComponent, 0x88 / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.blueComponent, 0.0, accuracy: 0.01)
    }

    func testHexInitInvalid() {
        XCTAssertNil(NSColor(hex: "nope"))
        XCTAssertNil(NSColor(hex: "#xyz"))
        XCTAssertNil(NSColor(hex: "#12345"))
    }
}
