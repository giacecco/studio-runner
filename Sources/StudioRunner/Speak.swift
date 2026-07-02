import AVFoundation
import Foundation

@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private let relay: SpeechFinishRelay
    private var continuation: CheckedContinuation<Void, Never>?
    private var current: AVSpeechUtterance?
    private var watchdog: Task<Void, Never>?

    init() {
        relay = SpeechFinishRelay()
        synth.delegate = relay
        relay.speaker = self
    }

    func speak(_ text: String) async {
        // Pre-empt any utterance still in flight: resume the interrupted
        // caller rather than overwriting (and leaking) its continuation.
        if continuation != nil { stop() }
        let utt = AVSpeechUtterance(string: text)
        if let voiceName = Config.ttsVoiceName,
           let voice = Self.findVoice(named: voiceName) {
            utt.voice = voice
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        if let v = Config.ttsVolume { utt.volume = v }
        await withCheckedContinuation { cont in
            continuation = cont
            current = utt
            synth.speak(utt)
            // Watchdog: if the synthesizer never delivers didFinish or
            // didCancel (bad internal state, missing voice), the awaiting
            // utterance pipeline would hold the DAW transport paused
            // forever. Cap at a generous estimate of the spoken duration.
            let cap = 30.0 + Double(text.count) * 0.15
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.watchdogFired(for: utt)
            }
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        current = nil
        watchdog?.cancel()
        watchdog = nil
        continuation?.resume()
        continuation = nil
    }

    private func watchdogFired(for utt: AVSpeechUtterance) {
        guard utt === current else { return }
        NSLog("studio-runner: TTS watchdog fired — synthesizer never finished")
        stop()
    }

    fileprivate func speechDidFinish(_ utt: AVSpeechUtterance) {
        // A late didFinish for an utterance that stop() already dealt with
        // must not resume the continuation of a newer one.
        guard utt === current else { return }
        current = nil
        watchdog?.cancel()
        watchdog = nil
        continuation?.resume()
        continuation = nil
    }

    private static func findVoice(named query: String) -> AVSpeechSynthesisVoice? {
        let lower = query.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let exact = voices.first(where: { $0.name.lowercased() == lower }) { return exact }
        if let byId = voices.first(where: { $0.identifier.lowercased().contains(lower) }) { return byId }
        return voices.first { $0.name.lowercased().contains(lower) }
    }
}

private final class SpeechFinishRelay: NSObject, AVSpeechSynthesizerDelegate {
    weak var speaker: Speaker?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        // AVSpeechSynthesizer does not document which thread delivers
        // delegate callbacks; assumeIsolated would trap the whole app if an
        // OS release moves them off main. Hop explicitly instead.
        Task { @MainActor [weak speaker] in speaker?.speechDidFinish(utterance) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak speaker] in speaker?.speechDidFinish(utterance) }
    }
}
