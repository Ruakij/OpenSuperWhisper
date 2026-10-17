import XCTest
@testable import OpenSuperWhisperCore

/// Asking the cleanup model for lists (#166): where the request sits in the prompt, and the check
/// that sends a reply which kept its sentence next to the list back for a plain pass.
final class CleanupListTests: CoreTestCase {

    private let slack = AppContextProfile(bundleIdentifier: "com.tinyspeck.slackmacgap",
                                          appName: "Slack", instructions: "Slack rules.")

    private func prompt(writesLists: Bool, profile: AppContextProfile? = nil) -> String {
        LLMPostProcessor.assembleSystemPrompt(
            generalCleanup: true, generalPrompt: "Opening.", profile: profile,
            closingPrompt: "Closing.", writesLists: writesLists) ?? ""
    }

    func testListsAreOnlyAskedForWhenWanted() {
        XCTAssertFalse(prompt(writesLists: false).contains(LLMPostProcessor.listInstruction))
        XCTAssertTrue(prompt(writesLists: true).contains(LLMPostProcessor.listInstruction))
    }

    /// The app's rules and the guardrail keep the last word.
    func testTheListRequestComesBeforeTheAppRulesAndTheGuardrail() throws {
        let system = prompt(writesLists: true, profile: slack)
        let list = try XCTUnwrap(system.range(of: LLMPostProcessor.listInstruction)).lowerBound
        let rules = try XCTUnwrap(system.range(of: "Slack rules.")).lowerBound
        let closing = try XCTUnwrap(system.range(of: "Closing.")).lowerBound
        XCTAssertLessThan(list, rules)
        XCTAssertLessThan(rules, closing)
    }

    /// An echo of the list request is caught like any other shipped instruction.
    func testTheListRequestCountsAsShippedText() {
        let shipped = LLMPostProcessor.shippedInstructions(
            generalCleanup: false, generalPrompt: "", profile: nil, closingPrompt: "",
            translating: false, translationPrompt: "", writesLists: true)
        XCTAssertTrue(shipped.contains(LLMPostProcessor.listInstruction))
    }

    func testAListWrittenInPlaceOfTheSentencePasses() {
        let input = "I need to buy eggs, milk, butter and a loaf of bread on the way home."
        let output = "I need to buy:\n- eggs\n- milk\n- butter\n- a loaf of bread on the way home."
        XCTAssertFalse(LLMPostProcessor.listRepeatsText(input: input, output: output))
    }

    /// Measured on Apple's model: the sentence kept, then the same items as a list.
    func testASentenceKeptNextToItsListIsCaught() {
        let input = "We could ship it on Monday, wait for the design review, or split it into two smaller releases."
        let output = """
            We could ship it on Monday, wait for the design review, or split it into two smaller releases.

            - 1. Ship it on Monday
            - 2. Wait for the design review
            - 3. Split it into two smaller releases
            """
        XCTAssertTrue(LLMPostProcessor.listRepeatsText(input: input, output: output))
    }

    func testAnUntouchedReplyPasses() {
        let text = "Sounds good, see you tomorrow at nine."
        XCTAssertFalse(LLMPostProcessor.listRepeatsText(input: text, output: text))
    }
}
