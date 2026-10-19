import AVFoundation
import Combine
import Foundation
import SwiftUI
import AppKit
import CoreAudio
import os
import OpenSuperWhisperCore

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    @Published var isConnecting = false
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    /// The volume duck waiting for the start chime to finish. Cancelled by a stop that lands
    /// first, or the duck would fire after the restore and leave the Mac turned down.
    private var pendingDuck: DispatchWorkItem?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?
    private var activeMicrophoneSubscription: AnyCancellable?
    private var connectionCheckTimer: DispatchSourceTimer?
    private var recordingDeviceID: AudioDeviceID?

    /// The next take's recorder, created and prepared ahead so a key press only has to call
    /// `record()`: building one costs 10-50ms, and every word spoken meanwhile is lost. It also
    /// keeps the audio hardware warm. Only valid for the input device and channel count it was
    /// prepared for.
    private struct PreparedTake {
        let recorder: AVAudioRecorder
        let url: URL
        let deviceID: AudioDeviceID
        let channelCount: Int
    }
    /// What `prepareToRecord` leaves in the file: the WAV header and no samples.
    private static let headerOnlyFileSize = 4096
    /// Filled from `preparationQueue` while a start takes it from another thread, hence the lock.
    private let preparedTake = OSAllocatedUnfairLock<PreparedTake?>(uncheckedState: nil)
    /// Serial, so the request made last finishes last and its take is the one that stays.
    private let preparationQueue = DispatchQueue(label: "AudioRecorder.preparation", qos: .userInitiated)

    /// Holds App Nap off for as long as a recording is running. Nil when nothing is recording.
    ///
    /// App Nap throttles timers and defers dispatch work for an app that is not frontmost and has
    /// no visible window — which describes every dictation, since the point of the app is to record
    /// while another app has focus. Playing audio holds App Nap off on its own; *recording* audio
    /// does not, so a recorder without an assertion gets suspended.
    ///
    /// That was #98. CoreAudio's I/O threads are real-time and carry on regardless, so the clip
    /// kept growing while everything meant to react to it stopped: the connection wait never
    /// ticked, the `isConnecting`/`isRecording` updates sat unapplied on the main queue, and the
    /// trigger key did nothing. The bubble stayed up with no way to stop it, and force-quitting was
    /// the only way out. Locking the Mac or opening Sound settings to change input is simply how
    /// you end up backgrounded and occluded, which is why the bug looked like it was about
    /// switching devices.
    ///
    /// Idle *system* sleep is deliberately left enabled: a recording that somehow never ends should
    /// not also keep the Mac awake for ever.
    private var recordingActivity: NSObjectProtocol?

    // MARK: - Singleton Instance

    static let shared = AudioRecorder()
    
    override private init() {
        let tempDir = FileManager.default.temporaryDirectory
        temporaryDirectory = tempDir.appendingPathComponent("temp_recordings")
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        setup()
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = microphoneChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        updateCanRecordStatus()
        // Ahead of the first preparation on the same queue, so the sweep cannot meet its file.
        preparationQueue.async { [weak self] in self?.removeAbandonedPreparedTakes() }
        prepareNextTakeInBackground()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }

        // Connects, disconnects and system input changes all end in a new active microphone, which
        // is published only after MicrophoneService has applied them. Observing the notifications
        // here would race its own observers.
        activeMicrophoneSubscription = MicrophoneService.shared.$currentMicrophone
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prepareNextTakeInBackground() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // CoreAudio may not have settled yet when the wake notification fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.prepareNextTakeInBackground()
            }
        }
    }
    
    private func updateCanRecordStatus() {
        canRecord = MicrophoneService.shared.getActiveMicrophone() != nil
    }

    private static func recorderSettings(channelCount: Int) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
    }

    /// A UUID suffix keeps each recording's temp file unique. Without it, two recordings
    /// started in the same wall-clock second share a path, and starting the next recording
    /// would truncate the previous clip's file while the background pipeline is still reading
    /// it to transcribe. (parallel-recording)
    private func newRecordingURL() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        return temporaryDirectory.appendingPathComponent("rec-\(timestamp)-\(UUID().uuidString.prefix(8)).wav")
    }

    /// Off the main thread: building a recorder touches CoreAudio and AVFoundation, which can stall.
    private func prepareNextTakeInBackground() {
        // The hosted test runner launches the app under another code signature, so preparing a
        // recorder there makes macOS ask for the microphone and the runner hangs on the prompt.
        guard !DefaultsStore.isRunningTests else { return }
        // The microphone active at request time: queued work may run after it changed.
        let activeMic = MicrophoneService.shared.getActiveMicrophone()
        preparationQueue.async { [weak self] in self?.prepareNextTake(for: activeMic) }
    }

    private func prepareNextTake(for activeMic: MicrophoneService.AudioDevice?) {
        // A recorder records from the system input, which a pinned microphone becomes only when a
        // recording starts. Until then a take would be bound to another device and be discarded.
        guard let activeMic,
              let deviceID = MicrophoneService.shared.getCurrentSystemDefaultInputDevice(),
              MicrophoneService.shared.getCoreAudioDeviceID(for: activeMic) == deviceID
        else { return }
        let channelCount = recordingChannels(for: activeMic).recorded
        let url = newRecordingURL()
        // `deviceID` is read before the recorder exists: an input that changes meanwhile leaves
        // the take marked with the old device, and the start discards it.
        guard let recorder = try? AVAudioRecorder(url: url, settings: Self.recorderSettings(channelCount: channelCount)),
              recorder.prepareToRecord()
        else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let take = PreparedTake(recorder: recorder, url: url, deviceID: deviceID, channelCount: channelCount)
        let replaced = preparedTake.withLockUnchecked { state in
            defer { state = take }
            return state
        }
        if let replaced {
            try? FileManager.default.removeItem(at: replaced.url)
        }
    }

    private func createTemporaryDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create temporary recordings directory: \(error)")
        }
    }

    /// A take prepared by an earlier run and never started stays behind as a header-only file that
    /// nothing else removes. The age keeps the sweep off a file another running instance has just
    /// prepared.
    private func removeAbandonedPreparedTakes() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: Array(keys))) ?? []
        let cutoff = Date().addingTimeInterval(-60)
        for url in files where url.lastPathComponent.hasPrefix("rec-") && url.pathExtension == "wav" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize, size <= Self.headerOnlyFileSize,
                  let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    /// The short chime used to confirm a recording state change. Internal rather than private so
    /// the Space latch can reuse it — same class of feedback, same preference.
    /// Which chime to play. The end of a take used to reuse the start chime, which sounded like a
    /// new recording beginning; the stop chime is the same note a fourth lower.
    enum Chime: String {
        case start = "notification"
        case stop = "notification-stop"
    }

    /// How long the chime is worth hearing before the volume may drop. The file runs about
    /// 1.8 s, silence included, and waiting for all of it left the room loud well into the
    /// take. Measured, the note has faded by about 20 dB at 150 ms.
    static let chimeAudibleLength: TimeInterval = 0.15

    func playNotificationSound(_ chime: Chime = .start) {
        // Try to play using NSSound first
        guard let soundURL = Bundle.main.url(forResource: chime.rawValue, withExtension: "mp3") else {
            print("Failed to find notification sound file")
            // Fall back to system sound if notification.mp3 is not found
            NSSound.beep()
            return
        }
        
        if let sound = NSSound(contentsOf: soundURL, byReference: false) {
            // Set maximum volume to ensure it's audible
            sound.volume = 0.3
            sound.play()
            notificationSound = sound
        } else {
            print("Failed to create NSSound from URL, falling back to system beep")
            // Fall back to system beep if NSSound creation fails
            NSSound.beep()
        }
    }
    
    /// Tells the system this app is doing work the user asked for, so App Nap leaves it alone.
    /// See `recordingActivity`. Ending any assertion already held keeps them from stacking: a
    /// start that never saw a matching stop would otherwise leak one and hold App Nap off for good.
    /// Internal rather than private so a test can check the pair stays balanced.
    func beginRecordingActivity() {
        endRecordingActivity()
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Recording audio for dictation")
    }

    /// Releases the assertion. Safe to call when none is held, which is what makes it usable both
    /// on every exit path and as the guard against stacking in `beginRecordingActivity`.
    func endRecordingActivity() {
        guard let activity = recordingActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        recordingActivity = nil
    }

    /// Whether an assertion is currently held. Exists so a test can check that starting and
    /// stopping a recording leaves none behind.
    var isHoldingRecordingActivity: Bool { recordingActivity != nil }

    /// Starts the recording in a detached task and returns at once; false when there is no input
    /// device. The hotkey path calls it before the caret lookup, the indicator and the context
    /// capture, which cost 25-60ms on the main thread (more for a browser URL), and every word
    /// spoken in that time is lost.
    func startRecordingInBackground() -> Bool {
        // `getActiveMicrophone()` reads the cached device, so this stays off the blocking
        // AVFoundation path that the hotkey tap must avoid (#freeze).
        guard MicrophoneService.shared.getActiveMicrophone() != nil else { return false }
        Task.detached { [self] in startRecording() }
        return true
    }

    func startRecording() {
        Diag.mark("recorder.startRecording (canRecord=\(canRecord))")
        guard canRecord else {
            print("Cannot start recording - no audio input available")
            return
        }

        if isRecording || isConnecting {
            print("stop recording while recording")
            _ = stopRecording()
        }

        // Before any of the audio setup, so the connection wait and the state updates that follow
        // are already protected from being throttled. (#98)
        beginRecordingActivity()

        #if os(macOS)
        if let activeMic = MicrophoneService.shared.getActiveMicrophone() {
            Diag.measure("setAsSystemDefaultInput") {
                _ = MicrophoneService.shared.setAsSystemDefaultInput(activeMic)
            }
            print("Set system default input to: \(activeMic.displayName)")

            if let deviceID = MicrophoneService.shared.getCoreAudioDeviceID(for: activeMic) {
                recordingDeviceID = deviceID
            }
        }
        #endif

        let requiresConnection = Diag.measure("isActiveMicrophoneRequiresConnection") {
            MicrophoneService.shared.isActiveMicrophoneRequiresConnection()
        }
        // Which device a take ran on, whether it has to connect first and how many of its
        // channels are recorded: the facts that pick the start path and the file's format, and
        // the first worth knowing from a report of a take going wrong.
        let channels = recordingChannels(for: MicrophoneService.shared.getActiveMicrophone())
        Diag.mark("recorder.device=\(MicrophoneService.shared.getActiveMicrophone()?.displayName ?? "none") "
            + "requiresConnection=\(requiresConnection) channels=\(channels.description)")
        updateRecordingState(isRecording: false, isConnecting: requiresConnection)
        startRecordingWithRecorder(channelCount: channels.recorded, monitorConnection: requiresConnection)

        // After the mic is open: pausing media, the chime and the duck cost ~100ms that would
        // otherwise sit between the key press and the first captured sample. A failed start has
        // no stop to undo them, so it skips them.
        guard currentRecordingURL != nil else { return }
        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.pauseMedia()
        }
        // Chime first, then lower the volume: ducked first, the start chime played at the
        // ducked level, 10% by default, and could not be heard at all, while the end chime,
        // played after the restore, could.
        var chimeLength: TimeInterval = 0
        if AppPreferences.shared.playSoundOnRecordStart {
            playNotificationSound()
            chimeLength = Self.chimeAudibleLength
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            let level = Float32(AppPreferences.shared.reduceVolumeLevel)
            // Checked when it fires: a take stopped meanwhile has already restored the volume.
            let duck = DispatchWorkItem { [weak self] in
                guard self?.currentRecordingURL != nil else { return }
                SystemVolumeController.shared.duck(to: level)
            }
            DispatchQueue.main.async { [weak self] in
                self?.pendingDuck?.cancel()
                self?.pendingDuck = duck
                DispatchQueue.main.asyncAfter(deadline: .now() + chimeLength, execute: duck)
            }
        }
    }

    struct ChannelChoice {
        let recorded: Int
        let reported: Int
        let isBuiltIn: Bool

        var description: String { "\(recorded)/\(reported)\(isBuiltIn ? " builtIn" : "")" }
    }

    /// How many channels to ask the recorder for. A multi-input interface (an Audient EVO 4: two
    /// mics and two loopback) can carry the speech on any one of its inputs, so all of them are
    /// recorded and the converter mixes the ones with signal. The built-in mic is the opposite
    /// case. It normally reports one processed channel, but a stuck coreaudiod (seen on a macOS
    /// 27.2 beta, cleared by restarting it) made it report three raw capsules that recorded
    /// 25-30 dB too quiet, and System Settings' own meter barely moved either. One channel is
    /// enough for speech in both states, and the core lifts a clip that is still too quiet
    /// (`QuietClipGain`).
    static func recordingChannelCount(isBuiltIn: Bool, reportedChannels: Int) -> Int {
        isBuiltIn ? 1 : max(reportedChannels, 1)
    }

    private func recordingChannels(for activeMic: MicrophoneService.AudioDevice?) -> ChannelChoice {
        let service = MicrophoneService.shared
        guard let activeMic else {
            return ChannelChoice(recorded: 1, reported: 1, isBuiltIn: false)
        }
        let isBuiltIn = service.hasBuiltInTransport(activeMic)
        let reported = service.getInputChannelCount(for: activeMic)
        return ChannelChoice(
            recorded: Self.recordingChannelCount(isBuiltIn: isBuiltIn, reportedChannels: reported),
            reported: reported, isBuiltIn: isBuiltIn)
    }

    private enum StartError: Error {
        case recorderRefused
    }

    /// The recorder is recording once this returns. `metering` is for the connection wait.
    private func beginTake(channelCount: Int, metering: Bool) throws -> (recorder: AVAudioRecorder, url: URL) {
        let taken = preparedTake.withLockUnchecked { state in
            defer { state = nil }
            return state
        }
        if let prepared = taken {
            // The file is gone when the system cleans the temp directory under an idle app;
            // recording into it would save nothing.
            let fits = prepared.deviceID == MicrophoneService.shared.getCurrentSystemDefaultInputDevice()
                && prepared.channelCount == channelCount
                && FileManager.default.fileExists(atPath: prepared.url.path)
            // `record()` returns false for a recorder that cannot start (sleep, a device reset);
            // a fresh one takes over then.
            if fits, record(prepared.recorder, metering: metering) {
                return (prepared.recorder, prepared.url)
            }
            try? FileManager.default.removeItem(at: prepared.url)
        }
        Diag.mark("recorder.preparedTake unusable or missing, building a fresh recorder")
        let url = newRecordingURL()
        let recorder = try AVAudioRecorder(url: url, settings: Self.recorderSettings(channelCount: channelCount))
        guard record(recorder, metering: metering) else {
            try? FileManager.default.removeItem(at: url)
            throw StartError.recorderRefused
        }
        return (recorder, url)
    }

    private func record(_ recorder: AVAudioRecorder, metering: Bool) -> Bool {
        recorder.delegate = self
        recorder.isMeteringEnabled = metering
        return recorder.record()
    }

    private func startRecordingWithRecorder(channelCount: Int, monitorConnection: Bool) {
        do {
            let take = try Diag.measure("recorder.beginTake") {
                try beginTake(channelCount: channelCount, metering: monitorConnection)
            }
            audioRecorder = take.recorder
            currentRecordingURL = take.url
            print("start record file to \(take.url)")
            Task { @MainActor in SpectrumAnalyzer.shared.start() }
            if monitorConnection {
                startConnectionMonitoring()
            } else {
                updateRecordingState(isRecording: true, isConnecting: false)
            }
            print("Recording started successfully")
        } catch {
            print("Failed to start recording: \(error)")
            currentRecordingURL = nil
            // No recording to protect, and nothing will call `stopRecording` for a start that
            // never happened — so release the assertion here or it is held for ever.
            endRecordingActivity()
            updateRecordingState(isRecording: false, isConnecting: false)
            // The start used up the prepared take, and no stop follows to prepare the next.
            prepareNextTakeInBackground()
        }
    }
    
    /// What a stop produced. A clip and an accidental tap used to be the same `nil`, so a
    /// recording that captured nothing ended as quietly as one the user never meant to make,
    /// and the only signal was noticing afterwards that the words were missing (#117).
    enum StopOutcome {
        case clip(URL)
        /// Real audio, just too little of it. Dropped without a word, as it always has been:
        /// a brushed trigger key should not queue an empty clip or flash a message.
        case tooShort
        /// No audio at all, so the take never began. The user spoke into nothing and has to be
        /// told, because unlike a brushed key this one costs them what they said.
        case noAudio

        var url: URL? {
            if case .clip(let url) = self { return url }
            return nil
        }

        /// Classify a finished take from what it produced. Pure, so the boundary between "we
        /// heard nothing" and "you brushed the key" is pinned by tests instead of only being
        /// exercised by a real recorder against a real microphone.
        ///
        /// A duration of zero covers both a file with no samples and one the player cannot
        /// open: neither holds anything to transcribe, and handing the second to the engine
        /// only moves the failure somewhere with less context.
        static func of(url: URL?, duration: TimeInterval) -> StopOutcome {
            guard let url, duration > 0 else { return .noAudio }
            return duration < AudioRecorder.minimumUsableDuration ? .tooShort : .clip(url)
        }
    }

    /// Below this, a take is treated as an accidental trigger press rather than a dictation.
    static let minimumUsableDuration: TimeInterval = 1.0

    func stopRecording() -> StopOutcome {
        // Runs on the main thread (IndicatorViewModel is @MainActor). AudioQueueStop waits for the
        // queue to drain, so an input device pulled out from under it could stall the app here —
        // timed so a `▶` with no `◀` would name it rather than leaving a silent freeze.
        Diag.measure("AVAudioRecorder.stop") { audioRecorder?.stop() }
        endRecordingActivity()

        updateRecordingState(isRecording: false, isConnecting: false)
        Task { @MainActor in SpectrumAnalyzer.shared.stop() }
        stopConnectionMonitoring()
        prepareNextTakeInBackground()

        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.resumeMedia()
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            cancelPendingDuck()
            SystemVolumeController.shared.restore()
        }

        let url = currentRecordingURL
        currentRecordingURL = nil

        let duration = url.flatMap { try? AVAudioPlayer(contentsOf: $0).duration } ?? 0
        let outcome = StopOutcome.of(url: url, duration: duration)
        if outcome.url == nil, let url {
            try? FileManager.default.removeItem(at: url)
        }
        if case .noAudio = outcome {
            Diag.mark("recorder.stop - no audio captured, clip discarded")
        }
        // Only a take that goes on to be transcribed gets the end chime: a brushed key stays as
        // silent as it always was, and a cancel is not a stop.
        if outcome.url != nil, AppPreferences.shared.playSoundOnRecordStop {
            playNotificationSound(.stop)
        }
        return outcome
    }

    private func cancelPendingDuck() {
        DispatchQueue.main.async { [weak self] in
            self?.pendingDuck?.cancel()
            self?.pendingDuck = nil
        }
    }

    func cancelRecording() {
        // Same blocking AudioQueueStop as `stopRecording`, timed for the same reason.
        Diag.measure("AVAudioRecorder.stop (cancel)") { audioRecorder?.stop() }
        endRecordingActivity()
        updateRecordingState(isRecording: false, isConnecting: false)
        Task { @MainActor in SpectrumAnalyzer.shared.stop() }
        stopConnectionMonitoring()

        if AppPreferences.shared.pauseMediaOnRecord {
            MediaPlaybackController.shared.resumeMedia()
        }
        if AppPreferences.shared.reduceVolumeOnRecord {
            cancelPendingDuck()
            SystemVolumeController.shared.restore()
        }
        
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentRecordingURL = nil
        prepareNextTakeInBackground()
    }
    
    
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws {

        let directory = finalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }
    
    func playRecording(url: URL) {
        // Stop current playback if any
        stopPlaying()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            currentlyPlayingURL = url
        } catch {
            print("Failed to play recording: \(error), url: \(url)")
            isPlaying = false
            currentlyPlayingURL = nil
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentlyPlayingURL = nil
    }
    
    private func updateRecordingState(isRecording: Bool, isConnecting: Bool) {
        DispatchQueue.main.async {
            self.isRecording = isRecording
            self.isConnecting = isConnecting
        }
    }
    
    /// How long to wait for a microphone that needs to connect before showing the recording as
    /// live anyway.
    ///
    /// Bluetooth headsets take a moment to actually start delivering audio, which is what the
    /// wait is for. Three seconds is far longer than that and short enough that nobody sits
    /// through it wondering whether the app heard them.
    static let connectionGracePeriod: TimeInterval = 3.0

    /// Whether to stop waiting and treat the recording as live.
    ///
    /// The growth check alone had no way out. If the file never grew — a device that went away
    /// while the Mac was locked, an input that delivers nothing — the app waited forever: the
    /// bubble was up, `isRecording` stayed false, and only force-quitting recovered it (#98).
    ///
    /// Timing out into "live" rather than into a failure is deliberate. The recorder is running
    /// either way and the person is already talking, so giving up would throw their words away
    /// to fix a state problem. The worst case here is a silent recording they can stop, look at,
    /// and try again — which is what every microphone that does not need connecting already does.
    static func shouldGoLive(growthObservations: Int, elapsed: TimeInterval) -> Bool {
        growthObservations >= 2 || elapsed >= connectionGracePeriod
    }

    private func startConnectionMonitoring() {
        stopConnectionMonitoring()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        let initialFileSize = Int64(Self.headerOnlyFileSize)
        let startedAt = Date()
        var growthCount = 0

        timer.setEventHandler { [weak self] in
            guard let self = self, let _ = self.audioRecorder, let url = self.currentRecordingURL else { return }

            let currentFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let totalGrowth = currentFileSize - initialFileSize

            if totalGrowth > 8000 {
                growthCount += 1
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            guard Self.shouldGoLive(growthObservations: growthCount, elapsed: elapsed) else { return }

            if growthCount < 2 {
                Diag.mark("recorder.connectionWait timed out after \(Int(elapsed * 1000))ms "
                    + "with \(totalGrowth) bytes written; going live anyway")
            }
            self.stopConnectionMonitoring()
            self.updateRecordingState(isRecording: true, isConnecting: false)
        }
        connectionCheckTimer = timer
        timer.resume()
    }

    private func stopConnectionMonitoring() {
        connectionCheckTimer?.cancel()
        connectionCheckTimer = nil
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Diag.mark("recorder.didFinishRecording failed - clip discarded")

        // Clearing the URL is also what the connection wait guards on, so on its own it left that
        // timer running at 20Hz with nothing to measure and no way to reach its own timeout. The
        // bubble then sat on "Connecting" until the app was force-quit. Reported by someone whose
        // AirPods reconfigure the input route out from under the recorder, which is one reliable
        // way to get here; the built-in microphone never does it, which is why it only happened
        // with AirPods.
        currentRecordingURL = nil
        stopConnectionMonitoring()
        endRecordingActivity()
        updateRecordingState(isRecording: false, isConnecting: false)
        // This ends the take without a stop, so nothing else prepares the next one.
        prepareNextTakeInBackground()

        Task { @MainActor in
            SpectrumAnalyzer.shared.stop()
            // Said out loud rather than left to be noticed. A take that captured nothing is
            // otherwise indistinguishable from one the user simply has not finished (#117).
            IndicatorWindowManager.shared.reportRecordingFailure("Recording stopped: the microphone dropped out")
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Diag.mark("recorder.encodeError \(error?.localizedDescription ?? "unknown")")
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
