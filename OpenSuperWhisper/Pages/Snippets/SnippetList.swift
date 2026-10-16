import SwiftUI
import OpenSuperWhisperCore

/// One row per snippet: what you say, the start of what is written, its length, and a menu.
struct SnippetList: View {
    let snippets: [Snippet]
    let dimmed: Bool
    let onEdit: (Snippet) -> Void
    let onDelete: (Snippet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Iterated by value: a binding into the array would resolve a deleted row.
            ForEach(snippets) { snippet in
                SnippetRow(snippet: snippet,
                           onEdit: { onEdit(snippet) },
                           onDelete: { onDelete(snippet) })
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    /// Lines of the snippet's text the row shows before cutting it short.
    private static let previewLines = 2

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(verbatim: snippet.trimmedTrigger)
                .scaledFont(size: 15, weight: .bold)
                .foregroundColor(STheme.textBright)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
            Text(verbatim: snippet.trimmedExpansion)
                .scaledFont(size: 13)
                .foregroundColor(STheme.textSecondary)
                .lineLimit(Self.previewLines)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            lengthTag
            menu
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(hovering ? STheme.accentTint : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Edit"), onEdit)
    }

    private var lineCount: Int {
        snippet.trimmedExpansion.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    /// A block of several lines is worth knowing about before it lands in a chat box.
    private var lengthTag: some View {
        Group {
            if lineCount > 1 {
                Text("\(lineCount) lines")
            } else {
                Text("One line")
            }
        }
        .scaledFont(size: 12, weight: .semibold)
        .foregroundColor(lineCount > 1 ? STheme.accent : STheme.hint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(lineCount > 1 ? STheme.accentSoft : STheme.fill))
        .fixedSize()
        .frame(minWidth: 84, alignment: .leading)
    }

    private var menu: some View {
        Menu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(STheme.hint)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}
