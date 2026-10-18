import XCTest
import AppKit
@testable import ShiftDrop

final class ShelfDragGestureTests: XCTestCase {
    func testStaleDragPasteboardCannotTriggerShelfDuringLaterClick() {
        var gesture = ShelfDragGesture()
        XCTAssertEqual(gesture.risingModifiers(mouseDown: false, pasteboardChangeCount: 17, flags: []), [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 17, flags: []), [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 17, flags: .shift), [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 17, flags: [.shift, .command]), [])
    }

    func testFreshDragKeepsRisingModifierAndModeSwitchBehavior() {
        var gesture = ShelfDragGesture()
        _ = gesture.risingModifiers(mouseDown: false, pasteboardChangeCount: 17, flags: [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: []), [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: .shift), .shift)
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: .shift), [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: [.shift, .command]), .command)
        _ = gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: .shift), .shift)
        _ = gesture.risingModifiers(mouseDown: false, pasteboardChangeCount: 18, flags: [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: .shift), [])
    }

    func testFirstObservedMouseHoldAndAlreadyHeldModifierDoNotTrigger() {
        var gesture = ShelfDragGesture()
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 18, flags: .shift), [])
        _ = gesture.risingModifiers(mouseDown: false, pasteboardChangeCount: 18, flags: .shift)
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 19, flags: .shift), [])
        _ = gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 19, flags: [])
        XCTAssertEqual(gesture.risingModifiers(mouseDown: true, pasteboardChangeCount: 19, flags: .shift), .shift)
    }
}
