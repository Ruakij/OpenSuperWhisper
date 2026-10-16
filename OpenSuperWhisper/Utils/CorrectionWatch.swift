import AppKit
import Carbon
import OpenSuperWhisperCore

/// One read of the watched field.
enum CorrectionRead: Sendable {
    case focusLeft
    /// Same length and selection as the last read: the text was not fetched.
    case unchanged
    /// nil text is a field that would not answer.
    case text(String?, windowStart: Int, state: WatchedField.State?)
}

/// The field a watch reads, behind a seam so the course of a watch is tested without one.
@MainActor
protocol CorrectionFieldSource: AnyObject {
    /// One attempt at finding the dictation in its field. nil when it is not there, or not yet.
    func land(_ inserted: String) async -> CorrectionTrail?
    func read(_ trail: CorrectionTrail, unless seen: WatchedField.State?) async -> CorrectionRead
    /// The app the text went into is still the one in front.
    func appIsInFront() -> Bool
}

/// Keeps reading the field a dictation went into while the user may be correcting it, then
/// offers the words they fixed for the dictionary (#169).
///
/// One watch at a time, and the app's own next insertion ends it first (`endCurrent()`): text
/// we paste is not a correction. A watch ends when the app or the field loses the focus, when
/// the message is sent or Return is pressed, when the setting or the dictionary is turned off,
/// or after `Timing.duration`. It reads only the one field, off the main thread, and keeps what
/// it read in memory until it ends. A field that cannot be read is simply not watched.
@MainActor
final class CorrectionWatch {
    private static var current: CorrectionWatch?

    struct Timing {
        /// A paste lands once the app reads the clipboard, which a busy app does late.
        var landingDelay: Duration = .milliseconds(600)
        var landingAttempts = 3
        /// Twice a second: a fix made just before sending is not lost, and a read whose field
        /// has not changed costs one small request.
        var pollInterval: Duration = .milliseconds(500)
        var duration: Duration = .seconds(60)
        /// A field that changed this recently when the watch ended may hold a word still being
        /// typed at the caret.
        var settle: Duration = .seconds(1)
        /// A fix left alone this long is offered while the user is still in the field, rather
        /// than only once the focus leaves it. Long enough not to offer a word half typed.
        var idle: Duration = .milliseconds(2500)
    }

    private let inserted: String
    private let source: CorrectionFieldSource
    private let timing: Timing
    private let isWanted: () -> Bool
    /// What the watch learned: the trail and the dictation as the user left it.
    private let deliver: (CorrectionTrail, String) -> Void
    private var trail: CorrectionTrail?
    private var task: Task<Void, Never>?
    private var ended = false
    private var lastChange: ContinuousClock.Instant?
    /// The change last offered while the watch went on, so one pause offers once.
    private var offeredChange: ContinuousClock.Instant?

    init(inserted: String, source: CorrectionFieldSource, timing: Timing = Timing(),
         isWanted: @escaping () -> Bool, deliver: @escaping (CorrectionTrail, String) -> Void) {
        self.inserted = inserted
        self.source = source
        self.timing = timing
        self.isWanted = isWanted
        self.deliver = deliver
    }

    /// Starts watching the app `pid`, where `inserted` was just put, when the setting asks
    /// for it.
    ///
    /// - Parameters:
    ///   - pid: the app the dictation was for. Not watched unless it is the one in front, where
    ///     the text went.
    ///   - language: what the dictation is in, nil when unknown; for the spelling dictionary and
    ///     for whether a capital means a name.
    static func begin(after inserted: String, pid: pid_t?, language: String?) {
        endCurrent()
        guard isWanted(), AXIsProcessTrusted(),
              // Secure input is on while a password is typed somewhere: not a time to read fields.
              !IsSecureEventInputEnabled(),
              !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              pid == nil || pid == front.processIdentifier else { return }
        let source = LiveCorrectionField(pid: front.processIdentifier)
        start(CorrectionWatch(inserted: inserted, source: source, isWanted: isWanted,
                              deliver: { offer($0, edited: $1, language: language) }))
        Diag.mark("correction watch: started")
    }

    /// The setting, and the dictionary it feeds: suggesting for a dictionary that is off is
    /// pointless.
    static func isWanted() -> Bool {
        AppPreferences.shared.suggestDictionaryWords && AppPreferences.shared.customDictionaryEnabled
    }

    static func start(_ watch: CorrectionWatch) {
        endCurrent()
        current = watch
        watch.task = Task { await watch.run() }
    }

