import XCTest
@testable import OpenSuperWhisperCore

/// Which corrected words are offered for the dictionary (#169). The spelling dictionary is a
/// small made-up one, so each rule is tested on its own and not on what macOS happens to know.
final class DictionaryCandidatesTests: CoreTestCase {

    private typealias Word = CorrectionDiff.Word

    /// English and French words as a spelling dictionary knows them: common words in lowercase,
    /// names only capitalised. A spelling dictionary accepts a lowercase word capitalised.
    private static let known: Set<String> = [
        "the", "there", "their", "great", "parakeet", "apple", "monkey", "my", "new", "book",
        "Monday", "Paris", "York", "OK", "iPhone", "ça", "demain", "rat", "maus",
    ]

    private static let typos: Set<String> = ["teh", "thier"]

    private let spelling = DictionaryCandidates.Spelling(
        knows: { word in
            known.contains(word) || known.contains(word.lowercased())
                && word == word.prefix(1).uppercased() + word.dropFirst()
        },
        correctsTypo: { typos.contains($0.lowercased()) })

    private func candidates(_ heard: String, _ written: String, startsSentence: Bool = false,
                            dictated: String? = nil, capitalMarksNames: Bool = true) -> [String] {
        let words = written.split(separator: " ").enumerated().map {
            Word(String($0.element), startsSentence: $0.offset == 0 && startsSentence)
        }
        let replacement = CorrectionDiff.Replacement(heard: heard.split(separator: " ").map(String.init),
                                                     written: words)
        return DictionaryCandidates.candidates(in: [replacement], dictated: dictated ?? heard,
                                               spelling: spelling, capitalMarksNames: capitalMarksNames)
            .map(\.term)
    }

    // MARK: - Offered

    func testAnUnknownCapitalisedWord() {
        XCTAssertEqual(candidates("rest sets", "Rsets"), ["Rsets"])
        XCTAssertEqual(candidates("rest sets", "Rsets", startsSentence: true), ["Rsets"])
    }

    func testACommonWordMadeANameMidSentence() {
        XCTAssertEqual(candidates("parakeet", "Parakeet"), ["Parakeet"])
    }

    func testAnUnknownLowercaseWord() {
        XCTAssertEqual(candidates("cube control", "kubectl"), ["kubectl"])
    }

    func testMixedCaseDigitsAndAcronyms() {
        XCTAssertEqual(candidates("get hub", "GitHub"), ["GitHub"])
        XCTAssertEqual(candidates("g p t four", "GPT4"), ["GPT4"])
        XCTAssertEqual(candidates("o s w", "OSW"), ["OSW"])
        XCTAssertEqual(candidates("mac os", "macOS"), ["macOS"])
        XCTAssertEqual(candidates("e bay", "eBay"), ["eBay"])
    }

    func testAnEmailAddress() {
        XCTAssertEqual(candidates("camille at example dot com", "camille@example.com"), ["camille@example.com"])
    }

    func testAMultiWordName() {
        XCTAssertEqual(candidates("my monkey", "My Monkey"), ["My Monkey"])
        XCTAssertEqual(candidates("cloud code", "Claude Code"), ["Claude Code"])
    }

    func testTheNoticeSaysWhatWasHeard() {
        let replacement = CorrectionDiff.Replacement(heard: ["rest", "sets"],
                                                     written: [Word("Rsets", startsSentence: false)])
        XCTAssertEqual(DictionaryCandidates.candidates(in: [replacement], dictated: "rest sets", spelling: spelling),
                       [.init(term: "Rsets", heard: "rest sets")])
    }

    func testGrammarAroundTheWordIsDropped() {
        XCTAssertEqual(candidates("la PI", "l’API"), ["API"])
        XCTAssertEqual(candidates("rest sets", "Rsets's"), ["Rsets"])
        XCTAssertEqual(candidates("rest sets", "d'Rsets"), ["Rsets"])
    }

    // MARK: - Left out

    func testCommonWords() {
        XCTAssertEqual(candidates("there", "their"), [])
        XCTAssertEqual(candidates("the", "teh"), [], "a typo of a known word")
        XCTAssertEqual(candidates("great", "Great", startsSentence: true), [])
        XCTAssertEqual(candidates("ok", "OK"), [])
        XCTAssertEqual(candidates("i phone", "iPhone"), [])
    }

    func testACapitalisedTypoAtASentenceStart() {
        XCTAssertEqual(candidates("their", "Thier", startsSentence: true), [])
        XCTAssertEqual(candidates("the", "Teh", startsSentence: true), [])
        // Mid-sentence an unknown capitalised word is a name, whatever it resembles.
        XCTAssertEqual(candidates("their", "Thier"), ["Thier"])
    }

