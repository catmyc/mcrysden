import AppKit
import SwiftUI

// MARK: - Data Model

struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let keyEquivalent: String
    let section: String
    let action: () -> Void
}

struct CommandPaletteSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [CommandPaletteItem]

    static var standardSections: [CommandPaletteSection] {
        func formatKey(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
            guard !key.isEmpty else { return "" }
            var result = ""
            if modifiers.contains(.control) { result += "⌃" }
            if modifiers.contains(.option) { result += "⌥" }
            if modifiers.contains(.shift) { result += "⇧" }
            if modifiers.contains(.command) { result += "⌘" }
            return result + key.uppercased()
        }
        func dispatch(_ selector: String, appTargeted: Bool = false) -> () -> Void {
            {
                let sel = NSSelectorFromString(selector)
                _ = NSApp.sendAction(sel, to: appTargeted ? NSApp.delegate : nil, from: nil)
            }
        }
        func analysis(_ tag: Int) -> () -> Void {
            {
                let sel = NSSelectorFromString("selectAnalysisMode:")
                let item = NSMenuItem(title: "", action: sel, keyEquivalent: "")
                item.tag = tag
                _ = NSApp.sendAction(sel, to: NSApp.delegate, from: item)
            }
        }
        return [
            CommandPaletteSection(title: "File", items: [
                CommandPaletteItem(title: "Open\u{2026}", keyEquivalent: formatKey("o", [.command]), section: "File", action: dispatch("openDocument:", appTargeted: true)),
                CommandPaletteItem(title: "Revert To Saved", keyEquivalent: "", section: "File", action: dispatch("revertToSaved:", appTargeted: true)),
                CommandPaletteItem(title: "Save State As\u{2026}", keyEquivalent: formatKey("S", [.command]), section: "File", action: dispatch("saveStateAs:", appTargeted: true)),
                CommandPaletteItem(title: "Export\u{2026}", keyEquivalent: formatKey("e", [.command]), section: "File", action: dispatch("exportDocument:", appTargeted: true)),
                CommandPaletteItem(title: "New Window", keyEquivalent: formatKey("n", [.command, .shift]), section: "File", action: dispatch("newDocument:", appTargeted: true)),
            ]),
            CommandPaletteSection(title: "Edit", items: [
                CommandPaletteItem(title: "Undo", keyEquivalent: formatKey("z", [.command]), section: "Edit", action: CommandPaletteView.retargeted("undo:")),
                CommandPaletteItem(title: "Redo", keyEquivalent: formatKey("z", [.command, .shift]), section: "Edit", action: CommandPaletteView.retargeted("redo:")),
                CommandPaletteItem(title: "Cut", keyEquivalent: formatKey("x", [.command]), section: "Edit", action: CommandPaletteView.retargeted("cut:")),
                CommandPaletteItem(title: "Copy", keyEquivalent: formatKey("c", [.command]), section: "Edit", action: CommandPaletteView.retargeted("copy:")),
                CommandPaletteItem(title: "Paste", keyEquivalent: formatKey("v", [.command]), section: "Edit", action: CommandPaletteView.retargeted("paste:")),
                CommandPaletteItem(title: "Select All", keyEquivalent: formatKey("a", [.command]), section: "Edit", action: CommandPaletteView.retargeted("selectAll:")),
                CommandPaletteItem(title: "Copy Current View", keyEquivalent: formatKey("c", [.command, .shift]), section: "Edit", action: dispatch("copyCurrentView:", appTargeted: true)),
            ]),
            CommandPaletteSection(title: "View", items: [
                CommandPaletteItem(title: "Toggle Element Labels", keyEquivalent: formatKey("l", [.command]), section: "View", action: dispatch("toggleLabelsFromMenu:", appTargeted: true)),
            ]),
            CommandPaletteSection(title: "Analysis", items: [
                CommandPaletteItem(title: "Selection", keyEquivalent: "", section: "Analysis", action: analysis(1)),
                CommandPaletteItem(title: "Distance", keyEquivalent: "", section: "Analysis", action: analysis(2)),
                CommandPaletteItem(title: "Angle", keyEquivalent: "", section: "Analysis", action: analysis(3)),
                CommandPaletteItem(title: "Dihedral", keyEquivalent: "", section: "Analysis", action: analysis(4)),
            ]),
        ]
    }
}

// MARK: - View Model

@MainActor
final class CommandPaletteModel: ObservableObject {
    @Published var searchText: String = "" { didSet { resetSelection() } }
    @Published var selectedIndex: Int = 0

    let sections: [CommandPaletteSection]

    init(sections: [CommandPaletteSection]) {
        self.sections = sections
    }

    var filteredItems: [CommandPaletteItem] {
        let all = sections.flatMap { $0.items }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var filteredSections: [CommandPaletteSection] {
        guard !searchText.isEmpty else { return sections }
        return sections.compactMap { section in
            let items = section.items.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
            guard !items.isEmpty else { return nil }
            return CommandPaletteSection(title: section.title, items: items)
        }
    }

    func isSelected(_ item: CommandPaletteItem) -> Bool {
        guard let idx = filteredItems.firstIndex(where: { $0.id == item.id }) else { return false }
        return idx == selectedIndex
    }

    func moveUp() {
        selectedIndex = max(0, selectedIndex - 1)
    }

    func moveDown() {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(filteredItems.count - 1, selectedIndex + 1)
    }

    func invokeSelected() {
        let items = filteredItems
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].action()
    }

