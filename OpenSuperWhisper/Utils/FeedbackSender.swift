import Foundation

/// What a message from the Feedback card is about.
enum FeedbackKind: String, CaseIterable {
    case bug, idea
}

/// One message from the Feedback card, as the user left it.
struct FeedbackSubmission: Equatable {
    var kind: FeedbackKind
    var message: String
    var email: String
    /// The app details line, or nil when the user switched it off.
    var details: String?

    /// Sent as the API's free-text `context`, the one field it keeps besides the message and
    /// the email: where the message came from, what it is about, and the details if allowed.
    var context: String {
        (["app", kind.rawValue] + [details].compactMap { $0 }).joined(separator: " · ")
    }

    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Why a message did not get through.
enum FeedbackSendError: Error, Equatable {
    /// The API answered 4xx: it will turn the same message down again, so retrying is no use.
    case refused(status: Int)
    /// Offline, timed out, or a server error: the same message may go through later.
    case unreachable
}

/// Posts a feedback message to the same endpoint as the form on opensuperwhisper.com. The API is
/// public and takes no credentials. The transport is injectable so tests never reach it: every
/// request lands in the owner's inbox.
struct FeedbackSender {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://git.my-monkey.fr/api/feedback")!
    static let product = "opensuperwhisper"
    static let timeout: TimeInterval = 15
    /// The API stores the User-Agent with each message. The system's own names the build, the
    /// CFNetwork and the Darwin version, which would go out even with the app details off.
    static let userAgent = "OpenSuperWhisper"

    /// The API's limits: it answers 400 past 4000 UTF-16 units of trimmed message (JavaScript's
    /// `length`), and refuses any body over 8 KB, which mostly-CJK or emoji text reaches first.
    static let maxMessageLength = 4000
    static let maxEmailLength = 200
    static let maxBodyBytes = 8 * 1024

    var transport: Transport = { try await FeedbackSender.session.data(for: $0) }

    /// No cookies, no cache, no credentials kept between sends, and the neutral User-Agent.
    static let sessionConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }()

    private static let session = URLSession(configuration: sessionConfiguration)

    func send(_ submission: FeedbackSubmission) async throws {
        let request = try Self.request(for: submission)
        let response: URLResponse
        do {
            (_, response) = try await transport(request)
        } catch {
            throw FeedbackSendError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw FeedbackSendError.unreachable }
        switch http.statusCode {
        case 200..<300: return
        case 400..<500: throw FeedbackSendError.refused(status: http.statusCode)
        default: throw FeedbackSendError.unreachable
        }
    }

    /// Whether the API would take this message as it stands, checked before Send is offered.
    static func fitsLimits(_ submission: FeedbackSubmission) -> Bool {
        guard submission.trimmedMessage.utf16.count <= maxMessageLength,
              submission.trimmedEmail.utf16.count <= maxEmailLength,
              let body = try? body(for: submission) else { return false }
        return body.count <= maxBodyBytes
    }

    static func request(for submission: FeedbackSubmission) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.httpBody = try body(for: submission)
        return request
    }

    private static func body(for submission: FeedbackSubmission) throws -> Data {
        let email = submission.trimmedEmail
        let encoder = JSONEncoder()
        // Unescaped slashes: a pasted path or URL would otherwise cost a byte more per slash.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(
            message: submission.trimmedMessage,
            email: email.isEmpty ? nil : email,
            product: product,
            context: submission.context))
    }

    /// The website's shape. `email` is left out rather than sent empty, as the site does.
    private struct Body: Encodable {
        let message: String
        let email: String?
        let product: String
        let context: String
    }
}

/// The one line of context the Feedback card offers to send, shown to the user word for word:
/// "OpenSuperWhisper 0.14.0 (63) · macOS 26.2 · Apple Silicon · Parakeet Ultra".
enum FeedbackAppDetails {
    static func line(version: String, build: String, os: OperatingSystemVersion,
                     appleSilicon: Bool, model: String?) -> String {
        let osVersion = os.patchVersion == 0
            ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return [
            "OpenSuperWhisper \(version) (\(build))",
            "macOS \(osVersion)",
            appleSilicon ? "Apple Silicon" : "Intel",
            model,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// - Parameter includingModel: off for a transcription report, which names the model that
    ///   wrote that dictation rather than the one selected now.
    @MainActor
    static func current(includingModel: Bool = true) -> String {
        let info = Bundle.main.infoDictionary
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return line(version: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
                    build: info?["CFBundleVersion"] as? String ?? "0",
                    os: ProcessInfo.processInfo.operatingSystemVersion,
                    appleSilicon: appleSilicon,
                    model: includingModel ? ModelSelectionStore.shared.active?.friendlyName : nil)
    }
}
