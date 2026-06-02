import Foundation

/// Loads simple KEY=VALUE pairs from .env-style files into an in-process dictionary.
///
/// macOS GUI apps inherit a very minimal environment (no PATH, no shell exports),
/// so anything we'd ordinarily set in the shell — DeepSeek API key, whisper model
/// path, BlackHole device name — has to be read from a file we own.
///
/// Lookup order (first hit wins):
///   1. `~/Library/Application Support/StudioRunner/.env`
///   2. project root `/.env`
///   3. `.env` next to the .app bundle (dev convenience when running from .build/)
enum EnvFile {
    private(set) static var loaded: [String: String] = [:]

    static func load(projectRoot: URL) {
        var merged: [String: String] = [:]

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let candidates: [URL] = [
            appSupport?.appendingPathComponent("StudioRunner/.env"),
            projectRoot.appendingPathComponent(".env"),
            siblingOfBundle(".env")
        ].compactMap { $0 }

        // Iterate in reverse so earlier candidates overwrite later ones (first hit wins).
        for url in candidates.reversed() {
            guard let pairs = readPairs(from: url) else { continue }
            for (k, v) in pairs { merged[k] = v }
        }

        loaded = merged
    }

    /// Resolve a variable: process env beats anything in the .env files.
    static func value(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        return loaded[key]
    }

    private static func siblingOfBundle(_ filename: String) -> URL? {
        let bundleURL = Bundle.main.bundleURL
        // Walk up four levels looking for the file — covers .build/StudioRunner.app
        // sitting next to the source repo's .env.
        var dir = bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func readPairs(from url: URL) -> [String: String]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var pairs: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            pairs[key] = value
        }
        return pairs
    }
}
