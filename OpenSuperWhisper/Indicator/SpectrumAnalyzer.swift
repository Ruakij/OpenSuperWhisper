import Accelerate
import Combine
import Foundation

/// Live spectrum of the microphone, driving the indicator's visualiser.
///
/// Reads the samples the recorder's input queue already captures instead of opening the
/// microphone a second time. A second `AVAudioEngine` on the same device is not free: it lands
/// right after the recorder has taken the device, which is when a route or format change is in
/// flight (#114), it cannot be pointed at every input (an engine bound to a Bluetooth headset
/// refuses to start, -10868), and building its I/O unit blocks the main thread for up to 600 ms.
/// The recorder's samples are 16 kHz, so they carry the 8 kHz the bands top out at.
@MainActor
final class SpectrumAnalyzer: ObservableObject {
    static let shared = SpectrumAnalyzer()

    /// Per-band levels, 0...1, oldest-to-highest frequency. All zeros while stopped.
    @Published private(set) var bands: [Float] = Array(repeating: 0, count: SpectrumBands.count)

    #if DEBUG
    /// Stages levels without a microphone, for the indicator probe's screenshots and GIFs.
    func stageBands(_ levels: [Float]) { bands = levels }
    #endif

    private var isRunning = false
    /// Unsubscribes from the recorder's samples; nil between takes.
    private var removeTap: (() -> Void)?

    private let fftSize = 1024
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    /// Ring of the newest samples, so a short buffer still produces a full transform.
    private var sampleBuffer: [Float] = []
    /// FFT bins per band, fixed by the recorder's sample rate.
    private let binRanges: [Range<Int>]

    private init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        binRanges = SpectrumBands.binRanges(sampleRate: Float(InputQueueRecorder.sampleRate), fftSize: fftSize)
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Whether the transform is worth running at all: it only feeds the visualiser, so with no
    /// visualiser on the bubble nothing reads it.
    nonisolated static func shouldRun(layout: IndicatorLayout) -> Bool {
        layout.contains(.waveform)
    }

    /// Subscribes to the take in progress. Does nothing when that take's stop already ran, which
    /// would otherwise leave the subscription open until the next take's stop.
    func start() {
        guard !isRunning, fftSetup != nil, AudioRecorder.shared.isTakeRecording else { return }
        guard Self.shouldRun(layout: IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout))
        else { return }
        removeTap = AudioRecorder.shared.addSampleTap { [weak self] samples in
            Task { @MainActor in self?.consume(samples) }
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        removeTap?()
        removeTap = nil
        isRunning = false
        sampleBuffer.removeAll(keepingCapacity: true)
        bands = Array(repeating: 0, count: SpectrumBands.count)
    }

    private func consume(_ samples: [Float]) {
        // A buffer already in flight when the take stopped must not lift the bands back up.
        guard isRunning else { return }
        sampleBuffer.append(contentsOf: samples)
        guard sampleBuffer.count >= fftSize else { return }
        // Keep only the newest window; older audio has already been drawn.
        sampleBuffer.removeFirst(sampleBuffer.count - fftSize)

        let magnitudes = transform(sampleBuffer)
        guard !magnitudes.isEmpty else { return }

        bands = binRanges.enumerated().map { index, range in
            let slice = magnitudes[range.clamped(to: 0..<magnitudes.count)]
            guard !slice.isEmpty else { return 0 }
            let peak = slice.max() ?? 0
            let target = SpectrumBands.normalize(magnitude: peak)
            let previous = index < bands.count ? bands[index] : 0
            return SpectrumBands.smooth(previous: previous, next: target)
        }
    }

    /// Windowed real FFT of one frame, returning bin magnitudes.
    private func transform(_ frame: [Float]) -> [Float] {
        guard let fftSetup, frame.count == fftSize else { return [] }
        let half = fftSize / 2

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowPtr in
                    windowPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // vDSP's real FFT returns twice the true amplitude, and the window removed energy.
        var scale = Float(1) / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
        return magnitudes
    }
}
