import AudioToolbox
import CoreAudio
import Foundation
import os

/// The microphone a take records from, as the recorder can use it.
enum InputDeviceChoice: Equatable {
    /// Nothing chosen: the queue reads the system default input.
    case systemDefault
    case device(uid: String, id: AudioDeviceID)
    /// A device was chosen but CoreAudio no longer knows it (unplugged between the last device
    /// refresh and the key press). The take falls back to the default input rather than failing.
    case unavailable(uid: String)

    /// `lookup` turns a device UID into its CoreAudio ID, nil when no such device exists.
    static func resolve(uid: String?, lookup: (String) -> AudioDeviceID?) -> InputDeviceChoice {
        guard let uid, !uid.isEmpty else { return .systemDefault }
        guard let id = lookup(uid), id != kAudioObjectUnknown else { return .unavailable(uid: uid) }
        return .device(uid: uid, id: id)
    }

    var deviceID: AudioDeviceID? {
        if case .device(_, let id) = self { return id }
        return nil
    }

    var description: String {
        switch self {
        case .systemDefault: return "system default"
        case .device(let uid, let id): return "\(uid) (id \(id))"
        case .unavailable(let uid): return "\(uid) is gone, using the system default"
        }
    }
}

/// The loudest sample of the last few buffers, so any number of readers can ask at any time
/// without taking the reading away from the others. The time is passed in, so tests control it.
struct PeakWindow {
    /// How far back the loudest sample counts; the slowest reader polls at 4 Hz.
    static let duration: TimeInterval = 0.25

    private var peaks: [Float]
    private var next = 0
    private var newest: TimeInterval?

    init(bufferDuration: TimeInterval) {
        peaks = Array(repeating: 0, count: max(Int((Self.duration / bufferDuration).rounded()), 1))
    }

    /// One buffer's linear peak, captured at `time` (seconds on any monotonic clock).
    mutating func record(peak: Float, at time: TimeInterval) {
        peaks[next] = peak
        next = (next + 1) % peaks.count
        newest = time
    }

    /// The loudest sample of the window in dBFS; -160 when no buffer arrived within it.
    func peakDBFS(at time: TimeInterval) -> Float {
        guard let newest, time - newest < Self.duration else { return InputQueueRecorder.decibels(fromPeak: 0) }
        return InputQueueRecorder.decibels(fromPeak: peaks.max() ?? 0)
    }
}

/// Records one device to a 16 kHz Float32 WAV through an `AudioQueue` input.
///
/// The queue takes its device by UID (`kAudioQueueProperty_CurrentDevice`), so a take reads the
/// chosen microphone directly.
///
/// `stop()` stops the queue and closes the file, waiting up to 1 s for whichever thread owns the
/// teardown. `onSamples` hands the same samples on for the visualiser and the live transcription.
/// `onFailure` fires once, off the main thread, when the queue stops by itself or the device
/// dies. A failure that wins the race against `stop()` still reports; the owner of the recorder
/// ignores it when the recorder is no longer the current one.
final class InputQueueRecorder {
    static let sampleRate: Float64 = 16_000
    /// Each buffer is handed to the file as soon as it is full, so the file grows every 50 ms
    /// and the connection wait, which watches its size, sees data without a long delay.
    static let bufferDuration: TimeInterval = 0.05
    static let bufferCount = 3

    /// The format of both the queue and the file: interleaved Float32, little-endian, as the WAV
    /// writer wants it.
    static func format(channelCount: Int) -> AudioStreamBasicDescription {
        let channels = UInt32(channelCount)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    /// The WAV file a take is written to, empty and ready for `AudioFileWritePackets`.
    static func createFile(at url: URL, channelCount: Int) throws -> AudioFileID {
        var format = format(channelCount: channelCount)
        var file: AudioFileID?
        let status = AudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, .eraseFile, &file)
        guard status == noErr, let file else { throw Failure(operation: "AudioFileCreate", status: status) }
        // Size fields are rewritten with every write instead of at close, so a take cut short by
        // a crash is a playable file whose header is right, not just one `WAVHeaderRepair` fixes.
        var deferSizes: UInt32 = 0
        _ = AudioFileSetProperty(file, kAudioFilePropertyDeferSizeUpdates, UInt32(MemoryLayout<UInt32>.size), &deferSizes)
        return file
    }

    /// Size of one queue buffer for `channelCount` channels.
    static func bufferBytes(channelCount: Int) -> UInt32 {
        UInt32(sampleRate * bufferDuration) * format(channelCount: channelCount).mBytesPerFrame
    }

    /// Loudest absolute sample, linear (0 for no samples).
    static func peak(of samples: UnsafeBufferPointer<Float>) -> Float {
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        return peak
    }

