import SwiftUI
import OpenSuperWhisperCore

/// The Suggested list: words offered from the corrections made after a dictation (#169), each
/// with what the engine had written and the same two answers as the notice.
struct DictionarySuggestionList: View {
    @ObservedObject var suggestions: DictionarySuggestions
    let emptyMessage: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if suggestions.pending.isEmpty {
                Text(emptyMessage)
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 28)
            }
            // Newest first: the word just corrected is the one the user remembers.
            ForEach(suggestions.pending.reversed()) { suggestion in
                DictionarySuggestionRow(suggestion: suggestion,
                                        onAdd: { suggestions.accept(suggestion) },
                                        onRefuse: { suggestions.refuse(suggestion) })
            }
        }
    }
}

private struct DictionarySuggestionRow: View {
    let suggestion: DictionarySuggestion
    let onAdd: () -> Void
    let onRefuse: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(verbatim: suggestion.term)
                .scaledFont(size: 15, weight: .bold)
                .foregroundColor(STheme.textBright)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
            HStack(spacing: 6) {
                Text("Heard as")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize()
                Text(verbatim: suggestion.heard)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(STheme.fill))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Not this one", action: onRefuse)
                .buttonStyle(.sSecondary)
            Button("Add", action: onAdd)
                .buttonStyle(.sPrimary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }
}
