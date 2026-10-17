import XCTest

@testable import OpenSuperWhisper

/// Releasing the trigger after a short hold (#220): a press long enough to enter push-to-talk but
/// too short to make a usable clip used to stop the take, and that clip was dropped silently.
final class ShortHoldTests: XCTestCase {

    func testATapPressedALittleLongKeepsRecording() {
        XCTAssertFalse(ShortcutManager.releaseEndsTake(heldFor: 0.45, holdOnly: false))
        XCTAssertFalse(ShortcutManager.releaseEndsTake(heldFor: 0.95, holdOnly: false))
    }

    func testAHoldLongEnoughForAClipEndsTheTake() {
        XCTAssertTrue(ShortcutManager.releaseEndsTake(heldFor: AudioRecorder.minimumUsableDuration, holdOnly: false))
        XCTAssertTrue(ShortcutManager.releaseEndsTake(heldFor: 4.2, holdOnly: false))
    }

    /// A hold-only trigger records while the key is down, however briefly.
    func testAHoldOnlyTriggerAlwaysEndsOnRelease() {
        XCTAssertTrue(ShortcutManager.releaseEndsTake(heldFor: 0.4, holdOnly: true))
    }
}
