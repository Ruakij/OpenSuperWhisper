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

    func testABufferHoldsFiftyMillisecondsOfEveryChannel() {
        XCTAssertEqual(InputQueueRecorder.bufferBytes(channelCount: 1), 800 * 4)
        XCTAssertEqual(InputQueueRecorder.bufferBytes(channelCount: 4), 800 * 16)
    }

    /// The file grows at least every 100 ms, which is what the connection wait watches.
    func testBuffersAreShortEnoughForTheConnectionWait() {
        XCTAssertLessThanOrEqual(InputQueueRecorder.bufferDuration, 0.1)
    }

    // MARK: Device choice

    /// A microphone that was unplugged after the last device refresh falls back to the default
    /// input instead of failing the take, and says so in the log.
    func testADeviceChoiceResolvesFromTheUID() {
        var lookedUp: [String] = []
        let cases: [(uid: String?, choice: InputDeviceChoice, deviceID: AudioDeviceID?)] = [
            (nil, .systemDefault, nil),
            ("", .systemDefault, nil),
            ("BuiltInMicrophoneDevice", .device(uid: "BuiltInMicrophoneDevice", id: 97), 97),
            ("gone", .unavailable(uid: "gone"), nil),
        ]
        for (uid, expected, deviceID) in cases {
            let choice = InputDeviceChoice.resolve(uid: uid) { uid in
                lookedUp.append(uid)
                return uid == "BuiltInMicrophoneDevice" ? 97 : nil
            }
            XCTAssertEqual(choice, expected, "uid \(uid ?? "nil")")
            XCTAssertEqual(choice.deviceID, deviceID, "uid \(uid ?? "nil")")
        }
        XCTAssertEqual(lookedUp, ["BuiltInMicrophoneDevice", "gone"], "no UID, nothing to look up")
        XCTAssertTrue(InputDeviceChoice.unavailable(uid: "gone").description.contains("gone"))
        XCTAssertEqual(InputDeviceChoice.resolve(uid: "x") { _ in AudioDeviceID(kAudioObjectUnknown) },
                       .unavailable(uid: "x"), "the unknown device ID counts as gone")
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

    // MARK: Peak window

    private func window() -> PeakWindow { PeakWindow(bufferDuration: InputQueueRecorder.bufferDuration) }

    /// Several readers (the indicator, the sound check, the connection wait) ask in turn.
    func testReadingThePeakDoesNotTakeItAway() {
        var peaks = window()
        peaks.record(peak: 0.5, at: 10)
        let first = peaks.peakDBFS(at: 10.01)
        XCTAssertEqual(first, -6.02, accuracy: 0.01)
        XCTAssertEqual(peaks.peakDBFS(at: 10.01), first)
    }

    func testTheWindowIsSilentWhenNoBufferArrivesWithin250Milliseconds() {
        var peaks = window()
        XCTAssertEqual(peaks.peakDBFS(at: 10), -160, "nothing recorded yet")
        peaks.record(peak: 0.5, at: 10)
        XCTAssertGreaterThan(peaks.peakDBFS(at: 10.2), -160)
        XCTAssertEqual(peaks.peakDBFS(at: 10.25), -160)
    }

    func testALoudPeakDropsOutAfterFiveNewerBuffers() {
        var peaks = window()
        peaks.record(peak: 0.9, at: 10)
        for i in 1...4 { peaks.record(peak: 0.01, at: 10 + Double(i) * 0.05) }
        XCTAssertEqual(peaks.peakDBFS(at: 10.2), InputQueueRecorder.decibels(fromPeak: 0.9), accuracy: 0.001)
        peaks.record(peak: 0.01, at: 10.25)
        XCTAssertEqual(peaks.peakDBFS(at: 10.25), InputQueueRecorder.decibels(fromPeak: 0.01), accuracy: 0.001)
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
