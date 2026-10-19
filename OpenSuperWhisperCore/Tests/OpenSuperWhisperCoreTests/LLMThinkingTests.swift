import XCTest
@testable import OpenSuperWhisperCore

final class LLMThinkingTests: CoreTestCase {

    func testTemplateSupportsThinking() {
        XCTAssertFalse(LlamaContext.templateSupportsThinking(nil))
        XCTAssertFalse(LlamaContext.templateSupportsThinking(
            "{% for m in messages %}<|im_start|>{{ m.role }}\n{{ m.content }}<|im_end|>\n{% endfor %}"))
        XCTAssertTrue(LlamaContext.templateSupportsThinking(
            "{% if enable_thinking is defined and enable_thinking is false %}<think>\n\n</think>\n\n{% endif %}"))
    }
}