    func testFileNamesAndHandles() {
        XCTAssertEqual(candidates("package jason", "package.json"), [])
        XCTAssertEqual(candidates("read me", "README.md"), [])
        XCTAssertEqual(candidates("main swift", "main.swift"), [])
        XCTAssertEqual(candidates("report", "Q3-report.pdf"), [])
        XCTAssertEqual(candidates("max im", "@MaximCosta"), [])
        XCTAssertEqual(candidates("vue js", "Vue.js"), ["Vue.js"])
    }

    func testNamesTheEngineAlreadyKnows() {
        XCTAssertEqual(candidates("monday", "Monday"), [])
        XCTAssertEqual(candidates("paris", "Paris"), [])
    }

    func testACapitalTheSentenceAsksFor() {
        XCTAssertEqual(candidates("apple", "Apple", startsSentence: true), [])
    }

    func testNounCapitalisingLanguages() {
        XCTAssertEqual(candidates("rat", "Rat", capitalMarksNames: false), [])
        XCTAssertEqual(candidates("Mause", "Maus", capitalMarksNames: false), [])
        XCTAssertEqual(candidates("rest sets", "Rsets", capitalMarksNames: false), ["Rsets"])
    }

    func testNumbers() {
        XCTAssertEqual(candidates("twelve", "12"), [])
        XCTAssertEqual(candidates("three pm", "3pm"), [])
        XCTAssertEqual(candidates("second", "2nd"), [])
        XCTAssertEqual(candidates("four k", "4K"), [])
        XCTAssertEqual(candidates("twelve thirty", "12h30"), [])
    }

    func testLinks() {
        XCTAssertEqual(candidates("example dot com", "example.com"), [])
        XCTAssertEqual(candidates("my site", "https://my-monkey.fr"), [])
        XCTAssertEqual(candidates("www", "www.Example.org"), [])
        XCTAssertEqual(candidates("the docs", "docs/Setup"), [])
    }

    func testCode() {
        XCTAssertEqual(candidates("is enabled", "isEnabled"), [])
        XCTAssertEqual(candidates("get element", "getElementById"), [])
        XCTAssertEqual(candidates("snake case", "snake_case"), [])
        XCTAssertEqual(candidates("run", "run()"), [])
        XCTAssertEqual(candidates("verbose", "--verbose"), [])
        XCTAssertEqual(candidates("hash tag", "#Rsets"), [])
        XCTAssertEqual(candidates("a", "a=b"), [])
    }

    func testWordsThatStayWords() {
        XCTAssertEqual(candidates("node js", "Node.js"), ["Node.js"])
        XCTAssertEqual(candidates("c plus plus", "C++"), ["C++"])
        XCTAssertEqual(candidates("c sharp", "C#"), ["C#"])
    }

    func testSingleLettersAndOverlongWords() {
        XCTAssertEqual(candidates("i", "I"), [])
        XCTAssertEqual(candidates("x", String(repeating: "Q", count: 41)), [])
    }

    func testAMultiWordRunNeedsCapitalsThroughout() {
        XCTAssertEqual(candidates("the rest sets", "the Rsets thing"), [])
        // Capitalised mid-sentence is the signal, so a title made of common words is offered;
        // refusing it once is enough.
        XCTAssertEqual(candidates("new book", "New Book"), ["New Book"])
        XCTAssertEqual(candidates("new book", "New Book", startsSentence: true), ["New Book"])
        XCTAssertEqual(candidates("new", "New", startsSentence: true), [])
    }

    func testAWordAlreadyInTheDictationWasMovedNotCorrected() {
        XCTAssertEqual(candidates("send", "Rsets", dictated: "Rsets send"), [])
    }

    func testAReworkedTextOffersNothing() {
        let replacements = (0...DictionaryCandidates.maxReplacements).map {
            CorrectionDiff.Replacement(heard: ["x\($0)"], written: [Word("Rsets\($0)", startsSentence: false)])
        }
        XCTAssertEqual(DictionaryCandidates.candidates(in: replacements, dictated: "x", spelling: spelling), [])
        XCTAssertEqual(DictionaryCandidates.candidates(in: Array(replacements.dropLast()), dictated: "x",
                                                       spelling: spelling).count, DictionaryCandidates.maxPerDictation)
    }

    func testDuplicatesAndTheCap() {
        let replacements = ["Rsets", "Rsets", "GitHub", "kubectl", "OSW"].map {
            CorrectionDiff.Replacement(heard: ["x"], written: [Word($0, startsSentence: false)])
        }
        XCTAssertEqual(DictionaryCandidates.candidates(in: replacements, dictated: "x", spelling: spelling)
                        .map(\.term), ["Rsets", "GitHub", "kubectl"])
    }
}
