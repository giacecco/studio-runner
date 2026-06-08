import Darwin
import Foundation

/// Persistent, project-scoped configuration. Serialised as
/// `<folder-name>.studiorunner` at the project root so it travels with the
/// DAW session folder, can be backed up or inspected as JSON, and opens
/// Studio Runner automatically when double-clicked in Finder.
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
    var dawPrerollSec: Double?    // nil = use the built-in default (10 s)
    var midiDeviceName: String?    // nil = accept from any MIDI device
    var midiBindings: MIDIBindingsStore.Pair?
    var mtcSourceName: String?    // nil = accept MTC from any source
    var aiEndpoint: String?       // nil = default endpoint (DeepSeek-compatible)
    var aiModel: String?          // nil = default model
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
        Self.markHasCustomIcon(at: url)
    }

    /// Set the FinderInfo `kHasCustomIcon` bit on the file. With this flag,
    /// Finder skips QuickLook thumbnail generation and falls back to the
    /// document type icon — that's how we get the mug instead of a text
    /// preview of the JSON body in icon view. The comment header alone
    /// doesn't suppress the text thumbnailer.
    private static func markHasCustomIcon(at url: URL) {
        // 32-byte FinderInfo: type(4) + creator(4) + flags(2) + location(4)
        // + fldr(2) + FXInfo(16). kHasCustomIcon = 0x0400 sits in the flags
        // word at offset 8 (big-endian).
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = setxattr(path, "com.apple.FinderInfo", info, info.count, 0, 0)
        }
    }

    // MARK: - Well-known paths

    /// Returns the `.studiorunner` file in `root`, or a default path for new projects.
    /// Scans the folder first so an existing file with any name is found correctly;
    /// falls back to `<folder-name>.studiorunner` only when none exists yet.
    static func projectFileURL(root: URL) -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        if let found = contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                               .first(where: { $0.pathExtension == "studiorunner" }) {
            return found
        }
        return root.appendingPathComponent("\(root.lastPathComponent).studiorunner")
    }

    static var globalFallbackURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("StudioRunner/settings.json")
    }
}
