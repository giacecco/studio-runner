import AppKit

/// Modal launch screen shown when the app starts without a project.
/// Lists recent projects (most recent first, top 5 visible, rest
/// scrollable) and offers New / Open Existing buttons.
@MainActor
final class ProjectPickerWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Outcome {
        case openRecent(URL)
        case new
        case openExisting
        case cancel
    }

    private static let visibleRowCount = 5
    private static let rowHeight: CGFloat = 48

    private var window: NSWindow!
    private var table: NSTableView!
    private var openSelectedButton: NSButton!
    private var recents: [URL] = []
    private var outcome: Outcome = .cancel

    func runModal() -> Outcome {
        recents = RecentProjects.load()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return outcome
    }

    private func buildWindow() {
        let width: CGFloat = 540
        let height: CGFloat = 380
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Studio Runner"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "Open a Studio Runner project")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: recents.isEmpty
            ? "No recent projects yet — create a new project or open an existing one."
            : "Recent projects:")
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = Self.rowHeight
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.style = .inset
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        col.resizingMask = .autoresizingMask
        col.width = width - 56
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.documentView = table

        let newButton = NSButton(title: "New Project…", target: self, action: #selector(newPressed))
        newButton.bezelStyle = .rounded
        newButton.translatesAutoresizingMaskIntoConstraints = false

        let openExistingButton = NSButton(title: "Open Existing…", target: self, action: #selector(openExistingPressed))
        openExistingButton.bezelStyle = .rounded
        openExistingButton.translatesAutoresizingMaskIntoConstraints = false

        openSelectedButton = NSButton(title: "Open", target: self, action: #selector(openSelectedPressed))
        openSelectedButton.bezelStyle = .rounded
        openSelectedButton.keyEquivalent = "\r"
        openSelectedButton.isEnabled = !recents.isEmpty
        openSelectedButton.isHidden = recents.isEmpty
        openSelectedButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(scroll)
        content.addSubview(newButton)
        content.addSubview(openExistingButton)
        content.addSubview(openSelectedButton)
        content.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * CGFloat(Self.visibleRowCount)),

            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cancelButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            openSelectedButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            openSelectedButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            openExistingButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            openExistingButton.trailingAnchor.constraint(
                equalTo: recents.isEmpty
                    ? content.trailingAnchor
                    : openSelectedButton.leadingAnchor,
                constant: recents.isEmpty ? -20 : -12),

            newButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            newButton.trailingAnchor.constraint(equalTo: openExistingButton.leadingAnchor, constant: -12),
        ])

        if !recents.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            window.initialFirstResponder = table
        } else {
            window.initialFirstResponder = newButton
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = recents[row]
        let cell = NSTableCellView()

        let name = NSTextField(labelWithString: url.deletingPathExtension().lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let path = NSTextField(labelWithString: prettyPath(url))
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(name)
        cell.addSubview(path)
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            path.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            path.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openSelectedButton.isEnabled = table.selectedRow >= 0
    }

    private func prettyPath(_ url: URL) -> String {
        let dir = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") {
            return "~" + dir.dropFirst(home.count)
        }
        return dir
    }

    // MARK: - Actions

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0 && row < recents.count else { return }
        finish(.openRecent(recents[row]))
    }

    @objc private func openSelectedPressed() {
        let row = table.selectedRow
        guard row >= 0 && row < recents.count else { return }
        finish(.openRecent(recents[row]))
    }

    @objc private func newPressed() { finish(.new) }

    @objc private func openExistingPressed() { finish(.openExisting) }

    @objc private func cancelPressed() { finish(.cancel) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return true
    }

    private func finish(_ result: Outcome) {
        outcome = result
        NSApp.stopModal()
    }
}
