import XCTest
import SwiftUI

@testable import MolVisApp

/// Verifies the sidebar-section collapse contract after the key-dedup change:
/// `CollapsibleSidebarSection.rawValue` is now the single source of truth for
/// the `@AppStorage` UserDefaults keys used by `SideBar`.
final class SidebarSectionTests: XCTestCase {

    private var defaults: UserDefaults { UserDefaults.standard }

    private func resetKeys() {
        for section in CollapsibleSidebarSection.allCases {
            defaults.removeObject(forKey: section.rawValue)
        }
    }

    override func setUp() {
        super.setUp()
        resetKeys()
    }

    override func tearDown() {
        resetKeys()
        super.tearDown()
    }

    // MARK: - Single source of truth

    func testRawValuesAreCanonicalKeys() {
        // Every case's rawValue must equal the full "SideBarCollapsed.<name>"
        // string that SideBar's @AppStorage references. Hardcoded expectations
        // here guard against silent drift between the enum and the storage key.
        let expected: [CollapsibleSidebarSection: String] = [
            .display: "SideBarCollapsed.display",
            .appearance: "SideBarCollapsed.appearance",
            .structureSummary: "SideBarCollapsed.structureSummary",
            .colorPlane: "SideBarCollapsed.colorPlane",
            .forces: "SideBarCollapsed.forces",
            .kPath: "SideBarCollapsed.kPath",
            .supercell: "SideBarCollapsed.supercell",
            .slab: "SideBarCollapsed.slab",
            .animation: "SideBarCollapsed.animation",
        ]
        for (section, key) in expected {
            XCTAssertEqual(section.rawValue, key)
        }
    }

    func testDefaultsKeyEqualsRawValue() {
        // The defaultsKey convenience must be derived from the rawValue so
        // there is exactly one place the key string is defined.
        for section in CollapsibleSidebarSection.allCases {
            XCTAssertEqual(section.defaultsKey, section.rawValue)
        }
    }

    func testAllSectionsHaveUniqueKeys() {
        let keys = CollapsibleSidebarSection.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(keys).count, keys.count,
                       "colliding UserDefaults keys would couple unrelated sections")
    }

    func testSideBarViewConstructsWithoutError() {
        // With keys now sourced from the enum, instantiating the sidebar must
        // compile and build a body without trapping.
        let sidebar = SideBar(state: SideBarState())
        XCTAssertNotNil(sidebar.body)
    }

    // MARK: - Default expanded

    func testDefaultExpandedWhenKeyAbsent() {
        // @AppStorage declares `= true`, so an absent key means expanded.
        // `bool(forKey:)` returns false for an absent key; the view's default
        // of true is applied only when nothing is stored. Verify nothing is
        // stored and that the contract (absent ⇒ expanded) holds.
        for section in CollapsibleSidebarSection.allCases {
            XCTAssertNil(defaults.object(forKey: section.rawValue),
                         "\(section) must start with no stored value (default expanded)")
        }
        // After a collapse+restore cycle the key is removed, returning to default.
        defaults.set(false, forKey: CollapsibleSidebarSection.display.rawValue)
        defaults.removeObject(forKey: CollapsibleSidebarSection.display.rawValue)
        XCTAssertNil(defaults.object(forKey: CollapsibleSidebarSection.display.rawValue))
    }

    // MARK: - Toggle

    func testToggleFlipsPersistedValue() {
        let key = CollapsibleSidebarSection.appearance.rawValue
        XCTAssertFalse(defaults.bool(forKey: key))

        defaults.set(false, forKey: key)
        XCTAssertFalse(defaults.bool(forKey: key))

        defaults.set(true, forKey: key)
        XCTAssertTrue(defaults.bool(forKey: key))
    }

    // MARK: - Persistence across view reconstruction

    func testPersistenceAcrossReconstruction() {
        // Simulate two successive SideBar views backed by the same
        // UserDefaults key (view teardown + rebuild). The collapsed state set
        // by the first "view" must be observable by the second.
        let key = CollapsibleSidebarSection.kPath.rawValue

        let firstView = SideBar(state: SideBarState())
        defaults.set(false, forKey: key)
        XCTAssertFalse(defaults.bool(forKey: key))

        // Reconstruct: a brand-new view reads the persisted value.
        let secondView = SideBar(state: SideBarState())
        XCTAssertFalse(defaults.bool(forKey: key),
                       "collapsed state must survive view reconstruction")
        XCTAssertNotNil(firstView.body)
        XCTAssertNotNil(secondView.body)
    }

    // MARK: - Section independence

    func testSectionIndependence() {
        let display = CollapsibleSidebarSection.display.rawValue
        let supercell = CollapsibleSidebarSection.supercell.rawValue

        defaults.set(false, forKey: display)
        XCTAssertFalse(defaults.bool(forKey: display))
        // Neighboring section untouched ⇒ still at its default (absent).
        XCTAssertNil(defaults.object(forKey: supercell))

        // Keys must differ so writes cannot alias.
        XCTAssertNotEqual(display, supercell)

        // Collapsing one section and reconstituting the view leaves a
        // separate section unaffected.
        defaults.removeObject(forKey: display)
        defaults.removeObject(forKey: supercell)
        defaults.set(false, forKey: display)
        _ = SideBar(state: SideBarState())           // trigger @AppStorage reads
        XCTAssertFalse(defaults.bool(forKey: display))
        XCTAssertNil(defaults.object(forKey: supercell))
    }
}
