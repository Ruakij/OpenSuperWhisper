import XCTest
@testable import OpenSuperWhisperCore

/// Saying a short phrase and getting a longer text (#167). The expansion runs on what the cleanup
/// model returned, so most cases here are written the way a model writes them back: a capital, a
/// period, a curly apostrophe, a French space before the exclamation mark.
final class SnippetExpanderTests: CoreTestCase {

    private let email = Snippet(trigger: "my email", expansion: "max@example.com")
    private let signature = Snippet(trigger: "sign off", expansion: "Best,\nMax Costa\nmy-monkey.fr")

    private func expand(_ text: String, _ snippets: [Snippet]? = nil,
                        dictionary: [CustomDictionaryEntry] = []) -> String {
        SnippetExpander.expand(text, snippets: snippets ?? [email, signature], dictionary: dictionary)
    }

    // MARK: - Where a trigger matches

    func testATriggerSaidAloneIsReplaced() {
        XCTAssertEqual(expand("my email"), "max@example.com")
    }

    func testATriggerInTheMiddleOfASentenceIsReplaced() {
        XCTAssertEqual(expand("Send the invoice to my email please"),
                       "Send the invoice to max@example.com please")
    }

    func testCaseDoesNotMatter() {
        XCTAssertEqual(expand("MY EMAIL"), "max@example.com")
        XCTAssertEqual(expand("Write to My Email today"), "Write to max@example.com today")
    }

    /// The model, or the engine, may leave two spaces or break the line between the words.
    func testAnySpacingBetweenWordsMatches() {
        XCTAssertEqual(expand("write to my  email now"), "write to max@example.com now")
        XCTAssertEqual(expand("write to my\temail now"), "write to max@example.com now")
    }

    func testOnlyWholeWordsMatch() {
        XCTAssertEqual(expand("all my emails are read"), "all my emails are read")
        XCTAssertEqual(expand("a dummy email address"), "a dummy email address")
        XCTAssertEqual(expand("my emailing list"), "my emailing list")
    }

    func testEveryOccurrenceIsReplaced() {
        XCTAssertEqual(expand("my email, I said my email"), "max@example.com, I said max@example.com")
    }

    func testSeveralSnippetsInOneDictation() {
        XCTAssertEqual(expand("Here is my email. Sign off."),
                       "Here is max@example.com. Best,\nMax Costa\nmy-monkey.fr")
    }

    /// A trigger holding characters that mean something in a regular expression is matched as
    /// the text it is.
    func testATriggerIsMatchedLiterallyNotAsAPattern() {
        let tip = Snippet(trigger: "c++ (tip)", expansion: "Prefer std::vector.")
        XCTAssertEqual(expand("here is a c++ (tip) for you", [tip]), "here is a Prefer std::vector. for you")
        XCTAssertEqual(expand("here is a c tip", [tip]), "here is a c tip")
    }

    /// The model writes "sign off" as "Sign-off" as readily as the other way round.
    func testSpacesAndHyphensBetweenWordsAreInterchangeable() {
        XCTAssertEqual(expand("Sign-off."), "Best,\nMax Costa\nmy-monkey.fr")
        XCTAssertEqual(expand("ok sign‑off"), "ok Best,\nMax Costa\nmy-monkey.fr")
        let hyphenated = Snippet(trigger: "follow-up note", expansion: "NOTE")
        XCTAssertEqual(expand("a follow up note", [hyphenated]), "a NOTE")
        XCTAssertEqual(expand("a follow-up note", [hyphenated]), "a NOTE")
    }

    /// A trigger made only of symbols would fire inside any word holding it.
    func testATriggerWithNoLetterOrDigitNeverFires() {
        let at = Snippet(trigger: "@", expansion: "at")
        XCTAssertEqual(expand("write to x@y.com", [at]), "write to x@y.com")
    }

    // MARK: - Longest trigger wins

    func testTheLongerOfTwoTriggersStartingTogetherWins() {
        let long = Snippet(trigger: "my email signature", expansion: "SIGNATURE")
        XCTAssertEqual(expand("Add my email signature.", [email, long]), "Add SIGNATURE.")
        XCTAssertEqual(expand("Add my email signature.", [long, email]), "Add SIGNATURE.")
    }

    /// Longest wins wherever the longer one starts, not only when both start at the same word.
    func testTheLongerOfTwoOverlappingTriggersWinsWhereverItStarts() {
        let tail = Snippet(trigger: "email signature", expansion: "SIGNATURE")
        XCTAssertEqual(expand("my email signature", [email, tail]), "my SIGNATURE")
    }

    func testTheShorterTriggerStillMatchesElsewhere() {
        let long = Snippet(trigger: "my email signature", expansion: "SIGNATURE")
        XCTAssertEqual(expand("my email signature and my email", [email, long]),
                       "SIGNATURE and max@example.com")
    }

