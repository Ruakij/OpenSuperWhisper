import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// A made-up field: what the watch finds after the paste and what each read returns. Reads run
/// out into `.unchanged`, a field nobody is touching.
@MainActor
private final class FakeField: CorrectionFieldSource {
    var landing: CorrectionTrail?
    var reads: [CorrectionRead] = []
    var inFront = true
    private(set) var readCount = 0

    init(landing: CorrectionTrail?) {
        self.landing = landing
    }

    func land(_ inserted: String) async -> CorrectionTrail? { landing }

    func read(_ trail: CorrectionTrail, unless seen: WatchedField.State?) async -> CorrectionRead {
        readCount += 1
        return reads.isEmpty ? .unchanged : reads.removeFirst()
    }

    func appIsInFront() -> Bool { inFront }
}

/// How a watch ends and what it hands over (#169), with a made-up field: nothing is read,
/// focused or pasted.
@MainActor
final class CorrectionWatchTests: XCTestCase {

    private static let dictated = "we should try rest sets today."
    private static let field = "Notes: " + dictated
    private static let edited = "Notes: we should try Rsets today."

    private let fast = CorrectionWatch.Timing(landingDelay: .milliseconds(1), landingAttempts: 2,
                                              pollInterval: .milliseconds(5), duration: .seconds(30),
                                              settle: .zero)

    private var trail: CorrectionTrail {
        CorrectionTrail(dictated: Self.dictated, window: Self.field, windowStart: 0,
                        caret: (Self.field as NSString).length)!
    }

    private func state(_ text: String, caret: Int? = nil) -> WatchedField.State {
        let length = (text as NSString).length
        return WatchedField.State(length: length, selection: NSRange(location: caret ?? length, length: 0))
    }

    private func edit(_ text: String? = nil, caret: Int? = nil) -> CorrectionRead {
        let text = text ?? Self.edited
        return .text(text, windowStart: 0, state: state(text, caret: caret))
    }

    /// Starts a watch on `field` and returns what it delivers, or nil if it delivers nothing
    /// within `timeout`.
    private func watch(_ field: FakeField, timing: CorrectionWatch.Timing? = nil,
                       isWanted: @escaping () -> Bool = { true }, timeout: TimeInterval = 2,
                       during: ((FakeField) async -> Void)? = nil) async -> String? {
        var delivered: String?
        let done = expectation(description: "delivered")
        CorrectionWatch.start(CorrectionWatch(inserted: Self.dictated, source: field, timing: timing ?? fast,
                                              isWanted: isWanted,
                                              deliver: { _, edited in delivered = edited; done.fulfill() }))
        await during?(field)
        await fulfillment(of: [done], timeout: timeout)
        return delivered
    }

    private func waitForReads(_ field: FakeField, atLeast count: Int) async {
        while field.readCount < count { try? await Task.sleep(for: .milliseconds(2)) }
    }

    override func tearDown() {
        CorrectionWatch.endCurrent()
        super.tearDown()
    }

    func testUnchangedReadsAreSkippedAndTheMinuteEndsOnTheLastText() async {
        let field = FakeField(landing: trail)
        field.reads = [edit(), .unchanged, .unchanged]
        var timing = fast
        timing.duration = .milliseconds(200)
        let delivered = await watch(field, timing: timing)
        XCTAssertEqual(delivered, "we should try Rsets today.")
        XCTAssertGreaterThan(field.readCount, 3, "kept reading through unchanged states")
    }

    /// A fix the user leaves alone is offered while they are still in the field, once.
    func testAFixLeftAloneIsOfferedBeforeTheWatchEnds() async {
        let field = FakeField(landing: trail)
        field.reads = [edit()]
        var timing = fast
        timing.idle = .milliseconds(20)
        var delivered: [String] = []
        let offered = expectation(description: "offered while watching")
        CorrectionWatch.start(CorrectionWatch(inserted: Self.dictated, source: field, timing: timing,
                                              isWanted: { true },
                                              deliver: { _, edited in
                                                  delivered.append(edited)
                                                  if delivered.count == 1 { offered.fulfill() }
                                              }))
        await fulfillment(of: [offered], timeout: 2)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(delivered, ["we should try Rsets today."], "one pause offers once")
        XCTAssertTrue(CorrectionWatch.isWatching, "and the watch goes on")
    }

    func testFocusLeavingTheFieldEndsTheWatch() async {
        let field = FakeField(landing: trail)
        field.reads = [edit(), .focusLeft]
        let delivered = await watch(field)
        XCTAssertEqual(delivered, "we should try Rsets today.")
    }

