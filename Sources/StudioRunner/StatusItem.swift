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
        button.image = makeIcon(for: .idle)
        button.image?.isTemplate = true
    }

    private func configureMenu() {
        menu.delegate = self

        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())

        menu.addItem(makeItem("Re-learn buttons…", #selector(actionRelearn)))
        menu.addItem(.separator())

        menu.addItem(makeItem("New project…", #selector(actionNewProject), key: "n"))
        menu.addItem(makeItem("Open project…", #selector(actionOpenProject), key: "o"))
        menu.addItem(makeItem("Reveal project in Finder", #selector(actionReveal), key: "R"))
        menu.addItem(makeItem("Settings…", #selector(actionSettings), key: ","))
        menu.addItem(.separator())

        menu.addItem(makeItem("Open studiorunner.md", #selector(actionOpenNotes), key: "1"))
        menu.addItem(makeItem("Open chat history", #selector(actionOpenChat), key: "2"))
        menu.addItem(makeItem("Open memo stream", #selector(actionOpenMemos), key: "3"))
        menu.addItem(makeItem("Clear session…", #selector(actionClearSession)))
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
            detail = coordinator.isSessionActive ? "Listening" : "Ready"
        } else {
            detail = state.label
        }
        return "\(detail)  ·  \(Config.projectRoot.lastPathComponent)"
    }

    // MARK: - Icon construction

    private func makeIcon(for state: SessionState) -> NSImage {
        if case .idle = state { return makeIdleIcon(sessionActive: coordinator.isSessionActive) }
        let img = NSImage(systemSymbolName: state.symbolName,
                          accessibilityDescription: state.label) ?? NSImage()
        img.isTemplate = true
        return img
    }

    /// Mug silhouette with a music note cut out of the body. When the session
    /// is not active a diagonal slash is drawn across the icon.
    private func makeIdleIcon(sessionActive: Bool) -> NSImage {
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

        // Carve a symbol out of the mug body in negative — destinationOut punches
        // transparent holes through whatever is already in the context.
        if sessionActive {
            // Music note: session is running, app is ready to record.
            let noteConf = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            if let note = NSImage(systemSymbolName: "music.note",
                                  accessibilityDescription: nil)?
                .withSymbolConfiguration(noteConf) {
                note.draw(in: NSRect(x: 4, y: 2, width: 9, height: 10),
                          from: .zero, operation: .destinationOut, fraction: 1.0)
            }
        } else {
            // X mark: session not active (session button not held).
            let xConf = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            if let xmark = NSImage(systemSymbolName: "xmark",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(xConf) {
                xmark.draw(in: NSRect(x: 4, y: 2, width: 10, height: 10),
                           from: .zero, operation: .destinationOut, fraction: 1.0)
            }
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - NSMenuDelegate (refresh enable/disable on open)

    func menuWillOpen(_ menu: NSMenu) {
        let hasProject = coordinator.hasCurrentProject
        for item in menu.items {
            guard let action = item.action else { continue }
            switch action {
            case #selector(actionRelearn),
                 #selector(actionReveal),
                 #selector(actionSettings):
                item.isEnabled = hasProject
            case #selector(actionOpenNotes), #selector(actionClearSession):
                item.isEnabled = hasProject && FileManager.default.fileExists(atPath: Config.notesFile.path)
            case #selector(actionOpenChat):
                item.isEnabled = hasProject && FileManager.default.fileExists(atPath: Config.chatFile.path)
            case #selector(actionOpenMemos):
                item.isEnabled = hasProject && FileManager.default.fileExists(atPath: Config.memosFile.path)
            default:
                break
            }
        }
        statusRow.title = statusLabel(for: coordinator.state.state)
    }

    // MARK: - Actions

    @objc private func actionRelearn() { coordinator.relearnBindings() }
    @objc private func actionOpenProject() { coordinator.promptOpenProject() }
    @objc private func actionNewProject()  { coordinator.promptNewProject() }
    @objc private func actionReveal() { coordinator.revealProjectInFinder() }
    @objc private func actionSettings() { coordinator.showSettings() }
    @objc private func actionOpenNotes() { coordinator.openNotes() }
    @objc private func actionOpenChat()  { coordinator.openChat() }
    @objc private func actionOpenMemos() { coordinator.openMemos() }
    @objc private func actionClearSession() { coordinator.clearSession() }
    @objc private func actionQuit() { NSApp.terminate(nil) }
}
