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

    // MARK: - Edit menu

    func testEditMenuHasStandardItems() {
        let app = App()
        let menu = app.buildMenu()
        guard let editMenu = menu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else {
            return XCTFail("Edit menu missing")
        }
        let titles = editMenu.items.map { $0.title }
        XCTAssertTrue(titles.contains("Undo"), "Edit menu should have Undo")
        XCTAssertTrue(titles.contains("Redo"), "Edit menu should have Redo")
        XCTAssertTrue(titles.contains("Cut"), "Edit menu should have Cut")
        XCTAssertTrue(titles.contains("Copy"), "Edit menu should have Copy")
        XCTAssertTrue(titles.contains("Paste"), "Edit menu should have Paste")
        XCTAssertTrue(titles.contains("Select All"), "Edit menu should have Select All")
    }

    func testEditMenuKeyEquivalents() {
        let app = App()
        let menu = app.buildMenu()
        guard let editMenu = menu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else {
            return XCTFail("Edit menu missing")
        }
        func key(_ title: String) -> String {
            editMenu.items.first { $0.title == title }?.keyEquivalent ?? ""
        }
        XCTAssertEqual(key("Undo"), "z")
        XCTAssertEqual(key("Redo"), "Z")
        XCTAssertEqual(key("Cut"), "x")
        XCTAssertEqual(key("Copy"), "c")
        XCTAssertEqual(key("Paste"), "v")
        XCTAssertEqual(key("Select All"), "a")
        XCTAssertEqual(key("Copy Current View"), "C")
    }

    func testEditMenuStandardActionsRouteToFirstResponder() {
        // Cut/Copy/Paste/Select All/Undo/Redo must have nil target so AppKit
        // routes them through the responder chain (first responder wins).
        let app = App()
        let menu = app.buildMenu()
        guard let editMenu = menu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else {
            return XCTFail("Edit menu missing")
        }
        for title in ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"] {
            guard let item = editMenu.items.first(where: { $0.title == title }) else {
                return XCTFail("\(title) missing")
            }
            XCTAssertNil(item.target, "\(title) target should be nil (first responder)")
        }
    }

    func testCopyCurrentViewItemWiredToApp() {
        let app = App()
        let menu = app.buildMenu()
        guard let editMenu = menu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu else {
            return XCTFail("Edit menu missing")
        }
        guard let copyView = editMenu.items.first(where: { $0.title == "Copy Current View" }) else {
            return XCTFail("Copy Current View menu item missing")
        }
        XCTAssertEqual(copyView.action, Selector(("copyCurrentView:")))
        XCTAssertEqual(copyView.target as? App, app)
        XCTAssertEqual(copyView.keyEquivalent, "C")
    }

    @MainActor
    func testCopyCurrentViewWithoutWindowIsNoOp() {
        // No mainWC → the action must return without trapping, even though
        // there is no pasteboard access or rendering attempted. The method is
        // private; dispatch via selector to exercise the ObjC entry point.
        let app = App()
        let item = NSMenuItem(title: "Copy Current View", action: Selector(("copyCurrentView:")), keyEquivalent: "C")
        item.target = NSApp
        app.perform(item.action, with: item)
        // When there is no first responder (nil mainWC), the action should
        // silently return. If it crashed, the test would not reach here.
    }

    @MainActor
    func testRepeatedCopyCancelsPendingResetTimer() {
        // Two rapid copies must not let the first copy's reset timer fire and
        // revert the title while the second copy's flash is still showing.
        let app = App()
        let item = NSMenuItem(title: "Copy Current View", action: #selector(NSObject.init), keyEquivalent: "")

        // First copy: title → "Copied View", reset scheduled at +1.0s.
        app.flashCopyResult(item, success: true)
        XCTAssertEqual(item.title, "Copied View")

        // Second copy at +0.1s: must cancel the first timer, schedule a fresh +1.0s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            app.flashCopyResult(item, success: true)
            XCTAssertEqual(item.title, "Copied View")
        }

        // At +0.5s the title must still be "Copied View" — the first timer was
        // cancelled, so it cannot have reverted the title.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(item.title, "Copied View")
        }

        // After the second timer fires, the title must be restored. Poll with a
        // predicate expectation to avoid depending on exact async-after timing
        // under full-suite load.
        let restore = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "title == %@", "Copy Current View"),
            object: item)
        wait(for: [restore], timeout: 4.0)
    }
}
