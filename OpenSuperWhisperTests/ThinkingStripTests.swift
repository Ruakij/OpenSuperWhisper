import XCTest
@testable import OpenSuperWhisper

/// Reasoning models put their thoughts in `<think>` blocks; only the answer may reach the text.
final class ThinkingStripTests: XCTestCase {

    private func strip(_ s: String) -> String { LLMPostProcessor.strippingThinking(s) }

    func testPlainOutputIsOnlyTrimmed() {
        XCTAssertEqual(strip("  Hello, world.\n"), "Hello, world.")
    }

    func testDropsClosedBlocks() {
        XCTAssertEqual(strip("<think>\nfix the comma\n</think>\n\nHello, world."), "Hello, world.")
        XCTAssertEqual(strip("<think>\n\n</think>\n\nHi."), "Hi.")
    }

    func testDropsEverythingBeforeLoneClosingTag() {
        XCTAssertEqual(strip("the prompt opened the block\n</think>\nHi."), "Hi.")
    }

    func testUnterminatedBlockLeavesNothing() {
        XCTAssertEqual(strip("<think>\nstill thinking when tokens ran out"), "")
    }
}