    func testTheAppLeavingTheFrontEndsTheWatch() async {
        let field = FakeField(landing: trail)
        field.reads = [edit()]
        let delivered = await watch(field, during: { field in
            await self.waitForReads(field, atLeast: 1)
            field.inFront = false
        })
        XCTAssertEqual(delivered, "we should try Rsets today.")
    }

    func testASentMessageEndsOnTheTextBeforeIt() async {
        let field = FakeField(landing: trail)
        field.reads = [edit(), edit("Notes: ")]
        let delivered = await watch(field)
        XCTAssertEqual(delivered, "we should try Rsets today.")
    }

    func testANewInsertionEndsTheWatchWithWhatItRead() async {
        let field = FakeField(landing: trail)
        field.reads = [edit()]
        let delivered = await watch(field, during: { field in
            await self.waitForReads(field, atLeast: 2)
            CorrectionWatch.endCurrent()
        })
        XCTAssertEqual(delivered, "we should try Rsets today.")
        XCTAssertFalse(CorrectionWatch.isWatching)
    }

    func testANewWatchEndsThePreviousOne() async {
        let first = FakeField(landing: trail)
        first.reads = [edit()]
        let delivered = await watch(first, during: { field in
            await self.waitForReads(field, atLeast: 2)
            CorrectionWatch.start(CorrectionWatch(inserted: Self.dictated, source: FakeField(landing: nil),
                                                  timing: self.fast, isWanted: { true }, deliver: { _, _ in }))
        })
        XCTAssertEqual(delivered, "we should try Rsets today.")
    }

    func testTurningItOffEndsTheWatchWithoutOffering() async {
        let field = FakeField(landing: trail)
        field.reads = [edit()]
        var wanted = true
        var delivered = false
        CorrectionWatch.start(CorrectionWatch(inserted: Self.dictated, source: field, timing: fast,
                                              isWanted: { wanted }, deliver: { _, _ in delivered = true }))
        await waitForReads(field, atLeast: 1)
        wanted = false
        while CorrectionWatch.isWatching { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(delivered)
    }

    func testAFieldWhereTheDictationIsNotFoundIsNotWatched() async {
        let field = FakeField(landing: nil)
        var delivered = false
        CorrectionWatch.start(CorrectionWatch(inserted: Self.dictated, source: field, timing: fast,
                                              isWanted: { true }, deliver: { _, _ in delivered = true }))
        while CorrectionWatch.isWatching { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(delivered)
        XCTAssertEqual(field.readCount, 0)
    }

    func testAWordStillBeingTypedIsLeftOut() async {
        let field = FakeField(landing: trail)
        let typing = "Notes: we should try Rsets tod"
        field.reads = [edit(typing), .focusLeft]
        var timing = fast
        timing.settle = .seconds(30)
        let delivered = await watch(field, timing: timing)
        XCTAssertEqual(delivered, "we should try Rsets ")
    }

    func testAFinishedWordAtTheCaretIsKept() async {
        let field = FakeField(landing: trail)
        field.reads = [edit()]
        var timing = fast
        timing.duration = .milliseconds(100)
        timing.settle = .milliseconds(10)
        let delivered = await watch(field, timing: timing)
        XCTAssertEqual(delivered, "we should try Rsets today.")
    }

    func testWantedNeedsTheSettingAndTheDictionary() {
        let scratch = ScratchPreferences()
        defer { scratch.restore() }
        let prefs = AppPreferences.shared
        prefs.suggestDictionaryWords = true
        XCTAssertFalse(CorrectionWatch.isWanted(), "dictionary off")
        prefs.customDictionaryEnabled = true
        XCTAssertTrue(CorrectionWatch.isWanted())
        prefs.suggestDictionaryWords = false
        XCTAssertFalse(CorrectionWatch.isWanted())
    }

    func testDroppingTheWordAtTheCaret() {
        XCTAssertEqual(CorrectionTrail.droppingWord(at: 9, in: "try Rsets tod"), "try  tod")
        XCTAssertEqual(CorrectionTrail.droppingWord(at: 13, in: "try Rsets tod"), "try Rsets ")
        XCTAssertEqual(CorrectionTrail.droppingWord(at: 10, in: "try Rsets tod"), "try Rsets tod",
                       "a caret after a space is between words")
        XCTAssertEqual(CorrectionTrail.droppingWord(at: 0, in: "Rsets"), "Rsets")
    }
}
