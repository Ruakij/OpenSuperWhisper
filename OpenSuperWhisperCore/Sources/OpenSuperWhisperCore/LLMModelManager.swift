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
public struct LLMModelDescriptor: Sendable {
    /// Human-readable name shown in UI.
    public let displayName: String
    /// On-disk filename (also used as the download "name" key).
    public let fileName: String
    /// Hugging Face (or other) download URL.
    public let downloadURL: URL
    /// Approximate download size in bytes (for UI display).
    public let approxBytes: Int64
}

public class LLMModelManager {
    public static let shared = LLMModelManager(storageRoot: CoreAccess.storageRoot)

    /// Built-in cleanup models: Qwen3.5, licensed Apache-2.0 (https://huggingface.co/Qwen/Qwen3.5-2B),
    /// as single-file GGUFs from unsloth/Qwen3.5-*-GGUF (the downloader handles one file per
    /// model). File names and byte sizes verified against the Hugging Face API on 2026-10-12; HF
    /// is case-sensitive and a wrong case is a silent 404.
    static let tinyModel = LLMModelDescriptor(
        displayName: "Qwen3.5 0.8B",
        fileName: "Qwen3.5-0.8B-Q6_K.gguf",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q6_K.gguf?download=true")!,
        approxBytes: 639_029_504
    )

    public static let defaultModel = LLMModelDescriptor(
        displayName: "Qwen3.5 2B",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true")!,
        approxBytes: 1_280_835_840
    )

    static let largeModel = LLMModelDescriptor(
        displayName: "Qwen3.5 4B",
        fileName: "Qwen3.5-4B-Q5_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q5_K_M.gguf?download=true")!,
        approxBytes: 3_143_656_608
    )

    /// Everything offered in Settings, smallest first.
    public static let availableModels: [LLMModelDescriptor] = [tinyModel, defaultModel, largeModel]

    /// The Qwen2.5 files earlier versions offered, each mapped to the replacement of its size
    /// class so a stored selection lands on the closest model.
    private static let supersededModels = [
        "qwen2.5-1.5b-instruct-q4_k_m.gguf": defaultModel.fileName,
        "qwen2.5-7b-instruct-q3_k_m.gguf": largeModel.fileName,
    ]

    /// The descriptor for a stored file name, falling back to the default so an unknown or stale
    /// preference can never leave the app without a model.
    public static func model(fileName: String) -> LLMModelDescriptor {
        let name = supersededModels[fileName] ?? fileName
        return availableModels.first { $0.fileName == name } ?? defaultModel
    }

    private static let modelsDirectoryName = "llm-models"
    private var activeDownloadTasks: [String: URLSessionDownloadTask] = [:]
    private let downloadTasksLock = NSLock()
    private let storageRoot: URL

    var modelsDirectory: URL {
        Self.modelsDirectory(in: storageRoot)
    }

    static func modelsDirectory(in root: URL) -> URL {
        root.appendingPathComponent(modelsDirectoryName)
    }

    init(storageRoot: URL) {
        self.storageRoot = storageRoot
        createModelsDirectoryIfNeeded()
    }

    private func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create LLM models directory: \(error)")
        }
    }

    /// Deletes the superseded files: no entry can select or delete them, and they are
    /// gigabytes. Only those exact names, never other files in the directory. Returns whether a
    /// file was deleted, which is what the user has to be told about.
    public func removeSupersededModels() -> Bool {
        var removed = false
        for name in Self.supersededModels.keys where isModelDownloaded(name: name) {
            if (try? FileManager.default.removeItem(at: localURL(for: name))) != nil { removed = true }
        }
        return removed
    }

    /// All downloaded .gguf models on disk.
    func getAvailableModels() -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("Failed to get available LLM models: \(error)")
            return []
        }
    }

    /// On-disk location for a model by filename (whether or not it exists yet).
    public func localURL(for name: String) -> URL {
        return modelsDirectory.appendingPathComponent(name)
    }

    /// Whether a specific model file is present on disk.
    public func isModelDownloaded(name: String) -> Bool {
        return FileManager.default.fileExists(atPath: localURL(for: name).path)
    }

    /// Convenience: is the default Qwen model present?
    func isDefaultModelDownloaded() -> Bool {
        return isModelDownloaded(name: Self.defaultModel.fileName)
    }

    /// Download a model with progress callback, reusing the WhisperModelManager pattern.
    public func downloadModel(url: URL, name: String, progressCallback: @escaping (Double) -> Void) async throws {
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
