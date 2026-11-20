import AudioToolbox
import CoreAudio
import XCTest

@testable import OpenSuperWhisper

/// The parts of the input queue recorder that need no microphone: the file format, which device a
/// take binds to, the meter arithmetic, and that what it writes is a file the repair code reads.
final class InputQueueRecorderTests: XCTestCase {

    // MARK: Format

    func testTheFormatIsSixteenKilohertzInterleavedFloat32() {
        let format = InputQueueRecorder.format(channelCount: 2)
        XCTAssertEqual(format.mSampleRate, 16_000)
        XCTAssertEqual(format.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(format.mFormatFlags, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        XCTAssertEqual(format.mBitsPerChannel, 32)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
        XCTAssertEqual(format.mBytesPerFrame, 8)
        XCTAssertEqual(format.mBytesPerPacket, 8)
        XCTAssertEqual(format.mFramesPerPacket, 1)
    }

    /// The channel count comes from `AudioRecorder.recordingChannelCount`, which never returns
    /// less than one, but the format does not trust that.
    func testTheFormatHasAtLeastOneChannel() {
        XCTAssertEqual(InputQueueRecorder.format(channelCount: 0).mChannelsPerFrame, 1)
        XCTAssertEqual(InputQueueRecorder.format(channelCount: -3).mChannelsPerFrame, 1)
    }

    func testABufferHoldsFiftyMillisecondsOfEveryChannel() {
        XCTAssertEqual(InputQueueRecorder.bufferBytes(channelCount: 1), 800 * 4)
        XCTAssertEqual(InputQueueRecorder.bufferBytes(channelCount: 4), 800 * 16)
    }

    /// The file grows at least every 100 ms, which is what the connection wait watches.
    func testBuffersAreShortEnoughForTheConnectionWait() {
        XCTAssertLessThanOrEqual(InputQueueRecorder.bufferDuration, 0.1)
    }

    // MARK: Device choice

    func testNoMicrophoneChosenUsesTheSystemDefault() {
        let choice = InputDeviceChoice.resolve(uid: nil) { _ in XCTFail("nothing to look up"); return nil }
        XCTAssertEqual(choice, .systemDefault)
        XCTAssertNil(choice.queueUID)
    }

    func testAnEmptyUIDIsNoChoice() {
        XCTAssertEqual(InputDeviceChoice.resolve(uid: "") { _ in 7 }, .systemDefault)
    }

    func testAKnownDeviceIsBoundByUID() {
        let choice = InputDeviceChoice.resolve(uid: "BuiltInMicrophoneDevice") { uid in
            uid == "BuiltInMicrophoneDevice" ? 97 : nil
        }
        XCTAssertEqual(choice, .device(uid: "BuiltInMicrophoneDevice", id: 97))
        XCTAssertEqual(choice.queueUID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(choice.deviceID, 97)
    }

    /// A microphone that was unplugged after the last device refresh: the take records from the
    /// default input instead of failing, and says so in the log.
    func testAGoneDeviceFallsBackToTheSystemDefault() {
        let choice = InputDeviceChoice.resolve(uid: "gone") { _ in nil }
        XCTAssertEqual(choice, .unavailable(uid: "gone"))
        XCTAssertNil(choice.queueUID)
        XCTAssertNil(choice.deviceID)
        XCTAssertTrue(choice.description.contains("gone"))
    }

    func testTheUnknownDeviceIDCountsAsGone() {
        let choice = InputDeviceChoice.resolve(uid: "x") { _ in AudioDeviceID(kAudioObjectUnknown) }
        XCTAssertEqual(choice, .unavailable(uid: "x"))
    }

    // MARK: Monitor samples

    func testOneChannelPassesThroughUnchanged() {
        let samples: [Float] = [0.1, -0.2, 0.3]
        let mono = samples.withUnsafeBufferPointer { InputQueueRecorder.monitorSamples($0, channelCount: 1) }
        XCTAssertEqual(mono, samples)
    }

    /// Interleaved L R L R: the right channel is the louder one, so it is the one monitored.
    func testTheLoudestChannelIsMonitored() {
        let samples: [Float] = [0.01, 0.5, -0.02, -0.4, 0.0, 0.3]
        let mono = samples.withUnsafeBufferPointer { InputQueueRecorder.monitorSamples($0, channelCount: 2) }
        XCTAssertEqual(mono, [0.5, -0.4, 0.3])
    }

    func testATrailingPartialFrameIsDropped() {
        let samples: [Float] = [0.1, 0.9, 0.2, 0.8, 0.7]
        let mono = samples.withUnsafeBufferPointer { InputQueueRecorder.monitorSamples($0, channelCount: 2) }
        XCTAssertEqual(mono.count, 2)
    }

    func testSilenceMonitorsAsSilence() {
        let samples = [Float](repeating: 0, count: 8)
        let mono = samples.withUnsafeBufferPointer { InputQueueRecorder.monitorSamples($0, channelCount: 2) }
        XCTAssertEqual(mono, [0, 0, 0, 0])
    }

    // MARK: Meter

    func testThePeakIsTheLoudestSampleOfEitherSign() {
        let samples: [Float] = [0.1, -0.5, 0.25, 0]
        let peak = samples.withUnsafeBufferPointer { InputQueueRecorder.peak(of: $0) }
        XCTAssertEqual(peak, 0.5)
    }

    func testNoSamplesHaveNoPeak() {
        let peak = [Float]().withUnsafeBufferPointer { InputQueueRecorder.peak(of: $0) }
        XCTAssertEqual(peak, 0)
    }

    func testDecibelsAreRelativeToFullScale() {
        XCTAssertEqual(InputQueueRecorder.decibels(fromPeak: 1), 0, accuracy: 0.001)
        XCTAssertEqual(InputQueueRecorder.decibels(fromPeak: 0.5), -6.02, accuracy: 0.01)
        XCTAssertEqual(InputQueueRecorder.decibels(fromPeak: 0.1), -20, accuracy: 0.01)
    }

    /// Silence is -160, the floor the quiet-input watch expects.
    func testSilenceIsTheFloor() {
        XCTAssertEqual(InputQueueRecorder.decibels(fromPeak: 0), -160)
        XCTAssertEqual(InputQueueRecorder.decibels(fromPeak: 1e-12), -160)
    }

    // MARK: File

    private func scratchURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iqr-\(UUID().uuidString)-\(name).wav")
    }

    /// A take cut short while the file is still open: the header on disk already states the
    /// audio written, and the repair leaves it alone.
    func testAnOpenFileAlreadyStatesItsSizes() throws {
        let url = scratchURL("open")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try InputQueueRecorder.createFile(at: url, channelCount: 2)
        defer { AudioFileClose(file) }

        var samples = [Float](repeating: 0.25, count: 16_000 * 2)
        var packets: UInt32 = 16_000
        let status = AudioFileWritePackets(file, false, UInt32(samples.count * 4), nil, 0, &packets, &samples)
        XCTAssertEqual(status, noErr)

        let onDisk = try Data(contentsOf: url)
        let repaired = try XCTUnwrap(WAVHeaderRepair.repair(
            header: onDisk.prefix(WAVHeaderRepair.headerWindow), fileLength: UInt64(onDisk.count)))
        XCTAssertEqual(repaired.audioBytes, 16_000 * 8)
        XCTAssertEqual(repaired.duration, 1, accuracy: 0.001)
        XCTAssertEqual(repaired.header, Data(onDisk.prefix(WAVHeaderRepair.headerWindow)),
                       "sizes that are already right are not rewritten")
    }

    /// The write reaches the file at once, not when the file is closed: the connection wait
    /// sees data by watching the file's size.
    func testWritesReachTheFileWithoutAClose() throws {
        let url = scratchURL("grow")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try InputQueueRecorder.createFile(at: url, channelCount: 1)
        defer { AudioFileClose(file) }

        func size() -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        var samples = [Float](repeating: 0.1, count: 800)
        var packets: UInt32 = 800
        let before = size()
        XCTAssertEqual(AudioFileWritePackets(file, false, 3200, nil, 0, &packets, &samples), noErr)
        XCTAssertEqual(size() - before, 3200)
    }
}
