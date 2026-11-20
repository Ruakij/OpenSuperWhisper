import AudioToolbox
import CoreAudio
import Foundation

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

    /// The UID to bind the queue to; nil leaves it on the default input.
    var queueUID: String? {
        if case .device(let uid, _) = self { return uid }
        return nil
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

/// Records one device to a 16 kHz Float32 WAV through an `AudioQueue` input.
///
/// The queue takes its device by UID (`kAudioQueueProperty_CurrentDevice`), so a take reads the
/// chosen microphone without touching the system default input. `AVAudioRecorder` cannot name a
/// device; it reads whatever the default is.
///
/// `stop()` is a synchronous `AudioQueueStop`, after which the file is closed. `onFailure` fires
/// once, off the main thread, when the queue stops by itself or the device dies; never after
/// `stop()`.
final class InputQueueRecorder {
    static let sampleRate: Float64 = 16_000
    /// Each buffer is handed to the file as soon as it is full, so the file grows every 50 ms
    /// and the connection wait, which watches its size, sees data without a long delay.
    static let bufferDuration: TimeInterval = 0.05
    static let bufferCount = 3

    /// The format of both the queue and the file: interleaved Float32, little-endian, as the WAV
    /// writer wants it.
    static func format(channelCount: Int) -> AudioStreamBasicDescription {
        let channels = UInt32(max(channelCount, 1))
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

    /// Set before `record()`. Called once on a background queue when the take ends without
    /// `stop()`; the file is closed by then.
    var onFailure: ((Error) -> Void)?

    /// When the take's first sample was captured (host time in nanoseconds; nil when the queue
    /// gave no time) and how long the take then stayed below `silenceThreshold`, capped at
    /// `silenceCap`. Measured, not judged: a gated input (Voice Isolation) is silent by design.
    struct StartMeasurement {
        let firstSampleNanos: UInt64?
        let silence: TimeInterval
        let silenceReachedCap: Bool
    }

    /// The level below which a sample counts as digital silence, as digital silence.
    static let silenceThreshold: Float = 1e-7
    static let silenceCap: TimeInterval = 2

    /// Set before `record()`. Called once on the writer queue, when the first sample at or above
    /// `silenceThreshold` arrives or the silence reaches `silenceCap`.
    var onStartMeasured: ((StartMeasurement) -> Void)?

    let channelCount: Int
    let choice: InputDeviceChoice

    private enum State { case ready, running, finished }

    private let lock = NSLock()
    private var state = State.ready
    private var queue: AudioQueueRef?
    private var file: AudioFileID?
    /// Writer-queue state.
    private var framesWritten: Int64 = 0
    private var peakSinceLastRead: Float = 0
    private let writerQueue = DispatchQueue(label: "InputQueueRecorder.writer", qos: .userInitiated)
    private let bytesPerFrame: UInt32
    /// Writer-queue state of the start measurement, which runs while `onStartMeasured` is set.
    private var sawFirstBuffer = false
    private var firstSampleNanos: UInt64?
    private var silentFrames = 0

    private final class WeakBox {
        weak var recorder: InputQueueRecorder?
    }
    private var listenerBox: Unmanaged<WeakBox>?

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
            try bindDevice()
            let bytes = Self.bufferBytes(channelCount: self.channelCount)
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                status = AudioQueueAllocateBuffer(queue, bytes, &buffer)
                guard status == noErr, let buffer else { throw Failure(operation: "AudioQueueAllocateBuffer", status: status) }
                status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                guard status == noErr else { throw Failure(operation: "AudioQueueEnqueueBuffer", status: status) }
            }
        } catch {
            release()
            throw error
        }
    }

    /// A recorder nobody stopped can lose its last reference inside `consume`, on the writer
    /// queue, and disposing a queue from its own callback queue is not safe: tear down elsewhere.
    deinit {
        let resources = takeResources()
        DispatchQueue.global(qos: .utility).async { Self.tearDown(resources) }
    }

    private func bindDevice() throws {
        guard let queue, let uid = choice.queueUID else { return }
        // The property value is the CFStringRef itself, so the pointer passed is to the reference.
        let cfString = uid as CFString
        var cfUID = Unmanaged.passUnretained(cfString)
        let status = withExtendedLifetime(cfString) {
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &cfUID,
                                  UInt32(MemoryLayout<Unmanaged<CFString>>.size))
        }
        guard status == noErr else { throw Failure(operation: "AudioQueueSetProperty(CurrentDevice)", status: status) }
    }

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .running
    }

    /// Starts capturing. The microphone is open when this returns, though a Bluetooth input may
    /// take a moment more to deliver samples.
    func record() throws {
        guard let queue else { throw Failure(operation: "record on a finished recorder", status: kAudio_ParamError) }
        lock.lock()
        guard state == .ready else { lock.unlock(); return }
        state = .running
        lock.unlock()

        watchForFailure(on: queue)
        let status = AudioQueueStart(queue, nil)
        guard status == noErr else {
            finish(failure: nil)
            throw Failure(operation: "AudioQueueStart", status: status)
        }
    }

    /// Stops capturing and closes the file. Blocks until the queue has drained; safe to call
    /// again, or after a failure.
    func stop() {
        finish(failure: nil)
    }

    /// The loudest sample since the last call, in dBFS, across all channels.
    func takePeakDBFS() -> Float {
        lock.lock()
        let peak = peakSinceLastRead
        peakSinceLastRead = 0
        lock.unlock()
        return Self.decibels(fromPeak: peak)
    }

    // MARK: - Writer

    /// Runs on `writerQueue`.
    private func consume(_ buffer: AudioQueueBufferRef, capturedAt time: AudioTimeStamp, from queue: AudioQueueRef) {
        // Buffers the stop flushes arrive after the state left `.running` and still hold the last
        // audio of the take, so they are written too; only the re-enqueue depends on the state.
        let byteCount = buffer.pointee.mAudioDataByteSize
        if byteCount > 0, let file {
            let samples = UnsafeBufferPointer(
                start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self),
                count: Int(byteCount) / MemoryLayout<Float>.size)
            let peak = Self.peak(of: samples)
            if onStartMeasured != nil { measureStart(samples, capturedAt: time) }
            var packets = byteCount / bytesPerFrame
            let status = AudioFileWritePackets(file, false, byteCount, nil, framesWritten, &packets, buffer.pointee.mAudioData)
            guard status == noErr else {
                fail(Failure(operation: "AudioFileWritePackets", status: status))
                return
            }
            framesWritten += Int64(packets)
            lock.lock()
            peakSinceLastRead = max(peakSinceLastRead, peak)
            lock.unlock()
        }
        lock.lock()
        let running = state == .running
        lock.unlock()
        if running { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
    }

    /// Runs on `writerQueue` for each buffer until the measurement is done.
    private func measureStart(_ samples: UnsafeBufferPointer<Float>, capturedAt time: AudioTimeStamp) {
        if !sawFirstBuffer {
            sawFirstBuffer = true
            if time.mFlags.contains(.hostTimeValid) { firstSampleNanos = AudioConvertHostTimeToNanos(time.mHostTime) }
        }
        let firstSignal = samples.firstIndex { abs($0) >= Self.silenceThreshold }
        silentFrames += (firstSignal ?? samples.count) / channelCount
        let cap = Int(Self.silenceCap * Self.sampleRate)
        guard firstSignal != nil || silentFrames >= cap else { return }
        let report = onStartMeasured
        onStartMeasured = nil
        report?(StartMeasurement(
            firstSampleNanos: firstSampleNanos,
            silence: Double(min(silentFrames, cap)) / Self.sampleRate,
            silenceReachedCap: firstSignal == nil))
    }

    // MARK: - Failure and teardown

    /// Ends the take from a thread that is not the writer: stopping waits for the writer queue.
    private func fail(_ error: Error) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.finish(failure: error)
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

    /// The one way out of `.running`. With a `failure` the caller hears about it afterwards.
    private func finish(failure: Error?) {
        lock.lock()
        let wasRunning = state == .running
        if wasRunning { state = .finished }
        lock.unlock()
        guard wasRunning else { return }

        if let queue { AudioQueueStop(queue, true) }
        // The stop delivers its last buffers to the writer queue asynchronously.
        writerQueue.sync {}
        release()
        if let failure { onFailure?(failure) }
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

    /// Frees the queue, the file and the listeners. Idempotent.
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
