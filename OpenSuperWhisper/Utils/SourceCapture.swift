import AppKit
import ApplicationServices
import Foundation

/// Best-effort capture of "where" a dictation happened, beyond the app name: the
/// focused window's title (Accessibility) and, for supported browsers, the active
/// tab's URL (AppleScript — triggers a one-time automation permission per app).
enum SourceCapture {
    /// Title of the system-wide focused window (e.g. a browser tab or document).
    static func focusedWindowTitle() -> String? {
        // These AX calls are synchronous IPC to the frontmost app and run on the
        // main thread at record-start / menu-open; a wedged target would freeze the
        // recording hotkey without a timeout (#freeze). Bound every request, exactly
        // as FocusUtils does.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, FocusUtils.axMessagingTimeout)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let windowRef else { return nil }

        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, FocusUtils.axMessagingTimeout)
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        ) == .success else { return nil }

        let title = titleRef as? String
        return (title?.isEmpty == false) ? title : nil
    }

    /// How much of the text before the caret is worth carrying. Whisper's prompt window is
    /// small and the custom dictionary already spends part of it, so this takes the tail of a
    /// sentence or two rather than a document.
    static let focusedTextLimit = 240

    /// The text already written in the field being dictated into, ending at the caret.
    ///
    /// Read from the frontmost app's own element rather than the system-wide one: the
    /// system-wide element answers `kAXErrorCannotComplete` in cases where the per-app element
    /// answers fine, and there is nothing to gain from asking the more fragile of the two.
    /// Returns nil when nothing is focused (`kAXErrorNoValue`), which is the common case in a
    /// browser sitting on a page, so callers must treat absence as normal rather than a fault.
    static func focusedText() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, FocusUtils.axMessagingTimeout)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return nil }

        return focusedText(in: focusedRef as! AXUIElement)
    }

    /// The same, from a focused element already in hand.
    static func focusedText(in element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let text = valueRef as? String, !text.isEmpty else { return nil }

        return tail(of: text, upTo: caretOffset(in: element) ?? text.count)
    }

    /// Where the caret sits in the focused element, as a character offset.
    private static func caretOffset(in element: AXUIElement) -> Int? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// The last `focusedTextLimit` characters before `caret`, trimmed to start on a word.
    ///
    /// Cutting mid-word would feed the model half a token as though it were a whole one, so the
    /// leading fragment is dropped when the cut lands inside a word.
    static func tail(of text: String, upTo caret: Int) -> String? {
        let end = min(max(caret, 0), text.count)
        let written = String(text.prefix(end))
        guard !written.isEmpty else { return nil }

        var slice = String(written.suffix(focusedTextLimit))
        if slice.count < written.count, let space = slice.firstIndex(where: { $0.isWhitespace }) {
            slice = String(slice[slice.index(after: space)...])
        }

        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// AppleScript to read the active tab/document URL, keyed by bundle id.
    private static let browserScripts: [String: String] = [
        "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
        "com.google.Chrome.beta": "tell application \"Google Chrome Beta\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
        "com.vivaldi.Vivaldi": "tell application \"Vivaldi\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
        "company.thebrowser.dia": "tell application \"Dia\" to return URL of active tab of front window",
        "com.apple.Safari": "tell application \"Safari\" to return URL of front document",
    ]

    static func isSupportedBrowser(bundleID: String) -> Bool {
        browserScripts.keys.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Where a dictation happened: the active tab's URL and its host, and the window title.
    struct Details: Sendable {
        var fullURL: String?
        var host: String?
        var windowTitle: String?
    }

    /// The URL, host and window title of the frontmost app at record start. Run off the main
    /// thread: the browser's reply and the Accessibility lookup both wait on the target app.
    static func details(bundleID: String) async -> Details {
        async let url = browserURL(bundleID: bundleID, timeout: 1)
        let title = focusedWindowTitle()
        let fullURL = await url
        return Details(fullURL: fullURL, host: host(of: fullURL), windowTitle: title)
    }

    /// Scripts run one at a time. NSAppleScript is not thread-safe, and a hung browser must not
    /// leave a new thread blocked for every take.
    private static let scriptQueue = DispatchQueue(label: "SourceCapture.scripts")

    /// Runs the script for a known browser and passes its URL to `completion`, once: nil when the
    /// bundle is not a browser (no queueing), when the script fails, or when `timeout` passes first.
    /// A script still queued at the timeout is skipped, so a hung browser leaves at most one
    /// script blocking the queue, not a backlog.
    private static func queueScript(bundleID: String, timeout: TimeInterval,
                                    completion: @escaping (String?) -> Void) {
        guard browserScripts[bundleID] != nil else {
            completion(nil)
            return
        }
        let once = ResumeOnce()
        scriptQueue.async {
            guard !once.isDone else { return }
            let url = runBrowserScript(bundleID: bundleID)
            once.run { completion(url) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            once.run { completion(nil) }
        }
    }

    /// Active-tab URL for a known browser bundle id, for the menu, which is open on main. Waits
    /// at most 0.3 s, then gives no URL.
    static func browserURL(bundleID: String) -> String? {
        var url: String?
        let replied = DispatchSemaphore(value: 0)
        queueScript(bundleID: bundleID, timeout: 0.3) { reply in
            url = reply
            replied.signal()
        }
        replied.wait()
        return url
    }

    /// `browserURL` for a recording: nil when the browser has not answered within `timeout`.
    static func browserURL(bundleID: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queueScript(bundleID: bundleID, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    private static func runBrowserScript(bundleID: String) -> String? {
        guard let source = browserScripts[bundleID],
              let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let url = result.stringValue
        return (url?.isEmpty == false) ? url : nil
    }

    /// Host of a URL string, "www." stripped — e.g. "github.com". For display and
    /// (later) per-site rules.
    static func host(of urlString: String?) -> String? {
        guard let urlString,
              let host = URLComponents(string: urlString)?.host,
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The host a person typed for a site rule: "https://www.Mail.Google.com/mail/u/0" and
    /// "mail.google.com" both give "mail.google.com". nil when no host can be read from it.
    static func normalizedHost(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return host(of: trimmed.contains("://") ? trimmed : "https://" + trimmed)?.lowercased()
    }
}

/// Lets the first of two racing completions resume a continuation; the second is dropped.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func run(_ resume: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { resume() }
    }
}
