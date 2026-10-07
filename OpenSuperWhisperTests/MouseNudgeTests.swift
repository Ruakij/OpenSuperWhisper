import XCTest
@testable import OpenSuperWhisper

/// "Cursor" mode keeps the bubble near the caret anchor but no further than a fixed distance from
/// the mouse, so a tall field whose caret accessibility cannot place does not put the bubble at
/// its top edge. Cocoa (bottom-left origin) coordinates.
final class MouseNudgeTests: XCTestCase {

    let field = CGRect(x: 100, y: 100, width: 600, height: 800)

    func testWithoutAnchorTheMouseIsUsed() {
        XCTAssertEqual(FocusUtils.mouseNudgedPoint(anchor: nil, mouse: CGPoint(x: 5, y: 7), maxDistance: 150), CGPoint(x: 5, y: 7))
    }

    func testMouseInsideTheFieldIsUsed() {
        let mouse = CGPoint(x: 300, y: 150)
        XCTAssertEqual(FocusUtils.mouseNudgedPoint(anchor: field, mouse: mouse, maxDistance: 150), mouse)
    }

    func testMouseJustOutsideTheFieldSnapsToItsEdge() {
        let point = FocusUtils.mouseNudgedPoint(anchor: field, mouse: CGPoint(x: 300, y: 60), maxDistance: 150)
        XCTAssertEqual(point, CGPoint(x: 300, y: 100))
    }

    func testCaretNearTheMouseIsUsed() {
        let caret = CGRect(x: 400, y: 500, width: 0, height: 18)
        let point = FocusUtils.mouseNudgedPoint(anchor: caret, mouse: CGPoint(x: 450, y: 480), maxDistance: 150)
        XCTAssertEqual(point, CGPoint(x: 400, y: 500))
    }

    func testFarCaretIsPulledToTheMaximumDistance() {
        let caret = CGRect(x: 100, y: 900, width: 0, height: 18)
        let mouse = CGPoint(x: 100, y: 200)
        let point = FocusUtils.mouseNudgedPoint(anchor: caret, mouse: mouse, maxDistance: 150)
        XCTAssertEqual(point.x, 100, accuracy: 0.001)
        XCTAssertEqual(point.y, 350, accuracy: 0.001)
    }

    func testOffKeepsTheAnchorsTopLeftCorner() {
        let point = FocusUtils.mouseNudgedPoint(anchor: field, mouse: CGPoint(x: 300, y: 150), maxDistance: nil)
        XCTAssertEqual(point, CGPoint(x: 100, y: 900))
    }

    func testStrongPutsTheBubbleAtTheMouse() {
        let caret = CGRect(x: 100, y: 900, width: 0, height: 18)
        let mouse = CGPoint(x: 400, y: 200)
        let point = FocusUtils.mouseNudgedPoint(anchor: caret, mouse: mouse,
                                                maxDistance: FocusUtils.mousePullDistance("strong"))
        XCTAssertEqual(point.x, mouse.x, accuracy: 0.001)
        XCTAssertEqual(point.y, mouse.y, accuracy: 0.001)
    }

    func testPullSettings() {
        XCTAssertNil(FocusUtils.mousePullDistance("off"))
        XCTAssertEqual(FocusUtils.mousePullDistance("normal"), 150)
        XCTAssertEqual(FocusUtils.mousePullDistance("unknown"), 150)
        XCTAssertGreaterThan(FocusUtils.mousePullDistance("light")!, FocusUtils.mousePullDistance("normal")!)
    }

    func testAXRectConversionFlipsAroundItsTopEdge() {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let converted = FocusUtils.convertAXRectToCocoa(CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(converted, CGRect(x: 10, y: primaryTop - 60, width: 30, height: 40))
    }
}
