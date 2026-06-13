import AppKit
import AVFoundation
import Foundation

/// Handles one push-to-talk utterance end-to-end. Both buttons feed this
/// single pipeline — every utterance gets the full capture treatment:
///   1. Extract the mic clip from the rolling buffer (preroll + postroll)
///   2. Transcribe it via whisper-cli
///   3. Take a full-screen screenshot
///   4. Extract the DAW clip (if the loopback device is present)
///   5. Append a memos.md entry — always, BEFORE any AI call, so a crash or
///      network failure can never lose a note
///   6. If the utterance is addressed to the assistant — wake word
///      (`Config.wakeWord`) in the transcript, or the answer button was used —
///      call the AI with the session state, append the exchange to chat.md,
///      log the spoken answer into memos.md with assistant attribution (so
///      consolidation can resolve open questions from it), speak the reply,
///      and execute any [PLAY:] / [SHOW:] / [GOTO:] / [CLEAR_SESSION] tags
///   7. Signal the consolidator
///
/// A silent tap on the answer button (press + release with no speech) is the
/// rescue path for a missed wake word: it answers the most recent utterance,
/// or re-speaks the last answer if that utterance was already answered.
actor UtteranceFlow {
    private let micBuffer: RollingBuffer
    private let dawBuffer: RollingBuffer?
    private let speaker: Speaker

    private let onState: (SessionState) -> Void
    private let onConsolidate: () -> Void
    private let onLog: (String) -> Void
    private let onClearSession: (@Sendable () -> Void)?
    private let onGoto: (@Sendable (Int, Int) -> Void)?
    private let onAnswerDone: (@Sendable () -> Void)?
    private let onSessionType: (@Sendable (String, Bool) -> Void)?

    private var lastText = ""
    private var lastUtterance: String?   // most recent producer utterance
    private var lastAnswer: String?      // what was spoken for it; nil if unanswered

    init(
        mic: RollingBuffer,
        daw: RollingBuffer?,
        speaker: Speaker,
        onState: @escaping (SessionState) -> Void,
        onConsolidate: @escaping () -> Void,
        onLog: @escaping (String) -> Void,
        onClearSession: (@Sendable () -> Void)? = nil,
        onGoto: (@Sendable (Int, Int) -> Void)? = nil,
        onAnswerDone: (@Sendable () -> Void)? = nil,
        onSessionType: (@Sendable (String, Bool) -> Void)? = nil
    ) {
        self.micBuffer = mic
        self.dawBuffer = daw
        self.speaker = speaker
        self.onState = onState
        self.onConsolidate = onConsolidate
        self.onLog = onLog
        self.onClearSession = onClearSession
        self.onGoto = onGoto
        self.onAnswerDone = onAnswerDone
        self.onSessionType = onSessionType
    }

    private static let answerSystemPrompt = """
    You are a concise music-production assistant the producer addresses by the name "\(Config.wakeWord)". The producer is mid-session, listening through speakers, so answer briefly and practically — short sentences, no preamble. Never open your response with your own name, a greeting, or any salutation — go straight to the answer. The utterance may contain your name as a form of address; never comment on that. Only answer questions about this session and project. If the question has nothing to do with the current production, say so briefly and don't engage with it further. When referring to a specific past note, cite its time in HH:MM form. If the answer is not in the provided context, say so.
    Answer only the specific question asked. Do not summarise the session state, recap the timeline, or enumerate past notes unless the producer explicitly asks for a summary or list. One or two sentences is the default length; expand only if the question genuinely requires it.
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
    private static let wakeWordRe    = try! NSRegularExpression(
        pattern: "\\b\(NSRegularExpression.escapedPattern(for: Config.wakeWord))\\b",
        options: [.caseInsensitive])
    // Matches "production", "mixing", or "mastering" as whole words.
    // The Bool capture group signals whether "continuing" preceded the type
    // (meaning back-fill adjacent unclassified sessions too).
    private static let sessionTypeRe = try! NSRegularExpression(
        pattern: #"\b(continuing\s+(?:the\s+)?)?(?:(production)|(mixing)|(mastering))\b"#,
        options: [.caseInsensitive])

    func handle(startMs: Double, endMs: Double, dawPosition: String?, dawTrack: String?, forceAnswer: Bool) async {
        var answered = false
        defer {
            // CC 119 un-ducks the Bitwig side after an answer cycle; harmless
            // when nothing was ducked, so err on the side of sending it.
            if forceAnswer || answered { onAnswerDone?() }
            onState(.idle)
        }
        onState(.processingMemo)

        // Mic extract: preroll on the head, postroll on the tail.
        let micStart = startMs - Config.micPrerollSec * 1000
        let micEnd = endMs + Config.micPostrollSec * 1000
        guard let micData = micBuffer.extract(startMs: micStart, endMs: micEnd) else {
            onLog("utterance: mic buffer returned nil — bytesWritten=\(micBuffer.totalBytesWritten) window=[\(Int(micStart))–\(Int(micEnd))]")
            return
        }

        // Write a temp WAV for whisper.
        let tmpMic = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-runner-utterance-\(Int(startMs)).wav")
        do {
            try WAVWriter.write(
                samples: micData,
                sampleRate: Int(Config.micSampleRate),
                channels: Int(Config.micChannels),
                bitDepth: Config.micBitDepth,
                to: tmpMic
            )
        } catch {
            onLog("utterance: WAV write failed — \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tmpMic) }

        let text: String
        do {
            text = try await Whisper.transcribe(wavURL: tmpMic)
        } catch {
            onLog("utterance: whisper failed — \(error)")
            return
        }
        // A single-word (or empty) transcript on the answer button is almost
        // certainly Whisper hallucinating on near-silence; treat it as a
        // silent tap rather than a real utterance so no memo is written and
        // the AI isn't called with noise.
        let isSilentTap = text.isEmpty ||
            (forceAnswer && text.split(whereSeparator: \.isWhitespace).count <= 1)
        if isSilentTap {
            if forceAnswer {
                if !text.isEmpty { onLog("utterance: near-silent tap (whisper: '\(text)')") }
                answered = await handleSilentTap()
            } else {
                onLog("utterance: whisper returned empty text")
            }
            return
        }
        if text == lastText {
            // Suppress consecutive identical transcriptions; clear so the same
            // phrase can recur after a different one.
            onLog("utterance: suppressed duplicate '\(text.prefix(60))'")
            return
        }
        lastText = text

        if let onSessionType {
            let range = NSRange(text.startIndex..., in: text)
            if let m = Self.sessionTypeRe.firstMatch(in: text, range: range) {
                let isContinuing = m.range(at: 1).location != NSNotFound &&
                    Range(m.range(at: 1), in: text).map({ !$0.isEmpty }) == true
                let typeIndex = (2...4).first { m.range(at: $0).location != NSNotFound }
                let typeNames = ["production", "mixing", "mastering"]
                if let idx = typeIndex {
                    let typeName = typeNames[idx - 2]
                    onSessionType(typeName, isContinuing)
                }
            }
        }

        let ts = Timestamps.compact(Date(timeIntervalSince1970: startMs / 1000))
        let screenshotRel = "\(Config.runnerDirName)/screenshots/\(ts).png"
        let audioRel = "\(Config.runnerDirName)/audio/\(ts).wav"
        let screenshotAbs = Config.screenshotsDir.appendingPathComponent("\(ts).png")
        let audioAbs = Config.audioDir.appendingPathComponent("\(ts).wav")

        try? await Screenshot.capture(to: screenshotAbs)

        // DAW clip — bounded preroll, no postroll (music after the utterance
        // belongs to the next entry).
        var hasDaw = false
        if let dawBuffer = dawBuffer {
            let dawStart = startMs - Config.dawPrerollSec * 1000
            if let dawData = dawBuffer.extract(startMs: dawStart, endMs: endMs) {
                do {
                    // Derive sample rate from the buffer's live bytesPerSecond, which
                    // the tap updates on its first callback to the real hardware rate.
                    let dawSR = dawBuffer.bytesPerSecond / Int(Config.dawChannels) / MemoryLayout<Int16>.size
                    try WAVWriter.write(
                        samples: dawData,
                        sampleRate: dawSR,
                        channels: Int(Config.dawChannels),
                        bitDepth: Config.dawBitDepth,
                        to: audioAbs
                    )
                    hasDaw = true
                } catch {
                    onLog("utterance: DAW WAV write failed — \(error)")
                }
            }
        }

        let fullDawPos: String?
        if let pos = dawPosition {
            if let track = dawTrack, !track.isEmpty {
                fullDawPos = "\(pos) in \"\(track)\""
            } else {
                fullDawPos = pos
            }
        } else {
            fullDawPos = nil
        }

        do {
            try MemoStream.append(.init(
                timestamp: ts,
                speaker: "The Producer",
                text: text,
                dawPosition: fullDawPos,
                audioRel: hasDaw ? audioRel : nil,
                screenshotRel: screenshotRel
            ))
        } catch {
            onLog("utterance: memos.md append failed — \(error)")
            return
        }
        onLog("[\(ts)] \(text)")
        lastUtterance = text
        lastAnswer = nil

        if forceAnswer {
            await answer(question: text)
            answered = true
        }
        onConsolidate()
    }

    // MARK: - Answering

    /// Silent tap on the answer button: answer the last utterance if it went
    /// unanswered (missed wake word), otherwise repeat the last answer.
    /// Returns true if anything was answered or spoken.
    private func handleSilentTap() async -> Bool {
        if let answer = lastAnswer {
            onState(.askSpeaking)
            await speaker.speak(answer)
            return true
        }
        if let utterance = lastUtterance {
            onLog("utterance: answering last utterance on silent tap")
            await answer(question: utterance)
            onConsolidate()
            return true
        }
        onLog("utterance: silent tap with nothing to answer")
        return false
    }

    private func answer(question: String) async {
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
            answer = try await AIClient.call(systemPrompt: Self.answerSystemPrompt, userPrompt: user)
        } catch {
            onLog("utterance: AI call failed — \(error)")
            return
        }
        onLog("A: \(answer)")
        let actions = Self.mediaActions(from: answer)
        let spokenText = Self.stripMediaTags(from: answer)
        appendChat(question: question, answer: spokenText)

        // Log the answer into the memo stream with assistant attribution so
        // the consolidator can resolve open questions from it.
        if !spokenText.isEmpty {
            try? MemoStream.append(.init(
                timestamp: Timestamps.compact(Date()),
                speaker: "Studio Runner",
                text: spokenText,
                dawPosition: nil,
                audioRel: nil,
                screenshotRel: nil
            ))
        }

        let textToSpeak = spokenText.isEmpty && !actions.isEmpty ? "OK" : spokenText
        lastAnswer = textToSpeak.isEmpty ? nil : textToSpeak
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
    }

    // MARK: - Wake word

    private static func containsWakeWord(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return wakeWordRe.firstMatch(in: text, range: range) != nil
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
        // Single-word transcripts are almost always Whisper hallucinations on
        // near-silent presses of the answer button. Use a neutral label instead
        // of echoing the noise back into the record.
        let wordCount = question.split(whereSeparator: \.isWhitespace).count
        let producerLine = wordCount <= 1
            ? "- The Producer solicits a response"
            : "- The Producer: \(question)"
        let runnerLine = answer.isEmpty ? "" : "\n- Studio Runner: \(answer)"
        let block = "\n## \(Timestamps.human())\n\(producerLine)\(runnerLine)\n---\n"
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
