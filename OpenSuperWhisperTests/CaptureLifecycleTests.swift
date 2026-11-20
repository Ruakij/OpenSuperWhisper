import XCTest
@testable import OpenSuperWhisper

/// The order of start, stop, failure and release, with the audio calls replaced by closures that
/// log and, where a test needs a thread to be somewhere, block on a gate.
final class CaptureLifecycleTests: XCTestCase {

    private final class Log {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    private struct Boom: Error {}

    private func make(_ log: Log,
                      start: @escaping () -> OSStatus = { noErr },
                      stop: @escaping () -> Void = {},
                      wait: TimeInterval = 1) -> CaptureLifecycle {
        CaptureLifecycle(.init(
            start: { log.add("start>"); let status = start(); log.add("start<"); return status },
            stop: { log.add("stop"); stop() },
            drain: { log.add("drain") },
            release: { log.add("release") }), stopWait: wait)
    }

    func testAStopDuringTheStartNeverOverlapsIt() {
        let log = Log()
        let inStart = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let lifecycle = make(log, start: {
            inStart.signal()
            gate.wait()
            return noErr
        })
        let started = expectation(description: "start returned")
        var startResult: Bool?
        DispatchQueue.global().async {
            startResult = try? lifecycle.start()
            started.fulfill()
        }
        inStart.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.signal() }

        XCTAssertTrue(lifecycle.stop())
        wait(for: [started], timeout: 2)
        XCTAssertEqual(log.all, ["start>", "start<", "stop", "drain", "release"])
        XCTAssertEqual(startResult, false)
    }

    func testAStopDuringAFailureWaitsForTheTeardown() {
        let log = Log()
        let inStop = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let lifecycle = make(log, stop: {
            inStop.signal()
            gate.wait()
        })
        let reported = expectation(description: "failure reported")
        reported.expectedFulfillmentCount = 1
        reported.assertForOverFulfill = true
        lifecycle.onFailure = { _ in reported.fulfill() }
        XCTAssertEqual(try lifecycle.start(), true)

        DispatchQueue.global().async { lifecycle.end(failure: Boom()) }
        inStop.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.signal() }

        XCTAssertTrue(lifecycle.stop())
        XCTAssertTrue(log.all.contains("release"), "the stop returns after the file is closed")
        wait(for: [reported], timeout: 2)
    }

    func testAStopBeforeTheStartOpensNothing() throws {
        let log = Log()
        let lifecycle = make(log)
        XCTAssertTrue(lifecycle.stop())
        XCTAssertEqual(try lifecycle.start(), false)
        XCTAssertEqual(log.all, ["release"])
    }

    func testAStuckTeardownBoundsTheWait() {
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        let lifecycle = make(log, stop: { release.wait() }, wait: 0.2)
        addTeardownBlock { release.signal() }
        XCTAssertEqual(try? lifecycle.start(), true)

        DispatchQueue.global().async { lifecycle.end(failure: nil) }
        while !log.all.contains("stop") { usleep(1000) }

        let returned = expectation(description: "stop returned")
        var result: Bool?
        var elapsed: TimeInterval = 0
        DispatchQueue.global().async {
            let began = Date()
            result = lifecycle.stop()
            elapsed = Date().timeIntervalSince(began)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 2)
        XCTAssertEqual(result, false)
        // The wait is 0.2 s; the upper bound leaves room for a loaded machine.
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testAFailureDuringTheStartIsReportedOnceAfterIt() throws {
        let log = Log()
        let inStart = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let lifecycle = make(log, start: {
            inStart.signal()
            gate.wait()
            return noErr
        })
        let reported = expectation(description: "failure reported")
        reported.expectedFulfillmentCount = 1
        reported.assertForOverFulfill = true
        lifecycle.onFailure = { _ in
            XCTAssertTrue(log.all.contains("release"), "reported after the teardown")
            reported.fulfill()
        }
        let started = expectation(description: "start returned")
        var startResult: Bool?
        DispatchQueue.global().async {
            startResult = try? lifecycle.start()
            started.fulfill()
        }
        inStart.wait()
        lifecycle.end(failure: Boom())
        XCTAssertEqual(log.all, ["start>"], "nothing is torn down while the start runs")
        gate.signal()

        wait(for: [started, reported], timeout: 2)
        XCTAssertEqual(startResult, false)
        XCTAssertEqual(log.all, ["start>", "start<", "stop", "drain", "release"])
    }

    func testAFailedStartReleasesAndThrows() {
        let log = Log()
        let lifecycle = make(log, start: { -50 })
        XCTAssertThrowsError(try lifecycle.start())
        XCTAssertEqual(log.all, ["start>", "start<", "stop", "drain", "release"])
        XCTAssertFalse(lifecycle.isRunning)
    }

    func testBuffersAreWrittenWhileStoppingButNotReenqueued() throws {
        let log = Log()
        var duringStop: (accepts: Bool, reenqueues: Bool)?
        var lifecycle: CaptureLifecycle!
        lifecycle = make(log, stop: {
            duringStop = (lifecycle.acceptsBuffers, lifecycle.reenqueues)
        })
        XCTAssertEqual(try lifecycle.start(), true)
        XCTAssertTrue(lifecycle.acceptsBuffers)
        XCTAssertTrue(lifecycle.reenqueues)

        lifecycle.stop()
        XCTAssertEqual(duringStop?.accepts, true)
        XCTAssertEqual(duringStop?.reenqueues, false)
        XCTAssertFalse(lifecycle.acceptsBuffers)
        XCTAssertFalse(lifecycle.reenqueues)
    }

    func testEndingTwiceTearsDownOnce() throws {
        let log = Log()
        let lifecycle = make(log)
        XCTAssertEqual(try lifecycle.start(), true)
        lifecycle.end(failure: nil)
        lifecycle.end(failure: Boom())
        lifecycle.stop()
        XCTAssertEqual(log.all, ["start>", "start<", "stop", "drain", "release"])
    }
}
