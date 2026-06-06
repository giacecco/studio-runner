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
    private let statusRow  = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let startItem  = NSMenuItem()
    private let stopItem   = NSMenuItem()

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
        button.image = makeIcon(for: .idle)
        button.image?.isTemplate = true
    }

    private func configureMenu() {
        menu.delegate = self

        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())

        startItem.title = "Start session"
        startItem.action = #selector(actionStart)
        startItem.target = self
        stopItem.title = "Stop session"
        stopItem.action = #selector(actionStop)
        stopItem.target = self
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(makeItem("Re-learn buttons…", #selector(actionRelearn)))
        menu.addItem(.separator())

        menu.addItem(makeItem("Choose project folder…", #selector(actionChooseFolder)))
        menu.addItem(makeItem("Reveal project in Finder", #selector(actionReveal)))
        menu.addItem(makeItem("Settings…", #selector(actionSettings), key: ","))
        menu.addItem(.separator())

        menu.addItem(makeItem("Open studiorunner.md", #selector(actionOpenNotes)))
        menu.addItem(makeItem("Open chat history", #selector(actionOpenChat)))
        menu.addItem(makeItem("Open raw stream", #selector(actionOpenRaw)))
        menu.addItem(makeItem("Prune consolidated entries", #selector(actionPrune)))
        menu.addItem(makeItem("Clear session timeline", #selector(actionClearTimeline)))
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
        statusRow.title = statusLabel(for: state)
        if let button = statusItem.button {
            button.image = makeIcon(for: state)
            button.toolTip = state.label
        }
    }

    private func statusLabel(for state: SessionState) -> String {
        let detail: String
        if case .idle = state {
            detail = coordinator.isRunning ? "Listening" : "Not running"
        } else {
            detail = state.label
        }
        return "\(detail)  ·  \(Config.projectRoot.lastPathComponent)"
    }

    // MARK: - Icon construction

    private func makeIcon(for state: SessionState) -> NSImage {
        if case .idle = state { return makeIdleIcon() }
        let img = NSImage(systemSymbolName: state.symbolName,
                          accessibilityDescription: state.label) ?? NSImage()
        img.isTemplate = true
        return img
    }

    /// Mug silhouette with a music note cut out of the body — like a printed
    /// design on the mug. Passes the compositing operation directly to the draw
    /// call so AppKit's internal graphics-state save/restore can't reset it.
    private func makeIdleIcon() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        let mugConf = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let mug = NSImage(systemSymbolName: "mug.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(mugConf) {
            mug.draw(in: NSRect(x: 0, y: 0, width: 20, height: 16),
                     from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Carve the note out of the mug body — destinationOut punches the note
        // shape as transparent pixels into whatever is already in the context.
        let noteConf = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        if let note = NSImage(systemSymbolName: "music.note",
                              accessibilityDescription: nil)?
            .withSymbolConfiguration(noteConf) {
            note.draw(in: NSRect(x: 4, y: 2, width: 9, height: 10),
                      from: .zero, operation: .destinationOut, fraction: 1.0)
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - NSMenuDelegate (refresh enable/disable on open)

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            guard let action = item.action else { continue }
            switch action {
            case #selector(actionStart):
                item.isHidden  = coordinator.isRunning
                item.isEnabled = isReadyState()
            case #selector(actionStop):
                item.isHidden  = !coordinator.isRunning
            case #selector(actionRelearn):
                item.isEnabled = MIDIBindingsStore.load() != nil || coordinator.isRunning
            case #selector(actionOpenNotes), #selector(actionClearTimeline):
                item.isEnabled = FileManager.default.fileExists(atPath: Config.notesFile.path)
            case #selector(actionOpenChat):
                item.isEnabled = FileManager.default.fileExists(atPath: Config.chatFile.path)
            case #selector(actionOpenRaw):
                item.isEnabled = FileManager.default.fileExists(atPath: Config.rawFile.path)
            default:
                break
            }
        }
        statusRow.title = statusLabel(for: coordinator.state.state)
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
    @objc private func actionSettings() { coordinator.showSettings() }
    @objc private func actionOpenNotes() { coordinator.openNotes() }
    @objc private func actionOpenChat()  { coordinator.openChat() }
    @objc private func actionOpenRaw()   { coordinator.openRaw() }
    @objc private func actionPrune()         { coordinator.runPrune() }
    @objc private func actionClearTimeline() { coordinator.clearTimeline() }
    @objc private func actionQuit() { NSApp.terminate(nil) }
}
