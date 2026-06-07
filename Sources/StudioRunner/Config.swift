import Foundation

/// Single source of truth for all tunable knobs.
///
/// Settings that the user can change are stored in `ProjectSettings`
/// (serialised as a `*.studiorunner` file at the project root). Everything else
/// is a hardcoded constant. There is no longer any .env file support.
///
/// The app does not remember the last project across launches: it either
/// starts with no project (prompting the user) or opens whatever
/// `.studiorunner` file was double-clicked.
enum Config {
    // ── Project layout ───────────────────────────────────────────────────

    private(set) static var projectRoot: URL = resolveInitialProjectRoot()
    static let runnerDirName = ".studiorunner.d"
    static let notesFilename = "studiorunner.md"
    static let systemFilename = "system.md"

    static var runnerDir: URL { projectRoot.appendingPathComponent(runnerDirName) }
    static var notesFile: URL { projectRoot.appendingPathComponent(notesFilename) }
    static var rawFile: URL { runnerDir.appendingPathComponent("raw.md") }
    static var chatFile: URL { runnerDir.appendingPathComponent("chat.md") }
    static var systemFile: URL { runnerDir.appendingPathComponent(systemFilename) }
    static var screenshotsDir: URL { runnerDir.appendingPathComponent("screenshots") }
    static var audioDir: URL { runnerDir.appendingPathComponent("audio") }
    static func setProjectRoot(_ url: URL) {
        projectRoot = url
        loadProjectSettings()
    }