    /// Ends the watch in progress, offering what it read last. Called before the app inserts
    /// anything: a paste of ours landing in the watched field would read as the user's own fix.
    static func endCurrent() {
        current?.end(offering: true)
    }

    #if DEBUG
    static var isWatching: Bool { current != nil }
    #endif

    private func run() async {
        guard await land() else {
            Diag.mark("correction watch: field unreadable or dictation not found, nothing watched")
            return end(offering: false)
        }
        let deadline = ContinuousClock.now + timing.duration
        var seen: WatchedField.State?
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: timing.pollInterval)
            guard !ended, var trail else { return }
            guard isWanted() else { return end(offering: false) }
            guard source.appIsInFront() else { break }

            let read = await source.read(trail, unless: seen)
            guard !ended else { return }
            switch read {
            case .focusLeft:
                return end(offering: true)
            case .unchanged:
                offerIfIdle()
                continue
            case .text(let text, let windowStart, let state):
                if state != seen { lastChange = .now }
                seen = state
                let next = trail.read(text, windowStart: windowStart, caret: state.map { NSMaxRange($0.selection) })
                self.trail = trail
                if case .done(let final) = next {
                    return end(offering: true, final: final)
                }
            }
        }
        end(offering: true)
    }

    /// Offers what the field shows once it has stayed the same for `Timing.idle` after a
    /// change, and keeps watching. Words already offered are not offered twice, so the end of the
    /// watch adds only what changed since.
    private func offerIfIdle() {
        guard let change = lastChange, change != offeredChange, let trail,
              ContinuousClock.now - change >= timing.idle, trail.latest != trail.dictated else { return }
        offeredChange = change
        deliver(trail, trail.latest)
    }

    private func land() async -> Bool {
        for _ in 0..<timing.landingAttempts {
            try? await Task.sleep(for: timing.landingDelay)
            guard !ended else { return false }
            if let landed = await source.land(inserted) {
                trail = landed
                return !ended
            }
        }
        return false
    }

    /// Ends the watch, and hands over what the corrections taught when `offering`.
    ///
    /// - Parameter final: the dictation as the field showed it when it was sent or Return was
    ///   pressed. Without one, the last read, less a word the user may still have been typing.
    private func end(offering: Bool, final: String? = nil) {
        guard !ended else { return }
        ended = true
        task?.cancel()
        if Self.current === self { Self.current = nil }
        guard offering, let trail else { return }
        let stillTyping = lastChange.map { ContinuousClock.now - $0 < timing.settle } ?? false
        deliver(trail, final ?? (stillTyping ? trail.settled(trail.latest) : trail.latest))
    }

    /// The live delivery: the candidates, through the spelling dictionary, to the Suggested list
    /// and the notice.
    private static func offer(_ trail: CorrectionTrail, edited: String, language: String?) {
        let known = language == "auto" ? nil : language
        let languageGuess = known ?? TranscriptInserter.guessedLanguage(of: trail.dictated, after: trail.anchors.before)
        let found = trail.candidates(edited: edited,
                                     spelling: SpellingDictionary.spelling(for: languageGuess),
                                     capitalMarksNames: CaretTextMatcher.adjustsCase(language: languageGuess))
        let offered = DictionarySuggestions.shared.offer(found)
        Diag.mark("correction watch: ended, \(found.count) candidate(s), \(offered.count) new")
        DictionarySuggestionNotice.shared.present(offered)
    }
}

/// The real field, through Accessibility, every request off the main thread.
@MainActor
final class LiveCorrectionField: CorrectionFieldSource {
    private let pid: pid_t
    private var field: WatchedField?

    init(pid: pid_t) {
        self.pid = pid
    }

    func land(_ inserted: String) async -> CorrectionTrail? {
        let pid = self.pid
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
        field = landed?.0
        return landed?.1
    }

    /// The text is fetched only when the length or the selection moved since `seen`.
    func read(_ trail: CorrectionTrail, unless seen: WatchedField.State?) async -> CorrectionRead {
        guard let field else { return .text(nil, windowStart: 0, state: nil) }
        return await Task.detached(priority: .utility) { () -> CorrectionRead in
            if field.hasFocus() == false { return .focusLeft }
            guard let state = field.state() else { return .text(nil, windowStart: 0, state: nil) }
            if state == seen { return .unchanged }
            guard let window = trail.window(fieldLength: state.length) else {
                return .text(nil, windowStart: 0, state: state)
            }
            return .text(field.text(in: window, fieldLength: state.length), windowStart: window.location, state: state)
        }.value
    }

    func appIsInFront() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
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
