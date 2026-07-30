import AppKit
import XCTest

@testable import MolVisApp

final class LabelOverlayViewTests: XCTestCase {
    func testDefaultStylePreservesAtomLabelAPI() {
        let label = LabelOverlayView.Label(symbol: "C", x: 12, y: 24)

        XCTAssertEqual(label.symbol, "C")
        XCTAssertEqual(label.style, .atom)
        XCTAssertTrue(label.isExportable)
    }

    func testPersistentStylesExportAndTooltipDoesNot() {
        let styles: [LabelOverlayView.Label.Style] = [
            .atom, .routeNode, .selectedRouteNode, .tooltip
        ]
        let exportability = styles.map { style in
            LabelOverlayView.Label(symbol: "G", x: 0, y: 0, style: style).isExportable
        }

        XCTAssertEqual(exportability, [true, true, true, false])
    }

    func testOverlayIsMouseTransparent() {
        let view = LabelOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)))
    }

    func testTooltipRectClampsToViewportEdges() {
        let label = LabelOverlayView.Label(symbol: "line one\nline two",
                                            x: 98, y: 98, style: .tooltip)
        let bounds = NSRect(x: 0, y: 0, width: 120, height: 100)
        let rect = LabelOverlayView.clampedDrawingRect(for: label, in: bounds)

        XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX)
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX)
        XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY)
        XCTAssertLessThan(rect.minX, label.x)
        XCTAssertLessThan(rect.minY, label.y)
    }

    func testLabelGeometryIsStableAndPaddingIsIncluded() {
        let label = LabelOverlayView.Label(symbol: "A\nB", x: 20, y: 30, style: .routeNode)
        let size1 = LabelOverlayView.measuredSize(for: label)
        let size2 = LabelOverlayView.measuredSize(for: label)
        let rect1 = LabelOverlayView.drawingRect(for: label)
        let rect2 = LabelOverlayView.drawingRect(for: label)

        XCTAssertEqual(size1, size2)
        XCTAssertEqual(rect1, rect2)
        XCTAssertGreaterThan(size1.height, 0)
        XCTAssertGreaterThan(rect1.width, size1.width)
        XCTAssertGreaterThan(rect1.height, size1.height)
        XCTAssertEqual(rect1.minX, label.x - 3)
        XCTAssertEqual(rect1.minY, label.y - 2)
    }

    func testMultilineTextDrawingRectUsesAllLinesAndFitsPaddedRect() {
        let oneLine = LabelOverlayView.Label(symbol: "line one", x: 20, y: 30, style: .tooltip)
        let multiline = LabelOverlayView.Label(symbol: "line one\nline two", x: 20, y: 30, style: .tooltip)
        let oneLineSize = LabelOverlayView.measuredSize(for: oneLine)
        let multilineSize = LabelOverlayView.measuredSize(for: multiline)
        let paddedRect = LabelOverlayView.drawingRect(for: multiline)
        let textRect = LabelOverlayView.textDrawingRect(for: multiline, in: paddedRect)

        XCTAssertGreaterThanOrEqual(multilineSize.height, oneLineSize.height * 2)
        XCTAssertEqual(textRect.size, multilineSize)
        XCTAssertGreaterThanOrEqual(textRect.minX, paddedRect.minX)
        XCTAssertGreaterThanOrEqual(textRect.minY, paddedRect.minY)
        XCTAssertLessThanOrEqual(textRect.maxX, paddedRect.maxX)
        XCTAssertLessThanOrEqual(textRect.maxY, paddedRect.maxY)
    }
}
