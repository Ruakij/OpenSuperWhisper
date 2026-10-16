import SwiftUI
import OpenSuperWhisperCore

/// What the AI engine menu and the fields under it say about Apple Intelligence on this Mac.
enum TextAIAppleIntelligence {
    /// The menu item: the plain name when it can be picked, the name and why not otherwise.
    static func menuItem(_ availability: AppleIntelligenceAvailability) -> LocalizedStringKey {
        switch availability {
        case .available:
            // Recommended from a side-by-side run on real French dictations (October 2026): it
            // fixed grammar without dropping or adding anything, where the 1.5B Qwen changed the
            // meaning of a quarter of them and the 7B invented a few words.
            return "Apple Intelligence (recommended)"
        case .unsupportedMac:
            return "Apple Intelligence · needs macOS 26 on Apple Silicon"
        case .turnedOff:
            return "Apple Intelligence · turned off in System Settings"
        case .modelNotReady:
            return "Apple Intelligence · still downloading"
        case .unsupportedLanguage(let code):
            return "Apple Intelligence · doesn't support \(languageName(code))"
        }
    }

    /// Shown under the menu while Apple Intelligence is the engine but can't run, so the user
    /// knows why their dictations come through uncleaned. Nil while it is available.
    static func unavailableNotice(_ availability: AppleIntelligenceAvailability) -> LocalizedStringKey? {
        switch availability {
        case .available:
            return nil
        case .unsupportedMac:
            return "Apple Intelligence needs macOS 26 on a Mac with Apple Silicon. Until then, the text is inserted without cleanup."
        case .turnedOff:
            return "Apple Intelligence is turned off in System Settings. Until then, the text is inserted without cleanup."
        case .modelNotReady:
            return "Apple Intelligence is still downloading. Until then, the text is inserted without cleanup."
        case .unsupportedLanguage(let code):
            return "Apple Intelligence doesn't support \(languageName(code)) yet, so the text is inserted without cleanup."
        }
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? LanguageUtil.displayName(for: code)
    }
}
