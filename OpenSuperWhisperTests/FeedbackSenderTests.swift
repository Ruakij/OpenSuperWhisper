import XCTest

@testable import OpenSuperWhisper

/// Records what the Feedback card would have posted and answers from a canned reply. Every test
/// goes through it: a real request lands in the owner's inbox.
private final class FeedbackTransportStub {
    enum Reply {
        case status(Int)
        case failure(URLError.Code)
    }

    private let reply: Reply
    /// The transport runs off the main actor while the test reads from it.
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    /// When holding, a send waits here until `release()`, so a test can look at it mid-flight.
    private var holds: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(reply: Reply = .status(200), holds: Bool = false) {
        self.reply = reply
        self.holds = holds
    }

    var sender: FeedbackSender {
        FeedbackSender(transport: { [self] request in
            lock.withLock { sent.append(request) }
            if lock.withLock({ holds }) {
                await withCheckedContinuation { continuation in
                    lock.withLock { gate = continuation }
                }
            }
            switch reply {
            case .failure(let code):
                throw URLError(code)
            case .status(let code):
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                               headerFields: nil)!
                return (Data(), response)
            }
        })
    }

    var requests: [URLRequest] { lock.withLock { sent } }
    var isHeld: Bool { lock.withLock { gate != nil } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holds = false
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}

private func jsonBody(_ request: URLRequest) throws -> [String: String] {
    let data = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
}

private let sampleDetails = "OpenSuperWhisper 0.14.0 (63) · macOS 26.2 · Apple Silicon · Parakeet Ultra"

/// The request the Feedback card posts: the website's endpoint and shape, with everything the
/// API does not know about folded into `context`.
final class FeedbackSenderTests: XCTestCase {

    func testItPostsJSONToTheFeedbackAPI() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .idea, message: "Hi", email: "", details: nil))

        XCTAssertEqual(request.url?.absoluteString, "https://git.my-monkey.fr/api/feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testItSaysOnlyTheAppNameAboutWhoIsSending() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .idea, message: "Hi", email: "", details: nil))

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OpenSuperWhisper",
                       "the system User-Agent names the build and the OS, details switch or not")
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Content-Type": "application/json",
            "User-Agent": "OpenSuperWhisper",
        ])
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testTheSessionKeepsNothingBetweenSends() {
        let configuration = FeedbackSender.sessionConfiguration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["User-Agent"] as? String, "OpenSuperWhisper")
    }

    func testSlashesAreNotEscaped() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .bug, message: "Crash in /Applications/OpenSuperWhisper.app", email: "", details: nil))
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("/Applications/OpenSuperWhisper.app"), body)
    }

    func testABugWithAnEmailAndTheDetails() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .bug, message: "  The bubble stays on screen.\n", email: " camille@example.com ",
            details: sampleDetails))

        XCTAssertEqual(try jsonBody(request), [
            "message": "The bubble stays on screen.",
            "email": "camille@example.com",
            "product": "opensuperwhisper",
            "context": "app · bug · " + sampleDetails,
        ])
    }

    func testAnIdeaWithoutEmailOrDetailsSendsNeither() throws {
        let request = try FeedbackSender.request(for: FeedbackSubmission(
            kind: .idea, message: "Dark icon please", email: "   ", details: nil))

        let body = try jsonBody(request)
        XCTAssertEqual(body, [
            "message": "Dark icon please",
            "product": "opensuperwhisper",
            "context": "app · idea",
        ])
        XCTAssertNil(body["email"], "an empty email is left out, as the website does")
    }

    func testA2xxAnswerIsASuccess() async throws {
        let stub = FeedbackTransportStub(reply: .status(201))
        try await stub.sender.send(FeedbackSubmission(kind: .idea, message: "Hi", email: "", details: nil))
        XCTAssertEqual(stub.requests.count, 1)
    }

    private func sendError(_ reply: FeedbackTransportStub.Reply) async -> FeedbackSendError? {
        do {
            try await FeedbackTransportStub(reply: reply).sender.send(
                FeedbackSubmission(kind: .idea, message: "Hi", email: "", details: nil))
            return nil
        } catch {
            return error as? FeedbackSendError
        }
    }

    func testAServerErrorIsWorthRetrying() async {
        let error = await sendError(.status(500))
        XCTAssertEqual(error, .unreachable)
    }

    func testANetworkErrorIsWorthRetrying() async {
        let error = await sendError(.failure(.notConnectedToInternet))
        XCTAssertEqual(error, .unreachable)
    }

    func testA4xxIsARefusalNotAConnectionProblem() async {
        for status in [400, 413] {
            let error = await sendError(.status(status))
            XCTAssertEqual(error, .refused(status: status))
        }
    }
}

