import XCTest
@testable import OpenSuperWhisperCore

final class BuiltInModelKeepLoadedTests: CoreTestCase {

    private func shouldKeep(unloadBuiltInModelWhenIdle: Bool = false,
                            aiBackend: String = "builtin",
                            aiPostProcessingEnabled: Bool = true,
                            appContextFormattingEnabled: Bool = false,
                            modelFileName: String? = LLMModelManager.defaultModel.fileName,
                            selectedModelFileName: String = LLMModelManager.defaultModel.fileName,
                            modelDownloaded: Bool = true) -> Bool {
        BuiltInLlamaBackend.shouldKeepModelLoaded(unloadBuiltInModelWhenIdle: unloadBuiltInModelWhenIdle,
                                                  aiBackend: aiBackend,
                                                  aiPostProcessingEnabled: aiPostProcessingEnabled,
                                                  appContextFormattingEnabled: appContextFormattingEnabled,
                                                  modelFileName: modelFileName,
                                                  selectedModelFileName: selectedModelFileName,
                                                  modelDownloaded: modelDownloaded)
    }

    func testKeepsTheModelWhenEveryConditionHolds() {
        XCTAssertTrue(shouldKeep())
    }

    func testReleasesTheModelWhenFreeMemoryWhenIdleIsOn() {
        XCTAssertFalse(shouldKeep(unloadBuiltInModelWhenIdle: true))
    }

    func testReleasesTheModelWhenTheBackendIsNotBuiltIn() {
        XCTAssertFalse(shouldKeep(aiBackend: "ollama"))
        XCTAssertFalse(shouldKeep(aiBackend: "remote"))
        XCTAssertFalse(shouldKeep(aiBackend: "apple"))
    }

    func testKeepsTheModelForPerAppFormattingWithCleanupOff() {
        XCTAssertTrue(shouldKeep(aiPostProcessingEnabled: false, appContextFormattingEnabled: true))
    }

    func testReleasesTheModelWhenCleanupAndPerAppFormattingAreOff() {
        XCTAssertFalse(shouldKeep(aiPostProcessingEnabled: false, appContextFormattingEnabled: false))
    }

    func testReleasesTheLoadedModelOnceAnotherIsSelected() {
        XCTAssertFalse(shouldKeep(modelFileName: LLMModelManager.defaultModel.fileName,
                                  selectedModelFileName: LLMModelManager.largeModel.fileName))
    }

    func testReleasesWhenNoModelIsLoaded() {
        XCTAssertFalse(shouldKeep(modelFileName: nil))
    }

    func testReleasesTheModelOnceItIsDeleted() {
        XCTAssertFalse(shouldKeep(modelDownloaded: false))
    }
}
