import Foundation

/// Shells out to `whisper-cli` (whisper.cpp) for local transcription. Same
/// invocation as the bun script:
///   - `--no-fallback` to suppress whisper's temperature-fallback retry, the
///     dominant source of pattern hallucinations on quantised models.
///   - `--no-speech-thold 0.5` to gate out silence.
enum Whisper {
    static func transcribe(wavURL: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Config.whisperBinary)
        process.arguments = [
            "-m", Config.whisperModel,
            "-l", Config.whisperLanguage,
            "--no-timestamps",
            "-t", "6",
            "--no-speech-thold", "0.5",
            "--no-fallback",
            "-f", wavURL.path
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        try? errPipe.fileHandleForReading.close()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }

        // whisper-cli's stdout looks like "[00:00:00.000 --> 00:00:03.500] hello".
        // We invoke with --no-timestamps but it still prints "[...]" prefixes in
        // some builds; strip them defensively.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripLeadingTimestamp(trimmed)
        return stripped
    }

    private static func stripLeadingTimestamp(_ s: String) -> String {
        guard s.hasPrefix("[") else { return s }
        if let close = s.firstIndex(of: "]") {
            let after = s.index(after: close)
            return s[after...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