/// The API's limits, checked before Send is offered: past them it answers 4xx, and no retry helps.
final class FeedbackLimitsTests: XCTestCase {

    private func fits(_ message: String, email: String = "") -> Bool {
        FeedbackSender.fitsLimits(FeedbackSubmission(kind: .bug, message: message, email: email,
                                                     details: sampleDetails))
    }

    func testTheMessageIsCappedAt4000Characters() {
        XCTAssertTrue(fits(String(repeating: "a", count: 4000)))
        XCTAssertFalse(fits(String(repeating: "a", count: 4001)))
    }

    func testSpacesAroundTheMessageDoNotCount() {
        XCTAssertTrue(fits("\n  " + String(repeating: "a", count: 4000) + "  \n"))
    }

    func testCharactersAreCountedAsTheServerCountsThem() {
        // Two UTF-16 units each, as JavaScript's length counts them.
        XCTAssertFalse(fits(String(repeating: "🍌", count: 2001)))
    }

    func testABodyOver8KBIsRefusedEvenUnder4000Characters() {
        // Three bytes each in UTF-8: 2800 characters make an 8.4 KB body.
        let cjk = String(repeating: "日", count: 2800)
        XCTAssertLessThan(cjk.utf16.count, FeedbackSender.maxMessageLength)
        XCTAssertFalse(fits(cjk))
        XCTAssertTrue(fits(String(repeating: "日", count: 2600)))
    }

    func testTheEmailIsCappedAt200Characters() {
        let local = String(repeating: "a", count: 188)
        XCTAssertTrue(fits("Hello", email: local + "@example.com"))
        XCTAssertFalse(fits("Hello", email: local + "x@example.com"))
    }
}

/// The details line, shown to the user word for word before it is sent.
final class FeedbackAppDetailsTests: XCTestCase {

    func testTheLineNamesVersionSystemChipAndModel() {
        XCTAssertEqual(FeedbackAppDetails.line(
            version: "0.14.0", build: "63",
            os: OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0),
            appleSilicon: true, model: "Parakeet Ultra"), sampleDetails)
    }

    func testAPatchReleaseAndNoModel() {
        XCTAssertEqual(FeedbackAppDetails.line(
            version: "0.14.0", build: "63",
            os: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1),
            appleSilicon: false, model: nil),
            "OpenSuperWhisper 0.14.0 (63) · macOS 15.6.1 · Intel")
    }
}

/// The card's draft and status: when Send is allowed, what a success and a failure leave behind.
@MainActor
final class FeedbackFormModelTests: XCTestCase {

    /// Successful sends seen by the model's `onSent`, which in the app ends the one-time ask.
    private var sentCount = 0

    private func makeModel(_ stub: FeedbackTransportStub) -> FeedbackFormModel {
        FeedbackFormModel(sender: stub.sender, appDetails: { sampleDetails },
                          onSent: { [self] in sentCount += 1 })
    }

    /// Whoever sent feedback is never asked for it (#206); a failed or refused send has not
    /// answered anything yet.
    func testOnlyASuccessCountsAsHavingSentFeedback() async {
        for (reply, sent) in [(FeedbackTransportStub.Reply.failure(.timedOut), 0), (.status(400), 0), (.status(200), 1)] {
            sentCount = 0
            let model = makeModel(FeedbackTransportStub(reply: reply))
            model.message = "It crashed"
            await model.send()
            XCTAssertEqual(sentCount, sent, "\(reply)")
        }
    }

    /// Opening the card, asked or not, sends nothing: only Send does.
    func testNothingGoesOutWithoutSend() {
        let stub = FeedbackTransportStub()
        let model = makeModel(stub)
        model.message = "Typed but not sent"
        model.cardClosed()
        model.discard()
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertEqual(sentCount, 0)
    }

    func testItStartsAsAnIdeaWithTheDetailsOn() {
        let model = makeModel(FeedbackTransportStub())
        XCTAssertEqual(model.kind, .idea)
        XCTAssertTrue(model.includeDetails)
        XCTAssertEqual(model.status, .editing)
        XCTAssertFalse(model.canSend)
    }

    func testSendNeedsTwoCharactersBesidesSpaces() {
        let model = makeModel(FeedbackTransportStub())
        for text in ["a", " a ", "\n\n a\t"] {
            model.message = text
            XCTAssertFalse(model.canSend, "\(text.debugDescription) was enough to send")
        }
        for text in ["ok", "a b"] {
            model.message = text
            XCTAssertTrue(model.canSend, "\(text.debugDescription) was not enough to send")
        }
    }

