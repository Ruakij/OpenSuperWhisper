import XCTest
@testable import OpenSuperWhisperCore

/// Finding a dictation in its field again after the user edited it, and lining the two up word
/// by word (#169). Pure: no field is read.
final class CorrectionDiffTests: CoreTestCase {

    private typealias Word = CorrectionDiff.Word

    // MARK: - Locating the insertion

    func testFindsTheInsertionEndingAtTheCaret() throws {
        let field = "Notes: we should try rest sets today. More text"
        let caret = ("Notes: we should try rest sets today." as NSString).length
        let found = try XCTUnwrap(CorrectionDiff.locate("we should try rest sets today.", in: field, caret: caret))
        XCTAssertEqual((field as NSString).substring(with: found.range), "we should try rest sets today.")
        XCTAssertEqual(found.anchors.before, "Notes: ")
        XCTAssertEqual(found.anchors.after, " More text")
    }

    func testTheSameWordsEarlierInTheFieldAreAnOlderDictation() throws {
        let field = "Hello there. Hello there."
        let found = try XCTUnwrap(CorrectionDiff.locate("Hello there.", in: field, caret: (field as NSString).length))
        XCTAssertEqual(found.range.location, 13)
        XCTAssertEqual(found.anchors.before, "Hello there. ")
        XCTAssertEqual(found.anchors.after, "")
    }

    func testIgnoresTheSpacesTheFittingAdded() throws {
        let field = "Done and dusted "
        let found = try XCTUnwrap(CorrectionDiff.locate(" and dusted ", in: field, caret: 16))
        XCTAssertEqual(found.range, NSRange(location: 5, length: 10))
        XCTAssertEqual(found.anchors.after, " ")
    }

    func testNothingWhenThePasteDidNotLand() {
        XCTAssertNil(CorrectionDiff.locate("rest sets", in: "Something else entirely", caret: 23))
    }

    func testNothingWhenTheTextIsFarFromTheCaret() {
        let field = "rest sets " + String(repeating: "x", count: 40)
        XCTAssertNil(CorrectionDiff.locate("rest sets", in: field, caret: (field as NSString).length))
    }

    func testNothingForAnEmptyDictationOrABadCaret() {
        XCTAssertNil(CorrectionDiff.locate("  ", in: "abc", caret: 3))
        XCTAssertNil(CorrectionDiff.locate("abc", in: "abc", caret: 9))
    }

    func testAnchorsAreCutToTheirLength() throws {
        let before = String(repeating: "a", count: 50) + " "
        let field = before + "word" + " " + String(repeating: "b", count: 50)
        let found = try XCTUnwrap(CorrectionDiff.locate("word", in: field, caret: (before as NSString).length + 4))
        XCTAssertEqual((found.anchors.before as NSString).length, CorrectionDiff.anchorLength)
        XCTAssertEqual((found.anchors.after as NSString).length, CorrectionDiff.anchorLength)
    }

    func testAnAnchorNeverSplitsAnEmoji() throws {
        // 31 units of text, then an emoji straddling the 32-unit cut.
        let before = "👍" + String(repeating: "a", count: 31)
        let found = try XCTUnwrap(CorrectionDiff.locate("word", in: before + "word",
                                                        caret: (before as NSString).length + 4))
        XCTAssertEqual(found.anchors.before, String(repeating: "a", count: 31))
    }

    // MARK: - Finding it again

    func testRegionBetweenTheAnchorsAfterAnEdit() {
        let anchors = CorrectionDiff.Anchors(before: "Notes: ", after: " More text")
        XCTAssertEqual(CorrectionDiff.region(in: "Notes: we should try Rsets today. More text",
                                             anchors: anchors, expectedStart: 7, maxLength: 200),
                       "we should try Rsets today.")
    }

    func testRegionSurvivesTextTypedBeforeIt() {
        let anchors = CorrectionDiff.Anchors(before: "Notes: ", after: "")
        XCTAssertEqual(CorrectionDiff.region(in: "Added a line.\nNotes: try Rsets",
                                             anchors: anchors, expectedStart: 7, maxLength: 200),
                       "try Rsets")
    }

