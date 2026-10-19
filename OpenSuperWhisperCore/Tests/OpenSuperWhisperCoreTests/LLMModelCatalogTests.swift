import XCTest
@testable import OpenSuperWhisperCore

final class LLMModelCatalogTests: CoreTestCase {

    func testModelsAreOfferedSmallestFirst() {
        let sizes = LLMModelManager.availableModels.map(\.approxBytes)
        XCTAssertEqual(sizes, sizes.sorted())
    }

    /// The on-disk name is the last path component of the URL; HF is case-sensitive, so a typo in
    /// either one is a silent 404.
    func testEveryDownloadURLEndsInItsFileName() {
        for model in LLMModelManager.availableModels {
            XCTAssertEqual(model.downloadURL.lastPathComponent, model.fileName)
            XCTAssertEqual(model.downloadURL.host, "huggingface.co")
        }
    }

    func testStoredQwen25NamesLandOnTheReplacementOfTheirSizeClass() {
        XCTAssertEqual(LLMModelManager.model(fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf").fileName,
                       "Qwen3.5-2B-Q4_K_M.gguf")
        XCTAssertEqual(LLMModelManager.model(fileName: "qwen2.5-7b-instruct-q3_k_m.gguf").fileName,
                       "Qwen3.5-4B-Q5_K_M.gguf")
        XCTAssertEqual(LLMModelManager.model(fileName: "Qwen3.5-4B-Q5_K_M.gguf").fileName,
                       "Qwen3.5-4B-Q5_K_M.gguf")
    }

    func testUnknownStoredNameResolvesToTheDefault() {
        XCTAssertEqual(LLMModelManager.model(fileName: "something-else.gguf").fileName,
                       LLMModelManager.defaultModel.fileName)
    }

    func testRemovesOnlyTheTwoSupersededFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LLMModelManager(storageRoot: root)
        let superseded = ["qwen2.5-1.5b-instruct-q4_k_m.gguf", "qwen2.5-7b-instruct-q3_k_m.gguf"]
        let kept = ["Qwen3.5-2B-Q4_K_M.gguf", "qwen2.5-3b-instruct-q4_k_m.gguf", "notes.txt"]
        for name in superseded + kept { try Data().write(to: manager.localURL(for: name)) }

        XCTAssertTrue(manager.removeSupersededModels())

        for name in superseded { XCTAssertFalse(manager.isModelDownloaded(name: name), name) }
        for name in kept { XCTAssertTrue(manager.isModelDownloaded(name: name), name) }
        XCTAssertFalse(manager.removeSupersededModels(), "nothing left to delete, so nothing to tell")
    }

    /// An install that selected a Qwen2.5 file may still have it on disk, but the backend
    /// resolves to the replacement, which is not there: nothing runs until it is downloaded.
    func testBackendIsNotReadyUntilTheResolvedModelIsDownloaded() throws {
        let old = LLMModelManager.shared.localURL(for: "qwen2.5-1.5b-instruct-q4_k_m.gguf")
        CoreTestEnvironment.preferences.builtInModelFileName = old.lastPathComponent
        try Data().write(to: old)
        defer { try? FileManager.default.removeItem(at: old) }

        XCTAssertFalse(BuiltInLlamaBackend.shared.isReady)
    }
}
