import AppKit
import XCTest

@testable import MolVisApp

final class AppExportTests: XCTestCase {
    private final class AsymmetricGraph: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2).fill()
            NSColor.blue.setFill()
            NSRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2).fill()
        }
    }

    // MARK: - exportSizeForViewport

    func testExportSizeForViewportDefaultScaleIsIdentity() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertEqual(App.exportSizeForViewport(size), size)
    }

    func testExportSizeForViewportZeroSizePassesThrough() {
        // A zero/negative size is rejected later by validatedExportSize; the
        // derivation helper itself is a pure scale so it must not trap or clamp.
        let zero = CGSize.zero
        XCTAssertEqual(App.exportSizeForViewport(zero), zero)
    }

    func testGUIWriteDestinationRejectsSourceAliases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcrysden-gui-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("input.xsf")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        let symlink = dir.appendingPathComponent("alias.mvis-state")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)

        XCTAssertThrowsError(try App.validateGUIWriteDestination(source, source: source))
        XCTAssertThrowsError(try App.validateGUIWriteDestination(symlink, source: source))
        XCTAssertNoThrow(try App.validateGUIWriteDestination(dir.appendingPathComponent("state.mvis-state"), source: source))
    }

    @MainActor
    func testExportGraphPreservesFlippedTopBottomLayout() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("asymmetric-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let image = try App.exportGraph(AsymmetricGraph(frame: NSRect(x: 0, y: 0, width: 80, height: 80)),
                                        configure: { _ in }, to: output,
                                        size: CGSize(width: 80, height: 80))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let top = 10 * image.width * 4 + 10 * 4
        let bottom = 70 * image.width * 4 + 10 * 4
        XCTAssertGreaterThan(pixels[top], pixels[top + 2], "top of a flipped view must remain red")
        XCTAssertGreaterThan(pixels[bottom + 2], pixels[bottom], "bottom of a flipped view must remain blue")
    }

    // MARK: - Menu wiring

    func testFileMenuHasExportItemWithActionAndTarget() {
        // Build the menu the same way the app does at launch and confirm the
        // Export item exists, carries the right action, and is wired to the app.
        let app = App()
        let menu = app.buildMenu()
        guard let fileItem = menu.items.first(where: { $0.title == "File" }),
              let fileMenu = fileItem.submenu else {
            return XCTFail("File menu missing")
        }
        guard let exportItem = fileMenu.items.first(where: { $0.title.hasPrefix("Export") }) else {
            return XCTFail("Export menu item missing")
        }
        XCTAssertEqual(exportItem.action, Selector(("exportDocument:")))
        XCTAssertEqual(exportItem.target as? App, app)
        XCTAssertEqual(exportItem.keyEquivalent, "e")
    }
}
