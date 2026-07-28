import AppKit
import XCTest
@testable import MolVisApp

@MainActor
final class CommandPaletteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Materialize the shared application so NSApp is non-nil and
        // sendAction delivers synchronously. No window is presented.
        _ = NSApplication.shared
        // Reset the routing hook so a crashed test can't leak a spy into the next.
        CommandPaletteView.routeTextEdit = CommandPaletteView.defaultRouteTextEdit
    }

    private let sections: [CommandPaletteSection] = [
        CommandPaletteSection(title: "File", items: [
            CommandPaletteItem(title: "Open\u{2026}", keyEquivalent: "⌘O", section: "File", action: {}),
            CommandPaletteItem(title: "Export\u{2026}", keyEquivalent: "⌘E", section: "File", action: {}),
        ]),
        CommandPaletteSection(title: "Edit", items: [
            CommandPaletteItem(title: "Undo", keyEquivalent: "⌘Z", section: "Edit", action: {}),
            CommandPaletteItem(title: "Redo", keyEquivalent: "⌘⇧Z", section: "Edit", action: {}),
            CommandPaletteItem(title: "Copy", keyEquivalent: "⌘C", section: "Edit", action: {}),
        ]),
    ]

    // MARK: - Filtering

    func testEmptySearchReturnsAllItems() {
        let model = CommandPaletteModel(sections: sections)
        XCTAssertEqual(model.filteredItems.count, 5)
    }

    func testFilterMatchesTitleCaseInsensitive() {
        let model = CommandPaletteModel(sections: sections)
        model.searchText = "undo"
        XCTAssertEqual(model.filteredItems.count, 1)
        XCTAssertEqual(model.filteredItems.first?.title, "Undo")
    }

    func testFilterMatchesPartialTitle() {
        let model = CommandPaletteModel(sections: sections)
        model.searchText = "open"
        XCTAssertEqual(model.filteredItems.count, 1)
        XCTAssertEqual(model.filteredItems.first?.title, "Open\u{2026}")
    }

    func testFilterWithNoMatchesReturnsEmpty() {
        let model = CommandPaletteModel(sections: sections)
        model.searchText = "zzz"
        XCTAssertTrue(model.filteredItems.isEmpty)
    }

    func testFilterReturnsOnlyMatchingSections() {
        let model = CommandPaletteModel(sections: sections)
        model.searchText = "copy"
        XCTAssertEqual(model.filteredSections.count, 1)
        XCTAssertEqual(model.filteredSections.first?.title, "Edit")
    }

    func testFilterPreservesAllSectionsWhenEmpty() {
        let model = CommandPaletteModel(sections: sections)
        XCTAssertEqual(model.filteredSections.count, 2)
    }

    // MARK: - Selection navigation

    func testInitialSelectionIsFirstItem() {
        let model = CommandPaletteModel(sections: sections)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertTrue(model.isSelected(model.filteredItems.first!))
    }

    func testMoveDownAdvancesSelection() {
        let model = CommandPaletteModel(sections: sections)
        model.moveDown()
        XCTAssertEqual(model.selectedIndex, 1)
    }

    func testMoveUpDecrementsSelection() {
        let model = CommandPaletteModel(sections: sections)
        model.moveDown()
        model.moveDown()
        model.moveUp()
        XCTAssertEqual(model.selectedIndex, 1)
    }

    func testMoveUpClampsAtZero() {
        let model = CommandPaletteModel(sections: sections)
        model.moveUp()
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testMoveDownClampsAtLastIndex() {
        let model = CommandPaletteModel(sections: sections)
        for _ in 0..<10 { model.moveDown() }
        XCTAssertEqual(model.selectedIndex, model.filteredItems.count - 1)
    }

    func testSelectionResetsOnSearchChange() {
        let model = CommandPaletteModel(sections: sections)
        model.moveDown()
        model.moveDown()
        XCTAssertEqual(model.selectedIndex, 2)
        model.searchText = "undo"
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.filteredItems.count, 1)
    }

    // MARK: - Invocation

    func testInvokeSelectedCallsCorrectAction() {
        var invoked = false
        let custom = CommandPaletteSection(title: "Test", items: [
            CommandPaletteItem(title: "Do Thing", keyEquivalent: "", section: "Test", action: { invoked = true }),
        ])
        let model = CommandPaletteModel(sections: [custom])
        model.invokeSelected()
        XCTAssertTrue(invoked)
    }

    func testInvokeSelectedCallsActionAtIndex() {
        var count = 0
        let custom = CommandPaletteSection(title: "Test", items: [
            CommandPaletteItem(title: "A", keyEquivalent: "", section: "Test", action: { count += 1 }),
            CommandPaletteItem(title: "B", keyEquivalent: "", section: "Test", action: { count += 10 }),
        ])
        let model = CommandPaletteModel(sections: [custom])
        model.moveDown()
        model.invokeSelected()
        XCTAssertEqual(count, 10)
    }

    func testInvokeOnEmptyFilterIsNoOp() {
        let model = CommandPaletteModel(sections: sections)
        model.searchText = "zzz"
        XCTAssertTrue(model.filteredItems.isEmpty)
        model.invokeSelected()  // must not trap
    }

    // MARK: - isSelected

    func testIsSelectedReturnsTrueOnlyForSelectedIndex() {
        let model = CommandPaletteModel(sections: sections)
        let items = model.filteredItems
        XCTAssertTrue(model.isSelected(items[0]))
        XCTAssertFalse(model.isSelected(items[1]))
        model.moveDown()
        XCTAssertFalse(model.isSelected(items[0]))
        XCTAssertTrue(model.isSelected(items[1]))
    }

    // MARK: - Standard sections

    func testStandardSectionsContainExpectedGroups() {
        let std = CommandPaletteSection.standardSections
        let titles = Set(std.map { $0.title })
        XCTAssertTrue(titles.contains("File"))
        XCTAssertTrue(titles.contains("Edit"))
        XCTAssertTrue(titles.contains("View"))
        XCTAssertTrue(titles.contains("Analysis"))
    }

    func testStandardSectionsHaveNoEmptyItems() {
        let std = CommandPaletteSection.standardSections
        for section in std {
            XCTAssertFalse(section.items.isEmpty, "Section \(section.title) has no items")
        }
    }

    func testStandardSectionsFileHasKeyEquivalents() {
        let std = CommandPaletteSection.standardSections
        guard let file = std.first(where: { $0.title == "File" }) else {
            return XCTFail("File section missing")
        }
        let open = file.items.first { $0.title.hasPrefix("Open") }
        XCTAssertEqual(open?.keyEquivalent, "⌘O")
    }

    // MARK: - Text-edit command routing

    // Standard NSTextView does not implement undo:/redo: directly; those reach
    // the undo manager via the responder chain. The palette therefore restores
    // the originating window/responder and dispatches with a nil target so the
    // normal chain resolves the action. These tests verify that wiring without
    // presenting a real window (which is required to exercise the chain end-to-end).

    /// Records window-routing calls. Never ordered front and never closed, so it
    /// can be instantiated in XCTest without the teardown crashes that afflict
    /// presented windows.
    private final class MockWindow: NSWindow {
        var didMakeKeyAndOrderFront = false
        var didMakeFirstResponder: NSResponder?
        var firstResponderToReturn: NSResponder?
        var isVisibleOverride: Bool
        override var isVisible: Bool { isVisibleOverride }
        override var firstResponder: NSResponder? { firstResponderToReturn }

        init(isVisible: Bool = true) {
            self.isVisibleOverride = isVisible
            super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            didMakeKeyAndOrderFront = true
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            didMakeFirstResponder = responder
            firstResponderToReturn = responder
            return true
        }
    }

    func testDefaultRouteRestoresWindowAndFirstResponder() {
        let window = MockWindow()
        let responder = NSResponder()
        let ctx = CommandPaletteView.PriorContext(window: window, responder: responder)
        CommandPaletteView.defaultRouteTextEdit(NSSelectorFromString("undo:"), ctx)
        XCTAssertTrue(window.didMakeKeyAndOrderFront)
        XCTAssertTrue(window.didMakeFirstResponder === responder)
    }

    func testDefaultRouteIsNoOpWhenWindowNotVisible() {
        let window = MockWindow(isVisible: false)
        let responder = NSResponder()
        let ctx = CommandPaletteView.PriorContext(window: window, responder: responder)
        CommandPaletteView.defaultRouteTextEdit(NSSelectorFromString("undo:"), ctx)
        XCTAssertFalse(window.didMakeKeyAndOrderFront)
        XCTAssertNil(window.didMakeFirstResponder)
    }

    func testDefaultRouteSkipsRestoreWhenContextNil() {
        // No origin means there is no safe responder chain to dispatch through.
        CommandPaletteView.defaultRouteTextEdit(NSSelectorFromString("undo:"), nil)
    }

    func testRetargetedActionReadsContextAtInvocation() {
        let responder = NSResponder()
        CommandPaletteView.testSetPriorContext(window: nil, responder: responder)
        var captured: NSResponder?
        CommandPaletteView.routeTextEdit = { _, ctx in
            captured = ctx?.responder
        }
        defer { CommandPaletteView.routeTextEdit = CommandPaletteView.defaultRouteTextEdit }
        let action = CommandPaletteView.retargeted("undo:")
        action()
        XCTAssertTrue(captured === responder)
    }

    func testRetargetedActionWithNilContextIsNoOp() {
        CommandPaletteView.testSetPriorContext(window: nil, responder: nil)
        let action = CommandPaletteView.retargeted("undo:")
        action()  // must not trap
    }

    func testStandardEditItemsRouteThroughHook() {
        var dispatched: [String] = []
        CommandPaletteView.routeTextEdit = { sel, _ in
            dispatched.append(NSStringFromSelector(sel))
        }
        defer { CommandPaletteView.routeTextEdit = CommandPaletteView.defaultRouteTextEdit }

        let std = CommandPaletteSection.standardSections
        guard let edit = std.first(where: { $0.title == "Edit" }) else {
            return XCTFail("Edit section missing")
        }
        for item in edit.items {
            item.action()
        }
        // The six standard text-edit items route through the responder-chain hook;
        // "Copy Current View" uses a separate app-targeted dispatch.
        XCTAssertEqual(dispatched, ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
    }

    func testInvokeSelectedRoutesTextEditCommand() {
        var dispatched: [String] = []
        CommandPaletteView.routeTextEdit = { sel, _ in
            dispatched.append(NSStringFromSelector(sel))
        }
        defer { CommandPaletteView.routeTextEdit = CommandPaletteView.defaultRouteTextEdit }

        let std = CommandPaletteSection.standardSections
        guard let edit = std.first(where: { $0.title == "Edit" }),
              let undo = edit.items.first(where: { $0.title == "Undo" }) else {
            return XCTFail("Undo item missing")
        }
        let model = CommandPaletteModel(sections: std)
        // Select the Undo row and invoke it, mirroring the keyboard-Return and
        // mouse-click paths, which both funnel through invokeSelected().
        if let idx = model.filteredItems.firstIndex(where: { $0.id == undo.id }) {
            model.selectedIndex = idx
        }
        model.invokeSelected()
        XCTAssertEqual(dispatched, ["undo:"])
    }
}
