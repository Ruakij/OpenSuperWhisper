import AVFoundation
import Combine
import Foundation
import OpenSuperWhisperCore

/// What the level bar draws, and what the quiet warning says.
struct InputLevelReading: Equatable {
    var levelDBFS: Float
    var peakDBFS: Float
    var verdict: QuietInput.Verdict

    static let silent = InputLevelReading(levelDBFS: InputLevel.emptyDBFS,
                                          peakDBFS: InputLevel.emptyDBFS,
                                          verdict: .listening)
}

/// Turns buffer levels into readings, no more often than the bar can use them.
struct InputLevelProcessor {
    /// About the display's refresh, halved: the bar animates between readings anyway.
    static let publishInterval: TimeInterval = 1.0 / 30

    private var smoother = InputLevelSmoother()
    private var watch = QuietInputWatch()
    private var sincePublished: TimeInterval = .infinity
    private var publishedVerdict: QuietInput.Verdict?

    /// The reading to publish after this buffer, or nil when the last one is recent enough.
    mutating func consume(rmsDBFS: Float, duration: TimeInterval) -> InputLevelReading? {
        smoother.feed(rmsDBFS: rmsDBFS, duration: duration)
        watch.observe(rmsDBFS: rmsDBFS, duration: duration)
        sincePublished += duration
        let verdict = watch.verdict
        guard sincePublished >= Self.publishInterval || verdict != publishedVerdict else { return nil }
        sincePublished = 0
        publishedVerdict = verdict
        return InputLevelReading(levelDBFS: smoother.levelDBFS, peakDBFS: smoother.peakDBFS, verdict: verdict)
    }
}

/// Somewhere levels come from. The real one opens a capture session; tests use a stand-in.
protocol InputLevelSource: AnyObject {
    /// Starts delivering readings for the microphone with this CoreAudio UID, or for the system
    /// input when it is nil or not connected. Replaces whatever was running.
    func start(deviceUID: String?, onReading: @escaping (InputLevelReading) -> Void)
    func stop()
}

/// The live level of the microphone the next dictation will record from, for the pickers.
///
/// A capture of its own, separate from the recorder and from the bubble's spectrum: those only
/// run during a take, while a picker shows a microphone before any take and may show one macOS
/// is not using yet. Several views can show it at once, so it is
/// reference counted: open while at least one of them holds a token, closed (and the microphone
/// indicator off) as soon as the last one lets go.
@MainActor
final class InputLevelMonitor: ObservableObject {
    static let shared = InputLevelMonitor(source: CaptureSessionLevelSource(), mayOpenInput: {
        // Under test the hosted app renders the real pickers; they must not open a real microphone.
        guard !DefaultsStore.isRunningTests else { return false }
        // A picker on its own never asks for microphone access: that prompt belongs to
        // onboarding and to the first dictation, not to opening a menu.
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    })

    @Published private(set) var reading = InputLevelReading.silent

    /// One view's hold on the capture. Releasing it releases that view only.
    struct Token: Hashable {
        fileprivate let id = UUID()
    }

    private let source: InputLevelSource
    private let mayOpenInput: () -> Bool
    private var holders = Set<UUID>()
    private var deviceUID: String?
    private(set) var isRunning = false
    /// Bumped on every stop, so readings still in flight from a closed capture are dropped
    /// instead of repainting a bar that was just cleared.
    private var generation = 0
    private var heardFromSource = false

    #if DEBUG
    /// Set once something has been staged: the probes draw staged levels and must never open the
    /// microphone behind them.
    private var isStaged = false

    func stage(_ staged: InputLevelReading) {
        isStaged = true
        reading = staged
    }
    #endif

    init(source: InputLevelSource, mayOpenInput: @escaping () -> Bool) {
        self.source = source
        self.mayOpenInput = mayOpenInput
    }

    /// Starts showing the level of the microphone with this UID, for as long as the token is held.
    func begin(deviceUID: String?) -> Token {
        let token = Token()
        holders.insert(token.id)
        if !isRunning || self.deviceUID != deviceUID {
            self.deviceUID = deviceUID
            restart()
        }
        return token
    }

    /// The microphone the next dictation will use changed while a view is showing it.
    func retarget(_ token: Token, deviceUID: String?) {
        guard holders.contains(token.id), self.deviceUID != deviceUID else { return }
        self.deviceUID = deviceUID
        if isRunning { restart() }
    }

    func end(_ token: Token) {
        guard holders.remove(token.id) != nil, holders.isEmpty else { return }
        stop()
    }

    private func restart() {
        stop()
        guard canOpen else { return }
        let generation = self.generation
        heardFromSource = false
        source.start(deviceUID: deviceUID) { [weak self] reading in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.heardFromSource = true
                self.reading = reading
            }
        }
        isRunning = true
        warnIfNothingArrives(generation: generation)
    }

    /// A capture that opens but never delivers a buffer it can read leaves the bar empty and the
    /// verdict listening forever; past the listening window, that is a microphone that hears
    /// nothing, and the user is told so.
    private func warnIfNothingArrives(generation: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(QuietInput.listeningWindow))
            guard let self, self.generation == generation, self.isRunning, !self.heardFromSource else { return }
            Diag.mark("input level: no readable audio after \(QuietInput.listeningWindow)s")
            self.reading.verdict = .tooQuiet
        }
    }

    private func stop() {
        guard isRunning else { return }
        source.stop()
        isRunning = false
        generation &+= 1
        reading = .silent
    }

    private var canOpen: Bool {
        #if DEBUG
        if isStaged { return false }
        #endif
        return mayOpenInput()
    }
}
