import XCTest
@testable import OpenSuperWhisperCore

/// The decoded system prompt is reused across calls. Reads the model only from `OSW_TEST_GGUF`
/// (`TEST_RUNNER_OSW_TEST_GGUF` through xcodebuild) and skips without it, so CI never runs these.
final class CoreLlamaPromptCacheTests: CoreTestCase {

    private let system = "Fix punctuation and capitalization. Reply with the corrected text only."
    private let user = "so yesterday i went to the store and bought three apples"

    func testSecondCallReusesThePrefix() throws {
        let path = try requireModel().path
        let context = try XCTUnwrap(LlamaContext(modelPath: path, gpuLayers: 0))

        _ = context.generate(system: system, user: "warm up", maxTokens: 64)
        XCTAssertEqual(context.reusedPrefixTokens, 0)

        let second = context.generate(system: system, user: user, maxTokens: 64)
        XCTAssertGreaterThan(context.reusedPrefixTokens, 0)
        XCTAssertFalse(second.isEmpty, "a reply cut off by the budget comes back empty")
    }

    func testChangedSystemPromptDoesNotReuseTheOldPrefix() throws {
        let path = try requireModel().path
        let context = try XCTUnwrap(LlamaContext(modelPath: path, gpuLayers: 0))

        _ = context.generate(system: system, user: user, maxTokens: 64)
        _ = context.generate(system: system + " Keep the language.", user: user, maxTokens: 64)
        XCTAssertEqual(context.reusedPrefixTokens, 0)
    }
}
