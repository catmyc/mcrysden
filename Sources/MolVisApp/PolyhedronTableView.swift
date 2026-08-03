import Foundation
import simd
import AppKit

/// A virtualized table of first-shell polyhedron metrics (volume, bond-length
/// distortion, angle deviation) for every atom of the coordination analysis.
/// Data-source backed like the neighbor table; never builds one view per row.
final class PolyhedronTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    /// Maximum number of rows retained (mirrors the analyzer's atom cap).
    static let displayCap = 4_096

    let searchField: NSSearchField
    let tableView: NSTableView
    let statusField: NSTextField
    private let scrollView: NSScrollView

    private var atoms: [Atom] = []
    private var metrics: [PolyhedronMetrics] = []
    private var displayIndices: [Int] = []
    private var rawTotalCount = 0

    internal private(set) var filterRebuildCount = 0

    // MARK: - Column identifiers

    static let colIndex = NSUserInterfaceItemIdentifier("index")
    static let colElement = NSUserInterfaceItemIdentifier("element")
    static let colCoordination = NSUserInterfaceItemIdentifier("cn")
    static let colVolume = NSUserInterfaceItemIdentifier("volume")
    static let colDistortion = NSUserInterfaceItemIdentifier("distortion")
    static let colAngle = NSUserInterfaceItemIdentifier("angle")
    static let colRatio = NSUserInterfaceItemIdentifier("ratio")

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        searchField = NSSearchField()
        scrollView = NSScrollView()
        tableView = NSTableView()
        statusField = NSTextField(labelWithString: "")
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        searchField = NSSearchField()
        scrollView = NSScrollView()
        tableView = NSTableView()
        statusField = NSTextField(labelWithString: "")
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .secondaryLabelColor
        searchField.placeholderString = "Filter by element or label"

        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        addSubview(searchField)
        addSubview(scrollView)
        addSubview(statusField)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusField.topAnchor, constant: -4),
            statusField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        for (id, title, width) in [
            (Self.colIndex, "#", CGFloat(44)),
            (Self.colElement, "Element", CGFloat(64)),
            (Self.colCoordination, "CN", CGFloat(44)),
            (Self.colVolume, "V (Å³)", CGFloat(84)),
            (Self.colDistortion, "D", CGFloat(64)),
            (Self.colAngle, "σθ (°)", CGFloat(64)),
            (Self.colRatio, "V/Videal", CGFloat(72)),
        ] {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = 40
            col.isEditable = false
            tableView.addTableColumn(col)
        }

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
    }

    // MARK: - Public API

    /// Refresh atoms + metrics. `metrics` must be aligned to `atoms` (one entry
    /// per atom); a shorter array is treated as unavailable and clears the table.
    func update(atoms: [Atom], metrics: [PolyhedronMetrics]?) {
        self.atoms = atoms
        self.metrics = (metrics?.count == atoms.count) ? metrics! : []
        rawTotalCount = self.metrics.count
        rebuildFilter()
    }

    // MARK: - Filtering

    @objc private func searchChanged(_ sender: NSSearchField) {
        rebuildFilter()
    }

    private func rebuildFilter() {
        filterRebuildCount += 1
        let terms = searchField.stringValue.split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        displayIndices = metrics.indices.filter { index in
            guard terms.allSatisfy({ term in
                let symbol = ElementTable.symbol(atoms[index].atomicNumber).lowercased()
                let label = atoms[index].label.lowercased()
                return symbol.contains(term) || label.contains(term)
            }) else { return false }
            return true
        }
        tableView.reloadData()
        if rawTotalCount > Self.displayCap {
            statusField.stringValue = "Showing \(displayIndices.count) of \(rawTotalCount) atoms"
                + " (display capped at \(Self.displayCap))"
        } else {
            statusField.stringValue = "\(displayIndices.count) of \(rawTotalCount) atoms"
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayIndices.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let id = tableColumn?.identifier,
              row >= 0, row < displayIndices.count else { return nil }
        let originalIndex = displayIndices[row]
        guard originalIndex >= 0, originalIndex < atoms.count,
              originalIndex < metrics.count else { return nil }
        let atom = atoms[originalIndex]
        let metric = metrics[originalIndex]

        switch id {
        case Self.colIndex:
            return "\(originalIndex + 1)"
        case Self.colElement:
            return atom.label.isEmpty ? ElementTable.symbol(atom.atomicNumber) : atom.label
        case Self.colCoordination:
            return "\(metric.neighborCount)"
        case Self.colVolume:
            return metric.volume.map { String(format: "%.3f", $0) } ?? "—"
        case Self.colDistortion:
            return metric.bondLengthDistortion.map { String(format: "%.4f", $0) } ?? "—"
        case Self.colAngle:
            return metric.angleDeviation.map { String(format: "%.2f", $0) } ?? "—"
        case Self.colRatio:
            return metric.volumeRatio.map { String(format: "%.3f", $0) } ?? "—"
        default:
            return nil
        }
    }
}
