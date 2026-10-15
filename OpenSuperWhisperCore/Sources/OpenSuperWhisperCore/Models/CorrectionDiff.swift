import Foundation

/// What became of a dictation once the user corrected it by hand in the field (#169).
///
/// Every time Parakeet writes "rest sets" for "Rsets" the user fixes it in the field, and that
/// fix is the most reliable signal there is about their vocabulary. This finds the dictation in
/// the field right after it went in, finds it again once the user is done with it, and lines the
/// two up word by word. Pure, so every case is tested without a field: reading the field is the
/// app's job.
public enum CorrectionDiff {

    /// The text on either side of an insertion, which is how it is found again after edits have
    /// moved it. Offsets alone would not survive the user typing anywhere before it.
    public struct Anchors: Equatable, Sendable {
        /// Up to `anchorLength` UTF-16 units right before the insertion. Empty when the insertion
        /// started the field.
        public let before: String
        /// Up to `anchorLength` units right after it. Empty when it ended the field.
        public let after: String

        public init(before: String, after: String) {
            self.before = before
            self.after = after
        }
    }

    /// Long enough to be unique in an ordinary field, short enough that an edit next to the
    /// insertion rarely reaches into it.
    public static let anchorLength = 32

    /// How far from the caret the inserted text may end and still count as the one just pasted.
    /// The fitting can leave a space after it, and some apps settle the caret a little later.
    static let caretSlack = 8

    /// Where the dictation is in a field read right after it went in, in UTF-16 units of `text`.
    ///
    /// It has to end next to the caret, where a paste leaves it. The same words earlier in the
    /// field are an older dictation, not this one. nil when it is not there: the paste missed,
    /// the app rewrote it (a rich list), or the field is not the one it went into.
    public static func locate(_ inserted: String, in text: String,
                              caret: Int) -> (range: NSRange, anchors: Anchors)? {
        let needle = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let field = text as NSString
        guard !needle.isEmpty, caret >= 0, caret <= field.length else { return nil }

        let searched = NSRange(location: 0, length: min(field.length, caret + caretSlack))
        let found = field.range(of: needle, options: .backwards, range: searched)
        guard found.location != NSNotFound,
              abs(NSMaxRange(found) - caret) <= caretSlack else { return nil }
        return (found, anchors(around: found, in: field))
    }

    /// The text between the anchors now: what the dictation became.
    ///
    /// - Parameters:
    ///   - expectedStart: where the dictation started last time, in units of `text`. The anchor
    ///     before it closest to there wins when it occurs more than once.
    ///   - maxLength: longer than this and the anchors were found in the wrong place, or the user
    ///     has written so much around the dictation that it is no longer a correction of it.
    /// - Returns: nil once the anchors are gone, which is what a sent message looks like: the
    ///   field was emptied, and what it held last is the answer.
    public static func region(in text: String, anchors: Anchors, expectedStart: Int,
                              maxLength: Int) -> String? {
        regionRange(in: text, anchors: anchors, expectedStart: expectedStart, maxLength: maxLength)
            .map { (text as NSString).substring(with: $0) }
    }

