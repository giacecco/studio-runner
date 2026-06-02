import Foundation

/// Captures a full-screen PNG via the system `screencapture` tool.
///
/// `screencapture` requires the user to grant the Screen Recording permission
/// to the app the first time it runs (System Settings → Privacy & Security →
/// Screen Recording). Until granted, the saved PNG will be blank.
enum Screenshot {
    static func capture(to url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Config.screencaptureBinary)
        process.arguments = ["-x", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}
