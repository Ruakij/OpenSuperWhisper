import Foundation

/// A phrase that, once dictated, is replaced by a longer text: "my email" gives the address,
/// "sign off" a three-line signature (#167).
///
/// Not a dictionary rule with a long replacement. A rule is built for fixing words: one line to
/// type in, matched before the cleanup model runs, which may then rewrite it. A snippet is text
/// the user wrote once and wants back exactly, so it is expanded after the cleanup (see
/// `SnippetExpander`).
public struct Snippet: Codable, Identifiable, Equatable, Hashable, Sendable {

    /// Long enough for any phrase someone would say as a shortcut, short enough that a trigger
    /// stays a trigger: past a sentence or so, the odds of saying it word for word fall apart.
    public static let maxTriggerLength = 60

    public var id: UUID
    /// What the user says, matched as whole words regardless of case.
    public var trigger: String
    /// What is inserted instead, verbatim, line breaks included.
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String = "", expansion: String = "") {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }

    /// Hand-written so a snippet saved by a later version with more fields still loads here, and
    /// one with a missing field loads as blank rather than throwing: the array is decoded as a
    /// whole, so one entry that throws would lose every snippet.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        expansion = try container.decodeIfPresent(String.self, forKey: .expansion) ?? ""
    }

    public var trimmedTrigger: String {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The expansion without the blank lines and spaces at its ends, which nobody sees in the
    /// editor and would otherwise land in the document.
    public var trimmedExpansion: String {
        expansion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both halves filled in. A snippet missing either does nothing: an empty expansion would
    /// silently delete the phrase from every dictation, which is never what an unfinished row
    /// means.
    public var isComplete: Bool {
        !trimmedTrigger.isEmpty && !trimmedExpansion.isEmpty
    }
}
