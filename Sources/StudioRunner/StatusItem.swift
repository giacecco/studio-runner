import AppKit
import Foundation

/// Owns the NSStatusItem and its menu. Subscribes to the coordinator's state
/// store to update the menu bar icon and the dynamic status line at the top
/// of the menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: Coordinator
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configureMenu()
        coordinator.state.observe { [weak self] state in
            self?.apply(state: state)
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform",
                               accessibilityDescription: "Studio Runner")
        button.image?.isTemplate = true
    }

    private func configureMenu() {
        menu.delegate = self

        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())

        menu.addItem(makeItem("Start session", #selector(actionStart)))
        menu.addItem(makeItem("Stop session",  #selector(actionStop)))
        menu.addItem(makeItem("Re-learn buttons…", #selector(actionRelearn)))
        menu.addItem(.separator())

        menu.addItem(makeItem("Choose project folder…", #selector(actionChooseFolder)))
        menu.addItem(makeItem("Reveal project in Finder", #selector(actionReveal)))
        menu.addItem(.separator())

        menu.addItem(makeItem("Open studiorunner.md", #selector(actionOpenNotes)))
        menu.addItem(makeItem("Open chat history", #selector(actionOpenChat)))
        menu.addItem(makeItem("Open raw stream", #selector(actionOpenRaw)))
        menu.addItem(makeItem("Prune consolidated entries", #selector(actionPrune)))
        menu.addItem(.separator())

        menu.addItem(makeItem("Quit Studio Runner", #selector(actionQuit), key: "q"))

        statusItem.menu = menu
    }

    private func makeItem(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - State binding

    private func apply(state: SessionState) {
        statusRow.title = state.label
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: state.symbolName,
                                   accessibilityDescription: state.label)
            button.image?.isTemplate = true
            button.toolTip = state.label
        }
    }

    // MARK: - NSMenuDelegate (refresh enable/disable on open)

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            guard let action = item.action else { continue }
            switch action {
            case #selector(actionStart):
                item.isEnabled = !coordinator.isRunning && isReadyState()
            case #selector(actionStop):
                item.isEnabled = coordinator.isRunning
            case #selector(actionRelearn):
                item.isEnabled = MIDIBindingsStore.load() != nil || coordinator.isRunning
            case #selector(actionOpenNotes):
                item.isEnabled = FileManager.default.fileExists(atPath: Config.notesFile.path)
            case #selector(actionOpenChat):
                item.isEnabled = FileManager.default.fileExists(atPath: Config.chatFile.path)
            case #selector(actionOpenRaw):
                item.isEnabled = FileManager.default.fileExists(atPath: Config.rawFile.path)
            default:
                break
            }
        }
        statusRow.title = "\(coordinator.state.state.label)  ·  \(Config.projectRoot.lastPathComponent)"
    }

    private func isReadyState() -> Bool {
        if case .notReady = coordinator.state.state { return false }
        return true
    }

    // MARK: - Actions

    @objc private func actionStart() { coordinator.startSession() }
    @objc private func actionStop()  { coordinator.stopSession() }
    @objc private func actionRelearn() { coordinator.relearnBindings() }
    @objc private func actionChooseFolder() { coordinator.chooseProjectFolder() }
    @objc private func actionReveal() { coordinator.revealProjectInFinder() }
    @objc private func actionOpenNotes() { coordinator.openNotes() }
    @objc private func actionOpenChat()  { coordinator.openChat() }
    @objc private func actionOpenRaw()   { coordinator.openRaw() }
    @objc private func actionPrune()     { coordinator.runPrune() }
    @objc private func actionQuit() { NSApp.terminate(nil) }
}
