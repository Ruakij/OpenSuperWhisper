import Foundation

/// The dictionary's words in the cleanup prompt (#169).
extension LLMPostProcessor {

    /// The dictionary's terms that are in the text being cleaned up, as whole words.
    ///
    /// Only those: the rest would tell the model nothing about this text, and on a remote server
    /// the dictionary would leave the Mac a little more with every dictation, names and
    /// addresses included. A term in the text was going to the server anyway. A small model
    /// handed a list of unrelated names also tends to slip one in.
    ///
    /// Whole words, or "Max" would go out with every "maximum" and "AI" with every "said". Case
    /// and accents are ignored, since the dictation is what the dictionary is there to fix, and
    /// the words of a term may be split by any white space.
    static func cleanupVocabulary(_ terms: [String], in text: String) -> [String] {
        let folded = fold(text)
        let range = NSRange(folded.startIndex..., in: folded)
        return terms.filter { term in
            guard let pattern = wholeWordPattern(for: fold(term)),
                  let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: folded, range: range) != nil
        }
    }

    /// The term as a pattern that only matches it between word boundaries. A boundary is only
    /// asked for on a side that ends in a letter or a digit, so "C++" and "#Rsets" still match:
    /// the same rule `CustomDictionary.apply` uses.
    static func wholeWordPattern(for term: String) -> String? {
        let words = term.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first?.first, let last = words.last?.last else { return nil }
        let body = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
        let notWord = "[\\p{L}\\p{N}_]"
        return (isWordCharacter(first) ? "(?<!\(notWord))" : "") + body
            + (isWordCharacter(last) ? "(?!\(notWord))" : "")
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The dictionary's terms, so the cleanup keeps them as the user spells them.
    ///
    /// A cleanup model fixing "obvious mis-recognitions" is exactly what turns a correct "Rsets"
    /// back into "resets": the rarer the word, the likelier it looks like a mistake. Only the
    /// terms go, never the phrasings that lead to them, and the list is cut short so a long
    /// dictionary cannot crowd the instruction out of a small model's attention. nil without
    /// terms, so a pass with no dictionary word in it sends exactly what it always did.
    static func vocabularySection(_ terms: [String]) -> String? {
        let kept = terms.prefix(maxVocabularyTerms)
        guard !kept.isEmpty else { return nil }
        return "Keep these words spelled exactly as written here: \(kept.joined(separator: ", "))."
    }

    static let maxVocabularyTerms = 40
}
