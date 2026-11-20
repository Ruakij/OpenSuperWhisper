import XCTest

@testable import OpenSuperWhisper

/// Who hears the recorder's samples: every subscriber, only while subscribed, and the visualiser
/// only for a take that records.
final class SampleTapTests: XCTestCase {

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [[Float]] = []
        func add(_ samples: [Float]) { lock.lock(); buffers.append(samples); lock.unlock() }
        var all: [[Float]] { lock.lock(); defer { lock.unlock() }; return buffers }
    }

    func testOnlySubscribedTapsHearTheSamples() {
        let recorder = AudioRecorder.shared
        let before = recorder.sampleTapCount
        let first = Heard(), second = Heard()
        let removeFirst = recorder.addSampleTap { first.add($0) }
        let removeSecond = recorder.addSampleTap { second.add($0) }
        defer { removeFirst(); removeSecond() }
        XCTAssertEqual(recorder.sampleTapCount, before + 2)

        removeFirst()
        recorder.deliverSamples([0.1, 0.2])

        XCTAssertEqual(recorder.sampleTapCount, before + 1)
        XCTAssertTrue(first.all.isEmpty)
        XCTAssertEqual(second.all, [[0.1, 0.2]])
    }

    /// The stored layout shows the meter, so the only reason left for `start()` to stay
    /// unsubscribed is that no take records. A recording take needs a microphone, so the
    /// subscribing half is not covered here.
    @MainActor
    func testTheVisualiserDoesNotSubscribeWithoutATake() {
        let saved = AppPreferences.shared.indicatorLayout
        defer { AppPreferences.shared.indicatorLayout = saved }
        AppPreferences.shared.indicatorLayout = IndicatorLayout.default.json
        XCTAssertTrue(SpectrumAnalyzer.shouldRun(
            layout: IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout)),
                      "the layout would let the visualiser run")
        XCTAssertFalse(AudioRecorder.shared.isTakeRecording)
        let before = AudioRecorder.shared.sampleTapCount

        SpectrumAnalyzer.shared.start()
        defer { SpectrumAnalyzer.shared.stop() }

        XCTAssertEqual(AudioRecorder.shared.sampleTapCount, before)
    }
}
