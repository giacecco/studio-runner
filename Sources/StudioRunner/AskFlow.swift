import Foundation

/// Handles one ask press end-to-end:
///   1. Extract the mic clip from the rolling buffer
///   2. Transcribe it
///   3. Build a DeepSeek prompt with the current studiorunner.md plus the
///      post-watermark tail of raw.md (so a freshly-spoken note can be cited
///      even before consolidation has caught up)
///   4. Append the Q&A to chat.md
///   5. Speak the reply via AVSpeechSynthesizer
actor AskFlow {
    private let micBuffer: RollingBuffer
    private let speaker: Speaker
    private let onState: (SessionState) -> Void
    private let onLog: (String) -> Void

    init(
        mic: RollingBuffer,
        speaker: Speaker,
        onState: @escaping (SessionState) -> Void,
        onLog: @escaping (String) -> Void
    ) {
        self.micBuffer = mic
        self.speaker = speaker
        self.onState = onState
        self.onLog = onLog
    }

    private static let systemPrompt = """
    You are a concise music-production assistant. The producer is mid-session, listening through speakers, so answer briefly and practically — short sentences, no preamble. When referring to a specific past note, cite its time in HH:MM form. If the answer is not in the provided context, say so.
    """

    func handle(startMs: Double, endMs: Double) async {
        onState(.processingMemo)

        let micStart = startMs - Config.micPrerollSec * 1000
        let micEnd = endMs + Config.micPostrollSec * 1000
        guard let micData = micBuffer.extract(startMs: micStart, endMs: micEnd) else {
            onState(.idle); return
        }

        let tmpMic = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-runner-ask-\(Int(startMs)).wav")
        do {
            try WAVWriter.write(
                samples: micData,
                sampleRate: Int(Config.micSampleRate),
                channels: Int(Config.micChannels),
                bitDepth: Config.micBitDepth,
                to: tmpMic
            )
        } catch {
            onLog("ask: WAV write failed — \(error)"); onState(.idle); return
        }
        defer { try? FileManager.default.removeItem(at: tmpMic) }

        let question: String
        do {
            question = try await Whisper.transcribe(wavURL: tmpMic)
        } catch {
            onLog("ask: whisper failed — \(error)"); onState(.idle); return
        }
        if question.isEmpty { onState(.idle); return }
        onLog("Q: \(question)")

        onState(.askThinking)
        let state = (try? String(contentsOf: Config.notesFile, encoding: .utf8)) ?? ""
        let recent = (try? RawStream.unprocessedFormatted()) ?? ""
        let user = """
        === Current track state ===
        \(state.isEmpty ? "(empty)" : state)

        === Unconsolidated recent notes (latest activity, may overlap with state) ===
        \(recent.isEmpty ? "(none)" : recent)

        The producer asks: \(question)
        """

        let answer: String
        do {
            answer = try await DeepSeek.call(systemPrompt: Self.systemPrompt, userPrompt: user)
        } catch {
            onLog("ask: DeepSeek call failed — \(error)"); onState(.idle); return
        }
        onLog("A: \(answer)")
        appendChat(question: question, answer: answer)

        if Config.ttsEnabled {
            onState(.askSpeaking)
            await speaker.speak(answer)
        }
        onState(.idle)
    }

    private func appendChat(question: String, answer: String) {
        let block = "\n## \(Timestamps.human())\n**Q:** \(question)\n\n**A:** \(answer)\n\n---\n"
        let url = Config.chatFile
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            if let data = block.data(using: .utf8) { try? handle.write(contentsOf: data) }
            try? handle.close()
        } else {
            try? block.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
