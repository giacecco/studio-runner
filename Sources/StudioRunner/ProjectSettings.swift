import Foundation

/// Persistent, project-scoped configuration. Serialised as
/// `studiorunner.json` at the project root so it travels with the DAW
/// session folder and can be copied, backed up, or inspected by the user.
///
/// A global fallback copy is kept at
/// `~/Library/Application Support/StudioRunner/settings.json`; it is
/// overwritten on every save and used to pre-populate brand-new projects.
struct ProjectSettings: Codable {
    var apiKey: String?
    var language: String?         // ISO 639-1 code, nil = "en"
    var ttsVoice: String?
    var ttsVolumePercent: Double?
    var micDeviceName: String?
    var dawDeviceName: String?
    var aiEndpoint: String?       // nil = DeepSeek default
    var aiModel: String?          // nil = "deepseek-chat"
    /// Last-used voice name per ISO 639-1 language code, e.g. ["en": "Moira (Enhanced)", "it": "Alice"]
    var voicePerLanguage: [String: String]?

    // MARK: - Persistence

    static func load(from url: URL) -> ProjectSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectSettings.self, from: data)
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Well-known paths

    static func projectFileURL(root: URL) -> URL {
        root.appendingPathComponent("studiorunner.json")
    }

    static var globalFallbackURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("StudioRunner/settings.json")
    }
}
