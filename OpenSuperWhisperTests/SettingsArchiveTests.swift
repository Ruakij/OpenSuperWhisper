import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The settings file: what goes in, what comes back out on another Mac, what never travels.
final class SettingsArchiveTests: XCTestCase {

    private var source: UserDefaults!
    private var target: UserDefaults!

    override func setUp() {
        super.setUp()
        source = UserDefaults(suiteName: "SettingsArchiveTests.source.\(UUID().uuidString)")
        target = UserDefaults(suiteName: "SettingsArchiveTests.target.\(UUID().uuidString)")
    }

    private func roundTrip() throws -> [String: Any] {
        let data = try SettingsArchive.export(from: source, appVersion: "1.0")
        let values = try SettingsArchive.read(data)
        SettingsArchive.apply(values, to: target)
        return values
    }

    /// A new preference must be sorted into one list or the other, or it silently stays behind.
    func testEveryPreferenceIsEitherPortableOrLocal() {
        let portable = Set(SettingsArchive.portableKeys)
        XCTAssertTrue(portable.isDisjoint(with: SettingsArchive.localKeys))
        XCTAssertEqual(portable.union(SettingsArchive.localKeys), Set(DefaultsKeySnapshotTests.goldenKeys))
    }

    func testPlainValuesComeBackAsTheyWere() throws {
        source.set(true, forKey: "autoCopyToClipboard")
        source.set(3, forKey: "beamSize")
        source.set(0.4, forKey: "temperature")
        source.set("fr", forKey: "whisperLanguage")
        source.set(["a", "b"], forKey: "dictionaryRefusedWords")

        _ = try roundTrip()

        XCTAssertEqual(target.object(forKey: "autoCopyToClipboard") as? Bool, true)
        XCTAssertEqual(target.object(forKey: "beamSize") as? Int, 3)
        XCTAssertEqual(target.object(forKey: "temperature") as? Double, 0.4)
        XCTAssertEqual(target.string(forKey: "whisperLanguage"), "fr")
        XCTAssertEqual(target.stringArray(forKey: "dictionaryRefusedWords"), ["a", "b"])
    }

    /// Snippets are stored as JSON `Data`; the file shows them as JSON and they decode the same.
    func testJSONDataIsReadableInTheFileAndDecodesTheSame() throws {
        let snippets = [Snippet(trigger: "addr", expansion: "1 rue de la Paix")]
        source.set(try JSONEncoder().encode(snippets), forKey: "snippetsData")

        let data = try SettingsArchive.export(from: source, appVersion: "1.0")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("1 rue de la Paix"))
        SettingsArchive.apply(try SettingsArchive.read(data), to: target)

        let stored = try XCTUnwrap(target.data(forKey: "snippetsData"))
        XCTAssertEqual(try JSONDecoder().decode([Snippet].self, from: stored), snippets)
    }

    func testOtherDataSurvivesAsBase64() throws {
        let bytes = Data([0x00, 0xFF, 0x10])
        source.set(bytes, forKey: "remoteFallbackModelData")
        _ = try roundTrip()
        XCTAssertEqual(target.data(forKey: "remoteFallbackModelData"), bytes)
    }

    func testThisMacsStateStaysBehind() throws {
        source.set(true, forKey: "hasCompletedOnboarding")
        source.set("/Users/someone/model.bin", forKey: "selectedWhisperModelPath")
        source.set(Data([1]), forKey: "selectedMicrophoneData")

        let values = try roundTrip()

        XCTAssertTrue(values.isEmpty)
        XCTAssertNil(target.object(forKey: "hasCompletedOnboarding"))
    }

    func testKeysMissingFromTheFileAreLeftAlone() throws {
        target.set("de", forKey: "whisperLanguage")
        source.set(true, forKey: "autoCopyToClipboard")
        _ = try roundTrip()
        XCTAssertEqual(target.string(forKey: "whisperLanguage"), "de")
    }

    func testAFileWithLocalOrUnknownKeysOnlyAppliesPortableOnes() throws {
        let file: [String: Any] = [
            "format": SettingsArchive.format, "version": 1,
            "settings": ["hasCompletedOnboarding": false, "somethingNew": 1, "beamSize": 2],
        ]
        let values = try SettingsArchive.read(try JSONSerialization.data(withJSONObject: file))
        XCTAssertEqual(Array(values.keys), ["beamSize"])
    }

    func testAnUnrelatedJSONFileIsRefused() {
        let data = Data(#"{"name": "package"}"#.utf8)
        XCTAssertThrowsError(try SettingsArchive.read(data)) { error in
            guard case SettingsArchive.ReadError.notASettingsFile = error else { return XCTFail("\(error)") }
        }
    }

    func testAFileFromANewerVersionIsRefused() throws {
        let file: [String: Any] = ["format": SettingsArchive.format, "version": 99, "settings": [:]]
        XCTAssertThrowsError(try SettingsArchive.read(try JSONSerialization.data(withJSONObject: file))) { error in
            guard case SettingsArchive.ReadError.newerVersion(99) = error else { return XCTFail("\(error)") }
        }
    }
}
