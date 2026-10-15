import SwiftUI
import OpenSuperWhisperCore

/// The modal editor behind a snippet row.
///
/// Edits a local copy and hands it back on Save, as the dictionary editor does: a binding into
/// the array resolves the row again on every keystroke, which traps once it is deleted.
struct SnippetEditor: View {
    let isNew: Bool
    /// The other snippets' triggers, to catch a phrase that is already taken.
    let otherTriggers: [String]
    /// The dictionary rules in force, so the test matches what a dictation would.
    let dictionary: [CustomDictionaryEntry]
    let onSave: (Snippet) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var draft: Snippet
    @State private var sample: String
    /// The test sentence is still the one written from the trigger, and follows it as it changes.
    @State private var sampleFollowsTrigger = true
    @Environment(\.textScaleFactor) private var textScale

    private static let expansionBaseHeight: CGFloat = 120
    private static let expansionMaxHeight: CGFloat = 170

    init(initial: Snippet, isNew: Bool, otherTriggers: [String], dictionary: [CustomDictionaryEntry],
         onSave: @escaping (Snippet) -> Void,
         onDelete: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.isNew = isNew
        self.otherTriggers = otherTriggers
        self.dictionary = dictionary
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose
        _draft = State(initialValue: initial)
        _sample = State(initialValue: Self.sampleSentence(for: initial.trimmedTrigger))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ViewThatFits(in: .vertical) {
                form
                ScrollView { form }
            }
            footer
        }
    }

    // MARK: - Layout

    private var header: some View {
        HStack {
            Text(isNew ? "New snippet" : "Edit snippet")
                .scaledFont(size: 22, weight: .bold)
                .foregroundColor(STheme.textBright)
            Spacer(minLength: 0)
            CloseButton(action: onClose)
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            triggerField
            expansionField
            SnippetTestBox(sample: sampleBinding, snippet: result, dictionary: dictionary)
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // A text view takes Esc for word completion, so the card's own Esc never hears it.
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !isNew {
                Button("Delete", action: onDelete)
                    .buttonStyle(.sDanger)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onClose)
                .buttonStyle(.sSecondary)
            Button("Save") { onSave(result) }
                .buttonStyle(.sPrimary)
                .disabled(!isValid)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var triggerField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("When you say")
                Spacer(minLength: 0)
                Text(verbatim: "\(draft.trigger.count) / \(Snippet.maxTriggerLength)")
                    .scaledFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundColor(draft.trigger.count >= Snippet.maxTriggerLength ? STheme.warn : STheme.faint)
            }
            TextField("", text: triggerBinding, prompt: Text("my email").foregroundColor(STheme.faint))
                .textFieldStyle(.plain)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(STheme.textBright)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(STheme.border, lineWidth: 1))
            if isTaken {
                Text("Another snippet already uses this phrase.")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(STheme.warn)
            } else {
                Text("A short phrase you would not say by accident. Any case, alone or mid-sentence.")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var expansionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Insert")
            SEditor(text: $draft.expansion,
                    height: min(Self.expansionBaseHeight * textScale, Self.expansionMaxHeight),
                    fontSize: 14, monospaced: false,
                    placeholder: "Best,\nMax")
                .accessibilityLabel(Text("Insert"))
            Text("Written exactly as you type it here, line breaks included.")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(STheme.textBright)
    }

    // MARK: - Logic

    /// Typing past the limit stops at it, and a pasted line break would make a trigger nobody
    /// can say, so it becomes a space.
    private var triggerBinding: Binding<String> {
        Binding(
            get: { draft.trigger },
            set: { typed in
                let flattened = typed.replacingOccurrences(of: "\\R", with: " ", options: .regularExpression)
                draft.trigger = String(flattened.prefix(Snippet.maxTriggerLength))
                if sampleFollowsTrigger {
                    sample = Self.sampleSentence(for: draft.trimmedTrigger)
                }
            })
    }

    private var sampleBinding: Binding<String> {
        Binding(
            get: { sample },
            set: {
                sample = $0
                sampleFollowsTrigger = false
            })
    }

    /// The snippet Save would store: both halves without the spaces and blank lines at their
    /// ends, which nobody sees in the fields.
    private var result: Snippet {
        var snippet = draft
        snippet.trigger = draft.trimmedTrigger
        snippet.expansion = draft.trimmedExpansion
        return snippet
    }

    private var isTaken: Bool {
        let trigger = draft.trimmedTrigger
        return !trigger.isEmpty
            && otherTriggers.contains { $0.caseInsensitiveCompare(trigger) == .orderedSame }
    }

    private var isValid: Bool {
        result.isComplete && !isTaken
    }

    /// The trigger as a sentence of its own after another one, the way the cleanup model hands
    /// it back: capitalised and closed by a period, both of which the expansion takes care of.
    private static func sampleSentence(for trigger: String) -> String {
        guard let first = trigger.first else { return "" }
        let spoken = first.uppercased() + trigger.dropFirst()
        return String(localized: "Thanks again. \(spoken).")
    }
}
