import Foundation

/// The words recognition is biased toward: the Whisper prompt and Parakeet's vocabulary boost.
///
/// Two lists feed it, each behind its own switch: the dictionary's written forms and the snippet
/// triggers (#167). A snippet only fires when its trigger is heard word for word, so helping the
/// model hear it is worth having, but boosting is off by default for both: on Parakeet any boost
/// at all moves the file pass from the offline decoder to the sliding-window one.
public enum RecognitionBoost {

    /// Both lists, the dictionary first, without repeating a term that differs only in case.
    public static func terms(dictionary: [String], snippets: [String]) -> [String] {
        var seen = Set<String>()
        return (dictionary + snippets).filter { seen.insert($0.lowercased()).inserted }
    }
}

extension CorePreferences {
    /// What the engines reading preferences directly (Parakeet's file pass, the live preview)
    /// should boost. `TranscriptionSettings.recognitionBoostTerms` is the same for a clip.
    public var recognitionBoostTerms: [String] {
        let dictionary = customDictionaryEnabled && customDictionaryBoostEnabled
            ? CustomDictionary.boostTerms(entries: customDictionaryEntries) : []
        let snippets = snippetsEnabled && snippetsBoostEnabled
            ? SnippetExpander.boostTerms(self.snippets) : []
        return RecognitionBoost.terms(dictionary: dictionary, snippets: snippets)
    }
}
