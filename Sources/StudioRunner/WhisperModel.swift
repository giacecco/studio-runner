import Foundation

/// Ensures the whisper model file for the current language is present on
/// disk under `Config.whisperModelsDir`. If not, downloads it from
/// Hugging Face. Reports fractional progress (0…1) on a callback.
///
/// One download at a time — `ensureCurrentModel` is not re-entrant. The
/// downloader is intentionally a singleton: a second call while a download
/// is in flight would race the delegate state.
final class WhisperModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = WhisperModelDownloader()

    private static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    // Mutated only on the URLSession delegate queue.
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double) -> Void)?

    /// Downloads `Config.whisperModel` if it doesn't already exist on disk.
    /// `progress` is invoked with values in 0…1 on an arbitrary thread.
    func ensureCurrentModel(progress: @escaping (Double) -> Void) async throws {
        let path = Config.whisperModel
        if FileManager.default.fileExists(atPath: path) { return }

        let dest = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let remote = URL(string: Self.baseURL + dest.lastPathComponent) else {
            throw NSError(domain: "WhisperModel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid model URL for \(dest.lastPathComponent)"])
        }

        self.onProgress = progress
        defer { self.onProgress = nil }

        let tmp = try await runDownload(from: remote)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Move into place atomically — if a previous half-written file
        // exists at `dest`, replace it.
        let staging = dest.appendingPathExtension("incoming")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.moveItem(at: tmp, to: staging)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: staging, to: dest)
    }

    private func runDownload(from remote: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            session.downloadTask(with: remote).resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is deleted as soon as this method returns, so move
        // synchronously to a temp file under our control.
        let parking = FileManager.default.temporaryDirectory
            .appendingPathComponent("studiorunner-whisper-\(UUID().uuidString).bin")
        let cont = continuation
        continuation = nil
        do {
            try FileManager.default.moveItem(at: location, to: parking)
            cont?.resume(returning: parking)
        } catch {
            cont?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Success is already handled by didFinishDownloadingTo; only
        // surface explicit failures here.
        guard let error = error, let cont = continuation else { return }
        continuation = nil
        cont.resume(throwing: error)
    }
}
