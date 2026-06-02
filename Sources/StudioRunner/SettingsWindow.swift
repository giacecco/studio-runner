import AppKit
import Foundation

/// Modeless settings window. Three controls: producer microphone picker, DAW
/// input device picker, and TTS volume slider. Edits are written to
/// UserDefaults via `Config` setters as soon as the user changes a control —
/// there is no Apply / Cancel.
///
/// Device changes are heavier than a volume change: if a session is running,
/// we ask the coordinator to bounce it so the recorders rebind. Volume
/// changes apply on the next spoken utterance — `Speaker` reads
/// `Config.ttsVolume` for every `speak()` call.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var coordinator: Coordinator?
    private let micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dawPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let volumeSlider = NSSlider()
    private let volumeReadout = NSTextField(labelWithString: "")
    private let volumeDefaultButton = NSButton(
        title: "Reset volume to default",
        target: nil,
        action: nil
    )
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 290),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Studio Runner Settings"
        window.isReleasedWhenClosed = false
        // Status-bar apps run as .accessory; without raising the level, this
        // window appears beneath whatever browser/DAW the user is in front of.
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        super.init(window: window)
        window.delegate = self
        buildLayout()
        populate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show() {
        populate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let micLabel = NSTextField(labelWithString: "Producer microphone:")
        micLabel.alignment = .right
        micPopup.target = self
        micPopup.action = #selector(micChanged)

        let dawLabel = NSTextField(labelWithString: "DAW input device:")
        dawLabel.alignment = .right
        dawPopup.target = self
        dawPopup.action = #selector(dawChanged)

        let volLabel = NSTextField(labelWithString: "DeepSeek voice volume:")
        volLabel.alignment = .right

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.numberOfTickMarks = 11
        volumeSlider.allowsTickMarkValuesOnly = false
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)

        volumeReadout.alignment = .left
        volumeReadout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        volumeDefaultButton.bezelStyle = .rounded
        volumeDefaultButton.target = self
        volumeDefaultButton.action = #selector(useDefaultVolume)

        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"          // Return / Enter closes the window
        doneButton.target = self
        doneButton.action = #selector(closeWindow)

        let hint = NSTextField(labelWithString: "Changes are saved automatically.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let grid = NSGridView(views: [
            [micLabel, micPopup],
            [dawLabel, dawPopup],
            [volLabel, volumeSlider],
            [NSGridCell.emptyContentView, makeVolumeFooter()]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let bottomBar = NSStackView(views: [hint, NSView(), doneButton])
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.distribution = .fill
        bottomBar.spacing = 8

        content.addSubview(grid)
        content.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottomBar.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func makeVolumeFooter() -> NSView {
        let stack = NSStackView(views: [volumeReadout, volumeDefaultButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    // MARK: - Populate

    private func populate() {
        let devices = CoreAudioDevice.listInputDevices()
        populateMicPopup(devices: devices)
        populateDAWPopup(devices: devices)
        populateVolume()
    }

    private func populateMicPopup(devices: [CoreAudioDevice.InputDevice]) {
        micPopup.removeAllItems()
        micPopup.addItem(withTitle: "System default")
        micPopup.lastItem?.representedObject = ""
        for d in devices {
            micPopup.addItem(withTitle: d.name)
            micPopup.lastItem?.representedObject = d.name
        }
        let current = Config.micDeviceName
        if current.isEmpty {
            micPopup.selectItem(at: 0)
        } else if let matched = micPopup.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            micPopup.select(matched)
        } else {
            micPopup.selectItem(at: 0)
        }
    }

    private func populateDAWPopup(devices: [CoreAudioDevice.InputDevice]) {
        dawPopup.removeAllItems()
        dawPopup.addItem(withTitle: "None (disable DAW capture)")
        dawPopup.lastItem?.representedObject = ""
        for d in devices {
            dawPopup.addItem(withTitle: d.name)
            dawPopup.lastItem?.representedObject = d.name
        }

        let current = Config.dawDeviceName
        // Pre-select: explicit empty → None; current match → that; else
        // BlackHole 2ch if present; else first device; else None.
        if current.isEmpty {
            dawPopup.selectItem(at: 0)
        } else if let matched = dawPopup.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            dawPopup.select(matched)
        } else if let bh = dawPopup.itemArray.first(where: {
            ($0.representedObject as? String)?.localizedCaseInsensitiveContains("blackhole") == true
        }) {
            dawPopup.select(bh)
        } else if dawPopup.numberOfItems > 1 {
            dawPopup.selectItem(at: 1)
        } else {
            dawPopup.selectItem(at: 0)
        }
    }

    private func populateVolume() {
        if let p = Config.ttsVolumePercent {
            volumeSlider.doubleValue = p
            volumeReadout.stringValue = "\(Int(p.rounded()))%"
            volumeDefaultButton.isEnabled = true
        } else {
            volumeSlider.doubleValue = 100
            volumeReadout.stringValue = "system default"
            volumeDefaultButton.isEnabled = false
        }
    }

    // MARK: - Actions

    @objc private func micChanged() {
        let name = (micPopup.selectedItem?.representedObject as? String) ?? ""
        Config.setMicDeviceName(name)
        coordinator?.applyMicDeviceChange()
    }

    @objc private func dawChanged() {
        let name = (dawPopup.selectedItem?.representedObject as? String) ?? ""
        Config.setDawDeviceName(name)
        coordinator?.applyDAWDeviceChange()
    }

    @objc private func volumeChanged() {
        let p = volumeSlider.doubleValue
        Config.setTtsVolumePercent(p)
        volumeReadout.stringValue = "\(Int(p.rounded()))%"
        volumeDefaultButton.isEnabled = true
    }

    @objc private func useDefaultVolume() {
        Config.setTtsVolumePercent(nil)
        populateVolume()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}
