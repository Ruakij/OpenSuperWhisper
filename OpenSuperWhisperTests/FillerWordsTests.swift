import XCTest

@testable import OpenSuperWhisper

/// The shipped filler pattern strips German fillers, but not the German words that sound like
/// them: "er" (he) and "um" (at, as in "um drei").
final class FillerWordsTests: XCTestCase {

    private var scratch: ScratchPreferences!

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
        AppPreferences.shared.removeFillerWords = true
    }

    override func tearDown() {
        scratch.restore()
        scratch = nil
        super.tearDown()
    }

    func testGermanFillersAreRemoved() {
        XCTAssertEqual(AppPreferences.shared.cleanTranscription("Ähm, das ist äh gut"), "das ist gut")
    }

    func testTheGermanPronounErIsKept() {
        XCTAssertEqual(AppPreferences.shared.cleanTranscription("Er sagt, er kommt"), "Er sagt, er kommt")
    }

    func testUmIsRemovedOnlyBeforeAComma() {
        XCTAssertEqual(AppPreferences.shared.cleanTranscription("Um drei kommt er, um, ich weiß nicht"),
                       "Um drei kommt er, ich weiß nicht")
    }
}