    /// Where `region(in:anchors:expectedStart:maxLength:)` is, in UTF-16 units of `text`, for the
    /// next read to look around.
    public static func regionRange(in text: String, anchors: Anchors, expectedStart: Int,
                                   maxLength: Int) -> NSRange? {
        let field = text as NSString
        let start: Int
        if anchors.before.isEmpty {
            start = 0
        } else {
            guard let found = closestOccurrence(of: anchors.before, in: field, endingNear: expectedStart)
            else { return nil }
            start = NSMaxRange(found)
        }
        let end: Int
        if anchors.after.isEmpty {
            end = field.length
        } else {
            let rest = NSRange(location: start, length: field.length - start)
            let found = field.range(of: anchors.after, range: rest)
            guard found.location != NSNotFound else { return nil }
            end = found.location
        }
        guard end - start <= maxLength else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The region as it stood when Return was pressed in it: up to the first line break the
    /// dictation did not have. Return sends a message, or starts a new paragraph that is the
    /// user's own writing and not a correction of the dictation (#169).
    ///
    /// Told from the text rather than from a key press: watching the keyboard would take a
    /// keystroke monitor, for a minute after every dictation, to learn one thing the field
    /// shows anyway. nil while no line break was added.
    public static func cutAtAddedLineBreak(_ region: String, dictated: String) -> String? {
        let dictatedBreaks = dictated.filter(\.isNewline).count
        var seen = 0
        for index in region.indices where region[index].isNewline {
            if seen == dictatedBreaks { return String(region[..<index]) }
            seen += 1
        }
        return nil
    }

    // MARK: - Word by word

    /// A word as the user left it, with what decides whether its capital means anything.
    public struct Word: Equatable, Sendable {
        public let text: String
        /// First word of a sentence, where a capital is grammar rather than spelling.
        public let startsSentence: Bool

        public init(_ text: String, startsSentence: Bool) {
            self.text = text
            self.startsSentence = startsSentence
        }
    }

    /// A run of dictated words the user replaced with other words.
    public struct Replacement: Equatable, Sendable {
        /// What the engine wrote.
        public let heard: [String]
        /// What the user put in its place.
        public let written: [Word]

        public init(heard: [String], written: [Word]) {
            self.heard = heard
            self.written = written
        }
    }

    /// Past these the user rewrote the sentence rather than fixed a word in it, and nothing
    /// they wrote is a correction of what was heard.
    static let maxHeardWords = 4
    static let maxWrittenWords = 3
    /// Lining up is quadratic. A dictation this long is a document, not a message, and a field
    /// edited this much tells nothing word by word anyway.
    static let maxWords = 600

    /// The words the user replaced, each run of them with what it became.
    ///
    /// Words they only added or only deleted are not corrections of what was heard and are
    /// left out, and so are changes to punctuation alone: words are compared without the
    /// punctuation at their ends. Case does count, since "parakeet" made "Parakeet" is exactly
    /// the kind of fix this is for.
    ///
    /// - Parameter startsSentence: whether the text before the dictation in the field ends a
    ///   sentence, which decides for its first word.
    public static func replacements(inserted: String, edited: String,
                                    startsSentence: Bool) -> [Replacement] {
        let heard = tokens(of: inserted)
        let written = tokens(of: edited)
        guard heard.count <= maxWords, written.count <= maxWords else { return [] }

        let pairs = commonSubsequence(heard.map(\.core), written.map(\.core))
        var result: [Replacement] = []
        var h = 0, w = 0
        for (matchedH, matchedW) in pairs + [(heard.count, written.count)] {
            if matchedH > h, matchedW > w,
               matchedH - h <= maxHeardWords, matchedW - w <= maxWrittenWords {
                let words = (w..<matchedW).map { index in
                    Word(written[index].core,
                         startsSentence: index == 0 ? startsSentence : endsSentence(written[index - 1].raw))
                }
                result.append(Replacement(heard: heard[h..<matchedH].map(\.core), written: words))
            }
            h = matchedH + 1
            w = matchedW + 1
        }
        return result
    }

    /// Whether the text before a word ends a sentence: nothing before it, a line break, or a
    /// sentence mark seen through closing quotes and brackets. A colon counts too: what follows
    /// one is capitalised often enough that its capital says nothing about the word.
    public static func endsSentence(_ before: String) -> Bool {
        for character in before.reversed() {
            if character.isNewline { return true }
            if character == " " || character == "\t" || closers.contains(character) { continue }
            return sentenceMarks.contains(character)
        }
        return true
    }

    private static let sentenceMarks: Set<Character> = [".", "!", "?", "…", ":", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", "\u{202F}", "\u{00A0}"]

    // MARK: - Helpers

    private struct Token {
        let raw: String
        let core: String
    }

    /// Words split on white space, each with its edge punctuation trimmed for comparing. A token
    /// that is nothing but punctuation (a dash between two clauses) is not a word.
    private static func tokens(of text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { Token(raw: String($0), core: core(of: String($0))) }
            .filter { !$0.core.isEmpty }
    }

    public static func core(of token: String) -> String {
        token.trimmingCharacters(in: edgePunctuation)
    }

    /// Quotes, brackets, sentence marks, dashes. Not `+` or `#`, which end "C++" and "C#".
    private static let edgePunctuation = CharacterSet.punctuationCharacters
        .subtracting(CharacterSet(charactersIn: "#@&_"))

    /// Index pairs of a longest common subsequence, in order.
    private static func commonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1
                                             : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func anchors(around range: NSRange, in field: NSString) -> Anchors {
        var start = max(0, range.location - anchorLength)
        if start > 0 {
            // Never half an emoji: the anchor has to be found again verbatim.
            let straddling = field.rangeOfComposedCharacterSequence(at: start)
            if straddling.location < start { start = NSMaxRange(straddling) }
        }
        var end = min(field.length, NSMaxRange(range) + anchorLength)
        if end < field.length { end = field.rangeOfComposedCharacterSequence(at: end).location }
        return Anchors(
            before: field.substring(with: NSRange(location: start, length: range.location - start)),
            after: field.substring(with: NSRange(location: NSMaxRange(range),
                                                 length: max(0, end - NSMaxRange(range)))))
    }

    private static func closestOccurrence(of needle: String, in field: NSString,
                                          endingNear expected: Int) -> NSRange? {
        var best: NSRange?
        var searched = NSRange(location: 0, length: field.length)
        while true {
            let found = field.range(of: needle, range: searched)
            guard found.location != NSNotFound else { break }
            if best.map({ abs(NSMaxRange($0) - expected) > abs(NSMaxRange(found) - expected) }) ?? true {
                best = found
            }
            let next = found.location + 1
            guard next < field.length else { break }
            searched = NSRange(location: next, length: field.length - next)
        }
        return best
    }
}
