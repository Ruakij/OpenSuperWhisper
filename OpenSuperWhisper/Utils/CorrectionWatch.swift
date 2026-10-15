import AppKit
import OpenSuperWhisperCore

/// What a watch knows about the dictation between two reads of its field (#169). Pure, so the
/// whole course of a watch is tested without a field.
struct CorrectionTrail: Equatable, Sendable {
    /// The dictation as it was found in the field right after it went in.
    let dictated: String
    let anchors: CorrectionDiff.Anchors
    /// The text before the dictation ended a sentence, which decides for its first word.
    let startsSentence: Bool
    /// Where the dictation starts in the field, in UTF-16 units, as of the last read.
    private(set) var start: Int
    /// The dictation as last seen, with the user's corrections in it.
    private(set) var latest: String

    /// Context read on either side of the dictation, wide enough for the anchors to be found
    /// again after a few lines were typed next to it.
    static let margin = 600

    enum Next: Equatable {
        case watching
        /// The watch is over, and this is what the dictation became.
        case done(String)
    }

    /// The dictation in the first read of its field, `window` holding the field from `windowStart`
    /// and the caret at `caret`. nil when it is not there to be found.
    init?(dictated inserted: String, window: String, windowStart: Int, caret: Int) {
        guard let found = CorrectionDiff.locate(inserted, in: window, caret: caret - windowStart) else { return nil }
        dictated = (window as NSString).substring(with: found.range)
        anchors = found.anchors
        startsSentence = CorrectionDiff.endsSentence(found.anchors.before)
        start = windowStart + found.range.location
        latest = dictated
    }

    /// The first read: the dictation ends at the caret, so that is where to look.
    static func landingWindow(caret: Int, dictatedLength: Int, fieldLength: Int) -> NSRange {
        let start = max(0, caret - dictatedLength - margin)
        let end = min(fieldLength, caret + margin)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Longer than this and the user wrote a new text around the dictation, not a correction.
    var maxRegionLength: Int { (dictated as NSString).length * 3 + 200 }

    /// The part of the field to read next. nil when it would be too much to read: a dictation at
    /// the end of a long document, with no text after it to stop at.
    func window(fieldLength: Int) -> NSRange? {
        let from = anchors.before.isEmpty ? 0 : max(0, start - Self.margin)
        let to = anchors.after.isEmpty ? fieldLength : min(fieldLength, start + maxRegionLength + Self.margin)
        guard to >= from, to - from <= WatchedField.maxWholeValue else { return nil }
        return NSRange(location: from, length: to - from)
    }

    /// Takes a new read of `window(fieldLength:)`. nil text is a field that stopped answering.
    ///
    /// The watch ends on the last state seen when the dictation can no longer be found, or
    /// leaves nothing but space: a message sent, a field cleared. It ends on the text up to the
    /// line break when the user pressed Return in it.
    mutating func read(_ text: String?, windowStart: Int) -> Next {
        guard let text,
              let range = CorrectionDiff.regionRange(in: text, anchors: anchors, expectedStart: start - windowStart,
                                                     maxLength: maxRegionLength) else { return .done(latest) }
        let region = (text as NSString).substring(with: range)
        guard !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .done(latest) }
        if let beforeReturn = CorrectionDiff.cutAtAddedLineBreak(region, dictated: dictated) {
            return .done(beforeReturn)
        }
        latest = region
        start = windowStart + range.location
        return .watching
    }

    /// The words worth offering from `edited`, the dictation as the watch left it.
    func candidates(edited: String, spelling: DictionaryCandidates.Spelling,
                    capitalMarksNames: Bool) -> [DictionaryCandidates.Candidate] {
        let replacements = CorrectionDiff.replacements(inserted: dictated, edited: edited,
                                                       startsSentence: startsSentence)
        return DictionaryCandidates.candidates(in: replacements, dictated: dictated, spelling: spelling,
                                               capitalMarksNames: capitalMarksNames)
    }
}

/// Keeps reading the field a dictation went into while the user may be correcting it, then
/// offers the words they fixed for the dictionary (#169).
///
/// One watch at a time: the next dictation ends the previous one where it stands. A watch ends
/// when the app or the field loses the focus, when the message is sent or Return is pressed,
/// or after `duration`. It reads only the one field, off the main thread, and keeps what it read
/// in memory until it ends. A field that cannot be read is simply not watched.
@MainActor
final class CorrectionWatch {
    private static var current: CorrectionWatch?

    static let duration: Duration = .seconds(60)
    /// Twice a second: a fix made just before sending is not lost, and a read whose field has
    /// not changed costs one small request.
    static let pollInterval: Duration = .milliseconds(500)
    /// A paste lands once the app reads the clipboard, which a busy app does late.
    static let landingDelay: Duration = .milliseconds(600)
    static let landingAttempts = 3

    private let inserted: String
    private let pid: pid_t
    private let language: String?
    private var trail: CorrectionTrail?
    private var task: Task<Void, Never>?
    private var ended = false

    private init(inserted: String, pid: pid_t, language: String?) {
        self.inserted = inserted
        self.pid = pid
        self.language = language
    }