    func testTwoSnippetsWithTheSameTriggerResolveToTheFirstListed() {
        let other = Snippet(trigger: "My Email", expansion: "other@example.com")
        XCTAssertEqual(expand("my email", [email, other]), "max@example.com")
        XCTAssertEqual(expand("my email", [other, email]), "other@example.com")
    }

    /// A snippet's text is never searched for triggers in turn, or two snippets naming each
    /// other would never finish.
    func testAnExpansionIsNotExpandedAgain() {
        let loop = Snippet(trigger: "contact", expansion: "my email")
        XCTAssertEqual(expand("contact", [loop, email]), "my email")
    }

    // MARK: - Punctuation the cleanup model adds

    func testThePeriodAddedToALoneTriggerIsDropped() {
        XCTAssertEqual(expand("My email."), "max@example.com")
        XCTAssertEqual(expand("My email!"), "max@example.com")
        XCTAssertEqual(expand("My email?"), "max@example.com")
        XCTAssertEqual(expand("My email..."), "max@example.com")
        XCTAssertEqual(expand("My email… "), "max@example.com ")
    }

    func testALoneTriggerAfterAnotherSentenceLosesItsPeriod() {
        XCTAssertEqual(expand("Thanks for the call. My email."), "Thanks for the call. max@example.com")
    }

    func testALoneTriggerOnItsOwnLineLosesItsPeriod() {
        XCTAssertEqual(expand("Thanks for the call.\nMy email.\nTalk soon."),
                       "Thanks for the call.\nmax@example.com\nTalk soon.")
    }

    func testOpeningQuotesDoNotHideTheStartOfASentence() {
        XCTAssertEqual(expand("“My email."), "“max@example.com")
    }

    /// A closing quote or bracket after the period does not make the trigger part of a longer
    /// line.
    func testALoneTriggerInQuotesLosesItsPeriod() {
        XCTAssertEqual(expand("“My email.”"), "“max@example.com”")
        XCTAssertEqual(expand("(My email.)"), "(max@example.com)")
    }

    /// An ellipsis trails off within a sentence rather than ending it.
    func testAfterAnEllipsisTheSentencesPeriodStays() {
        XCTAssertEqual(expand("Thanks… my email."), "Thanks… max@example.com.")
        XCTAssertEqual(expand("Thanks... my email."), "Thanks... max@example.com.")
    }

    /// The period ending a longer sentence is that sentence's, not the trigger's.
    func testTheSentencesOwnPeriodStays() {
        XCTAssertEqual(expand("You can write to my email."), "You can write to max@example.com.")
    }

    /// Followed by another sentence on the same line, the period is still needed between them.
    func testAPeriodBetweenTwoSentencesStays() {
        XCTAssertEqual(expand("My email. Talk soon."), "max@example.com. Talk soon.")
    }

    func testACommaInsideTheSentenceStays() {
        XCTAssertEqual(expand("My email, please."), "max@example.com, please.")
        XCTAssertEqual(expand("Use my email, not the old one."), "Use max@example.com, not the old one.")
    }

    /// A signature is a block of its own: a period after its last line would be stray.
    func testAMultiLineSnippetTakesThePeriodAfterIt() {
        XCTAssertEqual(expand("Thanks again for your help. Sign off."),
                       "Thanks again for your help. Best,\nMax Costa\nmy-monkey.fr")
        XCTAssertEqual(expand("thanks and sign off."), "thanks and Best,\nMax Costa\nmy-monkey.fr")
    }

    func testASnippetEndingWithAMarkTakesThePeriodAfterIt() {
        let bye = Snippet(trigger: "bye now", expansion: "See you soon!")
        XCTAssertEqual(expand("ok then bye now.", [bye]), "ok then See you soon!")
    }

    /// A comma joins what follows, so it stays even after a block.
    func testACommaAfterAMultiLineSnippetStays() {
        XCTAssertEqual(expand("sign off, and send it"), "Best,\nMax Costa\nmy-monkey.fr, and send it")
    }

    /// The trigger typed with its own punctuation still matches the bare phrase.
    func testPunctuationTypedInTheTriggerIsNotRequired() {
        let typed = Snippet(trigger: "Sign off!", expansion: "Best, Max")
        XCTAssertEqual(expand("ok sign off", [typed]), "ok Best, Max")
        XCTAssertEqual(expand("Sign off!", [typed]), "Best, Max")
    }

    // MARK: - French

    func testFrenchSpaceBeforeAMarkGoesWithIt() {
        let adresse = Snippet(trigger: "mon adresse", expansion: "12 rue de la Paix\n75002 Paris")
        XCTAssertEqual(expand("Mon adresse !", [adresse]), "12 rue de la Paix\n75002 Paris")
        XCTAssertEqual(expand("Mon adresse\u{202F}?", [adresse]), "12 rue de la Paix\n75002 Paris")
        XCTAssertEqual(expand("Mon adresse\u{00A0}!", [adresse]), "12 rue de la Paix\n75002 Paris")
    }

