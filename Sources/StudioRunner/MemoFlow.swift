import Foundation

/// Handles one memo press end-to-end:
///   1. Extract the mic clip from the rolling buffer (with preroll + postroll)
///   2. Transcribe it via whisper-cli
///   3. Take a full-screen screenshot
///   4. Extract the DAW clip (if BlackHole was found) and save it for later playback
///   5. Append a raw.md entry
///   6. Signal the consolidator
///
/// Writes raw.md *before* AI consolidation runs, so a network failure or
/// crash during consolidation can never lose a note.
actor MemoFlow {
    private let micBuffer: RollingBuffer
    private let dawBuffer: RollingBuffer?

    private let onState: (SessionState) -> Void
    private let onConsolidate: () -> Void
    private let onLog: (String) -> Void

    private var lastText = ""

    init(
        mic: RollingBuffer,
        daw: RollingBuffer?,
        onState: @escaping (SessionState) -> Void,
        onConsolidate: @escaping () -> Void,
        onLog: @escaping (String) -> Void
    ) {
        self.micBuffer = mic
        self.dawBuffer = daw
        self.onState = onState
        self.onConsolidate = onConsolidate
        self.onLog = onLog
    }

    func handle(startMs: Double, endMs: Double, dawPosition: String?) async {
        onState(.processingMemo)
        defer { onState(.idle) }

        // Mic extract: preroll on the head, postroll on the tail.
        let micStart = startMs - Config.micPrerollSec * 1000
        let micEnd = endMs + Config.micPostrollSec * 1000
        guard let micData = micBuffer.extract(startMs: micStart, endMs: micEnd) else {
            onLog("memo: mic buffer returned nil — bytesWritten=\(micBuffer.totalBytesWritten) window=[\(Int(micStart))–\(Int(micEnd))]")
            return
        }

        // Write a temp WAV for whisper.
        let tmpMic = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-runner-memo-\(Int(startMs)).wav")
        do {
            try WAVWriter.write(
                samples: micData,
                sampleRate: Int(Config.micSampleRate),
                channels: Int(Config.micChannels),
                bitDepth: Config.micBitDepth,
                to: tmpMic
            )
        } catch {
            onLog("memo: WAV write failed — \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tmpMic) }

        let text: String
        do {
            text = try await Whisper.transcribe(wavURL: tmpMic)
        } catch {
            onLog("memo: whisper failed — \(error)")
            return
        }
        if text.isEmpty {
            onLog("memo: whisper returned empty text")
            return
        }
        if text == lastText {
            // Suppress consecutive identical transcriptions; clear so the same
            // phrase can recur after a different one.
            onLog("memo: suppressed duplicate '\(text.prefix(60))'")
            return
        }
        lastText = text

        let ts = Timestamps.compact(Date(timeIntervalSince1970: startMs / 1000))
        let screenshotRel = "\(Config.runnerDirName)/screenshots/\(ts).png"
        let audioRel = "\(Config.runnerDirName)/audio/\(ts).wav"
        let screenshotAbs = Config.screenshotsDir.appendingPathComponent("\(ts).png")
        let audioAbs = Config.audioDir.appendingPathComponent("\(ts).wav")

        try? await Screenshot.capture(to: screenshotAbs)

        // DAW clip — bounded preroll, no postroll (music after the utterance
        // belongs to the next entry). Skip writing a clip when the buffer is
        // essentially silent: BlackHole forwards literal zeros when the DAW
        // transport is stopped, so a "clip" would just be silence pointed at
        // from raw.md, useless for later playback.
        var hasDaw = false
        if let dawBuffer = dawBuffer {
            let dawStart = startMs - Config.dawPrerollSec * 1000
            if let dawData = dawBuffer.extract(startMs: dawStart, endMs: endMs),
               !MemoFlow.isSilent(dawData) {
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
                    onLog("memo: DAW WAV write failed — \(error)")
                }
            }
        }

        do {
            try RawStream.append(.init(
                timestamp: ts,
                micText: text,
                dawPosition: dawPosition,
                audioRel: hasDaw ? audioRel : nil,
                screenshotRel: screenshotRel
            ))
        } catch {
            onLog("memo: raw.md append failed — \(error)")
            return
        }

        onLog("[\(ts)] \(text)")
        onConsolidate()
    }

    /// True when the interleaved Int16 PCM payload has no sample with
    /// magnitude above ~-54 dBFS — typical of BlackHole with the DAW
    /// transport stopped. We use peak rather than RMS so a single
    /// genuine note doesn't get drowned out by surrounding silence in
    /// the average.
    private static func isSilent(_ pcm: Data) -> Bool {
        guard pcm.count >= 2 else { return true }
        let peakThreshold: Int32 = 64   // ≈ -54 dBFS for Int16
        var peak: Int32 = 0
        pcm.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Int16.self)
            for sample in buf {
                let a = Int32(sample == Int16.min ? Int16.max : abs(sample))
                if a > peak { peak = a }
            }
        }
        return peak < peakThreshold
    }
}
