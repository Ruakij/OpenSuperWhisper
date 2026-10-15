import SwiftUI
import OpenSuperWhisperCore

/// An example sentence and what the snippet makes of it, computed by `SnippetExpander`, the same
/// code the dictation pipeline runs. The dictionary editor's test box, for snippets.
struct SnippetTestBox: View {
    @Binding var sample: String
    let snippet: Snippet
    let dictionary: [CustomDictionaryEntry]

    private var found: [SnippetExpander.Expansion] {
        SnippetExpander.expansions(in: sample, snippets: [snippet], dictionary: dictionary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test")
                .scaledFont(size: 11, weight: .bold)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundColor(STheme.hint)
            TextField("Type a sentence to try", text: $sample)
                .textFieldStyle(.plain)
                .scaledFont(size: 14)
                .foregroundColor(STheme.textBright)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
            // An unfinished snippet finds nothing, and the sentence repeated twice under itself
            // would say nothing either.
            if !snippet.isComplete {
                EmptyView()
            } else if found.isEmpty {
                if !sample.isEmpty {
                    Text("The trigger is not in this sentence.")
                        .scaledFont(size: 14)
                        .foregroundColor(STheme.hint)
                }
            } else {
                Text(SnippetPreview.matched(in: sample, found))
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SnippetPreview.result(of: sample, found))
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.textBright)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(STheme.fill))
    }
}

/// Builds the two lines of the test box from the spans `SnippetExpander` found.
enum SnippetPreview {

    /// The sentence with what the snippet replaces struck through, punctuation dropped with the
    /// trigger included.
    static func matched(in sample: String, _ found: [SnippetExpander.Expansion]) -> AttributedString {
        assemble(sample, found) { expansion in
            var struck = AttributedString(String(sample[expansion.range]))
            struck.strikethroughStyle = .single
            return struck
        }
    }

    /// The sentence as it would be inserted, the snippet's text highlighted. Line breaks are
    /// shown as they will be written: a signature is a block, not a line.
    static func result(of sample: String, _ found: [SnippetExpander.Expansion]) -> AttributedString {
        assemble(sample, found) { expansion in
            var inserted = AttributedString(expansion.snippet.trimmedExpansion)
            inserted.foregroundColor = STheme.accent
            inserted.backgroundColor = STheme.accentSoft
            inserted.inlinePresentationIntent = .stronglyEmphasized
            return inserted
        }
    }

    private static func assemble(_ sample: String, _ found: [SnippetExpander.Expansion],
                                 replacing piece: (SnippetExpander.Expansion) -> AttributedString) -> AttributedString {
        var out = AttributedString()
        var cursor = sample.startIndex
        for expansion in found {
            out += AttributedString(String(sample[cursor..<expansion.range.lowerBound]))
            out += piece(expansion)
            cursor = expansion.range.upperBound
        }
        out += AttributedString(String(sample[cursor...]))
        return out
    }
}
