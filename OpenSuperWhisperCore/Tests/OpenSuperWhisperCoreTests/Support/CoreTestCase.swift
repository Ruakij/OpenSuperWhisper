import XCTest
@testable import OpenSuperWhisperCore

/// Base class of every XCTest class in the core target. A SwiftPM test bundle has no principal
/// class, so the environment is installed here, before any instance `setUp` runs.
///
/// Instances are built before the class `setUp`, so a subclass must not read a core singleton
/// from a stored-property initializer.
class CoreTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        CoreTestEnvironment.install()
    }

    override func tearDown() {
        CoreTestEnvironment.preferences.reset()
        super.tearDown()
    }

    /// The model the llama tests run against, from `OSW_TEST_GGUF`; skips without one.
    func requireModel() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OSW_TEST_GGUF"], !path.isEmpty else {
            throw XCTSkip("OSW_TEST_GGUF is not set")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw XCTSkip("OSW_TEST_GGUF does not name a readable file: \(path)")
        }
        return URL(fileURLWithPath: path)
    }
}
