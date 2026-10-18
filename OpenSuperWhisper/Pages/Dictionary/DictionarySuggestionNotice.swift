import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// The small notice that offers a corrected word for the dictionary after a dictation (#169):
/// "Add “Rsets” to your dictionary?", with Add and Not this one.
///
/// A floating panel in the bottom-right corner, away from the notifications and the agent panel
/// at the top. It never takes the focus, so the user keeps typing where they were; its buttons
/// take the first click. Left alone it goes after `lifetime`, and the word waits in the
/// Dictionary's Suggested list: only an answer settles it.
@MainActor
final class DictionarySuggestionNotice {
    static let shared = DictionarySuggestionNotice()

    static let width: CGFloat = 380
    static let margin: CGFloat = 16
    static let lifetime: Duration = .seconds(20)
    /// Asked again this long after `lifetime` while the pointer rests on the notice.
    static let hoverGrace: Duration = .seconds(5)

    private var panel: NSPanel?
    /// The suggestions of the last dictation still to show, the one on screen first.
    private var queue: [DictionarySuggestion] = []
    private var expiry: Task<Void, Never>?

    private init() {}

    func present(_ suggestions: [DictionarySuggestion]) {
        guard !suggestions.isEmpty else { return }
        // A newer dictation's words replace the older ones on screen; those stay in the list.
        queue = suggestions
        showFirst()
    }

    private func answer(_ suggestion: DictionarySuggestion, add: Bool) {
        let store = DictionarySuggestions.shared
        // Answered in the Dictionary page while the notice was up: that answer stands.
        if store.pending.contains(where: { $0.id == suggestion.id }) {
            if add { store.accept(suggestion) } else { store.refuse(suggestion) }
        }
        queue.removeAll { $0.id == suggestion.id }
        showFirst()
    }

    /// Closes without answering: the word stays in the Suggested list.
    private func dismiss() {
        queue = []
        expiry?.cancel()
        panel?.orderOut(nil)
    }

    private func showFirst() {
        // Answered in the Dictionary page meanwhile: nothing left to ask.
        queue.removeAll { suggestion in !DictionarySuggestions.shared.pending.contains { $0.id == suggestion.id } }
        guard let suggestion = queue.first else { return dismiss() }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = FirstClickHostingView(rootView: DictionarySuggestionCard(
            suggestion: suggestion,
            onAdd: { [weak self] in self?.answer(suggestion, add: true) },
            onRefuse: { [weak self] in self?.answer(suggestion, add: false) },
            onClose: { [weak self] in self?.dismiss() })
            .environment(\.appTextScale, AppPreferences.shared.textScale))
        // Sized once from the content, never by the hosting view itself: the indicator's
        // auto-resize recursion on macOS 26 is reason enough not to let a floating panel do it.
        host.sizingOptions = []
        panel.contentView = host
        // Measured by asking the content, not read from the view: with its sizing options off,
        // a hosting view reports a zero fitting size, and the panel came out 0 points tall.
        let size = NSHostingController(rootView: DictionarySuggestionCard(
            suggestion: suggestion, onAdd: {}, onRefuse: {}, onClose: {})
            .environment(\.appTextScale, AppPreferences.shared.textScale))
            .sizeThatFits(in: CGSize(width: Self.width, height: CGFloat.greatestFiniteMagnitude))
        panel.setContentSize(NSSize(width: Self.width, height: ceil(size.height)))
        place(panel)
        panel.orderFrontRegardless()
        announce(suggestion)
        scheduleExpiry(after: Self.lifetime)
    }

    /// The panel never takes the focus, so VoiceOver would not read it on its own.
    private func announce(_ suggestion: DictionarySuggestion) {
        let text = String(localized: "Add “\(suggestion.term)” to your dictionary?")
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func scheduleExpiry(after delay: Duration) {
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let panel = self.panel, panel.isVisible else { return }
            if panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleExpiry(after: Self.hoverGrace)
            } else {
                self.dismiss()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }

    /// On the screen under the pointer, which is where the user is working: the screen with the
    /// menu bar can be another display altogether.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - Self.margin,
                                     y: visible.minY + Self.margin))
    }
}

/// The notice's card. Also drawn by the snapshot probe.
struct DictionarySuggestionCard: View {
    let suggestion: DictionarySuggestion
    let onAdd: () -> Void
    let onRefuse: () -> Void
    let onClose: () -> Void

    /// Transparent margin inside the borderless panel, for the card's shadow.
    static let shadowRoom: CGFloat = 14

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "character.book.closed")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundColor(STheme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(STheme.accentSoft))
            VStack(alignment: .leading, spacing: 4) {
                Text("Add “\(suggestion.term)” to your dictionary?")
                    .scaledFont(size: 14.5, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                    .fixedSize(horizontal: false, vertical: true)
                Text(suggestion.correctsHeard
                     ? "From now on, “\(suggestion.heard)” will be written “\(suggestion.term)”."
                     : "You wrote it in place of “\(suggestion.heard)”.")
                    .scaledFont(size: 12.5)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Add", action: onAdd)
                        .buttonStyle(.sPrimary)
                    Button("Not this one", action: onRefuse)
                        .buttonStyle(.sSecondary)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundColor(STheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(STheme.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .help("Decide later, from Suggested in the Dictionary")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(STheme.cardBg)
            .shadow(color: .black.opacity(0.16), radius: 12, y: 5))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(STheme.border, lineWidth: 1))
        .padding(Self.shadowRoom)
        .frame(width: DictionarySuggestionNotice.width)
    }
}
