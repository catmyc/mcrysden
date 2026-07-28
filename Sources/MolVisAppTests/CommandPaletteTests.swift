import XCTest
@testable import MolVisApp

@MainActor
final class CommandPaletteTests: XCTestCase {
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
}
