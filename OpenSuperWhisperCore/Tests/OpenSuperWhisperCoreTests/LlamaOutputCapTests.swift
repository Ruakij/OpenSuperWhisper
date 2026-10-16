import XCTest
@testable import OpenSuperWhisperCore

/// The reply budget and the KV cache setting mapping, neither of which needs a model file.
final class LlamaOutputCapTests: CoreTestCase {

    func testShortInputsGetTheFloor() {
        XCTAssertEqual(LlamaContext.outputCap(userTokenCount: 10), 256)
    }

    func testLongInputsGetTwiceTheirLength() {
        XCTAssertEqual(LlamaContext.outputCap(userTokenCount: 1000), 2000)
    }

    func testStoredKVCacheTypesResolve() {
        XCTAssertEqual(LlamaContext.KVCacheType(rawValue: "f16"), .f16)
        XCTAssertEqual(LlamaContext.KVCacheType(rawValue: "q8_0"), .q8_0)
    }
}
