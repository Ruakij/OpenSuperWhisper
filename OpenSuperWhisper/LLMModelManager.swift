//
//  LLMModelManager.swift
//  OpenSuperWhisper
//
//  Manages local GGUF LLM models for the built-in llama.cpp cleanup backend.
//  Mirrors WhisperModelManager: models live in
//  Application Support/<bundleID>/llm-models, downloads reuse the
//  URLSession + delegate pattern with progress callbacks.
//

import Combine
import Foundation

/// Reuses the same URLSession download-delegate shape as WhisperDownloadDelegate.
/// Kept separate so the two managers don't share mutable delegate state.
class LLMDownloadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let progressCallback: (Double) -> Void
    private var expectedContentLength: Int64 = 0
    var completionHandler: ((URL?, Error?) -> Void)?
    weak var downloadTask: URLSessionDownloadTask?

    init(progressCallback: @escaping (Double) -> Void) {
        self.progressCallback = progressCallback
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler?(location, nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if expectedContentLength == 0 {
            expectedContentLength = totalBytesExpectedToWrite
        }
        let progress = expectedContentLength > 0
            ? Double(totalBytesWritten) / Double(expectedContentLength)
            : 0
        DispatchQueue.main.async { [weak self] in
            self?.progressCallback(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completionHandler?(nil, error)
        }
    }
}

/// Descriptor for a downloadable LLM model.
struct LLMModelDescriptor {
    /// Human-readable name shown in UI.
    let displayName: String
    /// On-disk filename (also used as the download "name" key).
    let fileName: String
    /// Hugging Face (or other) download URL.
    let downloadURL: URL
    /// Approximate download size in bytes (for UI display).
    let approxBytes: Int64
    /// Text appended after the chat template's assistant header, as if the model had written it.
    /// Qwen3.5 takes an empty `<think>\n\n</think>\n\n` here: that is how its own template turns
    /// thinking off, and llama.cpp's template call has no switch for it.
    var assistantPrefill: String? = nil
    /// Generation budget. A model that reasons before answering needs more than a cleanup's worth.
    var maxOutputTokens: Int = 512
}

class LLMModelManager {
    static let shared = LLMModelManager()

    /// Built-in cleanup models: Qwen3.5, licensed Apache-2.0 (https://huggingface.co/Qwen/Qwen3.5-2B),
    /// as single-file GGUFs from unsloth/Qwen3.5-*-GGUF. Picked from a local benchmark (M4 Pro,
    /// llama.cpp, the shipped prompt, greedy decoding); RAM and time per cleanup below are from
    /// that run. File names and byte sizes verified against the HF API on 2026-10-06; HF is
    /// case-sensitive and a wrong case is a silent 404.
    ///
    /// Every entry takes the empty think block as prefill: with thinking on, these models loop
    /// for 17-34 s on a cleanup instead of answering within about a second.
    private static let noThinking = "<think>\n\n</think>\n\n"

    /// ~1.1 GB RAM, ~0.4 s.
    static let tinyModel = LLMModelDescriptor(
        displayName: "Qwen3.5 0.8B - fastest, least accurate",
        fileName: "Qwen3.5-0.8B-Q8_0.gguf",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q8_0.gguf?download=true")!,
        approxBytes: 811_843_840,
        assistantPrefill: noThinking
    )

    /// ~1.6 GB RAM, ~0.5 s.
    static let defaultModel = LLMModelDescriptor(
        displayName: "Qwen3.5 2B - recommended",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true")!,
        approxBytes: 1_280_835_840,
        assistantPrefill: noThinking
    )

    /// ~3.3 GB RAM, ~1.2 s.
    static let mediumModel = LLMModelDescriptor(
        displayName: "Qwen3.5 4B - more accurate, ~3 GB RAM",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true")!,
        approxBytes: 2_740_937_888,
        assistantPrefill: noThinking
    )

    /// ~3.8 GB RAM, ~2.1 s.
    static let largeModel = LLMModelDescriptor(
        displayName: "Qwen3.5 9B - most accurate, ~4 GB RAM, slower",
        fileName: "Qwen3.5-9B-UD-IQ2_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-UD-IQ2_M.gguf?download=true")!,
        approxBytes: 3_649_365_216,
        assistantPrefill: noThinking
    )

    /// Everything offered in Settings, smallest first.
    static let availableModels: [LLMModelDescriptor] = [tinyModel, defaultModel, mediumModel, largeModel]

    /// The descriptor for a stored file name, falling back to the default so an unknown or stale
    /// preference can never leave the app without a model.
    static func model(fileName: String) -> LLMModelDescriptor {
        availableModels.first { $0.fileName == fileName } ?? defaultModel
    }

    private let modelsDirectoryName = "llm-models"
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private let downloadTasksLock = NSLock()

    var modelsDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport
            .appendingPathComponent(AppIdentity.bundleID)
            .appendingPathComponent(modelsDirectoryName)
    }

    private init() {
        createModelsDirectoryIfNeeded()
        removeUnlistedModels()
    }

    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create LLM models directory: \(error)")
        }
    }

    /// Deletes GGUFs in this directory that belong to no listed model, such as one dropped from
    /// `availableModels` by an update: nothing can select or delete it any more, and these are
    /// gigabytes.
    private func removeUnlistedModels() {
        let listed = Set(Self.availableModels.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "gguf" && !listed.contains(file.lastPathComponent) {
            print("Removing unlisted LLM model: \(file.lastPathComponent)")
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// On-disk location for a model by filename (whether or not it exists yet).
    func localURL(for name: String) -> URL {
        return modelsDirectory.appendingPathComponent(name)
    }

    /// Whether a specific model file is present on disk.
    func isModelDownloaded(name: String) -> Bool {
        return FileManager.default.fileExists(atPath: localURL(for: name).path)
    }

    /// Convenience: is the default Qwen model present?
    func isDefaultModelDownloaded() -> Bool {
        return isModelDownloaded(name: Self.defaultModel.fileName)
    }

    /// Download a model with progress callback, reusing the WhisperModelManager pattern.
    func downloadModel(url: URL, name: String, progressCallback: @escaping (Double) -> Void) async throws {
        let destinationURL = localURL(for: name)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("LLM model already exists at: \(destinationURL.path)")
            DispatchQueue.main.async { progressCallback(1.0) }
            return
        }

        print("Starting LLM model download:")
        print("- URL: \(url.absoluteString)")
        print("- Destination: \(destinationURL.path)")

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = LLMDownloadDelegate(progressCallback: progressCallback)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            // LLM GGUFs are ~1 GB+; allow a generous resource timeout.
            configuration.timeoutIntervalForResource = 1800 // 30 minutes

            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: .main)

            let downloadTask = session.downloadTask(with: url)
            delegate.downloadTask = downloadTask

            downloadTasksLock.lock()
            activeDownloadTasks[name] = downloadTask
            downloadTasksLock.unlock()

            delegate.completionHandler = { [weak self] location, error in
                self?.downloadTasksLock.lock()
                self?.activeDownloadTasks.removeValue(forKey: name)
                self?.downloadTasksLock.unlock()

                if let error = error as? URLError, error.code == .cancelled {
                    print("LLM download cancelled")
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let error = error {
                    print("LLM download failed with error: \(error)")
                    continuation.resume(throwing: error)
                    return
                }
                guard let location = location else {
                    let error = NSError(domain: "LLMModelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No download URL received"])
                    continuation.resume(throwing: error)
                    return
                }
                do {
                    print("LLM download completed. Moving file to destination...")
                    try FileManager.default.moveItem(at: location, to: destinationURL)
                    print("LLM model saved to: \(destinationURL.path)")
                    DispatchQueue.main.async { progressCallback(1.0) }
                    continuation.resume(returning: ())
                } catch {
                    print("Failed to move downloaded LLM file: \(error)")
                    continuation.resume(throwing: error)
                }
            }

            downloadTask.resume()
        }
    }

    /// Convenience to download the bundled default Qwen model.
    func downloadDefaultModel(progressCallback: @escaping (Double) -> Void) async throws {
        try await downloadModel(url: Self.defaultModel.downloadURL,
                                name: Self.defaultModel.fileName,
                                progressCallback: progressCallback)
    }

    func cancelDownload(name: String) {
        downloadTasksLock.lock()
        defer { downloadTasksLock.unlock() }
        if let task = activeDownloadTasks[name] {
            task.cancel()
            activeDownloadTasks.removeValue(forKey: name)
            print("Cancelled LLM download for: \(name)")
        }
    }
}
