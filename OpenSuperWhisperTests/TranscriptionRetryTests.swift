import XCTest

@testable import OpenSuperWhisper

/// A failed transcription gets one more try before the dictation is reported as failed.
final class TranscriptionRetryTests: XCTestCase {

    private struct EngineError: Error {}

    /// Counts attempts and fails the first `failures` of them.
    private final class Engine: @unchecked Sendable {
        var attempts = 0
        let failures: Int
        init(failures: Int) { self.failures = failures }
        func transcribe() async throws -> String {
            attempts += 1
            if attempts <= failures { throw EngineError() }
            return "hello"
        }
    }

    func testASingleFailureIsRetried() async throws {
        let engine = Engine(failures: 1)
        let text = try await DictationPipeline.retryingOnce { try await engine.transcribe() }
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(engine.attempts, 2)
    }

    func testASecondFailureIsReported() async {
        let engine = Engine(failures: 2)
        do {
            _ = try await DictationPipeline.retryingOnce { try await engine.transcribe() }
            XCTFail("expected the second error")
        } catch {
            XCTAssertTrue(error is EngineError)
        }
        XCTAssertEqual(engine.attempts, 2)
    }

    func testASuccessRunsOnce() async throws {
        let engine = Engine(failures: 0)
        _ = try await DictationPipeline.retryingOnce { try await engine.transcribe() }
        XCTAssertEqual(engine.attempts, 1)
    }

    func testADiscardedDictationIsNotRetried() async {
        let engine = Engine(failures: 1)
        _ = try? await DictationPipeline.retryingOnce(stop: { true }) { try await engine.transcribe() }
        XCTAssertEqual(engine.attempts, 1)
    }

    func testACancellationIsNotRetried() async {
        var attempts = 0
        _ = try? await DictationPipeline.retryingOnce {
            attempts += 1
            throw CancellationError()
        }
        XCTAssertEqual(attempts, 1)
    }
}
