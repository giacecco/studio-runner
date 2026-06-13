import AVFoundation
import Foundation

@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private let relay: SpeechFinishRelay
    private var continuation: CheckedContinuation<Void, Never>?
    private var current: AVSpeechUtterance?

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
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        current = nil
        continuation?.resume()
        continuation = nil
    }

    fileprivate func speechDidFinish(_ utt: AVSpeechUtterance) {
        // A late didFinish for an utterance that stop() already dealt with
        // must not resume the continuation of a newer one.
        guard utt === current else { return }
        current = nil
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
        MainActor.assumeIsolated { speaker?.speechDidFinish(utterance) }
    }
}