    /// Starts watching the app in front, where `inserted` was just put, when the setting asks
    /// for it.
    ///
    /// - Parameter language: what the dictation is in, nil when unknown; for the spelling
    ///   dictionary and for whether a capital means a name.
    static func begin(after inserted: String, language: String?) {
        let prefs = AppPreferences.shared
        current?.end(offering: true)
        guard prefs.suggestDictionaryWords, prefs.customDictionaryEnabled, AXIsProcessTrusted(),
              !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let watch = CorrectionWatch(inserted: inserted, pid: front.processIdentifier, language: language)
        current = watch
        watch.task = Task { await watch.run() }
        Diag.mark("correction watch: started")
    }

    private func run() async {
        guard let field = await land() else {
            Diag.mark("correction watch: field unreadable or dictation not found, nothing watched")
            return end(offering: false)
        }
        let deadline = ContinuousClock.now + Self.duration
        var seen: WatchedField.State?
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
            guard !ended, var trail else { return }
            guard AppPreferences.shared.suggestDictionaryWords else { return end(offering: false) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { break }

            let read = await Self.read(field, trail: trail, unless: seen)
            guard !ended else { return }
            switch read {
            case .focusLeft:
                return end(offering: true)
            case .unchanged:
                continue
            case .text(let text, let windowStart, let state):
                seen = state
                let next = trail.read(text, windowStart: windowStart)
                self.trail = trail
                if case .done(let final) = next {
                    return end(offering: true, final: final)
                }
            }
        }
        end(offering: true)
    }

    /// Finds the dictation in its field, giving the paste a moment to land.
    private func land() async -> WatchedField? {
        for _ in 0..<Self.landingAttempts {
            try? await Task.sleep(for: Self.landingDelay)
            guard !ended else { return nil }
            let (inserted, pid) = (self.inserted, self.pid)
            let landed = await Task.detached(priority: .utility) { () -> (WatchedField, CorrectionTrail)? in
                guard let field = WatchedField.focused(in: pid), let state = field.state() else { return nil }
                let caret = NSMaxRange(state.selection)
                let window = CorrectionTrail.landingWindow(caret: caret, dictatedLength: (inserted as NSString).length,
                                                           fieldLength: state.length)
                guard let text = field.text(in: window, fieldLength: state.length),
                      let trail = CorrectionTrail(dictated: inserted, window: text, windowStart: window.location,
                                                  caret: caret) else { return nil }
                return (field, trail)
            }.value
            if let (field, trail) = landed {
                self.trail = trail
                return field
            }
        }
        return nil
    }

    private enum Read: Sendable {
        case focusLeft
        case unchanged
        case text(String?, windowStart: Int, state: WatchedField.State?)
    }

    /// One read of the field, off the main thread. The text is fetched only when the length or
    /// the selection moved since `seen`.
    private static func read(_ field: WatchedField, trail: CorrectionTrail,
                             unless seen: WatchedField.State?) async -> Read {
        await Task.detached(priority: .utility) { () -> Read in
            if field.hasFocus() == false { return .focusLeft }
            guard let state = field.state() else { return .text(nil, windowStart: 0, state: nil) }
            if state == seen { return .unchanged }
            guard let window = trail.window(fieldLength: state.length) else {
                return .text(nil, windowStart: 0, state: state)
            }
            return .text(field.text(in: window, fieldLength: state.length), windowStart: window.location, state: state)
        }.value
    }

    /// Ends the watch, and offers what the corrections taught when `offering`.
    private func end(offering: Bool, final: String? = nil) {
        guard !ended else { return }
        ended = true
        task?.cancel()
        if Self.current === self { Self.current = nil }
        guard offering, let trail else { return }

        let known = language == "auto" ? nil : language
        let languageGuess = known ?? TranscriptInserter.guessedLanguage(of: trail.dictated, after: trail.anchors.before)
        let found = trail.candidates(edited: final ?? trail.latest,
                                     spelling: SpellingDictionary.spelling(for: languageGuess),
                                     capitalMarksNames: CaretTextMatcher.adjustsCase(language: languageGuess))
        let offered = DictionarySuggestions.shared.offer(found)
        Diag.mark("correction watch: ended, \(found.count) candidate(s), \(offered.count) new")
        DictionarySuggestionNotice.shared.present(offered)
    }
}

/// The spelling dictionary of macOS, in the dictation's language and the user's own.
@MainActor
enum SpellingDictionary {
    static func spelling(for language: String?) -> DictionaryCandidates.Spelling {
        let languages = languages(for: language)
        let checker = NSSpellChecker.shared
        return DictionaryCandidates.Spelling(
            knows: { word in
                languages.contains { language in
                    checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
                }
            },
            correctsTypo: { word in
                languages.contains { language in
                    checker.correction(forWordRange: NSRange(location: 0, length: (word as NSString).length),
                                       in: word, language: language, inSpellDocumentWithTag: 0) != nil
                }
            })
    }

    /// A word known in any of these is a known word: people correct in the languages they write.
    static func languages(for dictation: String?) -> [String] {
        let checker = NSSpellChecker.shared
        let available = Set(checker.availableLanguages)
        var result: [String] = []
        for code in [dictation].compactMap({ $0 }) + checker.userPreferredLanguages {
            let primary = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
            for candidate in [code, primary] where available.contains(candidate) && !result.contains(candidate) {
                result.append(candidate)
                break
            }
        }
        return result.isEmpty ? [checker.language()] : Array(result.prefix(maxLanguages))
    }

    static let maxLanguages = 4
}
