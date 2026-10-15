import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The switches around snippets (#167): what the dictation pipeline expands, and what a clip
/// boosts. The matching itself is covered in the core's `SnippetExpanderTests`.
final class SnippetPreferencesTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private let email = Snippet(trigger: "my email", expansion: "max@example.com")

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        scratch.restore()
        super.tearDown()
    }

    func testSnippetsExpandOnAFreshInstall() {
        prefs.snippets = [email]
        XCTAssertEqual(prefs.expandSnippets("My email."), "max@example.com")
    }

    func testSnippetsOffLeaveTheTextAlone() {
        prefs.snippets = [email]
        prefs.snippetsEnabled = false
        XCTAssertEqual(prefs.expandSnippets("My email."), "My email.")
    }

    /// The dictionary ran before the cleanup; a trigger it rewrote is only recognised while it
    /// is on, since only then was the text rewritten.
    func testTheDictionaryFormOfATriggerFollowsTheDictionarySwitch() {
        prefs.snippets = [Snippet(trigger: "my monkey site", expansion: "https://my-monkey.fr")]
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "my monkey", replacement: "My-Monkey")]

        prefs.customDictionaryEnabled = true
        XCTAssertEqual(prefs.expandSnippets("Open My-Monkey site now"), "Open https://my-monkey.fr now")

        prefs.customDictionaryEnabled = false
        XCTAssertEqual(prefs.expandSnippets("Open My-Monkey site now"), "Open My-Monkey site now")
    }

    func testAClipBoostsTriggersOnlyWithBothSwitchesOn() {
        prefs.snippets = [email]
        XCTAssertEqual(Settings().snippetTriggers, [], "the boost is opt-in")

        prefs.snippetsBoostEnabled = true
        XCTAssertEqual(Settings().snippetTriggers, ["my email"])
        XCTAssertEqual(Settings().recognitionBoostTerms, ["my email"])

        prefs.snippetsEnabled = false
        XCTAssertEqual(Settings().snippetTriggers, [])
    }

    /// The live preview and Parakeet's file pass read the same list from the preferences.
    func testThePreferencesBoostTheSameTermsAsAClip() {
        prefs.snippets = [email]
        prefs.snippetsBoostEnabled = true
        prefs.customDictionaryEnabled = true
        prefs.customDictionaryBoostEnabled = true
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
        XCTAssertEqual(prefs.recognitionBoostTerms, ["GitHub", "my email"])
        XCTAssertEqual(Settings().recognitionBoostTerms, prefs.recognitionBoostTerms)
    }
}
