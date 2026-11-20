import Foundation

/// The order in which a capture starts, stops and releases its resources, whichever threads ask.
///
/// A stop or a failure that arrives while the start is still running waits for the start to
/// return, so the teardown never overlaps it. Exactly one thread owns the teardown; the others
/// return at once, or wait for it in `stop()`. The audio calls themselves are closures, so the
/// ordering can be tested without a device.
final class CaptureLifecycle {
    struct Operations {
        /// Adds the listeners and starts the queue.
        var start: () -> OSStatus
        /// Stops the queue and hands its pending buffers to the writer.
        var stop: () -> Void
        /// Returns once the writer has handled every buffer the stop handed over.
        var drain: () -> Void
        /// Removes the listeners and frees the queue and the file.
        var release: () -> Void
    }

    enum State { case ready, starting, running, stopping, closing, finished }

    /// What arrived while the start was running.
    private enum Pending {
        case none
        case stop
        case failure(Error)
    }

    /// Called once, after the teardown, on the thread that ran it. Never after a plain stop.
    var onFailure: ((Error) -> Void)?

    private let ops: Operations
    private let stopWait: TimeInterval
    private let condition = NSCondition()
    private var state = State.ready
    private var pending = Pending.none

    init(_ ops: Operations, stopWait: TimeInterval = 1) {
        self.ops = ops
        self.stopWait = stopWait
    }

    /// Starts the capture. False when it did not start or was ended while starting; throws when
    /// the start itself failed, after releasing everything.
    @discardableResult
    func start() throws -> Bool {
        condition.lock()
        guard state == .ready else { condition.unlock(); return false }
        state = .starting
        condition.unlock()

        let status = ops.start()

        condition.lock()
        let ended = pending
        state = .running
        condition.unlock()

        guard status == noErr else {
            end(failure: nil)
            throw InputQueueRecorder.Failure(operation: "AudioQueueStart", status: status)
        }
        switch ended {
        case .none:
            return true
        case .stop:
            end(failure: nil)
            return false
        case .failure(let error):
            end(failure: error)
            return false
        }
    }

    /// Ends the capture and releases its resources. The first caller runs the teardown, unless
    /// the start is in progress, which then runs it as soon as it returns. With a `failure` the
    /// owner reports it through `onFailure` afterwards.
    func end(failure: Error?) {
        condition.lock()
        let started: Bool
        switch state {
        case .ready:
            state = .closing
            started = false
        case .running:
            state = .stopping
            started = true
        case .starting:
            if case .none = pending { pending = failure.map(Pending.failure) ?? .stop }
            condition.unlock()
            return
        case .stopping, .closing, .finished:
            condition.unlock()
            return
        }
        condition.unlock()

        if started {
            ops.stop()
            // Buffers the stop handed back are written while the state is `.stopping`.
            ops.drain()
            set(.closing)
        }
        ops.release()
        set(.finished)
        if let failure { onFailure?(failure) }
    }

    /// `end(failure: nil)`, then waits up to `stopWait` for whichever thread owns the teardown.
    /// False when the wait ran out.
    @discardableResult
    func stop() -> Bool {
        end(failure: nil)
        let deadline = Date(timeIntervalSinceNow: stopWait)
        condition.lock()
        defer { condition.unlock() }
        while state != .finished {
            if !condition.wait(until: deadline) { return state == .finished }
        }
        return true
    }

    var isRunning: Bool { read() == .running }

    /// Whether the writer takes the buffers it is handed: while the capture runs and while the
    /// stop flushes the last ones. The first buffers can arrive before `start()` has returned.
    var acceptsBuffers: Bool {
        switch read() {
        case .starting, .running, .stopping: return true
        case .ready, .closing, .finished: return false
        }
    }

    /// Whether a handled buffer goes back to the queue.
    var reenqueues: Bool {
        switch read() {
        case .starting, .running: return true
        case .ready, .stopping, .closing, .finished: return false
        }
    }

    private func read() -> State {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    private func set(_ new: State) {
        condition.lock()
        state = new
        condition.broadcast()
        condition.unlock()
    }
}
