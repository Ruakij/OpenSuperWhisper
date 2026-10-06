import XCTest
@testable import OpenSuperWhisper

/// Which screen the bubble goes to for a point in Cocoa coordinates. Primary 2560x1440 at the
/// origin, a 1920x1080 display to its right, bottom-aligned.
final class NearestScreenTests: XCTestCase {

    let frames = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                  CGRect(x: 2560, y: 0, width: 1920, height: 1080)]

    func testPointInsideAScreen() {
        XCTAssertEqual(FocusUtils.nearestFrameIndex(to: NSPoint(x: 3000, y: 500), in: frames), 1)
    }

    /// The mouse on the second display's menu bar reports y == maxY, which `contains` excludes.
    func testTopRowOfASecondScreen() {
        XCTAssertEqual(FocusUtils.nearestFrameIndex(to: NSPoint(x: 3000, y: 1080), in: frames), 1)
    }

    func testPointAboveTheShorterScreenGoesToTheNearestOne() {
        XCTAssertEqual(FocusUtils.nearestFrameIndex(to: NSPoint(x: 4000, y: 1200), in: frames), 1)
        XCTAssertEqual(FocusUtils.nearestFrameIndex(to: NSPoint(x: 2600, y: 1400), in: frames), 0)
    }

    func testNoScreens() {
        XCTAssertNil(FocusUtils.nearestFrameIndex(to: .zero, in: []))
    }
}