    func testEmptyAnchorsTakeTheWholeField() {
        let anchors = CorrectionDiff.Anchors(before: "", after: "")
        XCTAssertEqual(CorrectionDiff.region(in: "try Rsets", anchors: anchors, expectedStart: 0, maxLength: 200),
                       "try Rsets")
    }

    func testTheAnchorClosestToWhereItWasWins() {
        let anchors = CorrectionDiff.Anchors(before: "- ", after: "")
        let field = "- one\n- two\n- Rsets"
        XCTAssertEqual(CorrectionDiff.region(in: field, anchors: anchors, expectedStart: 14, maxLength: 200),
                       "Rsets")
    }

    /// A dictation at the end of a note leaves a lone space as the anchor after it. The first
    /// space inside the dictation matched it, and the watch saw "On" instead of the sentence.
    func testALoneSpaceAfterTheDictationIsFoundWhereTheDictationEnds() throws {
        let pasted = "On se retrouve demain avec un rest set pour le point. "
        let found = try XCTUnwrap(CorrectionDiff.locate(pasted, in: pasted, caret: (pasted as NSString).length))
        XCTAssertEqual(found.anchors.after, " ")
        let edited = "On se retrouve demain avec un Rsets pour le point. "
        XCTAssertEqual(CorrectionDiff.region(in: edited, anchors: found.anchors, expectedStart: 0,
                                             expectedLength: found.range.length, maxLength: 500),
                       "On se retrouve demain avec un Rsets pour le point. ")
    }

    func testAShortAnchorAfterIsFoundNearTheEndNotInsideTheDictation() {
        let anchors = CorrectionDiff.Anchors(before: "", after: ".")
        let field = "Try Rsets. Then ship it."
        XCTAssertEqual(CorrectionDiff.region(in: field, anchors: anchors, expectedStart: 0,
                                             expectedLength: 22, maxLength: 200),
                       "Try Rsets. Then ship it")
    }

    func testNoRegionOnceTheFieldWasSent() {
        let anchors = CorrectionDiff.Anchors(before: "", after: "")
        XCTAssertEqual(CorrectionDiff.region(in: "", anchors: anchors, expectedStart: 0, maxLength: 200), "")
        let sent = CorrectionDiff.Anchors(before: "Notes: ", after: "")
        XCTAssertNil(CorrectionDiff.region(in: "", anchors: sent, expectedStart: 7, maxLength: 200))
    }

    func testNoRegionWhenTheAfterAnchorIsGone() {
        let anchors = CorrectionDiff.Anchors(before: "", after: " More text")
        XCTAssertNil(CorrectionDiff.region(in: "Rsets", anchors: anchors, expectedStart: 0, maxLength: 200))
    }

    func testNoRegionWhenItGrewPastTheLimit() {
        let anchors = CorrectionDiff.Anchors(before: "", after: "")
        XCTAssertNil(CorrectionDiff.region(in: String(repeating: "x", count: 300), anchors: anchors,
                                           expectedStart: 0, maxLength: 200))
    }

    func testRegionRangeSaysWhereItIs() {
        let anchors = CorrectionDiff.Anchors(before: "Notes: ", after: " More")
        XCTAssertEqual(CorrectionDiff.regionRange(in: "x\nNotes: try Rsets More", anchors: anchors,
                                                  expectedStart: 7, maxLength: 200),
                       NSRange(location: 9, length: 9))
    }

    // MARK: - Return

    func testCutAtTheFirstLineBreakTheDictationDidNotHave() {
        XCTAssertEqual(CorrectionDiff.cutAtAddedLineBreak("try Rsets\nnext paragraph", dictated: "try rest sets"),
                       "try Rsets")
        XCTAssertEqual(CorrectionDiff.cutAtAddedLineBreak("one\ntwo Rsets\nthree", dictated: "one\ntwo rest sets"),
                       "one\ntwo Rsets")
    }

    func testNoCutWithoutAnAddedLineBreak() {
        XCTAssertNil(CorrectionDiff.cutAtAddedLineBreak("try Rsets", dictated: "try rest sets"))
        XCTAssertNil(CorrectionDiff.cutAtAddedLineBreak("one\ntwo Rsets", dictated: "one\ntwo rest sets"))
    }

