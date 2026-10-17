import XCTest

@testable import OpenSuperWhisper

/// The GitHub side of settings sync, against canned responses: no request leaves the machine.
final class GitHubSettingsSyncTests: XCTestCase {

    /// Answers each request from `routes` by method and path, and records what was sent.
    private final class FakeGitHub: @unchecked Sendable {
        var routes: [String: (Int, Any)] = [:]
        var sent: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            sent.append(request)
            let url = request.url!
            let path = url.query.map { "\(url.path)?\($0)" } ?? url.path
            let (status, body) = routes["\(request.httpMethod ?? "GET") \(path)"] ?? (404, [String: Any]())
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (try JSONSerialization.data(withJSONObject: body), response)
        }

        func body(of index: Int) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent[index].httpBody)) as? [String: Any])
        }
    }

    private let github = FakeGitHub()
    private var sync: GitHubSettingsSync {
        var sync = GitHubSettingsSync()
        sync.send = github.send
        return sync
    }

    private let firstPage = "GET /gists?per_page=100&page=1"
    private let settingsGist: [String: Any] = ["id": "abc", "files": [SettingsArchive.fileName: [:]]]

    func testPollAnswersMapToWhatTheAppDoesNext() {
        XCTAssertEqual(GitHubSettingsSync.pollResult(["access_token": "t"]), .token("t"))
        XCTAssertEqual(GitHubSettingsSync.pollResult(["error": "authorization_pending"]), .pending)
        XCTAssertEqual(GitHubSettingsSync.pollResult(["error": "slow_down"]), .slowDown)
        XCTAssertEqual(GitHubSettingsSync.pollResult(["error": "access_denied"]), .denied)
        XCTAssertEqual(GitHubSettingsSync.pollResult(["error": "expired_token"]), .expired)
    }

    func testTheDeviceCodeAsksOnlyForGists() async throws {
        github.routes["POST /login/device/code"] = (200, [
            "device_code": "d", "user_code": "ABCD-1234",
            "verification_uri": "https://github.com/login/device", "interval": 5, "expires_in": 900,
        ])

        let code = try await sync.requestDeviceCode()

        XCTAssertEqual(code.userCode, "ABCD-1234")
        let form = String(decoding: try XCTUnwrap(github.sent.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(form.contains("scope=gist"), form)
    }

    func testTheFirstSendCreatesASecretGist() async throws {
        github.routes[firstPage] = (200, [["id": "other", "files": ["notes.md": [:]]]])
        github.routes["POST /gists"] = (201, ["id": "new"])

        try await sync.upload(Data("{}".utf8), token: "t")

        let body = try github.body(of: 1)
        XCTAssertEqual(body["public"] as? Bool, false)
        XCTAssertNotNil((body["files"] as? [String: Any])?[SettingsArchive.fileName])
        XCTAssertEqual(github.sent[1].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testALaterSendUpdatesTheSameGist() async throws {
        github.routes[firstPage] = (200, [settingsGist])
        github.routes["PATCH /gists/abc"] = (200, ["id": "abc"])

        try await sync.upload(Data("{}".utf8), token: "t")

        XCTAssertEqual(github.sent.map { $0.httpMethod }, ["GET", "PATCH"])
    }

    func testFetchReadsTheSettingsFileFromTheGist() async throws {
        github.routes[firstPage] = (200, [settingsGist])
        github.routes["GET /gists/abc"] = (200, [
            "updated_at": "2026-10-17T10:00:00Z",
            "files": [SettingsArchive.fileName: ["content": #"{"format":"x"}"#]],
        ])

        let remote = try await sync.fetch(token: "t")

        XCTAssertEqual(remote.map { String(decoding: $0.content, as: UTF8.self) }, #"{"format":"x"}"#)
        XCTAssertNotNil(remote?.updatedAt)
    }

    func testFetchWithNoGistFindsNothing() async throws {
        github.routes[firstPage] = (200, [[String: Any]]())
        let remote = try await sync.fetch(token: "t")
        XCTAssertNil(remote)
    }

    func testARevokedTokenReadsAsSignedOut() async {
        github.routes[firstPage] = (401, ["message": "Bad credentials"])
        do {
            _ = try await sync.fetch(token: "t")
            XCTFail("expected an error")
        } catch GitHubSettingsSync.SyncError.signedOut {
        } catch {
            XCTFail("\(error)")
        }
    }
}
