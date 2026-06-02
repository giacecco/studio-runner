import AppKit
import Foundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: Coordinator!
    private var statusController: StatusItemController!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = Coordinator()
        statusController = StatusItemController(coordinator: coordinator)
        coordinator.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
