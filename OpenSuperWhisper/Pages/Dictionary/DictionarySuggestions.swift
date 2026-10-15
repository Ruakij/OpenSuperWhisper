import CryptoKit
import Foundation
import OpenSuperWhisperCore

/// A word offered for the dictionary and not answered yet (#169).
struct DictionarySuggestion: Codable, Equatable, Identifiable, Sendable {
    let term: String
    /// What the engine had written instead, so the user can tell where the word came from.
    let heard: String

    var id: String { term.lowercased() }
}

/// The words the corrections after a dictation offered for the dictionary, and the ones the
/// user turned down (#169).
///
/// Suggests, never adds on its own: a word goes into the dictionary only from Add. A word the
/// user refused, or deleted from the dictionary, is never offered again, whatever its case.
/// The dictionary's Suggested list and the notice after a dictation are two views of this one
/// list, so answering in either answers both.
@MainActor
final class DictionarySuggestions: ObservableObject {
    static let shared = DictionarySuggestions()

    @Published private(set) var pending: [DictionarySuggestion]

    /// The oldest go first past this. An unanswered suggestion is the user's own correction
    /// kept on disk, and one nobody looked at in twenty dictations is not going to be.
    static let maxPending = 20

    private let prefs: AppPreferences

    init(prefs: AppPreferences = .shared) {
        self.prefs = prefs
        pending = prefs.dictionarySuggestionsData
            .flatMap { try? JSONDecoder().decode([DictionarySuggestion].self, from: $0) } ?? []
    }

    #if DEBUG
    /// Re-reads the list, for the snapshot probe, which seeds it after the store was made.
    func reload() {
        pending = prefs.dictionarySuggestionsData
            .flatMap { try? JSONDecoder().decode([DictionarySuggestion].self, from: $0) } ?? []
    }
    #endif

    /// Adds the candidates that are new, and returns them in order for the notice. A term
    /// already in the dictionary, already offered, or ever refused is left out.
    @discardableResult
    func offer(_ candidates: [DictionaryCandidates.Candidate]) -> [DictionarySuggestion] {
        var added: [DictionarySuggestion] = []
        for candidate in candidates where isNew(candidate.term)
            && !added.contains(where: { $0.id == candidate.term.lowercased() }) {
            added.append(DictionarySuggestion(term: candidate.term, heard: candidate.heard))
        }
        guard !added.isEmpty else { return [] }
        save(Array((pending + added).suffix(Self.maxPending)))
        return added
    }

    /// Whether `term` may be offered: not in the dictionary in any form, not pending, never
    /// refused.
    func isNew(_ term: String) -> Bool {
        let lowered = term.lowercased()
        let entries = prefs.customDictionaryEntries
        let inDictionary = entries.contains { entry in
            ([entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)] + entry.triggers)
                .contains { $0.lowercased() == lowered }
        }
        return !inDictionary
            && !pending.contains { $0.id == lowered }
            && !Set(prefs.dictionaryRefusedWords).contains(Self.digest(term))
    }

    /// Adds the term to the dictionary as a word: a rule that writes it as it is, which is what
    /// feeds the recognition boost and the cleanup prompt and fixes its case.
    func accept(_ suggestion: DictionarySuggestion) {
        remove(suggestion)
        guard !prefs.customDictionaryEntries.contains(where: {
            $0.trimmedReplacement.caseInsensitiveCompare(suggestion.term) == .orderedSame
        }) else { return }
        prefs.customDictionaryEntries.append(
            CustomDictionaryEntry(original: suggestion.term, replacement: suggestion.term))
        NotificationCenter.default.post(name: .customDictionaryDidChange, object: nil)
    }

    func refuse(_ suggestion: DictionarySuggestion) {
        remove(suggestion)
        neverOffer(suggestion.term)
    }

    /// A word deleted from the dictionary was a word the user did not want there: offering it
    /// back after the next correction would undo their decision.
    func noteDeleted(_ entry: CustomDictionaryEntry) {
        let term = entry.trimmedReplacement
        guard !entry.isRegex, term.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        neverOffer(term)
    }

    /// Case-insensitive, and a digest rather than the word: see `dictionaryRefusedWords`.
    static func digest(_ term: String) -> String {
        SHA256.hash(data: Data(term.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func neverOffer(_ term: String) {
        let digest = Self.digest(term)
        guard !prefs.dictionaryRefusedWords.contains(digest) else { return }
        prefs.dictionaryRefusedWords.append(digest)
    }

    private func remove(_ suggestion: DictionarySuggestion) {
        save(pending.filter { $0.id != suggestion.id })
    }

    private func save(_ suggestions: [DictionarySuggestion]) {
        pending = suggestions
        prefs.dictionarySuggestionsData = suggestions.isEmpty ? nil : try? JSONEncoder().encode(suggestions)
    }
}

extension Notification.Name {
    /// The dictionary changed outside the Dictionary page, so an open one re-reads it.
    static let customDictionaryDidChange = Notification.Name("CustomDictionaryDidChange")
}
