import SwiftUI

/// Runs the LLM cleanup over a few fixed dictations, plus the user's latest ones, and times it, so
/// models can be compared on speed and on the output itself. Every sample goes through
/// `LLMPostProcessor.process` with the user's own settings, so prompt, dictionary and output
/// checks are exactly what a real dictation gets.
@MainActor
final class CleanupBenchmarkModel: ObservableObject {
    struct Sample {
        let label: String
        let text: String
    }

    struct SampleResult: Identifiable {
        let id = UUID()
        let label: String
        let input: String
        let output: String
        let seconds: Double
    }

    struct ModelRun: Identifiable {
        let id = UUID()
        let name: String
        /// Only the built-in backend has a load step of its own; a server loads on first request.
        var loadSeconds: Double?
        var results: [SampleResult] = []
        var failure: String?

        var averageSeconds: Double? {
            results.isEmpty ? nil : results.map(\.seconds).reduce(0, +) / Double(results.count)
        }
    }

    /// Raw recognizer output: no punctuation, fillers, and tech terms heard as ordinary words.
    static let samples: [Sample] = [
        Sample(label: "English, commands",
               text: "um so i need to run cube control get pods in the default name space and uh then check the logs with cube control logs dash f for the api server pod you know the one that keeps crashing"),
        Sample(label: "English, question",
               text: "hey can you tell me what the difference between git rebase and git merge is i always mix them up and uh which one should i use for my feature branch"),
        Sample(label: "German, commands",
               text: "also ich hab heute morgen den docker container neu gebaut und äh dann mit cube control apply das deployment aktualisiert aber der pod hängt immer noch im crash loop back off"),
        Sample(label: "German, message",
               text: "ähm schreib dem team bitte dass das meeting morgen um zehn uhr ausfällt und wir das auf donnerstag verschieben weil die post gres migration noch nicht durch ist"),
    ]

    @Published private(set) var runs: [ModelRun] = []
    @Published private(set) var isRunning = false
    @Published private(set) var notice: String?
    private var task: Task<Void, Never>?

    /// Built-in models on disk, for the compare-all run.
    var downloadedBuiltInModels: [LLMModelDescriptor] {
        LLMModelManager.availableModels.filter {
            LLMModelManager.shared.isModelDownloaded(name: $0.fileName)
        }
    }

    /// A benchmark sample on the inference queue would delay a real dictation's cleanup, so the
    /// benchmark only starts, and only continues, while nothing is being recorded or processed.
    private var appIsBusy: Bool {
        AudioRecorder.shared.isRecording
            || DictationPipeline.shared.isProcessing
            || TranscriptionQueue.shared.isProcessing
            || TranscriptionService.shared.isTranscribing
    }

    func start(allBuiltInModels: Bool) {
        guard !isRunning else { return }
        guard !appIsBusy else {
            notice = "A dictation is in progress. Try again once it is done."
            return
        }
        runs = []
        notice = nil
        isRunning = true
        task = Task {
            await run(allBuiltInModels: allBuiltInModels)
            isRunning = false
            task = nil
        }
    }

    /// Takes effect between samples: a generation already running on the model finishes first.
    func cancel() {
        task?.cancel()
    }

