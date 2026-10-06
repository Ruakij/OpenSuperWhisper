import Foundation

/// One long dictation: while the recorder keeps writing its WAV, cuts the audio at pauses and
/// transcribes and cleans each chunk in the background, so stopping leaves only the tail to
/// process. The pure parts live in `LongDictationCore`.
///
/// Chunks run strictly in order on one serial task chain: the sentence carry and the LLM history
/// both depend on the previous chunk.
@MainActor
final class LongDictationSession {
    private let settings: Settings
    private let modelOption: DictationModelOption?
    private let bundleID: String?
    private let params: LongDictationCore.CutParameters
    private let contextChunks: Int
    /// Cleared for the rest of the session once a live paste found no target to insert into.
    private var livePaste: Bool

    private var fileURL: URL?
    /// Mono frames of the recording already handed to a chunk.
    private var cutFrame = 0
    private(set) var cutCount = 0
    /// A chunk failed to transcribe, so its words are missing from `parts`.
    private(set) var failed = false
    private var pending = ""
    private var parts: [String] = []
    private var turns: [LLMTurn] = []
    private var insertedParts = 0
    private var lastInsertedEndsInSpace = true
    private var chain: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var finishTask: Task<(full: String, rest: String), Never>?
    private var tempFiles: [URL] = []
    /// Chunks cut but not yet transcribed and cleaned, reported while recording.
    private var outstanding = 0 {
        didSet { onOutstandingChange?(outstanding) }
    }
    var onOutstandingChange: ((Int) -> Void)?
    private var cancelled = false
    /// Set once the recording stopped: from then on parts wait for the pipeline, which inserts
    /// them in recording order after any dictation queued before this one.
    private var finishing = false

    /// A tail shorter than this is not worth a transcription; Whisper tends to hallucinate on it.
    private static let minimumTailSeconds = 0.3

    init(context: DictationPipeline.ContextSnapshot, modelOption: DictationModelOption?) {
        let prefs = AppPreferences.shared
        settings = DictationPipeline.transcriptionSettings(for: context)
        self.modelOption = modelOption
        bundleID = context.bundleID
        let target = min(max(prefs.longDictationChunkSeconds, 10), 120)
        params = LongDictationCore.CutParameters(
            targetSeconds: target,
            maxSeconds: max(prefs.longDictationMaxChunkSeconds, target),
            minGapMs: min(max(prefs.longDictationMinGapMs, 100), 1500),
            silenceDb: min(max(prefs.longDictationSilenceDb, -60), -20))
        contextChunks = min(max(prefs.longDictationContextChunks, 0), 8)
        livePaste = prefs.longDictationLivePaste
    }

    /// Whether the recording has to end through `finish` rather than the normal path: some
    /// audio was already cut off. A failed chunk sends it back to the normal path, which
    /// transcribes the whole file again, unless parts are already pasted and would be doubled.
    var takesOverFinish: Bool { cutCount > 0 && (!failed || pastedLive) }

    var pastedLive: Bool { insertedParts > 0 }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    /// Stops polling and processes the tail of the finished recording at `url`. `result()`
    /// returns the joined text once every chunk is done.
    func finish(fileURL url: URL) {
        finishing = true
        onOutstandingChange = nil
        let poller = pollTask
        poller?.cancel()
        pollTask = nil
        finishTask = Task {
            await poller?.value
            if let read = await Self.read(url: url, fromFrame: cutFrame),
               Double(read.samples.count) >= Self.minimumTailSeconds * Double(read.sampleRate) {
                enqueueChunk(read.samples, sampleRate: read.sampleRate)
            }
            enqueue { session in
                let rest = session.pending
                session.pending = ""
                await session.cleanPart(rest)
            }
            await chain?.value
            deleteTempFiles()
            // Without pasted parts the pipeline transcribes the whole file again instead.
            if failed, pastedLive, !cancelled {
                IndicatorWindowManager.shared.flash(.error("Part of the dictation could not be transcribed"))
            }
            let rest = LongDictationCore.joined(Array(parts.dropFirst(insertedParts)))
            return (LongDictationCore.joined(parts),
                    rest.isEmpty || lastInsertedEndsInSpace ? rest : " " + rest)
        }
    }