    // MARK: - Word by word

    func testTwoHeardWordsReplacedByOne() {
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "We should try rest sets today.",
                                                   edited: "We should try Rsets today.", startsSentence: true),
                       [.init(heard: ["rest", "sets"], written: [Word("Rsets", startsSentence: false)])])
    }

    func testACaseOnlyFixIsAReplacement() {
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "I use parakeet daily",
                                                   edited: "I use Parakeet daily", startsSentence: true),
                       [.init(heard: ["parakeet"], written: [Word("Parakeet", startsSentence: false)])])
    }

    func testPunctuationAloneIsNoChange() {
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "Hello there, friend.",
                                                   edited: "Hello there friend!", startsSentence: true), [])
    }

    func testAddedAndDeletedWordsAreNotCorrections() {
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "send it now", edited: "please send it right now",
                                                   startsSentence: true), [])
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "send it right now please", edited: "send it now",
                                                   startsSentence: true), [])
    }

    func testARewrittenSentenceIsNotACorrection() {
        XCTAssertEqual(CorrectionDiff.replacements(
            inserted: "ok so the meeting is moved to the afternoon then",
            edited: "ok Our Weekly Sync Gets Postponed Until Later then", startsSentence: true), [])
    }

    func testSentenceStartsAreTracked() {
        let result = CorrectionDiff.replacements(inserted: "Done. rest sets work. Then go",
                                                 edited: "Done. Rsets work. Then go", startsSentence: true)
        XCTAssertEqual(result, [.init(heard: ["rest", "sets"], written: [Word("Rsets", startsSentence: true)])])
    }

    func testTheFirstWordTakesTheFieldsSentence() {
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "rest sets", edited: "Rsets", startsSentence: false),
                       [.init(heard: ["rest", "sets"], written: [Word("Rsets", startsSentence: false)])])
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "rest sets", edited: "Rsets", startsSentence: true),
                       [.init(heard: ["rest", "sets"], written: [Word("Rsets", startsSentence: true)])])
    }

    func testSeveralSeparateFixes() {
        let result = CorrectionDiff.replacements(inserted: "ask claude about rest sets please",
                                                 edited: "ask Claude about Rsets please", startsSentence: true)
        XCTAssertEqual(result.map(\.written), [[Word("Claude", startsSentence: false)],
                                               [Word("Rsets", startsSentence: false)]])
    }

    func testAMultiWordName() {
        XCTAssertEqual(CorrectionDiff.replacements(inserted: "thanks to my monkey team",
                                                   edited: "thanks to My Monkey team", startsSentence: true),
                       [.init(heard: ["my", "monkey"], written: [Word("My", startsSentence: false),
                                                                 Word("Monkey", startsSentence: false)])])
    }

    func testAColonCountsAsASentenceEnd() {
        XCTAssertTrue(CorrectionDiff.endsSentence("Note: "))
        XCTAssertTrue(CorrectionDiff.endsSentence(""))
        XCTAssertTrue(CorrectionDiff.endsSentence("He left.\" "))
        XCTAssertTrue(CorrectionDiff.endsSentence("Tu viens\u{202F}? "))
        XCTAssertTrue(CorrectionDiff.endsSentence("line\n"))
        XCTAssertFalse(CorrectionDiff.endsSentence("we should, "))
        XCTAssertFalse(CorrectionDiff.endsSentence("the "))
    }

    func testAVeryLongDictationIsLeftAlone() {
        let long = Array(repeating: "word", count: CorrectionDiff.maxWords + 1).joined(separator: " ")
        XCTAssertEqual(CorrectionDiff.replacements(inserted: long, edited: long + " Rsets", startsSentence: true), [])
    }

    func testFrenchCorrection() {
        let result = CorrectionDiff.replacements(inserted: "on teste rest sets demain, d'accord ?",
                                                 edited: "on teste Rsets demain, d'accord ?", startsSentence: true)
        XCTAssertEqual(result, [.init(heard: ["rest", "sets"], written: [Word("Rsets", startsSentence: false)])])
    }
}
