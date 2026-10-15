import GRDB
import XCTest

@testable import OpenSuperWhisperCore

/// What happens to a dictation's kept original when the queue rewrites the row (#168). An import
/// or a rerun stores its own text as the original, since that text is the engine's; a progress
/// update that does not finish anything leaves the original alone.
@MainActor
final class RecordingOriginalTextTests: CoreTestCase {

    private var queue: DatabaseQueue!
    private var store: RecordingStore!
    private var recording: Recording!

    override func setUp() async throws {
        queue = try DatabaseQueue()
        store = try RecordingStore(databaseQueue: queue)
        recording = Recording(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_760_000_000), fileName: "r.wav",
                              transcription: "Send the mockups.", duration: 2, status: .completed, progress: 1,
                              rawTranscription: "um send the mock ups")
        let recording = recording!
        try await queue.write { db in try recording.insert(db) }
    }

    private func stored() async throws -> Recording? {
        let id = recording.id
        return try await queue.read { db in try Recording.filter(Recording.Columns.id == id).fetchOne(db) }
    }

    /// The progress notification for one update, caught while `update` runs.
    private func notification(during update: () async -> Void) async throws -> [AnyHashable: Any] {
        var caught: [AnyHashable: Any]?
        let observer = NotificationCenter.default.addObserver(
            forName: RecordingStore.recordingProgressDidUpdateNotification, object: nil, queue: nil
        ) { caught = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(observer) }
        await update()
        return try XCTUnwrap(caught)
    }

    func testARerunStoresItsOwnTextAsTheOriginal() async throws {
        let info = try await notification {
            await store.updateRecordingProgressOnlySync(recording.id, transcription: "Send the mock-ups.",
                                                        progress: 1, status: .completed,
                                                        rawTranscription: "Send the mock-ups.")
        }

        let row = try await stored()
        XCTAssertEqual(row?.transcription, "Send the mock-ups.")
        XCTAssertEqual(row?.rawTranscription, "Send the mock-ups.")
        XCTAssertNil(row?.distinctOriginal, "nothing left to offer: the text is the engine's")
        XCTAssertEqual(info["rawTranscription"] as? String, "Send the mock-ups.")
    }

    func testAnUpdateWithoutAnOriginalKeepsTheOneStored() async throws {
        let info = try await notification {
            await store.updateRecordingProgressOnlySync(recording.id, transcription: "Send the mockups.",
                                                        progress: 0.5, status: .transcribing)
        }

        let row = try await stored()
        XCTAssertEqual(row?.rawTranscription, "um send the mock ups")
        XCTAssertNil(info["rawTranscription"])
    }

    /// A report on such a row says "same as before cleanup", not "not kept".
    func testAReportOnARerunHasTheSameTextBeforeCleanup() async throws {
        await store.updateRecordingProgressOnlySync(recording.id, transcription: "Rerun text", progress: 1,
                                                    status: .completed, rawTranscription: "Rerun text")
        let fetched = try await stored()
        let row = try XCTUnwrap(fetched)

        let report = TranscriptionReport(recording: row, problem: .other, languageSetting: nil, appDetails: "x")

        XCTAssertEqual(report.rawText, "Rerun text")
        XCTAssertNil(report.distinctRawText)
    }
}
