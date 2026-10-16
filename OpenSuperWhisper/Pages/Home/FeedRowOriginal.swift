import AppKit
import SwiftUI

/// "Original ⌄" on the meta line of a dictation the cleanup changed (#168): filler words taken
/// out, or the AI rewriting it. Quiet, since with the cleanup on most rows have one.
struct FeedRowOriginalToggle: View {
    @Binding var isShown: Bool

    var body: some View {
        Button { isShown.toggle() } label: {
            HStack(spacing: 3) {
                Text("Original")
                Image(systemName: isShown ? "chevron.up" : "chevron.down")
                    .scaledFont(size: 9, weight: .semibold)
            }
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(isShown ? STheme.accent : STheme.hint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the text as the engine wrote it, before the cleanup")
        .fixedSize()
    }
}

/// The engine's own text under the one the user got, and the button that copies it. Both texts
/// stay in the history; nothing is replaced.
struct FeedRowOriginalText: View {
    let original: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1).fill(STheme.border).frame(width: 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("Before cleanup")
                    .scaledFont(size: 11, weight: .bold)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(STheme.hint)
                Text(verbatim: original)
                    .scaledFont(size: 14)
                    .lineSpacing(2)
                    .foregroundColor(STheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy original",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.sSecondary)
                .help("Copy this text, to paste it where the cleaned one went")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
