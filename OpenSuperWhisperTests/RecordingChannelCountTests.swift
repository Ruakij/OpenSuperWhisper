import XCTest
@testable import OpenSuperWhisper

/// How many channels a take is recorded with. The built-in mic array reports three, and recording
/// all three bypassed the processed mono macOS gives for one, leaving speech 25-30 dB too quiet.
/// A multi-input interface keeps every channel, since its speech can sit on any one of them.
final class RecordingChannelCountTests: XCTestCase {

    func testBuiltInMicArrayIsRecordedOnOneChannel() {
        XCTAssertEqual(AudioRecorder.recordingChannelCount(isBuiltIn: true, reportedChannels: 3), 1)
    }

    func testExternalInterfaceKeepsEveryChannel() {
        XCTAssertEqual(AudioRecorder.recordingChannelCount(isBuiltIn: false, reportedChannels: 4), 4)
    }

    func testMonoExternalMicStaysMono() {
        XCTAssertEqual(AudioRecorder.recordingChannelCount(isBuiltIn: false, reportedChannels: 1), 1)
    }

    /// A device whose stream configuration could not be read still records something.
    func testUnreadableChannelCountFallsBackToOne() {
        XCTAssertEqual(AudioRecorder.recordingChannelCount(isBuiltIn: false, reportedChannels: 0), 1)
    }

    func testAChosenDeviceKeepsItsChannels() {
        let device = InputDeviceChoice.device(uid: "evo4", id: 42)
        XCTAssertEqual(AudioRecorder.recordingChannelCount(for: device, isBuiltIn: false, reportedChannels: 4), 4)
        XCTAssertEqual(AudioRecorder.recordingChannelCount(for: device, isBuiltIn: true, reportedChannels: 3), 1)
    }

    /// The queue reads the default input, not the 4-channel interface that is gone or not chosen.
    func testAFallbackToTheSystemDefaultRecordsOneChannel() {
        XCTAssertEqual(AudioRecorder.recordingChannelCount(
            for: .unavailable(uid: "evo4"), isBuiltIn: false, reportedChannels: 4), 1)
        XCTAssertEqual(AudioRecorder.recordingChannelCount(
            for: .systemDefault, isBuiltIn: false, reportedChannels: 4), 1)
    }
}
