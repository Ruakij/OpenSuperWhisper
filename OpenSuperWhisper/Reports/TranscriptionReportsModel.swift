import Foundation
import OpenSuperWhisperCore

/// The saved reports, for the Reports card and the count on Home (#168). Everything stays on
/// this Mac: saving copies the audio next to the database, exporting writes a zip where the user
/// asked, and the GitHub link is opened by the card only on a click.
@MainActor
final class TranscriptionReportsModel: ObservableObject {
    static let shared = TranscriptionReportsModel(store: RecordingStore.shared)

    @Published private(set) var reports: [TranscriptionReport] = []

    private let store: RecordingStore
    private let appDetails: @MainActor () -> String
    private let languageSetting: @MainActor () -> String?
    private var observer: NSObjectProtocol?

    init(store: RecordingStore,
         appDetails: @escaping @MainActor () -> String = { FeedbackAppDetails.current(includingModel: false) },
         languageSetting: @escaping @MainActor () -> String? = { AppPreferences.shared.whisperLanguage }) {
        self.store = store
        self.appDetails = appDetails
        self.languageSetting = languageSetting
        observer = NotificationCenter.default.addObserver(
            forName: RecordingStore.reportsDidUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() async {
        reports = (try? await store.fetchReports()) ?? []
    }

    /// Saves the draft as a report on `recording`, with its own copy of the recording's audio.
    func save(_ draft: ReportDraft, for recording: Recording) async throws {
        guard let report = draft.report(for: recording, languageSetting: languageSetting(),
                                        appDetails: appDetails()) else { return }
        try await store.saveReport(report, audioFrom: recording.url)
        await refresh()
    }

    func delete(_ report: TranscriptionReport) async {
        try? await store.deleteReport(report)
        await refresh()
    }

    /// Writes every report into one zip at `destination`, off the main thread: the audio copies
    /// can add up.
    func export(to destination: URL) async throws {
        let reports = reports
        let exportedWith = appDetails()
        try await Task.detached(priority: .userInitiated) {
            try TranscriptionReportArchive.write(reports, to: destination, exportedWith: exportedWith)
        }.value
    }
}
