import AVFoundation
import Foundation

/// Wraps `AVSpeechSynthesizer` so we can speak DeepSeek's reply without
/// shelling out to `say` + `afplay`. Volume is applied directly on the
/// utterance — no per-voice quirks like the legacy `[[volm]]` directive.
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        if let voiceName = Config.ttsVoiceName,
           let voice = Self.findVoice(named: voiceName) {
            utt.voice = voice
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        if let v = Config.ttsVolume { utt.volume = v }
        synth.speak(utt)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private static func findVoice(named query: String) -> AVSpeechSynthesisVoice? {
        let lower = query.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let exact = voices.first(where: { $0.name.lowercased() == lower }) { return exact }
        if let byId = voices.first(where: { $0.identifier.lowercased().contains(lower) }) { return byId }
        return voices.first { $0.name.lowercased().contains(lower) }
    }
}
