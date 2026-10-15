import CryptoKit
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
    ///
    /// A snippet stored without an id gets one derived from its content, the same on every
    /// read: a fresh one each time would make the page see a new snippet on every refresh, and
    /// the editor treat an existing one as unsaved.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        expansion = try container.decodeIfPresent(String.self, forKey: .expansion) ?? ""
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
            ?? Self.stableID(trigger: trigger, expansion: expansion)
    }

    private static func stableID(trigger: String, expansion: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data((trigger + "\u{0}" + expansion).utf8)))
        // Marked as a name-based UUID (version 3, RFC 4122 variant), which is what this is.
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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
    ///
    /// The trigger also needs a letter or a digit. One made of symbols is nothing anyone says,
    /// and since it has no word edges it would fire inside any text holding it: "@" would
    /// rewrite every email address.
    public var isComplete: Bool {
        hasSayableTrigger && !trimmedExpansion.isEmpty
    }

    public var hasSayableTrigger: Bool {
        trimmedTrigger.rangeOfCharacter(from: .alphanumerics) != nil
    }

    /// The trigger as matching sees it: without the marks typed at its end, case folded,
    /// hyphens and runs of spaces as one space, one apostrophe for all. Two snippets with the
    /// same key fire on the same words, so only the first would ever be used.
    public var triggerKey: String {
        SnippetPunctuation.trimmingTrailingMarks(trimmedTrigger)
            .lowercased()
            .replacingOccurrences(of: "[\\s\\-‐‑]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[’ʼ]", with: "'", options: .regularExpression)
    }
}
