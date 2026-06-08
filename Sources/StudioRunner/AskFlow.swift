import AppKit
import AVFoundation
import Foundation

/// Handles one ask press end-to-end:
///   1. Extract the mic clip from the rolling buffer
///   2. Transcribe it
///   3. Build a prompt with the current studiorunner.md plus the
///      post-watermark tail of memos.md (so a freshly-spoken note can be cited
///      even before consolidation has caught up)
///   4. Append the Q&A to chat.md
///   5. Speak the reply via AVSpeechSynthesizer
///   6. Execute any [PLAY: path] / [SHOW: path] / [GOTO: M:SS] tags from the answer after TTS
actor AskFlow {
    private let micBuffer: RollingBuffer
    private let speaker: Speaker
    private let onState: (SessionState) -> Void
    private let onLog: (String) -> Void
    private let onClearSession: (@Sendable () -> Void)?
    private let onGoto: (@Sendable (Int, Int) -> Void)?
    private let onDone: (@Sendable () -> Void)?

    init(
        mic: RollingBuffer,
        speaker: Speaker,
        onState: @escaping (SessionState) -> Void,
        onLog: @escaping (String) -> Void,
        onClearSession: (@Sendable () -> Void)? = nil,
        onGoto: (@Sendable (Int, Int) -> Void)? = nil,
        onDone: (@Sendable () -> Void)? = nil
    ) {
        self.micBuffer = mic
        self.speaker = speaker
        self.onState = onState
        self.onLog = onLog
        self.onClearSession = onClearSession
        self.onGoto = onGoto
        self.onDone = onDone
    }

    private static let systemPrompt = """
    You are a concise music-production assistant. The producer is mid-session, listening through speakers, so answer briefly and practically — short sentences, no preamble. Only answer questions about this session and project. If the question has nothing to do with the current production, say so briefly and don't engage with it further. When referring to a specific past note, cite its time in HH:MM form. If the answer is not in the provided context, say so.
    When the producer asks to hear a recording, include [PLAY: <relative-path>] in your response — for example [PLAY: audio/260606141523.wav]. The path comes verbatim from the audio: field in the raw notes or from the (audio/...) link in the session timeline. Never invent a path.
    When the producer asks to see a screenshot, include [SHOW: <relative-path>] in your response — for example [SHOW: screenshots/260606141523.png]. The path comes verbatim from the screenshot: field in the raw notes or from the (screenshot/...) link in the session timeline. Never invent a path.
    When the producer asks to go to, navigate to, jump to, or find a position, include [GOTO: M:SS] in your response — for example [GOTO: 2:03]. The value must come verbatim from the daw_pos field of the matching raw note or the timestamp in the session timeline. Never invent a position; if no position is recorded for the note, say so instead.
    All [PLAY:], [SHOW:], [GOTO:], and [CLEAR_SESSION] tags are stripped before your response is spoken and executed after TTS finishes. Never mention the filename, path, or position anywhere else in your response — only inside the tag itself.
    When the producer asks to clear, reset, or wipe the session, include [CLEAR_SESSION] anywhere in your response. Confirm the action in your spoken reply (e.g. "Done, session cleared.") but do not repeat the tag text.
    """

    // Regex compiled once at class load time.
    private static let playRe        = try! NSRegularExpression(pattern: #"\[PLAY:\s*([^\]]+)\]"#)
    private static let showRe        = try! NSRegularExpression(pattern: #"\[SHOW:\s*([^\]]+)\]"#)
    private static let clearRe       = try! NSRegularExpression(pattern: #"\[CLEAR_SESSION\]"#)
    private static let gotoRe        = try! NSRegularExpression(pattern: #"\[GOTO:\s*(\d+:\d{2})\]"#)
    private static let allRe         = try! NSRegularExpression(pattern: #"\[(?:PLAY|SHOW):\s*[^\]]+\]|\[CLEAR_SESSION\]|\[GOTO:\s*\d+:\d{2}\]"#)
    // Catches bare paths, markdown links/images, and bare timestamp filenames the AI echoes from context.
    private static let fileRefRe     = try! NSRegularExpression(pattern: #"!?\[[^\]]*\]\([^)]*\)|(?:\.studiorunner\.d/)?(?:audio|screenshots)/\S+|\b\d{12}\.(?:wav|png)\b"#)

    func handle(startMs: Double, endMs: Double) async {
        defer { onDone?() }
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
        let recent = (try? MemoStream.unprocessedFormatted()) ?? ""
        let user = """
        === Current track state ===
        \(state.isEmpty ? "(empty)" : state)

        === Unconsolidated recent notes (latest activity, may overlap with state) ===
        \(recent.isEmpty ? "(none)" : recent)

        The producer asks: \(question)
        """

        let answer: String
        do {
            answer = try await AIClient.call(systemPrompt: Self.systemPrompt, userPrompt: user)
        } catch {
            onLog("ask: AI call failed — \(error)"); onState(.idle); return
        }
        onLog("A: \(answer)")
        appendChat(question: question, answer: answer)

        let actions = Self.mediaActions(from: answer)
        let spokenText = Self.stripMediaTags(from: answer)

        let textToSpeak = spokenText.isEmpty && !actions.isEmpty ? "OK" : spokenText
        if !textToSpeak.isEmpty {
            onState(.askSpeaking)
            await speaker.speak(textToSpeak)
        }

        for action in actions {
            switch action {
            case .audio(let url):             await playClip(at: url)
            case .screenshot(let url):        await openInPreview(at: url)
            case .clearSession:               onClearSession?()
            case .goto(let mins, let secs):   onGoto?(mins, secs)
            }
        }

        onState(.idle)
    }

    // MARK: - Tag parsing

    private enum MediaAction {
        case audio(URL)
        case screenshot(URL)
        case clearSession
        case goto(minutes: Int, seconds: Int)
    }

    private static func mediaActions(from text: String) -> [MediaAction] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var tagged: [(loc: Int, action: MediaAction)] = []

        for m in playRe.matches(in: text, range: full) where m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { continue }
            let path = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            tagged.append((m.range.location, .audio(Config.projectRoot.appendingPathComponent(path))))
        }
        for m in showRe.matches(in: text, range: full) where m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { continue }
            let path = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            tagged.append((m.range.location, .screenshot(Config.projectRoot.appendingPathComponent(path))))
        }
        for m in clearRe.matches(in: text, range: full) {
            tagged.append((m.range.location, .clearSession))
        }
        for m in gotoRe.matches(in: text, range: full) where m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { continue }
            let timeStr = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            let parts = timeStr.split(separator: ":")
            if parts.count == 2, let mins = Int(parts[0]), let secs = Int(parts[1]) {
                tagged.append((m.range.location, .goto(minutes: mins, seconds: secs)))
            }
        }
        return tagged.sorted { $0.loc < $1.loc }.map(\.action)
    }

    private static func stripMediaTags(from text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let pass1 = allRe.stringByReplacingMatches(in: text, range: full, withTemplate: "")
        let ns2 = pass1 as NSString
        let full2 = NSRange(location: 0, length: ns2.length)
        return fileRefRe.stringByReplacingMatches(in: pass1, range: full2, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chat log

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

// MARK: - Media playback (MainActor: AVAudioPlayer and NSWorkspace need main thread)

@MainActor
private func playClip(at url: URL) async {
    guard FileManager.default.fileExists(atPath: url.path),
          let player = try? AVAudioPlayer(contentsOf: url) else { return }
    let relay = AudioFinishRelay()
    player.delegate = relay
    player.play()
    await relay.waitForFinish()
}

@MainActor
private func openInPreview(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    NSWorkspace.shared.open(url)
}

private final class AudioFinishRelay: NSObject, AVAudioPlayerDelegate {
    private var cont: CheckedContinuation<Void, Never>?

    func waitForFinish() async {
        await withCheckedContinuation { cont = $0 }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        cont?.resume()
        cont = nil
    }
}
