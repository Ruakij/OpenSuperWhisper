import Foundation
import OpenSuperWhisperCore

/// Signs in to GitHub with the device flow and keeps the settings file in a secret gist.
///
/// The device flow needs no client secret and no redirect: the app shows a short code, the person
/// types it on github.com, and the app polls until GitHub hands over a token limited to gists.
/// The token sits in the Keychain. Sending and fetching are explicit, never automatic, so two Macs
/// never overwrite each other behind anyone's back.
struct GitHubSettingsSync {
    /// The my-monkeys OAuth app, device flow enabled. Public by design: the device flow has no
    /// secret, and anyone signing in sees the app's name before approving.
    static let clientID = "Ov23liREPLACE_ME"
    static let tokenAccount = "githubSettingsSyncToken"
    static let gistDescription = "OpenSuperWhisper settings"

    typealias Send = (URLRequest) async throws -> (Data, URLResponse)
    var send: Send = { try await URLSession.shared.data(for: $0) }

    struct DeviceCode: Equatable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let interval: TimeInterval
        let expiresIn: TimeInterval
    }

    enum PollResult: Equatable {
        case token(String)
        case pending
        case slowDown
        case expired
        case denied
    }

    struct RemoteSettings {
        let gistID: String
        let updatedAt: Date?
        let content: Data
    }

    enum SyncError: LocalizedError {
        case unexpectedResponse(Int)
        case signedOut
        case nothingSaved

        var errorDescription: String? {
            switch self {
            case .unexpectedResponse(let status):
                return String(localized: "GitHub answered with an error (\(status)).")
            case .signedOut:
                return String(localized: "GitHub no longer accepts this sign-in. Sign in again.")
            case .nothingSaved:
                return String(localized: "No settings saved on GitHub yet. Send them from a Mac first.")
            }
        }
    }

    // MARK: - Sign-in

    func requestDeviceCode() async throws -> DeviceCode {
        let json = try await post("https://github.com/login/device/code",
                                  form: ["client_id": Self.clientID, "scope": "gist"])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String,
              let url = URL(string: uri)
        else { throw SyncError.unexpectedResponse(200) }
        return DeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURL: url,
                          interval: json["interval"] as? TimeInterval ?? 5,
                          expiresIn: json["expires_in"] as? TimeInterval ?? 900)
    }

    func poll(_ code: DeviceCode) async throws -> PollResult {
        let json = try await post("https://github.com/login/oauth/access_token", form: [
            "client_id": Self.clientID,
            "device_code": code.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        return Self.pollResult(json)
    }

    static func pollResult(_ json: [String: Any]) -> PollResult {
        if let token = json["access_token"] as? String { return .token(token) }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        default: return .expired
        }
    }

    func login(token: String) async throws -> String {
        let (data, _) = try await api("GET", "/user", token: token)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["login"] as? String ?? ""
    }

    // MARK: - Gist

    /// The gist holding the settings file, found by its file name among the account's gists.
    func fetch(token: String) async throws -> RemoteSettings? {
        guard let id = try await findGistID(token: token) else { return nil }
        let (data, _) = try await api("GET", "/gists/\(id)", token: token)
        let gist = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = gist?["files"] as? [String: Any]
        let file = files?[SettingsArchive.fileName] as? [String: Any]
        guard let content = file?["content"] as? String else { return nil }
        return RemoteSettings(gistID: id, updatedAt: Self.date(gist?["updated_at"]), content: Data(content.utf8))
    }

    /// Writes the settings file, into the existing gist when there is one, otherwise a new
    /// secret gist.
    func upload(_ content: Data, token: String) async throws {
        let files = [SettingsArchive.fileName: ["content": String(decoding: content, as: UTF8.self)]]
        if let id = try await findGistID(token: token) {
            _ = try await api("PATCH", "/gists/\(id)", token: token, body: ["files": files])
        } else {
            _ = try await api("POST", "/gists", token: token, body: [
                "description": Self.gistDescription, "public": false, "files": files,
            ])
        }
    }

    private func findGistID(token: String) async throws -> String? {
        for page in 1...10 {
            let (data, _) = try await api("GET", "/gists?per_page=100&page=\(page)", token: token)
            let gists = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            if let id = Self.settingsGistID(in: gists) { return id }
            if gists.count < 100 { return nil }
        }
        return nil
    }

    static func settingsGistID(in gists: [[String: Any]]) -> String? {
        gists.first { ($0["files"] as? [String: Any])?[SettingsArchive.fileName] != nil }?["id"] as? String
    }

    // MARK: - HTTP

    private func post(_ url: String, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await send(request)
        try Self.check(response)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func api(_ method: String, _ path: String, token: String, body: [String: Any]? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await send(request)
        try Self.check(response)
        return (data, response)
    }

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        if status == 401 { throw SyncError.signedOut }
        guard (200..<300).contains(status) else { throw SyncError.unexpectedResponse(status) }
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
