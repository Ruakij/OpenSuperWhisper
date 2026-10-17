import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The language and translate stores the menu bar and Settings both write through (#63). Each
/// change is written, published and announced once; writing the same value again announces
/// nothing, which is what keeps the menu and an open Settings window from echoing each other.
@MainActor
final class SettingsStoresTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private var posts = 0
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        observer.map(NotificationCenter.default.removeObserver)
        scratch.restore()
        super.tearDown()
    }

    private func countPosts(of name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.posts += 1 }
        }
    }

    func testALanguageChangeIsWrittenPublishedAndAnnouncedOnce() {
        let store = LanguageStore.shared
        let other = AppPreferences.shared.whisperLanguage == "de" ? "fr" : "de"
        countPosts(of: .appPreferencesLanguageChanged)

        store.select(other)

        XCTAssertEqual(AppPreferences.shared.whisperLanguage, other)
        XCTAssertEqual(store.language, other)
        XCTAssertEqual(posts, 1)
    }

    func testSelectingTheCurrentLanguageAnnouncesNothing() {
        let current = AppPreferences.shared.whisperLanguage
        countPosts(of: .appPreferencesLanguageChanged)

        LanguageStore.shared.select(current)

        XCTAssertEqual(posts, 0)
    }

    func testTranslateTogglesBackAndForth() {
        let store = TranslateStore.shared
        let start = AppPreferences.shared.translateToEnglish
        countPosts(of: .translateSettingDidChange)

        store.toggle()
        XCTAssertEqual(AppPreferences.shared.translateToEnglish, !start)
        XCTAssertEqual(store.enabled, !start)
        store.toggle()
        XCTAssertEqual(AppPreferences.shared.translateToEnglish, start)
        XCTAssertEqual(posts, 2)
    }

    func testSettingTheCurrentTranslateValueAnnouncesNothing() {
        countPosts(of: .translateSettingDidChange)
        TranslateStore.shared.set(AppPreferences.shared.translateToEnglish)
        XCTAssertEqual(posts, 0)
    }
}