    /// A linear peak in dBFS, floored at -160.
    static func decibels(fromPeak peak: Float) -> Float {
        peak > 0 ? max(20 * log10(peak), -160) : -160
    }

    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus
        var description: String { "\(operation) failed (OSStatus \(status))" }
    }

    /// Set before `record()`. Called once on a background queue when the take ends by itself, or
    /// when a failure beats a concurrent `stop()`; the file is closed by then.
    var onFailure: ((Error) -> Void)?

    let channelCount: Int
    let choice: InputDeviceChoice

    private var queue: AudioQueueRef?
    private var file: AudioFileID?
    /// Writer-queue state.
    private var framesWritten: Int64 = 0
    /// Written by the writer queue, read by any thread.
    private let peaks = OSAllocatedUnfairLock(
        initialState: PeakWindow(bufferDuration: InputQueueRecorder.bufferDuration))
    private let writerQueue = DispatchQueue(label: "InputQueueRecorder.writer", qos: .userInitiated)
    private let bytesPerFrame: UInt32

    private final class WeakBox {
        weak var recorder: InputQueueRecorder?
    }
    private var listenerBox: Unmanaged<WeakBox>?
    /// Orders start, stop, failure and release. Set as the last step of `init`.
    private var lifecycle: CaptureLifecycle!

    init(url: URL, channelCount: Int, choice: InputDeviceChoice) throws {
        self.channelCount = max(channelCount, 1)
        self.choice = choice
        var format = Self.format(channelCount: self.channelCount)
        bytesPerFrame = format.mBytesPerFrame

        let file = try Self.createFile(at: url, channelCount: self.channelCount)
        self.file = file
        var status = noErr

        var queue: AudioQueueRef?
        status = AudioQueueNewInputWithDispatchQueue(&queue, &format, 0, writerQueue) { [weak self] queue, buffer, startTime, _, _ in
            self?.consume(buffer, capturedAt: startTime.pointee, from: queue)
        }
        guard status == noErr, let queue else {
            AudioFileClose(file)
            self.file = nil
            throw Failure(operation: "AudioQueueNewInput", status: status)
        }
        self.queue = queue

        do {
            // Without a chosen device the queue stays on the system default input.
            if case .device(let uid, _) = choice {
                // The property value is the CFStringRef itself, so the pointer passed is to the
                // reference.
                let cfString = uid as CFString
                var cfUID = Unmanaged.passUnretained(cfString)
                status = withExtendedLifetime(cfString) {
                    AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &cfUID,
                                          UInt32(MemoryLayout<Unmanaged<CFString>>.size))
                }
                guard status == noErr else {
                    throw Failure(operation: "AudioQueueSetProperty(CurrentDevice)", status: status)
                }
            }
            let bytes = Self.bufferBytes(channelCount: self.channelCount)
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                status = AudioQueueAllocateBuffer(queue, bytes, &buffer)
                guard status == noErr, let buffer else { throw Failure(operation: "AudioQueueAllocateBuffer", status: status) }
                status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                guard status == noErr else { throw Failure(operation: "AudioQueueEnqueueBuffer", status: status) }
            }
        } catch {
            // No lifecycle yet and no other thread: the queue was never started.
            release()
            throw error
        }

        lifecycle = CaptureLifecycle(.init(
            start: { [unowned self] in
                watchForFailure(on: queue)
                return AudioQueueStart(queue, nil)
            },
            stop: { AudioQueueStop(queue, true) },
            drain: { [writerQueue] in writerQueue.sync {} },
            release: { [unowned self] in release() }))
        lifecycle.onFailure = { [unowned self] in onFailure?($0) }
    }

    /// A recorder nobody stopped can lose its last reference inside `consume`, on the writer
    /// queue, and disposing a queue from its own callback queue is not safe: tear down elsewhere.
    deinit {
        let resources = takeResources()
        DispatchQueue.global(qos: .utility).async { Self.tearDown(resources) }
    }

    var isRecording: Bool { lifecycle.isRunning }

    /// Starts capturing. The microphone is open when this returns, though a Bluetooth input may
    /// take a moment more to deliver samples.
    /// False when a `stop()` or a failure ended the take while it was starting; the teardown
    /// has run or is running then, and the caller must not treat the take as recording.
    func record() throws -> Bool {
        try lifecycle.start()
    }

    /// Stops capturing and closes the file. Waits up to 1 s for the file to be closed, also when
    /// a failure or a start in progress owns the teardown; safe to call again, or after a failure.
    func stop() {
        if !lifecycle.stop() { Diag.mark("recorder.stop: teardown still running after 1 s") }
    }

    /// The loudest sample of the last 250 ms, in dBFS, across all channels. Reading does not
    /// reset it, so several readers see the same level.
    func recentPeakDBFS() -> Float {
        peaks.withLock { $0.peakDBFS(at: ProcessInfo.processInfo.systemUptime) }
    }

    // MARK: - Writer

    /// Runs on `writerQueue`.
    private func consume(_ buffer: AudioQueueBufferRef, capturedAt time: AudioTimeStamp, from queue: AudioQueueRef) {
        // Buffers the stop hands back while the lifecycle is stopping still hold the last audio of
        // the take, so they are written too; an immediate stop drops a partly filled buffer (at
        // most 50 ms). Only the re-enqueue depends on the capture still running.
        guard lifecycle.acceptsBuffers else { return }
        let byteCount = buffer.pointee.mAudioDataByteSize
        if byteCount > 0, let file {
            let samples = UnsafeBufferPointer(
                start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self),
                count: Int(byteCount) / MemoryLayout<Float>.size)
            let peak = Self.peak(of: samples)
            var packets = byteCount / bytesPerFrame
            let status = AudioFileWritePackets(file, false, byteCount, nil, framesWritten, &packets, buffer.pointee.mAudioData)
            guard status == noErr else {
                fail(Failure(operation: "AudioFileWritePackets", status: status))
                return
            }
            framesWritten += Int64(packets)
            peaks.withLock { $0.record(peak: peak, at: ProcessInfo.processInfo.systemUptime) }
        }
        if lifecycle.reenqueues { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
    }

    // MARK: - Failure and teardown

    /// Ends the take from a thread that is not the writer: stopping waits for the writer queue.
    private func fail(_ error: Error) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.lifecycle.end(failure: error)
        }
    }

    /// A C function, not a closure, so `release()` can remove it by the same pointer.
    private static let isRunningListener: AudioQueuePropertyListenerProc = { userData, queue, property in
        guard let userData else { return }
        let recorder = Unmanaged<WeakBox>.fromOpaque(userData).takeUnretainedValue().recorder
        var running: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioQueueGetProperty(queue, property, &running, &size) == noErr, running == 0 else { return }
        recorder?.fail(Failure(operation: "the input queue stopped by itself", status: 0))
    }

    private static let deviceIsAliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// A C function for the same reason. A block handed to `AudioObjectAddPropertyListenerBlock`
    /// is re-wrapped on every call from Swift, so the remove never finds it and the listener
    /// stays for the rest of the process (see `CoreAudioInputVolume`).
    private static let deviceAliveListener: AudioObjectPropertyListenerProc = { deviceID, _, _, userData in
        guard let userData else { return noErr }
        let recorder = Unmanaged<WeakBox>.fromOpaque(userData).takeUnretainedValue().recorder
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = deviceIsAliveAddress
        // An unplugged device answers the read with a bad-object error, not with 0.
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        if status != noErr || alive == 0 {
            recorder?.fail(Failure(operation: "the input device went away", status: 0))
        }
        return noErr
    }

    /// The queue stopping on its own (an AirPods route change does it) or the device dying
    /// while the queue never notices.
    private func watchForFailure(on queue: AudioQueueRef) {
        let box = WeakBox()
        box.recorder = self
        let retained = Unmanaged.passRetained(box)
        listenerBox = retained
        AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning, Self.isRunningListener, retained.toOpaque())

        guard let deviceID = choice.deviceID else { return }
        var address = Self.deviceIsAliveAddress
        AudioObjectAddPropertyListener(deviceID, &address, Self.deviceAliveListener, retained.toOpaque())
    }

    /// What `release()` frees, detached from the recorder so it can outlive it.
    private struct Resources {
        var queue: AudioQueueRef?
        var file: AudioFileID?
        var box: Unmanaged<WeakBox>?
        var deviceID: AudioDeviceID?
    }

    private func takeResources() -> Resources {
        let resources = Resources(queue: queue, file: file, box: listenerBox,
                                  deviceID: choice.deviceID)
        queue = nil
        file = nil
        listenerBox = nil
        return resources
    }

    /// Frees the queue, the file and the listeners. Called by the lifecycle, and by `init` when
    /// it fails before the lifecycle exists.
    private func release() {
        Self.tearDown(takeResources())
    }

    private static func tearDown(_ resources: Resources) {
        if let deviceID = resources.deviceID, let box = resources.box {
            var address = deviceIsAliveAddress
            AudioObjectRemovePropertyListener(deviceID, &address, deviceAliveListener, box.toOpaque())
        }
        if let queue = resources.queue {
            if let box = resources.box {
                AudioQueueRemovePropertyListener(queue, kAudioQueueProperty_IsRunning,
                                                 isRunningListener, box.toOpaque())
            }
            AudioQueueDispose(queue, true)
        }
        resources.box?.release()
        if let file = resources.file { AudioFileClose(file) }
    }
}
