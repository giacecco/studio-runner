import Foundation

/// Persisted list of recently opened `.studiorunner` project files, most
/// recent first. Stored in UserDefaults as an array of POSIX paths. The
/// store self-cleans missing files on read so the picker never offers a
/// vanished entry.
enum RecentProjects {
    private static let key = "recentProjects"
    private static let maxCount = 20

    static func load() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        let fm = FileManager.default
        return paths.compactMap { p in
            let url = URL(fileURLWithPath: p)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
        UserDefaults.standard.set(paths, forKey: key)
    }
}
