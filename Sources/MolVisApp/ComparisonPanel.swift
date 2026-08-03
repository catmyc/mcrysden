import Foundation
import simd
import AppKit

/// A small panel showing the two-structure comparison summary: reference name,
/// RMS/mean/max displacement, matched/unmatched counts, and a per-element RMS
/// table. The sidebar hosts the Compare/Clear/Export actions and the arrow
/// toggle; this panel is a read-only detail view.
final class ComparisonPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    let titleField: NSTextField
    let summaryField: NSTextField
    let tableView: NSTableView
    /// Invoked by the "Choose Reference…" button; the controller re-presents
    /// the open panel and updates this view on success.
    var onChooseReference: (() -> Void)?

    private let scrollView: NSScrollView
    private var perElement: [StructureComparisonElementResult] = []

    static let colElement = NSUserInterfaceItemIdentifier("element")
    static let colMatched = NSUserInterfaceItemIdentifier("matched")
    static let colRMS = NSUserInterfaceItemIdentifier("rms")

    override init(frame frameRect: NSRect) {
        titleField = NSTextField(labelWithString: "")
        summaryField = NSTextField(labelWithString: "")
        scrollView = NSScrollView()
        tableView = NSTableView()
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        titleField = NSTextField(labelWithString: "")
        summaryField = NSTextField(labelWithString: "")
        scrollView = NSScrollView()
        tableView = NSTableView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        summaryField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        summaryField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        summaryField.textColor = .secondaryLabelColor
        summaryField.maximumNumberOfLines = 0
        summaryField.lineBreakMode = .byWordWrapping

        let chooseButton = NSButton(title: "Choose Reference…", target: self,
                                    action: #selector(chooseReference(_:)))
        chooseButton.translatesAutoresizingMaskIntoConstraints = false
        chooseButton.bezelStyle = .rounded

        addSubview(titleField)
        addSubview(summaryField)
        addSubview(scrollView)
        addSubview(chooseButton)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            summaryField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
            summaryField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summaryField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: summaryField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: chooseButton.topAnchor, constant: -8),
            chooseButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chooseButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        for (id, title, width) in [
            (Self.colElement, "Element", CGFloat(90)),
            (Self.colMatched, "Matched", CGFloat(80)),
            (Self.colRMS, "RMS (Å)", CGFloat(90)),
        ] {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.isEditable = false
            tableView.addTableColumn(col)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
    }

    @objc private func chooseReference(_ sender: Any?) {
        onChooseReference?()
    }

    /// Update the panel with a fresh comparison result.
    func update(referenceTitle: String, result: StructureComparisonResult) {
        titleField.stringValue = "Comparison with \(referenceTitle)"
        perElement = result.perElement
        tableView.reloadData()

        var lines: [String] = []
        if let rms = result.rmsDisplacement {
            lines.append(String(format: "RMS displacement: %.4f Å", rms))
        } else {
            lines.append("RMS displacement: —")
        }
        if let mean = result.meanDisplacement {
            lines.append(String(format: "Mean displacement: %.4f Å", mean))
        }
        if let max = result.maxDisplacement {
            lines.append(String(format: "Max displacement: %.4f Å", max))
        }
        lines.append("Matched pairs: \(result.matchedPairCount) "
            + "(cutoff \(String(format: "%.2f", result.maxMatchDistance)) Å)")
        lines.append("Unmatched source atoms: \(result.unmatchedSourceIndices.count)")
        lines.append("Unmatched reference atoms: \(result.unmatchedTargetIndices.count)")
        if !result.isComplete {
            lines.append("Analysis incomplete: safety cap exceeded.")
        }
        summaryField.stringValue = lines.joined(separator: "\n")
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        perElement.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let id = tableColumn?.identifier,
              row >= 0, row < perElement.count else { return nil }
        let entry = perElement[row]
        switch id {
        case Self.colElement:
            return ElementTable.symbol(entry.atomicNumber)
        case Self.colMatched:
            return "\(entry.matchedCount)"
        case Self.colRMS:
            return entry.rmsDisplacement.map { String(format: "%.4f", $0) } ?? "—"
        default:
            return nil
        }
    }
}