    private func run(allBuiltInModels: Bool) async {
        let prefs = AppPreferences.shared
        let settings = Settings()
        // The same steps a recognizer result gets before cleanup: engine post-processing
        // (dictionary, autocorrect), then the filler-word pass.
        let samples = Self.samples.map {
            Sample(label: $0.label,
                   text: prefs.cleanTranscription(TranscriptionPostProcessing.finish($0.text, settings: settings)))
        }
        let recordings = (try? await RecordingStore.shared.fetchRecordings(
            limit: RecentTranscripts.scanDepth, offset: 0)) ?? []
        let recent = RecentTranscripts.pick(from: recordings, limit: 3)
            .map { Sample(label: "Your recent dictation", text: $0.transcription) }

        let targets: [(name: String, model: LLMModelDescriptor?)]
        if allBuiltInModels {
            targets = downloadedBuiltInModels.map { ($0.displayName, $0) }
        } else if prefs.aiBackend == "builtin" {
            let model = LLMModelManager.model(fileName: prefs.builtInModelFileName)
            targets = [(model.displayName, model)]
        } else {
            targets = [(prefs.aiBackend == "remote" ? prefs.aiRemoteModel : prefs.aiOllamaModel, nil)]
        }

        for target in targets {
            guard !Task.isCancelled else { break }
            runs.append(ModelRun(name: target.name))
            let index = runs.count - 1

            var backend = LLMPostProcessor.currentBackend()
            if let model = target.model {
                backend = BuiltInLlamaBackend.Pinned(model: model)
                let started = Date()
                guard await BuiltInLlamaBackend.shared.reload(model) else {
                    runs[index].failure = "The model failed to load."
                    continue
                }
                runs[index].loadSeconds = Date().timeIntervalSince(started)
            }

            // Past dictations stay on this Mac: they go only to the built-in model, never to a
            // server the benchmark would be sending them to unasked.
            for input in target.model == nil ? samples : samples + recent {
                if appIsBusy {
                    notice = "Stopped: a dictation started."
                    task?.cancel()
                }
                guard !Task.isCancelled else { break }
                let started = Date()
                let output = await LLMPostProcessor.process(input.text, bundleID: nil, backend: backend)
                guard !Task.isCancelled else { break }
                runs[index].results.append(SampleResult(
                    label: input.label, input: input.text, output: output,
                    seconds: Date().timeIntervalSince(started)))
            }
        }

        if Task.isCancelled, notice == nil { notice = "Cancelled." }
        // The last benchmarked model may not be the selected one; load that back so the next
        // dictation does not pay for the switch.
        if prefs.aiBackend == "builtin" { BuiltInLlamaBackend.shared.preload() }
    }
}

struct CleanupBenchmarkView: View {
    let onClose: () -> Void

    @StateObject private var model = CleanupBenchmarkModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(STheme.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.runs) { run in
                        runView(run)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(STheme.border)
            footer
        }
        .frame(width: 680, height: 560)
        .background(STheme.windowBg)
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Cleanup benchmark")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundColor(STheme.textBright)
            Text("Four sample dictations, cleaned with your current settings. The built-in models also get your three most recent dictations, which never leave this Mac.")
                .scaledFont(size: 11)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func runView(_ run: CleanupBenchmarkModel.ModelRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(run.name)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                Spacer()
                if let load = run.loadSeconds {
                    Text("Load \(Self.format(load))")
                }
                if let average = run.averageSeconds {
                    Text("Average \(Self.format(average))")
                }
            }
            .scaledFont(size: 11)
            .foregroundColor(STheme.hint)
            .monospacedDigit()

            if let failure = run.failure {
                Text(failure).scaledFont(size: 11).foregroundColor(STheme.warn)
            }
            ForEach(run.results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(result.label).scaledFont(size: 11, weight: .medium)
                        Spacer()
                        Text(Self.format(result.seconds)).monospacedDigit()
                    }
                    .scaledFont(size: 11)
                    .foregroundColor(STheme.hint)
                    Text(result.input)
                        .scaledFont(size: 11)
                        .foregroundColor(STheme.hint)
                    Text(result.output)
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.textBright)
                    if result.output == result.input {
                        Text("Returned unchanged: the cleanup failed, its output was rejected, or there was nothing to fix.")
                            .scaledFont(size: 11)
                            .foregroundColor(STheme.warn)
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(STheme.cardBg))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(STheme.border, lineWidth: 1))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancel() }
            } else {
                Button("Run") { model.start(allBuiltInModels: false) }
                Button("Run all downloaded built-in models") { model.start(allBuiltInModels: true) }
                    .disabled(model.downloadedBuiltInModels.isEmpty)
            }
            if let notice = model.notice {
                Text(notice).scaledFont(size: 11).foregroundColor(STheme.warn)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }
}
