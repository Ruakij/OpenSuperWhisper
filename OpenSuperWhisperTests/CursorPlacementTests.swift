import XCTest
@testable import OpenSuperWhisper

/// "Cursor" mode trusts a reported caret while the mouse is near it and drifts toward a distant
/// mouse only partly. With just a field reported, the bubble goes to the field edge nearest the
/// mouse rather than following the mouse into the field and covering the text. Cocoa
/// (bottom-left origin) coordinates.
final class CursorPlacementTests: XCTestCase {

    let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let field = CGRect(x: 100, y: 200, width: 600, height: 800)
    let caret = CGRect(x: 400, y: 500, width: 0, height: 18)

    private func place(caret: CGRect? = nil, field: CGRect? = nil, mouse: CGPoint,
                       pull: CGFloat = 0.5) -> FocusUtils.Placement {
        FocusUtils.placement(caret: caret, field: field, mouse: mouse, pull: pull, screen: screen)
    }

    func testNothingReportedUsesTheMouse() {
        XCTAssertEqual(place(mouse: CGPoint(x: 5, y: 7)), .init(point: CGPoint(x: 5, y: 7)))
    }

    func testCaretNearTheMouseIsUsedAsIs() {
        XCTAssertEqual(place(caret: caret, mouse: CGPoint(x: 450, y: 450)), .init(point: CGPoint(x: 400, y: 518)))
    }

    func testFarMouseDrawsThePullFractionOfTheDistanceBeyondTheDeadZone() {
        let mouse = CGPoint(x: 400, y: 518 - 450)
        let point = place(caret: caret, mouse: mouse, pull: 0.5).point
        XCTAssertEqual(point.x, 400, accuracy: 0.001)
        XCTAssertEqual(point.y, 518 - 150, accuracy: 0.001)
    }

    func testOffKeepsTheCaret() {
        XCTAssertEqual(place(caret: caret, mouse: CGPoint(x: 1900, y: 10), pull: 0).point, CGPoint(x: 400, y: 518))
    }

    func testOffKeepsTheFieldsTopLeft() {
        XCTAssertEqual(place(field: field, mouse: CGPoint(x: 300, y: 250), pull: 0).point, CGPoint(x: 100, y: 1000))
    }

    func testMouseLowInTheFieldHangsTheBubbleBelowIt() {
        XCTAssertEqual(place(field: field, mouse: CGPoint(x: 300, y: 250)),
                       .init(point: CGPoint(x: 300, y: 200), hangsBelow: true))
    }

    func testMouseHighInTheFieldSitsTheBubbleAboveIt() {
        XCTAssertEqual(place(field: field, mouse: CGPoint(x: 300, y: 900)), .init(point: CGPoint(x: 300, y: 1000)))
    }

    func testNoRoomBelowTheFieldSitsTheBubbleAboveIt() {
        let lowField = CGRect(x: 100, y: 40, width: 600, height: 80)
        XCTAssertEqual(place(field: lowField, mouse: CGPoint(x: 300, y: 50)), .init(point: CGPoint(x: 300, y: 120)))
    }

    func testMouseBesideTheFieldClampsToItsWidth() {
        XCTAssertEqual(place(field: field, mouse: CGPoint(x: 900, y: 900)).point, CGPoint(x: 700, y: 1000))
    }

    func testPullSettings() {
        XCTAssertEqual(FocusUtils.mousePull("off"), 0)
        XCTAssertEqual(FocusUtils.mousePull("unknown"), FocusUtils.mousePull("normal"))
        XCTAssertLessThan(FocusUtils.mousePull("light"), FocusUtils.mousePull("normal"))
        XCTAssertLessThan(FocusUtils.mousePull("normal"), FocusUtils.mousePull("strong"))
    }

    func testAXRectConversionFlipsAroundItsTopEdge() {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let converted = FocusUtils.convertAXRectToCocoa(CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(converted, CGRect(x: 10, y: primaryTop - 60, width: 30, height: 40))
    }
}
