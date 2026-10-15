import XCTest
@testable import OpenSuperWhisperCore

/// The dictionary's terms in the cleanup prompt (#169), so the model keeps "Rsets" rather than
/// "fixing" it back into "resets".
final class CleanupVocabularyTests: CoreTestCase {

    private let slack = AppContextProfile(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack",
                                          instructions: "SLACK-RULES")

    func testNoTermsSendsThePromptUnchanged() {
        let without = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPEN", profile: slack, closingPrompt: "CLOSE")
        let empty = LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPEN", profile: slack, closingPrompt: "CLOSE", vocabulary: [])
        XCTAssertEqual(without, empty)
        XCTAssertNil(LLMPostProcessor.vocabularySection([]))
    }

    func testTermsSitAfterTheOpeningAndBeforeTheAppRulesAndClosing() throws {
        let system = try XCTUnwrap(LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "OPEN", profile: slack, closingPrompt: "CLOSE",
            translating: true, translationPrompt: "TRANSLATED", vocabulary: ["Rsets", "OpenSuperWhisper"]))
        XCTAssertEqual(system, """
            OPEN

            TRANSLATED

            Keep these words spelled exactly as written here: Rsets, OpenSuperWhisper.

            App-specific formatting rules:
            SLACK-RULES

            CLOSE
            """)
    }

    func testTermsAloneDoNotStartAPass() {
        XCTAssertNil(LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: false, generalPrompt: "OPEN", profile: nil, vocabulary: ["Rsets"]))
    }

    func testOnlyTheTermsInTheTextAreSent() {
        let terms = ["Rsets", "OpenSuperWhisper", "camille@example.com", "Ångström"]
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(terms, in: "we tried rsets and angstrom units"),
                       ["Rsets", "Ångström"])
        XCTAssertEqual(LLMPostProcessor.cleanupVocabulary(terms, in: "nothing of the kind"), [])
    }

    func testTheListIsCut() throws {
        let terms = (1...60).map { "Term\($0)" }
        let section = try XCTUnwrap(LLMPostProcessor.vocabularySection(terms))
        XCTAssertTrue(section.contains("Term40."))
        XCTAssertFalse(section.contains("Term41"))
    }

    func testTheSectionIsPartOfWhatTheEchoGuardKnows() {
        let shipped = LLMPostProcessor.shippedInstructions(
            generalCleanup: true, generalPrompt: "custom", profile: nil, closingPrompt: "custom",
            translating: false, translationPrompt: "", vocabulary: ["Rsets"])
        XCTAssertEqual(shipped, "Keep these words spelled exactly as written here: Rsets.")
    }

    /// The section is built from the dictionary only while it is on, through `process`'s use of
    /// `boostTerms`: punctuation rules and regex templates never reach the model as words.
    func testOnlyRealTermsReachThePrompt() {
        let terms = CustomDictionary.boostTerms(entries: [
            CustomDictionaryEntry(original: "rsets", replacement: "Rsets"),
            CustomDictionaryEntry(original: "open quote", replacement: "“", spacing: .attachesRight),
            CustomDictionaryEntry(original: "(\\w+) said", replacement: "$1 said", isRegex: true),
        ])
        XCTAssertEqual(LLMPostProcessor.vocabularySection(terms),
                       "Keep these words spelled exactly as written here: Rsets.")
    }
}
