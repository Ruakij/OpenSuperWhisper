import XCTest
@testable import OpenSuperWhisperCore

/// The pure parts of thinking control: spotting a thinking template, and keeping the reasoning out
/// of the text that gets inserted. The model itself is exercised by hand.
final class LLMThinkingTests: CoreTestCase {

    private func strip(_ s: String) -> String { LLMPostProcessor.strippingThinking(s) }

    func testPlainOutputIsOnlyTrimmed() {
        XCTAssertEqual(strip("  Hello, world.\n"), "Hello, world.")
    }

    func testDropsClosedBlocks() {
        XCTAssertEqual(strip("<think>\nfix the comma\n</think>\n\nHello, world."), "Hello, world.")
        XCTAssertEqual(strip("<think>\n\n</think>\n\nHi."), "Hi.")
        XCTAssertEqual(strip("<think>a</think><think>b</think>Hi."), "Hi.")
    }

    /// The prompt opens the block, so the model's own output starts inside it.
    func testDropsReasoningBeforeAnUnopenedClosingTag() {
        XCTAssertEqual(strip("fix the comma\n</think>\n\nHello, world."), "Hello, world.")
        XCTAssertEqual(strip("</think>\n\nHi."), "Hi.")
    }

    func testUnterminatedLeadingBlockLeavesNothing() {
        XCTAssertEqual(strip("<think>\nstill thinking when the tokens ran out"), "")
        XCTAssertEqual(strip("\n<think>\n"), "")
    }

    func testTagMentionedInTheAnswerSurvives() {
        XCTAssertEqual(strip("Wrap it in a <think> tag."), "Wrap it in a <think> tag.")
    }

    func testTemplateSupportsThinking() {
        XCTAssertFalse(LlamaContext.templateSupportsThinking(nil))
        XCTAssertFalse(LlamaContext.templateSupportsThinking(
            "{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}"))
        XCTAssertTrue(LlamaContext.templateSupportsThinking(
            "{% if enable_thinking is defined and enable_thinking is false %}<think>\n\n</think>\n\n{% endif %}"))
    }
}
