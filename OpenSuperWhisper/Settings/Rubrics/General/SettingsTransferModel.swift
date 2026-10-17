import AppKit
import OpenSuperWhisperCore
import SwiftUI
import UniformTypeIdentifiers

/// Export and import of the settings file, and its copy in a GitHub gist. Imported values take
/// effect after a relaunch: shortcuts, the engine and the bubble are all set up at launch.
@MainActor
final class SettingsTransferModel: ObservableObject {
    enum GitHubState: Equatable {
        case signedOut
        case signingIn(GitHubSettingsSync.DeviceCode)
        case signedIn(login: String)
    }

    struct PendingImport {
        let values: [String: Any]
        let savedAt: Date?
    }

    @Published private(set) var github: GitHubState = .signedOut
    @Published private(set) var isBusy = false
    @Published private(set) var status: LocalizedStringKey?
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsRelaunch = false
    @Published var pendingImport: PendingImport?

    private let sync = GitHubSettingsSync()
    private var signInTask: Task<Void, Never>?

    private var token: String? { Keychain.read(GitHubSettingsSync.tokenAccount) }

    func refreshGitHub() {
        guard case .signedOut = github, let token else { return }
        github = .signedIn(login: "")
        Task {
            do {
                github = .signedIn(login: try await sync.login(token: token))
            } catch GitHubSettingsSync.SyncError.signedOut {
                signOut()
            } catch {}
        }
    }

    // MARK: - File

    func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = SettingsArchive.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            try self.exported().write(to: url, options: .atomic)
            self.status = "Settings saved to \(url.lastPathComponent)."
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            let values = try SettingsArchive.read(try Data(contentsOf: url))
            self.pendingImport = PendingImport(values: values, savedAt: nil)
        }
    }

    func confirmImport() {
        guard let pending = pendingImport else { return }
        SettingsArchive.apply(pending.values, to: DefaultsStore.current)
        pendingImport = nil
        status = nil
        needsRelaunch = true
    }

    // MARK: - GitHub

    func signIn() {
        signInTask?.cancel()
        signInTask = Task {
            do {
                let code = try await sync.requestDeviceCode()
                github = .signingIn(code)
                try await waitForApproval(code)
            } catch is CancellationError {
            } catch {
                github = .signedOut
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        github = .signedOut
    }

    func copyCodeAndOpenGitHub() {
        guard case .signingIn(let code) = github else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        NSWorkspace.shared.open(code.verificationURL)
    }

    func signOut() {
        Keychain.set(nil, for: GitHubSettingsSync.tokenAccount)
        github = .signedOut
    }

    func send() {
        guard let token else { return signOut() }
        run {
            try await self.sync.upload(try self.exported(), token: token)
            self.status = "Settings sent to GitHub."
        }
    }

    func fetch() {
        guard let token else { return signOut() }
        run {
            guard let remote = try await self.sync.fetch(token: token) else {
                throw GitHubSettingsSync.SyncError.nothingSaved
            }
            let values = try SettingsArchive.read(remote.content)
            self.pendingImport = PendingImport(values: values, savedAt: remote.updatedAt)
        }
    }

    private func waitForApproval(_ code: GitHubSettingsSync.DeviceCode) async throws {
        var interval = code.interval
        let deadline = Date().addingTimeInterval(code.expiresIn)
        polling: while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            switch try await sync.poll(code) {
            case .token(let token):
                Keychain.set(token, for: GitHubSettingsSync.tokenAccount)
                github = .signedIn(login: (try? await sync.login(token: token)) ?? "")
                status = "Signed in to GitHub."
                return
            case .pending:
                continue
            case .slowDown:
                // GitHub asks for five more seconds between polls each time it says this.
                interval += 5
            case .denied:
                github = .signedOut
                return
            case .expired:
                break polling
            }
        }
        github = .signedOut
        errorMessage = String(localized: "The GitHub code expired. Sign in again.")
    }

    // MARK: - Helpers

    private func exported() throws -> Data {
        try SettingsArchive.export(from: DefaultsStore.current, appVersion: UpdateChecker.currentVersion)
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        status = nil
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do {
                try await work()
            } catch GitHubSettingsSync.SyncError.signedOut {
                signOut()
                errorMessage = GitHubSettingsSync.SyncError.signedOut.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
