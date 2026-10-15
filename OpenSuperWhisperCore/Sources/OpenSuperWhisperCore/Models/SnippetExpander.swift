import Foundation

/// Finds snippet triggers in a finished dictation and puts their text in their place (#167).
///
/// It runs on the text as it leaves the cleanup model, which is the reason most of this exists.
/// Expanding earlier would hand the snippet to the model, free to rewrite the address or the
/// signature the user typed. Expanding after means matching what the model made of the trigger:
/// "my email" comes back as "My email." So the matching tolerates case, the spacing between
/// words, the apostrophe the model picked, and the punctuation it added; and that punctuation is
/// dropped with the trigger when it was the model's, not the sentence's.
///
/// Pure, so every case is tested without a dictation.
public enum SnippetExpander {

    /// One trigger found in the text, and the span its snippet replaces.
    public struct Expansion: Equatable, Sendable {
        /// The trigger as it appears in the text, plus any punctuation that goes with it.
        public let range: Range<String.Index>
        public let snippet: Snippet
    }

    /// The text with every trigger replaced by its snippet's text.
    ///
    /// - Parameter dictionary: the custom dictionary rules in force. They run on the engine's
    ///   output before this does, so a trigger containing a word they rewrite ("my monkey site",
    ///   with "my monkey" written "My-Monkey") would otherwise never be found. Each trigger is
    ///   also looked for as the dictionary would have written it.
    public static func expand(_ text: String, snippets: [Snippet],
                              dictionary: [CustomDictionaryEntry] = []) -> String {
        let found = expansions(in: text, snippets: snippets, dictionary: dictionary)
        guard !found.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for expansion in found {
            result += text[cursor..<expansion.range.lowerBound]
            result += expansion.snippet.trimmedExpansion
            cursor = expansion.range.upperBound
        }
        return result + text[cursor...]
    }

    /// The triggers found in `text`, in reading order, none overlapping.
    ///
    /// Where two triggers overlap the longer one wins, wherever it starts: with "my email" and
    /// "my email signature" both defined, saying the second must not give the address followed
    /// by the word "signature". A text is scanned once, so a snippet's own text is never searched
    /// for triggers in turn.
    public static func expansions(in text: String, snippets: [Snippet],
                                  dictionary: [CustomDictionaryEntry] = []) -> [Expansion] {
        guard !text.isEmpty else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var candidates: [(range: NSRange, order: Int)] = []
        for (order, snippet) in snippets.enumerated() where snippet.isComplete {
            for form in spokenForms(of: snippet, dictionary: dictionary) {
                guard let regex = try? NSRegularExpression(pattern: pattern(for: form),
                                                           options: [.caseInsensitive]) else { continue }
                for match in regex.matches(in: text, range: whole) where match.range.length > 0 {
                    candidates.append((match.range, order))
                }
            }
        }
        // Longest first; then the earlier in the text, then the snippet listed first, so two
        // snippets sharing a trigger always resolve the same way.
        candidates.sort {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.order < $1.order
        }
        var kept: [(range: NSRange, order: Int)] = []
        for candidate in candidates
        where !kept.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
            kept.append(candidate)
        }
        kept.sort { $0.range.location < $1.range.location }

