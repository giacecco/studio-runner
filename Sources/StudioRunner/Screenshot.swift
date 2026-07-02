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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Screenshot", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                              "screencapture exited with status \(process.terminationStatus)"])
        }
    }
}