    func testFrenchColonInsideASentenceStays() {
        let mail = Snippet(trigger: "mon mail", expansion: "max@example.com")
        XCTAssertEqual(expand("Voici mon mail : écris-moi", [mail]), "Voici max@example.com : écris-moi")
    }

    func testAccentedTriggersIgnoreCase() {
        let signature = Snippet(trigger: "ma signature élégante", expansion: "Max")
        XCTAssertEqual(expand("Ajoute Ma Signature ÉLÉGANTE.", [signature]), "Ajoute Max.")
    }

    func testEitherApostropheMatches() {
        let office = Snippet(trigger: "l'adresse du bureau", expansion: "3 place du Marché")
        XCTAssertEqual(expand("L’adresse du bureau.", [office]), "3 place du Marché")
        XCTAssertEqual(expand("envoie l'adresse du bureau", [office]), "envoie 3 place du Marché")
    }

    /// "l'" belongs to the word after it: a trigger starting at that word must not fire and leave
    /// the article glued to the expansion.
    func testAFrenchElisionIsNotSplitFromItsWord() {
        let office = Snippet(trigger: "adresse du bureau", expansion: "12 rue de la Paix")
        XCTAssertEqual(expand("Envoie à l'adresse du bureau.", [office]), "Envoie à l'adresse du bureau.")
        XCTAssertEqual(expand("Envoie à l’adresse du bureau.", [office]), "Envoie à l’adresse du bureau.")
        XCTAssertEqual(expand("Envoie mon adresse du bureau.", [office]), "Envoie mon 12 rue de la Paix.")
    }

    func testATriggerWrittenWithItsArticleMatchesAfterAPreposition() {
        let office = Snippet(trigger: "l'adresse du bureau", expansion: "12 rue de la Paix")
        XCTAssertEqual(expand("Envoie à l’adresse du bureau.", [office]), "Envoie à 12 rue de la Paix.")
    }

    func testAnAccentedWordIsWholeToo() {
        let ete = Snippet(trigger: "été", expansion: "summer")
        XCTAssertEqual(expand("un étéphant", [ete]), "un étéphant")
        XCTAssertEqual(expand("cet été là", [ete]), "cet summer là")
    }

    // MARK: - The dictionary ran first

    func testATriggerTheDictionaryRewroteStillMatches() {
        let site = Snippet(trigger: "my monkey site", expansion: "https://my-monkey.fr")
        let rule = CustomDictionaryEntry(original: "my monkey", replacement: "MyMonkey")
        XCTAssertEqual(expand("Open MyMonkey site now", [site], dictionary: [rule]),
                       "Open https://my-monkey.fr now")
        XCTAssertEqual(expand("Open my monkey site now", [site], dictionary: [rule]),
                       "Open https://my-monkey.fr now")
    }

    func testWithoutTheDictionaryTheRewrittenFormDoesNotMatch() {
        let site = Snippet(trigger: "my monkey site", expansion: "https://my-monkey.fr")
        XCTAssertEqual(expand("Open MyMonkey site now", [site]), "Open MyMonkey site now")
    }

    // MARK: - Snippets that do nothing

    func testAnUnfinishedSnippetLeavesTheTextAlone() {
        let noText = Snippet(trigger: "my email", expansion: "  \n ")
        let noTrigger = Snippet(trigger: " ", expansion: "max@example.com")
        XCTAssertEqual(expand("my email", [noText, noTrigger]), "my email")
    }

    func testNothingToExpand() {
        XCTAssertEqual(expand(""), "")
        XCTAssertEqual(expand("my email", []), "my email")
        XCTAssertEqual(expand("nothing to see here"), "nothing to see here")
    }

    func testTheExpansionIsInsertedWithoutTheBlankLinesAroundIt() {
        let padded = Snippet(trigger: "sign off", expansion: "\n\nBest,\nMax\n  ")
        XCTAssertEqual(expand("ok sign off", [padded]), "ok Best,\nMax")
    }

    // MARK: - Ranges, for the test field

    func testTheRangeCoversTheTriggerAndThePunctuationDroppedWithIt() {
        let text = "Thanks. My email."
        let found = SnippetExpander.expansions(in: text, snippets: [email])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.map { String(text[$0.range]) }, "My email.")
        XCTAssertEqual(found.first?.snippet, email)
    }

    func testRangesComeInReadingOrder() {
        let text = "sign off and my email"
        let found = SnippetExpander.expansions(in: text, snippets: [email, signature])
        XCTAssertEqual(found.map { String(text[$0.range]) }, ["sign off", "my email"])
    }
}
