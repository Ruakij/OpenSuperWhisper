import Foundation
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
    /// Where the caret was in `latest`, in UTF-16 units, when it was inside or at its end.
    private(set) var caret: Int?

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
    ///
    /// - Parameter caret: where the caret is in the field, for `settled(_:)`.
    mutating func read(_ text: String?, windowStart: Int, caret fieldCaret: Int? = nil) -> Next {
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
        caret = fieldCaret.map { $0 - start }.flatMap { (0...range.length).contains($0) ? $0 : nil }
        return .watching
    }

    /// `edited` without the word the caret is in or at the end of: one the user was still
    /// typing when the watch ended, the focus already elsewhere or the minute up. Half a word
    /// is not a spelling to learn.
    func settled(_ edited: String) -> String {
        guard let caret else { return edited }
        return Self.droppingWord(at: caret, in: edited)
    }

    static func droppingWord(at caret: Int, in text: String) -> String {
        let field = text as NSString
        guard caret > 0, caret <= field.length else { return text }
        func isWordUnit(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(field.character(at: index)) else { return true }
            return !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        guard isWordUnit(caret - 1) else { return text }
        var start = caret - 1
        while start > 0, isWordUnit(start - 1) { start -= 1 }
        var end = caret
        while end < field.length, isWordUnit(end) { end += 1 }
        return field.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
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
