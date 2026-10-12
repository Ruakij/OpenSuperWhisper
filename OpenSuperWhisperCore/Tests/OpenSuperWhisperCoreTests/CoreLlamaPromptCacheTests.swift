import XCTest
@testable import OpenSuperWhisperCore

/// The decoded system prompt is reused across calls. Reads the model only from `OSW_TEST_GGUF`
/// (`TEST_RUNNER_OSW_TEST_GGUF` through xcodebuild) and skips without it, so CI never runs these.
final class CoreLlamaPromptCacheTests: CoreTestCase {

    private let system = "Fix punctuation and capitalization. Reply with the corrected text only."
    private let user = "so yesterday i went to the store and bought three apples"

    func testSecondCallReusesThePrefixAndAnswersLikeAFreshContext() throws {
        let path = try requireModel()
        let cached = try XCTUnwrap(LlamaContext(modelPath: path, gpuLayers: 0))

        _ = cached.generate(system: system, user: "warm up", maxTokens: 64)
        XCTAssertEqual(cached.reusedPrefixTokens, 0)

        let second = cached.generate(system: system, user: user, maxTokens: 64)
        XCTAssertGreaterThan(cached.reusedPrefixTokens, 0)
        XCTAssertFalse(second.isEmpty, "a reply cut off by the budget comes back empty")

        let fresh = try XCTUnwrap(LlamaContext(modelPath: path, gpuLayers: 0))
        XCTAssertEqual(second, fresh.generate(system: system, user: user, maxTokens: 64))
    }

    func testChangedSystemPromptDoesNotReuseTheOldPrefix() throws {
        let path = try requireModel()
        let context = try XCTUnwrap(LlamaContext(modelPath: path, gpuLayers: 0))

        _ = context.generate(system: system, user: user, maxTokens: 64)
        _ = context.generate(system: system + " Keep the language.", user: user, maxTokens: 64)
        XCTAssertEqual(context.reusedPrefixTokens, 0)
    }

    private func requireModel() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OSW_TEST_GGUF"], !path.isEmpty else {
            throw XCTSkip("OSW_TEST_GGUF is not set")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw XCTSkip("OSW_TEST_GGUF does not name a readable file: \(path)")
        }
        return path
    }
}