    func testTheSwitchDecidesWhetherTheDetailsGo() {
        let model = makeModel(FeedbackTransportStub())
        model.kind = .bug
        XCTAssertEqual(model.submission.context, "app · bug · " + sampleDetails)
        model.includeDetails = false
        XCTAssertEqual(model.submission.context, "app · bug")
    }

    func testASuccessThanksAndClearsTheForm() async throws {
        let stub = FeedbackTransportStub()
        let model = makeModel(stub)
        model.kind = .bug
        model.message = "It crashed"
        model.email = "camille@example.com"
        model.includeDetails = false

        await model.send()

        XCTAssertEqual(model.status, .sent)
        XCTAssertEqual(try jsonBody(XCTUnwrap(stub.requests.first))["message"], "It crashed")
        XCTAssertEqual(model.kind, .idea)
        XCTAssertEqual(model.message, "")
        XCTAssertEqual(model.email, "")
        XCTAssertTrue(model.includeDetails)

        model.cardClosed()
        XCTAssertEqual(model.status, .editing, "the thank-you showed again on the next open")
    }

    func testAFailureKeepsTheText() async {
        let model = makeModel(FeedbackTransportStub(reply: .failure(.timedOut)))
        model.kind = .bug
        model.message = "It crashed"
        model.email = "camille@example.com"

        await model.send()

        XCTAssertEqual(model.status, .failed)
        XCTAssertEqual(model.kind, .bug)
        XCTAssertEqual(model.message, "It crashed")
        XCTAssertEqual(model.email, "camille@example.com")
        XCTAssertTrue(model.canSend, "a failed send could not be retried")
    }

    func testSendIsOffWhileSending() async {
        let stub = FeedbackTransportStub(holds: true)
        let model = makeModel(stub)
        model.message = "Hello there"

        let sending = Task { await model.send() }
        while !stub.isHeld { await Task.yield() }
        XCTAssertEqual(model.status, .sending)
        XCTAssertFalse(model.canSend)
        model.cardClosed()
        XCTAssertEqual(model.status, .sending, "closing the card forgot a send in flight")

        stub.release()
        await sending.value
        XCTAssertEqual(model.status, .sent)
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testALongMessageShowsACounterThenCannotBeSent() {
        let model = makeModel(FeedbackTransportStub())
        model.message = String(repeating: "a", count: FeedbackFormModel.counterThreshold - 1)
        XCTAssertFalse(model.showsCounter)
        model.message += "a"
        XCTAssertTrue(model.showsCounter)
        XCTAssertTrue(model.canSend)

        model.message = String(repeating: "a", count: FeedbackSender.maxMessageLength + 1)
        XCTAssertEqual(model.messageLength, 4001)
        XCTAssertEqual(model.limitProblem, .messageTooLong)
        XCTAssertFalse(model.canSend)
    }

    func testATooLongEmailCannotBeSent() {
        let model = makeModel(FeedbackTransportStub())
        model.message = "Hello"
        model.email = String(repeating: "a", count: 190) + "@example.com"
        XCTAssertEqual(model.limitProblem, .emailTooLong)
        XCTAssertFalse(model.canSend)
    }

    func testARefusalIsNotTakenForAConnectionProblem() async {
        let stub = FeedbackTransportStub(reply: .status(400))
        let model = makeModel(stub)
        model.message = "It crashed"

        await model.send()

        XCTAssertEqual(model.status, .refused)
        XCTAssertEqual(model.message, "It crashed", "a refusal lost the text")
    }

    func testCancelDoesNothingWhileSending() async {
        let stub = FeedbackTransportStub(reply: .failure(.timedOut), holds: true)
        let model = makeModel(stub)
        model.kind = .bug
        model.message = "It crashed"

        let sending = Task { await model.send() }
        while !stub.isHeld { await Task.yield() }
        XCTAssertFalse(model.isEditable)
        model.discard()
        XCTAssertEqual(model.message, "It crashed", "Cancel dropped a draft still being sent")
        XCTAssertEqual(model.status, .sending)

        stub.release()
        await sending.value
        XCTAssertEqual(model.status, .failed)
        XCTAssertEqual(model.kind, .bug)
        XCTAssertEqual(model.message, "It crashed", "the failure came back over an empty form")
        XCTAssertTrue(model.isEditable)
    }

    func testCancelDropsTheDraftButClosingKeepsIt() {
        let model = makeModel(FeedbackTransportStub())
        model.message = "Half a thought"
        model.cardClosed()
        XCTAssertEqual(model.message, "Half a thought", "a click outside the card lost the draft")
        model.discard()
        XCTAssertEqual(model.message, "")
    }
}
