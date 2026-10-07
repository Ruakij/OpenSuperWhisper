import XCTest
@testable import OpenSuperWhisper

/// "Cursor" mode takes the horizontal position from the text (caret, or the field's left edge)
/// and lets the mouse move the bubble only vertically, by a share of its distance beyond the dead
/// zone. Cocoa (bottom-left origin) coordinates.
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
        XCTAssertEqual(place(caret: caret, mouse: CGPoint(x: 900, y: 450)), .init(point: CGPoint(x: 400, y: 518)))
    }

    func testFarMouseMovesTheBubbleOnlyVertically() {
        let placed = place(caret: caret, field: field, mouse: CGPoint(x: 650, y: 218))
        XCTAssertEqual(placed, .init(point: CGPoint(x: 400, y: 418), alignWithin: 100...700))
    }

    func testStrongerSettingsPullFurther() {
        let mouse = CGPoint(x: 650, y: 218)
        let light = place(caret: caret, field: field, mouse: mouse, pull: FocusUtils.mousePull("light")).point.y
        let normal = place(caret: caret, field: field, mouse: mouse, pull: FocusUtils.mousePull("normal")).point.y
        let strong = place(caret: caret, field: field, mouse: mouse, pull: FocusUtils.mousePull("strong")).point.y
        XCTAssertGreaterThan(light, normal)
        XCTAssertGreaterThan(normal, strong)
        XCTAssertEqual(strong, 318)
    }

    func testOffKeepsTheCaret() {
        XCTAssertEqual(place(caret: caret, mouse: CGPoint(x: 1900, y: 10), pull: 0).point, CGPoint(x: 400, y: 518))
    }

    func testOffKeepsTheFieldsTopLeft() {
        XCTAssertEqual(place(field: field, mouse: CGPoint(x: 300, y: 250), pull: 0).point, CGPoint(x: 100, y: 1000))
    }

    func testFieldOnlyWithTheMouseLowHangsBelowAtTheLeftEdge() {
        XCTAssertEqual(place(field: field, mouse: CGPoint(x: 300, y: 250)),
                       .init(point: CGPoint(x: 100, y: 200), hangsBelow: true, alignWithin: 100...700))
    }

    func testFieldOnlyWithTheMouseHighSitsAbove() {
        XCTAssertEqual(place(field: field, mouse: CGPoint(x: 300, y: 900)).point, CGPoint(x: 100, y: 1000))
    }

    func testNoRoomBelowTheFieldSitsTheBubbleAboveIt() {
        let lowField = CGRect(x: 100, y: 40, width: 600, height: 80)
        XCTAssertEqual(place(field: lowField, mouse: CGPoint(x: 300, y: 50)).point, CGPoint(x: 100, y: 120))
    }

    func testFieldOnlyFollowsAMouseFarBelow() {
        let placed = place(field: field, mouse: CGPoint(x: 300, y: -200))
        XCTAssertEqual(placed.point, CGPoint(x: 100, y: 50))
        XCTAssertTrue(placed.hangsBelow)
    }

    func testWideBubbleIsCentredOnTheField() {
        XCTAssertEqual(FocusUtils.alignedCenterX(width: 350, within: 100...700, toward: 120), 400)
    }

    func testThirdWideBubbleSnapsToTheThirdHoldingTheCaret() {
        XCTAssertEqual(FocusUtils.alignedCenterX(width: 240, within: 100...700, toward: 120), 220)
        XCTAssertEqual(FocusUtils.alignedCenterX(width: 240, within: 100...700, toward: 450), 400)
        XCTAssertEqual(FocusUtils.alignedCenterX(width: 240, within: 100...700, toward: 690), 580)
    }

    func testSmallBubbleGetsMoreSpots() {
        XCTAssertEqual(FocusUtils.alignedCenterX(width: 120, within: 100...700, toward: 260), 256, accuracy: 0.001)
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
