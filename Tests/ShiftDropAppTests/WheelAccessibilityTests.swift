import XCTest
import AppKit
import ShiftDropCore
@testable import ShiftDrop

final class WheelAccessibilityTests: XCTestCase {
    @MainActor
    func testAccessibleOperationActivatesAndUsesTheDrawnSectorFrame() throws {
        _ = NSApplication.shared
        var selected: String?
        let view = RadialWheelView(choices: [.format(.png), .format(.jpeg)], mode: .convert, inputs: [], receive: { _, _ in }, close: {}, choose: { selected = $0.title })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let elements = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(elements.count, 2)
        XCTAssertTrue(elements[1].accessibilityPerformPress())
        XCTAssertEqual(selected, "JPEG")
        for sector in RadialWheelLayout(count: 2).sectors {
            let point = window.convertPoint(toScreen: view.convert(sector.center, to: nil))
            let frame = elements[sector.index].accessibilityFrame()
            XCTAssertEqual(frame.midX, point.x, accuracy: 0.1)
            XCTAssertEqual(frame.midY, point.y, accuracy: 0.1)
        }
    }
    // Metadata-only: no application, window, event, or accessibility action is invoked.
    @MainActor
    func testAvailableChoicesExposeEnabledNamedAccessibilityButtons() throws {
        let view = RadialWheelView(choices: [.format(.png), .format(.jpeg)], mode: .convert, inputs: [], receive: { _, _ in }, close: {}, choose: { _ in })
        view.viewDidMoveToWindow()
        let elements = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.map { $0.accessibilityLabel() ?? "" }, ["Drop files: PNG", "Drop files: JPEG"])
        XCTAssertTrue(elements.allSatisfy { $0.isAccessibilityEnabled() })
        let empty = RadialWheelView(choices: [], mode: .convert, inputs: [], receive: { _, _ in }, close: {}, choose: { _ in })
        empty.viewDidMoveToWindow()
        XCTAssertTrue((empty.accessibilityChildren() ?? []).isEmpty)
    }
    @MainActor
    func testEmptyWheelExposesNonactionableExplanationAndFullFilename() {
        let filename = "synthetic-very-long-original-filename-for-accessibility-context.png"
        let view = RadialWheelView(choices: [], mode: .convert, inputs: [URL(fileURLWithPath: "/tmp/" + filename)], receive: { _, _ in }, close: {}, choose: { _ in })
        view.viewDidMoveToWindow()
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertTrue(view.accessibilityLabel()?.contains("No compatible formats") == true)
        XCTAssertTrue(view.accessibilityLabel()?.contains(filename) == true)
        XCTAssertTrue((view.accessibilityChildren() ?? []).isEmpty)
    }

}
