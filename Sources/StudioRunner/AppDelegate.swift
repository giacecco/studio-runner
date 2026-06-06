import AppKit
import AVFoundation
import Foundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: Coordinator!
    private var statusController: StatusItemController!
    // application(_:open:) can fire before applicationDidFinishLaunching when the
    // app is launched by a file double-click. Stash the URL and consume it in
    // applicationDidFinishLaunching rather than crashing on a nil coordinator.
    private var pendingOpenURL: URL?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        coordinator = Coordinator()
        statusController = StatusItemController(coordinator: coordinator)
        if let url = pendingOpenURL {
            pendingOpenURL = nil
            coordinator.openProjectFile(url)
        } else {
            coordinator.bootstrap()
        }
        // Request microphone permission at startup so the system dialog appears
        // at a predictable moment, not mid-interaction (e.g. during TTS voice
        // testing in Settings, which also initialises AVAudioEngine on Sequoia).
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // Accessory apps have no visible menu bar, but NSApp.mainMenu still drives
    // keyboard-shortcut routing through the responder chain. Without it, standard
    // edit commands (cut/copy/paste/select all) silently do nothing in text fields.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = NSMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = main
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "studiorunner" }) else { return }
        if coordinator == nil {
            pendingOpenURL = url
        } else {
            coordinator.openProjectFile(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