    func resetSelection() {
        selectedIndex = 0
    }
}

// MARK: - View

struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel
    var onDismiss: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if model.filteredItems.isEmpty {
                noResults
            } else {
                commandList
            }
        }
        .frame(width: 520, height: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 24)
        .onAppear { searchFocused = true }
        .onKeyPress(.upArrow) { model.moveUp(); return .handled }
        .onKeyPress(.downArrow) { model.moveDown(); return .handled }
        .onKeyPress(.return) {
            model.invokeSelected()
            onDismiss()
            return .handled
        }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    private var searchField: some View {
        TextField("Search commands...", text: $model.searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .padding(12)
            .focused($searchFocused)
    }

    private var noResults: some View {
        Text("No matching commands")
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commandList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.filteredSections) { section in
                        CommandSectionHeader(title: section.title)
                        ForEach(section.items) { item in
                            CommandRow(
                                item: item,
                                isSelected: model.isSelected(item),
                                onSelect: {
                                    if let idx = model.filteredItems.firstIndex(where: { $0.id == item.id }) {
                                        model.selectedIndex = idx
                                    }
                                },
                                onInvoke: {
                                    if let idx = model.filteredItems.firstIndex(where: { $0.id == item.id }) {
                                        model.selectedIndex = idx
                                    }
                                    model.invokeSelected()
                                    onDismiss()
                                }
                            )
                            .id(item.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selectedIndex) { _, _ in
                let items = model.filteredItems
                if items.indices.contains(model.selectedIndex) {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(items[model.selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct CommandSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommandRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onInvoke: () -> Void

    var body: some View {
        HStack {
            Text(item.title)
                .font(.system(size: 13))
            Spacer()
            if !item.keyEquivalent.isEmpty {
                Text(item.keyEquivalent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
        .foregroundColor(isSelected ? .white : .primary)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture { onInvoke() }
        .onHover { hovering in
            if hovering { onSelect() }
        }
    }
}

// MARK: - Presentation

extension CommandPaletteView {
    private static weak var currentPanel: NSPanel?

    @MainActor
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// The window and first responder that were active before the palette
    /// opened. Text commands are routed back through the originating window's
    /// responder chain (the only way NSTextView's undo:/redo: reach the undo
    /// manager), not targeted at the responder directly.
    struct PriorContext {
        weak var window: NSWindow?
        weak var responder: NSResponder?
    }

    private static var priorContext: PriorContext?

    /// Default routing for a text-edit command: restores the originating
    /// window as key and its first responder, then dispatches with a nil target
    /// so the normal responder/undo-manager chain resolves it.
    static let defaultRouteTextEdit: (Selector, PriorContext?) -> Void = { sel, ctx in
        guard let window = ctx?.window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        if let responder = ctx?.responder, window.firstResponder !== responder {
            guard window.makeFirstResponder(responder) else { return }
        }
        _ = NSApp?.sendAction(sel, to: nil, from: nil)
    }

    /// Overridable routing hook. Mirrors `defaultRouteTextEdit`; tests replace
    /// this to observe routing without presenting a real window.
    static var routeTextEdit: (Selector, PriorContext?) -> Void = defaultRouteTextEdit

    /// Action factory for text-editing commands: routes through the originating
    /// window's responder chain via `routeTextEdit`, reading context at
    /// invocation time. Shared by both the Return key and mouse-click paths.
    static func retargeted(_ selector: String) -> () -> Void {
        return {
            let sel = NSSelectorFromString(selector)
            routeTextEdit(sel, priorContext)
        }
    }

    /// Test seam: set the context that `retargeted` actions route through. Avoids
    /// presenting a real palette window in XCTest.
    static func testSetPriorContext(window: NSWindow?, responder: NSResponder?) {
        priorContext = PriorContext(window: window, responder: responder)
    }

    static func show(sections: [CommandPaletteSection] = CommandPaletteSection.standardSections) {
        currentPanel?.close()
        let keyWindow = NSApp?.keyWindow
        priorContext = PriorContext(window: keyWindow, responder: keyWindow?.firstResponder)

        // Capture the active window's screen (not necessarily main) so the palette
        // opens on the same display as the viewer that invoked it.
        guard NSApp != nil, let screen = keyWindow?.screen ?? NSScreen.main else { return }
        let model = CommandPaletteModel(sections: sections)

        let panel = KeyablePanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isReleasedWhenClosed = true

        let dismiss: () -> Void = { [weak panel] in panel?.close() }

        let container = ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .ignoresSafeArea()
            CommandPaletteView(model: model, onDismiss: dismiss)
        }
        .frame(width: screen.frame.width, height: screen.frame.height)

        panel.contentView = NSHostingView(rootView: container)
        currentPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}
