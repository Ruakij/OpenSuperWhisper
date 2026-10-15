#if DEBUG
import Foundation
import OpenSuperWhisperCore

extension UISnapshotProbe {
    /// Made-up snippets for the Snippets screens, written to the isolated preferences before the
    /// page's view model reads them. `empty` shows the page before the first one.
    static func seedSnippets(openEditor: Bool = false, empty: Bool = false) {
        AppPreferences.shared.snippetsEnabled = true
        AppPreferences.shared.snippets = empty ? [] : [
            Snippet(trigger: "my email", expansion: "camille.martin@example.com"),
            Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/camille/30min"),
            Snippet(trigger: "sign off",
                    expansion: "Best,\nCamille Martin\nProduct designer, Example Studio"),
            Snippet(trigger: "office address",
                    expansion: "Example Studio\n12 rue de la Paix\n75002 Paris"),
            Snippet(trigger: "standup update",
                    expansion: "Yesterday: \nToday: \nBlocked by: "),
        ]
        SnippetsPage.snapshotOpensFirstSnippet = openEditor
    }
}
#endif
