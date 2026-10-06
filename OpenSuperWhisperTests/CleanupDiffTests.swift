import XCTest
@testable import OpenSuperWhisper

final class CleanupDiffTests: XCTestCase {

    func testRemovedAndAddedWordsReconstructBothSides() {
        let input = "um so i run cube control"
        let output = "So I run kubectl."
        let segments = CleanupDiff.segments(from: input, to: output)

        func words(_ kind: CleanupDiff.Kind) -> [String] {
            segments.filter { $0.kind == kind && !$0.text.allSatisfy(\.isWhitespace) }.map(\.text)
        }
        XCTAssertEqual(words(.removed), ["um", "so", "i", "cube", "control"])
        XCTAssertEqual(words(.added), ["So", "I", "kubectl", "."])
        XCTAssertEqual(words(.same), ["run"])
        XCTAssertEqual(segments.filter { $0.kind != .added }.map(\.text).joined(), input)
        XCTAssertEqual(segments.filter { $0.kind != .removed }.map(\.text).joined(), output)
    }

    func testUmlautsStayInsideWords() {
        let segments = CleanupDiff.segments(from: "äh hängt", to: "Hängt.")
        XCTAssertEqual(segments.filter { $0.kind == .added }.map(\.text), ["Hängt", "."])
    }
}
