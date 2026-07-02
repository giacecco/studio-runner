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

    // `continuation` is installed on the caller's task thread and consumed
    // on the URLSession delegate queue — both go through `stateLock`, and
    // `install`/`take` guarantee a single live continuation (a concurrent
    // second download is rejected rather than silently leaking the first
    // caller's continuation).
    private let stateLock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double) -> Void)?

    private func install(_ cont: CheckedContinuation<URL, Error>,
                         progress: @escaping (Double) -> Void) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard continuation == nil else { return false }
        continuation = cont
        onProgress = progress
        return true
    }

    private func take() -> CheckedContinuation<URL, Error>? {
        stateLock.lock(); defer { stateLock.unlock() }
        let cont = continuation
        continuation = nil
        onProgress = nil
        return cont
    }

    private func progressCallback() -> ((Double) -> Void)? {
        stateLock.lock(); defer { stateLock.unlock() }
        return onProgress
    }

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

        let tmp = try await runDownload(from: remote, progress: progress)
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

    private func runDownload(from remote: URL,
                             progress: @escaping (Double) -> Void) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            guard install(cont, progress: progress) else {
                cont.resume(throwing: NSError(
                    domain: "WhisperModel", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "A model download is already in progress"]))
                return
            }
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
        let cont = take()
        // A completed transfer is not a successful download: a 404/503 body
        // would otherwise be installed as the model file and, because the
        // fileExists check short-circuits future downloads, never replaced.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            cont?.resume(throwing: NSError(
                domain: "WhisperModel", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "Model download failed: HTTP \(http.statusCode)"]))
            return
        }
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
        progressCallback()?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Success is already handled by didFinishDownloadingTo; only
        // surface explicit failures here.
        guard let error = error, let cont = take() else { return }
        cont.resume(throwing: error)
    }
}
