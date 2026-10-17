import SwiftUI
import OpenSuperWhisperCore

/// Settings › General › Backup and sync: a settings file to export and import, and the same file
/// kept in a secret gist for moving between Macs.
struct SettingsTransferGroup: View {
    @StateObject private var model = SettingsTransferModel()

    var body: some View {
        SettingsGroup("Backup and sync") {
            SettingRow("Settings file",
                       hint: "Your preferences, dictionary and snippets in one file. API keys stay in this Mac's Keychain.") {
                HStack(spacing: 8) {
                    Button("Export…") { model.exportFile() }
                    Button("Import…") { model.importFile() }
                }
                .buttonStyle(.sSecondary)
                .disabled(model.isBusy)
            }
            githubRow
            notices
        }
        .onAppear { model.refreshGitHub() }
        .confirmationDialog(importTitle, isPresented: Binding(
            get: { model.pendingImport != nil },
            set: { if !$0 { model.pendingImport = nil } })) {
            Button("Replace my settings") { model.confirmImport() }
            Button("Cancel", role: .cancel) { model.pendingImport = nil }
        } message: {
            Text("Settings that are not in the file stay as they are. A relaunch applies the new ones.")
        }
    }

    @ViewBuilder
    private var githubRow: some View {
        switch model.github {
        case .signedOut:
            SettingRow("GitHub sync", hint: "Keeps a copy in a secret gist on your GitHub account, to fetch on another Mac.") {
                Button("Sign in with GitHub") { model.signIn() }
                    .buttonStyle(.sSecondary)
            }
        case .signingIn(let code):
            SettingRow("GitHub sync", hint: "Enter this code on github.com, then come back here.") {
                Text(code.userCode)
                    .scaledFont(size: 15, weight: .semibold)
                    .monospaced()
                    .textSelection(.enabled)
            }
            SettingNotice("Waiting for GitHub…") {
                HStack(spacing: 8) {
                    Button("Cancel") { model.cancelSignIn() }
                        .buttonStyle(.sSecondary)
                    Button("Copy code and open GitHub") { model.copyCodeAndOpenGitHub() }
                        .buttonStyle(.sPrimary)
                }
            }
        case .signedIn(let login):
            SettingRow("GitHub sync", hint: signedInHint(login), stacked: true) {
                HStack(spacing: 8) {
                    Button("Send") { model.send() }
                    Button("Fetch") { model.fetch() }
                    Button("Sign out") { model.signOut() }
                        .buttonStyle(.sQuiet)
                }
                .buttonStyle(.sSecondary)
                .disabled(model.isBusy)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.needsRelaunch {
            SettingNotice("Settings imported. Relaunch to apply them.") {
                Button("Relaunch now") { LanguageManager.relaunch() }
                    .buttonStyle(.sPrimary)
            }
        } else if let error = model.errorMessage {
            SettingNotice(LocalizedStringKey(error))
        } else if let status = model.status {
            SettingNotice(status)
        }
    }

    private func signedInHint(_ login: String) -> LocalizedStringKey {
        login.isEmpty
            ? "Send saves this Mac's settings to your gist. Fetch replaces them with the saved copy."
            : "Signed in as @\(login). Send saves this Mac's settings to your gist. Fetch replaces them with the saved copy."
    }

    private var importTitle: LocalizedStringKey {
        guard let savedAt = model.pendingImport?.savedAt else { return "Replace your settings with this file?" }
        return "Replace your settings with the copy saved \(savedAt.formatted(.relative(presentation: .named)))?"
    }
}