    /// The whole cleaned text, and the part of it not yet pasted live (with a leading space when
    /// it continues pasted text).
    func result() async -> (full: String, rest: String) {
        await finishTask?.value ?? ("", "")
    }

    /// Drops everything: no more chunks, no live paste, temp files removed.
    func cancel() {
        cancelled = true
        onOutstandingChange = nil
        pollTask?.cancel()
        pollTask = nil
        finishTask?.cancel()
        deleteTempFiles()
    }

    // MARK: - Private

    private func poll() async {
        guard let url = fileURL ?? AudioRecorder.shared.currentRecordingURL else { return }
        fileURL = url
        guard let read = await Self.read(url: url, fromFrame: cutFrame) else { return }
        var p = params
        p.sampleRate = read.sampleRate
        let chunks = await Task.detached { LongDictationCore.chunks(samples: read.samples, p) }.value
        guard !cancelled, pollTask != nil else { return }
        for chunk in chunks {
            cutFrame += chunk.count
            cutCount += 1
            enqueueChunk(chunk, sampleRate: read.sampleRate)
        }
    }

    private nonisolated static func read(url: URL, fromFrame: Int) async -> (samples: [Float], sampleRate: Int)? {
        await Task.detached { LongDictationCore.readMono(url: url, fromFrame: fromFrame) }.value
    }

    private func enqueue(_ step: @escaping @MainActor (LongDictationSession) async -> Void) {
        let previous = chain
        chain = Task { [self] in
            await previous?.value
            guard !cancelled else { return }
            await step(self)
        }
    }

    private func enqueueChunk(_ samples: [Float], sampleRate: Int) {
        outstanding += 1
        enqueue { session in
            await session.processChunk(samples, sampleRate: sampleRate)
            session.outstanding -= 1
        }
    }

    private func processChunk(_ samples: [Float], sampleRate: Int) async {
        guard !LongDictationCore.isSilent(samples: samples, sampleRate: sampleRate,
                                          silenceDb: params.silenceDb) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("long-dictation-\(UUID().uuidString).wav")
        tempFiles.append(url)
        defer { try? FileManager.default.removeItem(at: url) }

        var raw: String
        do {
            try LongDictationCore.wavData(samples: samples, sampleRate: sampleRate).write(to: url)
            raw = try await TranscriptionService.shared.transcribeAudio(
                url: url, settings: settings, modelOverride: modelOption)
        } catch {
            Diag.mark("longDictation.chunk transcription failed: \(error.localizedDescription)")
            failed = true
            raw = ""
        }
        guard !cancelled else { return }
        raw = raw == TranscriptionResult.noSpeech ? "" : AppPreferences.shared.cleanTranscription(raw)

        let carried = LongDictationCore.carry(pending: pending, chunk: raw)
        pending = carried.pending
        await cleanPart(carried.complete)
    }

    private func cleanPart(_ raw: String) async {
        guard !raw.isEmpty else { return }
        let cleaned = await LLMPostProcessor.process(
            raw, bundleID: bundleID, translating: settings.translateToEnglish,
            history: Array(turns.suffix(contextChunks)))
        guard !cancelled else { return }
        turns.append(LLMTurn(user: raw, assistant: cleaned))
        parts.append(cleaned)
        // A part not pasted here waits for the next live paste or the final insert. Earlier
        // dictations still in the pipeline insert first, and a held modifier (the push-to-talk
        // key) would merge into the synthetic paste.
        guard livePaste, !finishing, AppPreferences.shared.autoPasteTranscription,
              !DictationPipeline.shared.isProcessing, !PasteLastTranscript.modifiersAreHeld()
        else { return }
        let unpasted = LongDictationCore.joined(Array(parts.dropFirst(insertedParts)))
        guard !unpasted.isEmpty else { return }

        let text = IndicatorViewModel.applyPostProcessing(unpasted)
        let targetMissing = TranscriptInserter.insert(lastInsertedEndsInSpace ? text : " " + text,
                                                      honorAutoPastePreference: true, targetBundleID: bundleID)
        guard !targetMissing else {
            livePaste = false
            return
        }
        lastInsertedEndsInSpace = text.last?.isWhitespace ?? false
        insertedParts = parts.count
    }

    private func deleteTempFiles() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
    }
}
