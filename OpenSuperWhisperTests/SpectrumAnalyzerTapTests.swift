import AVFoundation
import CoreAudio
import XCTest

@testable import OpenSuperWhisper

/// When the visualiser should listen to the take at all.
///
/// The visualiser reads the recorder's samples rather than a microphone tap of its own: a second
/// tap opened right after the recorder takes the device can be refused for a format mismatch,
/// after which CoreAudio fails to start the input at all (#114). With no visualiser on the bubble
/// nothing subscribes and nothing transforms.
final class SpectrumAnalyzerTapTests: XCTestCase {

    private func layout(_ shown: [IndicatorElement]) -> IndicatorLayout {
        IndicatorLayout(order: IndicatorElement.allCases,
                        hidden: Set(IndicatorElement.allCases).subtracting(shown),
                        waveformHeight: IndicatorLayout.defaultWaveformHeight)
    }

    func testTheVisualiserRunsWhenTheWaveformIsShown() {
        XCTAssertTrue(SpectrumAnalyzer.shouldRun(layout: layout([.waveform])))
        XCTAssertTrue(SpectrumAnalyzer.shouldRun(layout: layout([.waveform, .label, .stopButton])))
    }

    /// The whole point: no visualiser, no subscription to the take.
    func testTheVisualiserDoesNotRunWithoutTheWaveform() {
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: layout([.dot, .label])))
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: layout([])))
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: layout([.stopButton, .cancelButton])))
    }

    /// The transcribing row borrows the meter to carry a spinner when the layout has neither
    /// meter nor label. That spinner draws nothing from the microphone, so it must not be read as
    /// a reason to listen to the take.
    func testTheBorrowedSpinnerIsNotAReasonToListen() {
        let dotOnly = layout([.dot])

        XCTAssertTrue(dotOnly.decodingLeading.contains(.waveform),
                      "this layout is the one that borrows the meter")
        XCTAssertFalse(SpectrumAnalyzer.shouldRun(layout: dotOnly))
    }

    /// The default layout does show the meter, so nobody loses the visualiser to this.
    func testTheDefaultLayoutStillGetsItsMeter() {
        XCTAssertTrue(SpectrumAnalyzer.shouldRun(layout: .default))
    }
}