    private static func resolveInitialProjectRoot() -> URL {
        // Earlier versions persisted the last project path here; we no longer
        // do, so wipe any leftover value rather than let it sit indefinitely.
        UserDefaults.standard.removeObject(forKey: "projectRoot")
        if let envRoot = ProcessInfo.processInfo.environment["STUDIO_PROJECT_ROOT"], !envRoot.isEmpty {
            return URL(fileURLWithPath: envRoot)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    // ── Project settings (*.studiorunner) ────────────────────────────────

    private(set) static var settings = ProjectSettings()

    /// Loads project settings for the current `projectRoot`.
    ///
    /// Lookup order:
    ///   1. `<projectRoot>/<name>.studiorunner` — project-specific file (scanned by extension).
    ///   2. Global fallback at `~/Library/Application Support/StudioRunner/settings.json`
    ///      (written on every save; seeds brand-new projects).
    ///
    /// Returns `true` when the settings file already existed in the project folder.
    @discardableResult
    static func loadProjectSettings() -> Bool {
        let fileURL = ProjectSettings.projectFileURL(root: projectRoot)
        if let loaded = ProjectSettings.load(from: fileURL) {
            settings = loaded
            return true
        }
        if let fallbackURL = ProjectSettings.globalFallbackURL,
           let fallback = ProjectSettings.load(from: fallbackURL) {
            settings = fallback
        } else {
            settings = ProjectSettings(
                apiKey: nil,
                ttsVolumePercent: (UserDefaults.standard.object(forKey: "ttsVolumePercent") as? NSNumber)?.doubleValue,
                micDeviceName: {
                    let v = UserDefaults.standard.string(forKey: "micDeviceName") ?? ""
                    return v.isEmpty ? nil : v
                }(),
                dawDeviceName: {
                    let v = UserDefaults.standard.string(forKey: "dawDeviceName") ?? ""
                    return v.isEmpty ? nil : v
                }()
            )
        }
        return false
    }

    static func saveSettings() {
        settings.save(to: ProjectSettings.projectFileURL(root: projectRoot))
        if let url = ProjectSettings.globalFallbackURL {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            settings.save(to: url)
        }
    }

    // ── Language ─────────────────────────────────────────────────────────

    struct LanguageOption {
        let name: String    // English display name shown in the UI
        let code: String    // ISO 639-1 code — used for Whisper + voice filtering
    }

    static let languages: [LanguageOption] = [
        .init(name: "English",    code: "en"),
        .init(name: "French",     code: "fr"),
        .init(name: "German",     code: "de"),
        .init(name: "Spanish",    code: "es"),
        .init(name: "Italian",    code: "it"),
        .init(name: "Dutch",      code: "nl"),
        .init(name: "Portuguese", code: "pt"),
        .init(name: "Japanese",   code: "ja"),
        .init(name: "Korean",     code: "ko"),
        .init(name: "Chinese",    code: "zh"),
    ]

    static var language: String { settings.language ?? "en" }
    static func setLanguage(_ code: String) {
        settings.language = code == "en" ? nil : code
        saveSettings()
    }

    // ── Whisper ──────────────────────────────────────────────────────────

    static var whisperModel: String {
        let base = "/opt/homebrew/share/whisper-cpp/models/"
        // The .en model only supports English; use the multilingual variant for others.
        return language == "en" ? base + "ggml-medium.en.bin" : base + "ggml-medium.bin"
    }
    static var whisperLanguage: String { language }
    static var whisperBinary: String {
        which("whisper-cli") ?? "/opt/homebrew/bin/whisper-cli"
    }
    static let screencaptureBinary = "/usr/sbin/screencapture"

    // ── Audio ────────────────────────────────────────────────────────────

    static let micGainDb: Double = 25
    static let micPrerollSec: Double = 0.5
    static let micPostrollSec: Double = 0.5

    static var micDeviceName: String { settings.micDeviceName ?? "" }
    static func setMicDeviceName(_ name: String) {
        settings.micDeviceName = name.isEmpty ? nil : name
        saveSettings()
    }

    static var dawDeviceName: String { settings.dawDeviceName ?? "BlackHole 2ch" }
    static func setDawDeviceName(_ name: String) {
        settings.dawDeviceName = name
        saveSettings()
    }

    static var midiDeviceName: String? { settings.midiDeviceName }
    static func setMidiDeviceName(_ name: String?) {
        settings.midiDeviceName = name
        saveSettings()
    }

    static var midiBindings: MIDIBindingsStore.Pair? { settings.midiBindings }
    static func setMidiBindings(_ pair: MIDIBindingsStore.Pair?) {
        settings.midiBindings = pair
        saveSettings()
    }

    static var mtcSourceName: String? { settings.mtcSourceName }
    static func setMtcSourceName(_ name: String?) {
        settings.mtcSourceName = name
        saveSettings()
    }

    static let dawPrerollSec: Double = 10

    static let micSampleRate: Double = 16_000
    static let micChannels: UInt32 = 1
    static let micBitDepth: Int = 16
    static let micBytesPerSecond: Int = 16_000 * 2

    static let dawSampleRate: Double = 44_100
    static let dawChannels: UInt32 = 2
    static let dawBitDepth: Int = 16
    static let dawBytesPerSecond: Int = 44_100 * 2 * 2

    // ── Ring buffers ─────────────────────────────────────────────────────

    static let micBufferSeconds: Double = 60
    static var dawBufferSeconds: Double { max(60, dawPrerollSec + 30) }

    // ── AI client ────────────────────────────────────────────────────────

    /// Endpoint and model are stored in the .studiorunner file so they can be
    /// overridden per-project by editing the file directly (e.g. to point at
    /// Claude or a local proxy) without needing a UI.
    static var aiEndpoint: String {
        settings.aiEndpoint ?? "https://api.deepseek.com/anthropic/v1/messages"
    }
    static var aiModel: String { settings.aiModel ?? "deepseek-chat" }

    static var apiKey: String? { settings.apiKey }
    static func setApiKey(_ key: String?) {
        settings.apiKey = key.flatMap { $0.isEmpty ? nil : $0 }
        saveSettings()
    }

    // ── TTS ──────────────────────────────────────────────────────────────

    static var ttsVoiceName: String? { settings.ttsVoice }
    static func setTtsVoice(_ voice: String?) {
        let normalized = voice?.isEmpty == true ? nil : voice
        let lang = language  // capture before writing settings — avoids Swift exclusivity violation
        settings.ttsVoice = normalized
        if let name = normalized {
            if settings.voicePerLanguage == nil { settings.voicePerLanguage = [:] }
            settings.voicePerLanguage?[lang] = name
        }
        saveSettings()
    }

    static var ttsVolumePercent: Double? {
        settings.ttsVolumePercent.map { max(0, min(100, $0)) }
    }
    static var ttsVolume: Float? {
        ttsVolumePercent.map { Float($0 / 100.0) }
    }
    static func setTtsVolumePercent(_ percent: Double?) {
        settings.ttsVolumePercent = percent.map { max(0, min(100, $0)) }
        saveSettings()
    }

    // ── Base role baked into every AI system prompt ──────────────────────

    static var baseRole: String {
        let langName = languages.first { $0.code == language }?.name ?? "English"
        return """
You are a studio runner in a recording studio, helping The Producer through a music-production session. The Producer logs voice notes via push-to-talk while they work; you keep a curated track-state markdown (\(notesFilename)) up to date from the raw stream, and you answer the Producer's spoken questions about the session.

Be brief and practical. Short sentences. No preamble. When you mention a past note, cite its DAW position (e.g. "2:03") if known, otherwise its wall-clock time. The Producer is listening through speakers in a live mix context — they can't read long answers and don't want them.

Always respond in \(langName), including all content written to \(notesFilename).
"""
    }
}

/// Best-effort PATH lookup for binaries needed at runtime.
func which(_ name: String) -> String? {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"]
    for dir in candidates {
        let p = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}
