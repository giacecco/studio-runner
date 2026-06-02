import Foundation

/// Single source of truth for tunable knobs. Reads from process env first, then
/// from `EnvFile` (which has already been loaded against the current project
/// root), then falls back to a default.
enum Config {
    // ── Project layout ───────────────────────────────────────────────────

    private(set) static var projectRoot: URL = resolveInitialProjectRoot()
    static var runnerDirName: String { EnvFile.value("STUDIO_RUNNER_DIR") ?? ".studiorunner.d" }
    static var notesFilename: String { EnvFile.value("STUDIO_NOTES_FILE") ?? "studiorunner.md" }
    static var systemFilename: String { EnvFile.value("STUDIO_SYSTEM_FILE") ?? "system.md" }

    static var runnerDir: URL { projectRoot.appendingPathComponent(runnerDirName) }
    static var notesFile: URL { projectRoot.appendingPathComponent(notesFilename) }
    static var rawFile: URL { runnerDir.appendingPathComponent("raw.md") }
    static var chatFile: URL { runnerDir.appendingPathComponent("chat.md") }
    static var systemFile: URL { runnerDir.appendingPathComponent(systemFilename) }
    static var screenshotsDir: URL { runnerDir.appendingPathComponent("screenshots") }
    static var audioDir: URL { runnerDir.appendingPathComponent("audio") }
    static var bindingsFile: URL { runnerDir.appendingPathComponent("midi-bindings.json") }

    static func setProjectRoot(_ url: URL) {
        projectRoot = url
        UserDefaults.standard.set(url.path, forKey: "projectRoot")
        EnvFile.load(projectRoot: url)
    }

    private static func resolveInitialProjectRoot() -> URL {
        if let stored = UserDefaults.standard.string(forKey: "projectRoot"), !stored.isEmpty {
            return URL(fileURLWithPath: stored)
        }
        if let envRoot = ProcessInfo.processInfo.environment["STUDIO_PROJECT_ROOT"], !envRoot.isEmpty {
            return URL(fileURLWithPath: envRoot)
        }
        // Last resort: the user's Documents folder. They'll be prompted to pick
        // a real project folder from the menu.
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    // ── Whisper ──────────────────────────────────────────────────────────

    static var whisperModel: String {
        EnvFile.value("WHISPER_MODEL")
            ?? "/opt/homebrew/share/whisper-cpp/models/ggml-medium.en.bin"
    }
    static var whisperLanguage: String { EnvFile.value("WHISPER_LANG") ?? "en" }
    static var whisperBinary: String {
        which("whisper-cli") ?? "/opt/homebrew/bin/whisper-cli"
    }
    static let screencaptureBinary = "/usr/sbin/screencapture"

    // ── Audio ────────────────────────────────────────────────────────────

    static var micGainDb: Double { Double(EnvFile.value("STUDIO_MIC_GAIN") ?? "") ?? 25 }
    static var micPrerollSec: Double { Double(EnvFile.value("STUDIO_MIC_PREROLL") ?? "") ?? 0.5 }
    static var micPostrollSec: Double { Double(EnvFile.value("STUDIO_MIC_POSTROLL") ?? "") ?? 0.5 }

    static var dawDeviceName: String { EnvFile.value("STUDIO_DAW_DEVICE") ?? "BlackHole 2ch" }
    static var dawPrerollSec: Double { Double(EnvFile.value("STUDIO_DAW_PREROLL") ?? "") ?? 10 }

    // Audio formats (constant — match the bun script's behaviour).
    static let micSampleRate: Double = 16_000
    static let micChannels: UInt32 = 1
    static let micBitDepth: Int = 16
    static let micBytesPerSecond: Int = 16_000 * 2

    static let dawSampleRate: Double = 44_100
    static let dawChannels: UInt32 = 2
    static let dawBitDepth: Int = 16
    static let dawBytesPerSecond: Int = 44_100 * 2 * 2

    // ── Ring buffers ─────────────────────────────────────────────────────

    /// Mic ring buffer length. Covers any reasonable single utterance plus
    /// preroll/postroll. 60s @ 32 KB/s = 1.92 MB.
    static let micBufferSeconds: Double = 60

    /// DAW ring buffer length — must cover dawPrerollSec + a long utterance.
    /// 60s @ 176 KB/s = 10.6 MB.
    static var dawBufferSeconds: Double { max(60, dawPrerollSec + 30) }

    // ── DeepSeek ─────────────────────────────────────────────────────────

    static var deepseekModel: String { EnvFile.value("STUDIO_DEEPSEEK_MODEL") ?? "deepseek-chat" }
    static var apiKey: String? { EnvFile.value("STUDIORUNNER_AI_API_KEY") }

    // ── TTS ──────────────────────────────────────────────────────────────

    static var ttsEnabled: Bool { (EnvFile.value("STUDIO_TTS") ?? "1") != "0" }
    static var ttsVoiceName: String? { EnvFile.value("STUDIO_TTS_VOICE") }
    /// 0.0–1.0 (mapped from 0–100 env var). nil means "leave at synthesizer default".
    static var ttsVolume: Float? {
        guard let raw = EnvFile.value("STUDIO_TTS_VOLUME"), let v = Double(raw) else { return nil }
        return Float(max(0, min(100, v)) / 100.0)
    }

    // ── Maintenance ──────────────────────────────────────────────────────

    static var pruneAssets: Bool { (EnvFile.value("STUDIO_PRUNE_ASSETS") ?? "0") == "1" }

    // ── Base role baked into every DeepSeek system prompt ────────────────

    static let baseRole = """
You are a studio runner in a recording studio, helping The Producer through a music-production session. The Producer logs voice notes via push-to-talk while they work; you keep a curated track-state markdown (\(Config.notesFilename)) up to date from the raw stream, and you answer the Producer's spoken questions about the session.

Be brief and practical. Short sentences. No preamble. When you mention a past note, cite its time in HH:MM form. The Producer is listening through speakers in a live mix context — they can't read long answers and don't want them.
"""
}

/// Best-effort PATH lookup for binaries needed at runtime. The .app inherits
/// the system's default PATH which lacks /opt/homebrew/bin, so we probe the
/// usual Homebrew locations directly.
func which(_ name: String) -> String? {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"]
    for dir in candidates {
        let p = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}
