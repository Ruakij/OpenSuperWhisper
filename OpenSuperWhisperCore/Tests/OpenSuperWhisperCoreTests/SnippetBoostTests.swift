import XCTest
@testable import OpenSuperWhisperCore

/// Snippet triggers join the words recognition is biased toward, so a trigger is heard word for
/// word in the first place (#167), and snippets persist in a format that survives change.
final class SnippetBoostTests: CoreTestCase {

    private let email = Snippet(trigger: "my email", expansion: "max@example.com")
    private let calendly = Snippet(trigger: "my calendly", expansion: "https://calendly.com/max")

    // MARK: - Boost terms

    func testTheTriggersAreTheBoostTerms() {
        XCTAssertEqual(SnippetExpander.boostTerms([email, calendly]), ["my email", "my calendly"])
    }

    func testUnfinishedSnippetsAreNotBoosted() {
        let noText = Snippet(trigger: "sign off", expansion: " ")
        XCTAssertEqual(SnippetExpander.boostTerms([noText, email]), ["my email"])
    }

    func testBoostTermsAreTrimmedAndDeduplicatedIgnoringCase() {
        let shouted = Snippet(trigger: "  MY EMAIL! ", expansion: "other@example.com")
        XCTAssertEqual(SnippetExpander.boostTerms([email, shouted]), ["my email"])
        XCTAssertEqual(SnippetExpander.boostTerms([shouted, email]), ["MY EMAIL"])
    }

    func testATriggerWithNoLetterIsNotBoosted() {
        let arrow = Snippet(trigger: "->", expansion: "→")
        XCTAssertEqual(SnippetExpander.boostTerms([arrow]), [])
    }

    func testDictionaryTermsComeFirstAndAreNotRepeated() {
        XCTAssertEqual(RecognitionBoost.terms(dictionary: ["GitHub", "Calendly"],
                                              snippets: ["calendly", "my email"]),
                       ["GitHub", "Calendly", "my email"])
    }

    // MARK: - One clip's settings

    private func settings(dictionaryBoost: Bool, snippetTriggers: [String]) -> TranscriptionSettings {
        TranscriptionSettings(
            selectedLanguage: "en", translateToEnglish: false, suppressBlankAudio: true,
            showTimestamps: false, temperature: 0, noSpeechThreshold: 0.6, initialPrompt: "",
            useBeamSearch: false, beamSize: 5, useAsianAutocorrect: false,
            customDictionaryEnabled: true, customDictionaryBoostEnabled: dictionaryBoost,
            customDictionaryEntries: [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")],
            useSurroundingTextAsContext: false, snippetTriggers: snippetTriggers)
    }

    func testTheClipBoostsSnippetTriggersEvenWithTheDictionaryBoostOff() {
        XCTAssertEqual(settings(dictionaryBoost: false, snippetTriggers: ["my email"]).recognitionBoostTerms,
                       ["my email"])
    }

    func testTheClipBoostsBothWhenBothAreOn() {
        XCTAssertEqual(settings(dictionaryBoost: true, snippetTriggers: ["my email"]).recognitionBoostTerms,
                       ["GitHub", "my email"])
    }

    func testAClipWithoutSnippetTriggersBoostsWhatItDidBefore() {
        XCTAssertEqual(settings(dictionaryBoost: true, snippetTriggers: []).recognitionBoostTerms, ["GitHub"])
        XCTAssertEqual(settings(dictionaryBoost: false, snippetTriggers: []).recognitionBoostTerms, [])
    }

    // MARK: - Preferences

    func testPreferencesBoostTriggersOnlyWithBothSwitchesOn() {
        let prefs = CoreTestEnvironment.preferences
        prefs.snippets = [email]

        prefs.snippetsEnabled = true
        prefs.snippetsBoostEnabled = false
        XCTAssertEqual(prefs.recognitionBoostTerms, [], "the boost is opt-in")

        prefs.snippetsBoostEnabled = true
        XCTAssertEqual(prefs.recognitionBoostTerms, ["my email"])

        prefs.snippetsEnabled = false
        XCTAssertEqual(prefs.recognitionBoostTerms, [], "snippets off boost nothing")
    }

    func testPreferencesCombineTheDictionaryAndTheSnippets() {
        let prefs = CoreTestEnvironment.preferences
        prefs.customDictionaryEnabled = true
        prefs.customDictionaryBoostEnabled = true
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
        prefs.snippetsBoostEnabled = true
        prefs.snippets = [email]
        XCTAssertEqual(prefs.recognitionBoostTerms, ["GitHub", "my email"])
    }

    // MARK: - Stored format

    func testASnippetRoundTrips() throws {
        let data = try JSONEncoder().encode([email])
        XCTAssertEqual(try JSONDecoder().decode([Snippet].self, from: data), [email])
    }

    /// One snippet missing a field must not cost the user every other one: the array is decoded
    /// as a whole.
    func testAMissingFieldLoadsAsBlank() throws {
        let json = #"[{"id":"5B1D7C0E-6A2B-4F3C-9D8E-1A2B3C4D5E6F","trigger":"my email"},{"trigger":"sign off","expansion":"Max"}]"#
        let snippets = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))
        XCTAssertEqual(snippets.map(\.trigger), ["my email", "sign off"])
        XCTAssertEqual(snippets.map(\.expansion), ["", "Max"])
        XCTAssertEqual(snippets[0].id.uuidString, "5B1D7C0E-6A2B-4F3C-9D8E-1A2B3C4D5E6F")
    }

    /// A later version may add fields; this one reads what it knows.
    func testUnknownFieldsAreIgnored() throws {
        let json = #"[{"id":"5B1D7C0E-6A2B-4F3C-9D8E-1A2B3C4D5E6F","trigger":"t","expansion":"e","richText":true}]"#
        let snippets = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))
        XCTAssertEqual(snippets.map(\.expansion), ["e"])
    }
}