        var result: [Expansion] = []
        for (position, candidate) in kept.enumerated() {
            guard let trigger = Range(candidate.range, in: text) else { continue }
            let snippet = snippets[candidate.order]
            let nextStart = position + 1 < kept.count
                ? Range(kept[position + 1].range, in: text)?.lowerBound ?? text.endIndex
                : text.endIndex
            let end = min(SnippetPunctuation.end(of: trigger, in: text,
                                                 expansion: snippet.trimmedExpansion),
                          nextStart)
            result.append(Expansion(range: trigger.lowerBound..<end, snippet: snippet))
        }
        return result
    }

    /// The triggers to bias recognition toward, de-duplicated without regard to case. A trigger
    /// with no letter or digit has nothing to teach a model and is left out.
    public static func boostTerms(_ snippets: [Snippet]) -> [String] {
        var seen = Set<String>()
        return snippets
            .filter(\.isComplete)
            .map { SnippetPunctuation.trimmingTrailingMarks($0.trimmedTrigger) }
            .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Matching

    /// The trigger as typed, and as the dictionary would have rewritten it when that differs.
    /// Trailing punctuation typed into the trigger is not required in the text: "Sign off!"
    /// still matches a plain "sign off".
    static func spokenForms(of snippet: Snippet, dictionary: [CustomDictionaryEntry]) -> [String] {
        let spoken = SnippetPunctuation.trimmingTrailingMarks(snippet.trimmedTrigger)
        guard !spoken.isEmpty else { return [] }
        guard !dictionary.isEmpty else { return [spoken] }
        let rewritten = SnippetPunctuation.trimmingTrailingMarks(
            CustomDictionary.apply(spoken, entries: dictionary)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rewritten.isEmpty, rewritten.caseInsensitiveCompare(spoken) != .orderedSame else {
            return [spoken]
        }
        return [spoken, rewritten]
    }

    /// A whole-word, case-insensitive pattern for one form of a trigger.
    ///
    /// Word boundaries are added only where the trigger starts or ends with a word character,
    /// as `CustomDictionary.apply` does, so a trigger like "C++" can still match. Any run of
    /// spaces between words matches any other run, and an apostrophe matches either the straight
    /// or the curly one, since which one the model writes is not up to the user ("l'adresse").
    static func pattern(for form: String) -> String {
        var body = ""
        var spaceBefore = false
        for character in form {
            if character.isWhitespace {
                spaceBefore = true
                continue
            }
            if spaceBefore {
                body += "\\s+"
                spaceBefore = false
            }
            body += apostrophes.contains(character)
                ? "['’ʼ]"
                : NSRegularExpression.escapedPattern(for: String(character))
        }
        let leading = isWordCharacter(form.first) ? "\\b" : ""
        let trailing = isWordCharacter(form.last) ? "\\b" : ""
        return leading + body + trailing
    }

    private static let apostrophes: Set<Character> = ["'", "’", "ʼ"]

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}

/// What happens to the punctuation around a trigger once it is expanded.
enum SnippetPunctuation {

    /// Marks the cleanup model puts after a phrase, or that close the clause it ends.
    static let marks: Set<Character> = [".", "!", "?", "…", ",", ";", ":", "。", "！", "？"]
    /// The marks that end a sentence.
    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    /// French puts a space, often a narrow no-break one, before these.
    private static let spacedMarks: Set<Character> = ["!", "?", ";", ":"]
    private static let spacesBeforeMarks: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]
    /// Looked through when deciding whether a trigger starts a sentence: `"My email` does.
    private static let openers: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "¿", "¡"]

    /// Where the replaced span ends: right after the trigger, or after the marks that follow it
    /// when those belong to the trigger rather than to the sentence around it.
    ///
    /// They are the trigger's in two cases. The trigger is a sentence of its own with nothing
    /// after it on the line, which is what a dictation of just "my email" looks like once the
    /// model has made it "My email.": the period was the model's. Or the snippet is a block
    /// (it holds a line break) or ends with a mark of its own, so a period after it would be
    /// stray. A comma or a period after a trigger inside a longer sentence is that sentence's
    /// own, and stays.
    static func end(of trigger: Range<String.Index>, in text: String, expansion: String) -> String.Index {
        let marksEnd = endOfMarks(after: trigger.upperBound, in: text)
        guard marksEnd > trigger.upperBound else { return trigger.upperBound }

        let rest = text[marksEnd...]
        let restOfLineIsBlank = rest.prefix(while: { !$0.isNewline }).allSatisfy(\.isWhitespace)
        if restOfLineIsBlank && startsSentence(text[..<trigger.lowerBound]) {
            return marksEnd
        }

        let run = text[trigger.upperBound..<marksEnd].filter { !spacesBeforeMarks.contains($0) }
        let isBlock = expansion.contains(where: \.isNewline)
        let endsWithMark = expansion.last.map(marks.contains) ?? false
        if run.allSatisfy(sentenceEnds.contains) && (isBlock || endsWithMark) {
            return marksEnd
        }
        return trigger.upperBound
    }

    /// The end of the run of marks right after `index`, or `index` when there is none. One space
    /// before a mark that takes one in French is part of the run: "Mon email !" drops whole.
    private static func endOfMarks(after index: String.Index, in text: String) -> String.Index {
        var cursor = index
        if cursor < text.endIndex, spacesBeforeMarks.contains(text[cursor]) {
            let next = text.index(after: cursor)
            guard next < text.endIndex, spacedMarks.contains(text[next]) else { return index }
            cursor = next
        }
        while cursor < text.endIndex, marks.contains(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// Whether a trigger preceded by `before` starts a sentence: at the start of the text or of
    /// a line, or after a sentence's final mark. Spaces and opening quotes are looked through.
    static func startsSentence(_ before: Substring) -> Bool {
        for character in before.reversed() {
            if character.isNewline { return true }
            if character == " " || character == "\t" || openers.contains(character) { continue }
            return sentenceEnds.contains(character)
        }
        return true
    }

    /// The trigger without the marks typed at its end, which the text need not repeat.
    static func trimmingTrailingMarks(_ trigger: String) -> String {
        var trimmed = Substring(trigger)
        while let last = trimmed.last, marks.contains(last) || last.isWhitespace {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }
}
