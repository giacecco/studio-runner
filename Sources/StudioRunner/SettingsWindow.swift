import AppKit
import AVFoundation
import Foundation

/// Modeless settings window. Controls: language, producer microphone, DAW
/// input device, AI voice (filtered to the chosen language), TTS volume, and
/// Anthropic-compatible API key. Edits write to the project's `.studiorunner`
/// file immediately via `Config` setters — there is no Apply / Cancel.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private weak var coordinator: Coordinator?

    private let languagePopup    = NSPopUpButton(frame: .zero, pullsDown: false)
    private let micPopup         = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dawPopup         = NSPopUpButton(frame: .zero, pullsDown: false)
    private let midiPopup        = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mtcPopup         = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voicePopup       = NSPopUpButton(frame: .zero, pullsDown: false)
    private let volumeSlider     = NSSlider()
    private let volumeReadout    = NSTextField(labelWithString: "")
    private let testVoiceButton  = NSButton(title: "Test voice", target: nil, action: nil)
    private let volumeDefaultButton = NSButton(title: "Reset to default", target: nil, action: nil)
    private let apiKeyField      = NSSecureTextField()
    private let apiKeyTestButton = NSButton(title: "Test", target: nil, action: nil)
    private let apiKeyStatus     = NSTextField(labelWithString: "")
    private let doneButton       = NSButton(title: "Done", target: nil, action: nil)
    private let speaker          = Speaker()
    private var originalApiKey: String?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 625),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Studio Runner Settings"
        window.isReleasedWhenClosed = false
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

        // Language
        let langLabel = NSTextField(labelWithString: "Session language:")
        langLabel.alignment = .right
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        // Microphone
        let micLabel = NSTextField(labelWithString: "Producer microphone:")
        micLabel.alignment = .right
        micPopup.target = self
        micPopup.action = #selector(micChanged)

        // DAW
        let dawLabel = NSTextField(labelWithString: "DAW input device:")
        dawLabel.alignment = .right
        dawPopup.target = self
        dawPopup.action = #selector(dawChanged)

        // MIDI controller device
        let midiLabel = NSTextField(labelWithString: "MIDI controller:")
        midiLabel.alignment = .right
        midiPopup.target = self
        midiPopup.action = #selector(midiDeviceChanged)

        // MTC source
        let mtcLabel = NSTextField(labelWithString: "MTC source:")
        mtcLabel.alignment = .right
        mtcPopup.target = self
        mtcPopup.action = #selector(mtcSourceChanged)

        let mtcHint = NSTextField(labelWithString:
            "Enable MTC output in your DAW and route it to the IAC Driver (Audio MIDI Setup → IAC Driver → Device is online). The app will then display DAW timeline positions on each memo.")
        mtcHint.textColor = .secondaryLabelColor
        mtcHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        mtcHint.isEditable = false
        mtcHint.isBordered = false
        mtcHint.backgroundColor = .clear
        mtcHint.lineBreakMode = .byWordWrapping
        mtcHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Voice
        let voiceLabel = NSTextField(labelWithString: "AI voice:")
        voiceLabel.alignment = .right
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)

        let voiceHint = NSTextField(labelWithString:
            "Add voices or download enhanced versions: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…")
        voiceHint.textColor = .secondaryLabelColor
        voiceHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        voiceHint.isEditable = false
        voiceHint.isBordered = false
        voiceHint.backgroundColor = .clear
        voiceHint.lineBreakMode = .byWordWrapping
        voiceHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Volume
        let volLabel = NSTextField(labelWithString: "Voice volume:")
        volLabel.alignment = .right

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.numberOfTickMarks = 11
        volumeSlider.allowsTickMarkValuesOnly = false
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)

        volumeReadout.alignment = .left
        volumeReadout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        testVoiceButton.bezelStyle = .rounded
        testVoiceButton.target = self
        testVoiceButton.action = #selector(testVoice)

        volumeDefaultButton.bezelStyle = .rounded
        volumeDefaultButton.target = self
        volumeDefaultButton.action = #selector(useDefaultVolume)

        // API key
        let apiLabel = NSTextField(labelWithString: "Anthropic-compatible API key:")
        apiLabel.alignment = .right

        apiKeyField.placeholderString = "sk-…"
        apiKeyField.usesSingleLineMode = true
        apiKeyField.cell?.wraps = false
        apiKeyField.cell?.isScrollable = true
        apiKeyField.delegate = self
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyCommitted)

        apiKeyTestButton.bezelStyle = .rounded
        apiKeyTestButton.target = self
        apiKeyTestButton.action = #selector(testApiKey)

        apiKeyStatus.alignment = .left
        apiKeyStatus.textColor = .secondaryLabelColor
        apiKeyStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        apiKeyStatus.isEditable = false
        apiKeyStatus.isBordered = false
        apiKeyStatus.backgroundColor = .clear

        // Done
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(closeWindow)

        let hint = NSTextField(labelWithString: "Changes are saved automatically.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let grid = NSGridView(views: [
            [langLabel,  languagePopup],
            [micLabel,   micPopup],
            [dawLabel,   dawPopup],
            [midiLabel,  midiPopup],
            [mtcLabel,   mtcPopup],
            [NSGridCell.emptyContentView, mtcHint],
            [voiceLabel, voicePopup],
            [NSGridCell.emptyContentView, voiceHint],
            [volLabel,   volumeSlider],
            [NSGridCell.emptyContentView, makeVolumeFooter()],
            [apiLabel,   apiKeyField],
            [NSGridCell.emptyContentView, makeApiKeyFooter()],
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
        let stack = NSStackView(views: [volumeReadout, testVoiceButton, volumeDefaultButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func makeApiKeyFooter() -> NSView {
        let stack = NSStackView(views: [apiKeyTestButton, apiKeyStatus])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    // MARK: - Populate

    private func populate() {
        let devices = CoreAudioDevice.listInputDevices()
        populateLanguagePopup()
        populateMicPopup(devices: devices)
        populateDAWPopup(devices: devices)
        populateMidiPopup()
        populateMtcPopup()
        populateVoicePopup()
        populateVolume()
        populateApiKey()
    }

    private func populateLanguagePopup() {
        languagePopup.removeAllItems()
        let current = Config.language
        for (i, lang) in Config.languages.enumerated() {
            let title = i == 0 ? "\(lang.name) (default)" : lang.name
            languagePopup.addItem(withTitle: title)
            languagePopup.lastItem?.representedObject = lang.code
        }
        if let matched = languagePopup.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            languagePopup.select(matched)
        } else {
            languagePopup.selectItem(at: 0)
        }
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
        if Config.settings.micDeviceName == nil {
            Config.setMicDeviceName((micPopup.selectedItem?.representedObject as? String) ?? "")
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
        if Config.settings.dawDeviceName == nil {
            Config.setDawDeviceName((dawPopup.selectedItem?.representedObject as? String) ?? "")
        }
    }

    private func populateMidiPopup() {
        midiPopup.removeAllItems()
        midiPopup.addItem(withTitle: "Any (all devices)")
        midiPopup.lastItem?.representedObject = ""
        for name in MIDIClient.listSourceNames() {
            midiPopup.addItem(withTitle: name)
            midiPopup.lastItem?.representedObject = name
        }
        let current = Config.midiDeviceName ?? ""
        if current.isEmpty {
            midiPopup.selectItem(at: 0)
        } else if let matched = midiPopup.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            midiPopup.select(matched)
        } else {
            midiPopup.selectItem(at: 0)
        }
    }

    private func populateMtcPopup() {
        mtcPopup.removeAllItems()
        mtcPopup.addItem(withTitle: "Any (accept from all sources)")
        mtcPopup.lastItem?.representedObject = ""
        for name in MIDIClient.listSourceNames() {
            mtcPopup.addItem(withTitle: name)
            mtcPopup.lastItem?.representedObject = name
        }
        let current = Config.mtcSourceName ?? ""
        if current.isEmpty {
            mtcPopup.selectItem(at: 0)
        } else if let matched = mtcPopup.itemArray.first(where: { ($0.representedObject as? String) == current }) {
            mtcPopup.select(matched)
        } else {
            mtcPopup.selectItem(at: 0)
        }
    }

    private func populateVoicePopup() {
        // Prefer the per-language remembered voice; fall back to current popup selection or global setting.
        let currentPopupVoice = voicePopup.selectedItem?.representedObject as? String
        let remembered = Config.settings.voicePerLanguage?[Config.language]
        let previousVoice = remembered ?? currentPopupVoice ?? Config.ttsVoiceName
        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: "System default")
        voicePopup.lastItem?.representedObject = ""

        let langCode = Config.language
        // Show voices for the selected language family, sorted by BCP-47 locale
        // (so en-AU, en-GB, en-IE, en-US group together) then by name within each.
        // Use exact-code or "code-" prefix matching to avoid false matches (e.g.
        // "it" must not match a hypothetical "ita-..." code).
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == langCode || $0.language.hasPrefix(langCode + "-") }
            .filter { !$0.identifier.hasPrefix("com.apple.eloquence") }
            .filter {
                guard #available(macOS 14, *) else { return true }
                return !$0.voiceTraits.contains(.isNoveltyVoice)
            }
            .sorted {
                if $0.language != $1.language { return $0.language < $1.language }
                return $0.name < $1.name
            }
        for voice in voices {
            // Display as "en-IE — Moira (Enhanced)" so the locale is visible.
            let title = "\(voice.language) — \(voice.name)"
            voicePopup.addItem(withTitle: title)
            voicePopup.lastItem?.representedObject = voice.name
        }

        if let name = previousVoice, !name.isEmpty,
           let matched = voicePopup.itemArray.first(where: { ($0.representedObject as? String) == name }) {
            voicePopup.select(matched)
        } else {
            voicePopup.selectItem(at: 0)
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

    private func populateApiKey() {
        originalApiKey = Config.settings.apiKey
        apiKeyField.stringValue = Config.settings.apiKey ?? ""
    }

    // MARK: - Actions

    @objc private func languageChanged() {
        let code = (languagePopup.selectedItem?.representedObject as? String) ?? "en"
        let previousCode = Config.language
        if code == previousCode { return }

        // Pre-commit: if the new language's whisper model isn't on disk,
        // confirm the ~1.5 GB download up front. If the user cancels,
        // roll the popup back to the previous selection so the language
        // setting never actually changes.
        let prospective = Config.whisperModelPath(forLanguage: code)
        if !FileManager.default.fileExists(atPath: prospective) {
            let langName = Config.languages.first(where: { $0.code == code })?.name ?? code
            let modelName = Config.whisperModelFilename(forLanguage: code)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Download \(langName) Whisper model?"
            alert.informativeText = """
Switching to \(langName) needs the Whisper model \(modelName) (~1.5 GB), which \
isn't yet on disk. Download it now? Cancelling leaves the session language as \
it was.
"""
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                if let item = languagePopup.itemArray.first(where: { ($0.representedObject as? String) == previousCode }) {
                    languagePopup.select(item)
                }
                return
            }
        }

        Config.setLanguage(code)
        populateVoicePopup()
        // Restore the last-used voice for this language; fall back to first alphabetical.
        let remembered = Config.settings.voicePerLanguage?[code]
        if let name = remembered, !name.isEmpty,
           let matched = voicePopup.itemArray.first(where: { ($0.representedObject as? String) == name }) {
            voicePopup.select(matched)
            Config.setTtsVoice(name)
        } else if voicePopup.numberOfItems > 1 {
            voicePopup.selectItem(at: 1)
            let name = (voicePopup.selectedItem?.representedObject as? String) ?? ""
            Config.setTtsVoice(name.isEmpty ? nil : name)
        } else {
            Config.setTtsVoice(nil)
        }
        speaker.stop()
        Task { await self.speaker.speak(Self.voiceCheckPhrase) }
        coordinator?.applyLanguageChange()
    }

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

    @objc private func midiDeviceChanged() {
        let name = (midiPopup.selectedItem?.representedObject as? String) ?? ""
        Config.setMidiDeviceName(name.isEmpty ? nil : name)
        coordinator?.applyMidiDeviceChange()
    }

    @objc private func mtcSourceChanged() {
        let name = (mtcPopup.selectedItem?.representedObject as? String) ?? ""
        Config.setMtcSourceName(name.isEmpty ? nil : name)
        coordinator?.applyMtcSourceChange()
    }

    @objc private func voiceChanged() {
        let name = (voicePopup.selectedItem?.representedObject as? String) ?? ""
        Config.setTtsVoice(name.isEmpty ? nil : name)
        speaker.stop()
        Task { await self.speaker.speak(Self.voiceCheckPhrase) }
    }

    @objc private func volumeChanged() {
        let p = volumeSlider.doubleValue
        Config.setTtsVolumePercent(p)
        volumeReadout.stringValue = "\(Int(p.rounded()))%"
        volumeDefaultButton.isEnabled = true
        if NSApp.currentEvent?.type == .leftMouseUp { testVoice() }
    }

    @objc private func testVoice() {
        speaker.stop()
        Task { await self.speaker.speak(Self.voiceCheckPhrase) }
    }

    private static var voiceCheckPhrase: String {
        switch Config.language {
        case "fr": return "Studio Runner, vérification de la voix."
        case "de": return "Studio Runner, Sprachtest."
        case "es": return "Studio Runner, comprobación de voz."
        case "it": return "Studio Runner, verifica della voce."
        case "nl": return "Studio Runner, stemcontrole."
        case "pt": return "Studio Runner, verificação de voz."
        case "ja": return "スタジオランナー、音声確認。"
        case "ko": return "스튜디오 러너, 음성 확인."
        case "zh": return "Studio Runner，语音检查。"
        default:   return "Studio Runner, voice check."
        }
    }

    @objc private func useDefaultVolume() {
        Config.setTtsVolumePercent(nil)
        populateVolume()
    }

    @objc private func apiKeyCommitted() {
        saveApiKeyIfChanged()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === apiKeyField else { return }
        saveApiKeyIfChanged()
    }

    private func saveApiKeyIfChanged() {
        let entered = apiKeyField.stringValue
        guard entered != (originalApiKey ?? "") else { return }
        Config.setApiKey(entered.isEmpty ? nil : entered)
        originalApiKey = Config.settings.apiKey
        coordinator?.notifyApiKeySet()
        apiKeyStatus.stringValue = ""
    }

    @objc private func testApiKey() {
        saveApiKeyIfChanged()
        guard Config.apiKey != nil else {
            apiKeyStatus.stringValue = "✗ No API key set"
            apiKeyStatus.textColor = .systemRed
            return
        }
        apiKeyStatus.stringValue = "Testing…"
        apiKeyStatus.textColor = .secondaryLabelColor
        apiKeyTestButton.isEnabled = false
        Task {
            do {
                try await AIClient.ping()
                apiKeyStatus.stringValue = "✓ Working"
                apiKeyStatus.textColor = .systemGreen
            } catch {
                let msg = (error as? AIClient.APIError)?.description ?? error.localizedDescription
                apiKeyStatus.stringValue = "✗ \(msg)"
                apiKeyStatus.textColor = .systemRed
            }
            apiKeyTestButton.isEnabled = true
        }
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}
