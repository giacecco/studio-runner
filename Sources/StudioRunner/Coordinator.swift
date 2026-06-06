import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers

/// Top-level controller. Owns the long-lived components (MIDI client, audio
/// recorders, flows, consolidator) and brokers the lifecycle in response to
/// menu-bar actions: start, stop, re-learn buttons, choose project folder.
@MainActor
final class Coordinator {
    let state = SessionStateStore()
    let speaker = Speaker()

    private var midi: MIDIClient?
    private var mic: MicRecorder?
    private var daw: DAWRecorder?
    private var gate: MIDIGate?
    private var mtcReceiver: MTCReceiver?
    private var memoFlow: MemoFlow?
    private var askFlow: AskFlow?
    private var consolidator: Consolidator?
    private var settingsWindow: SettingsWindowController?
    private(set) var isRunning = false

    private let cursors = Cursors()

    private final class Cursors {
        var memoStart = 0.0
        var askStart  = 0.0
        var memoDawPosition: String? = nil
    }

    // MARK: - Bootstrap

    func bootstrap() {
        Config.loadProjectSettings()

        // No .studiorunner file found — ask the user what to do before going further.
        let settingsURL = ProjectSettings.projectFileURL(root: Config.projectRoot)
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            promptFirstProject()
            return
        }

        do {
            try Layout.ensure()
        } catch {
            state.set(.notReady(reason: "can't write to project folder (\(Config.projectRoot.lastPathComponent))"))
            return
        }
        if Config.apiKey == nil {
            state.set(.notReady(reason: "API key missing — open Settings to add it"))
            return
        }
        state.set(.idle)
    }

    private func promptFirstProject() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "No project found"
        alert.informativeText = "Create a new Studio Runner project or open an existing one."
        alert.addButton(withTitle: "New project…")
        alert.addButton(withTitle: "Open existing…")
        switch alert.runModal() {
        case .alertFirstButtonReturn: promptNewProject()
        case .alertSecondButtonReturn: promptOpenProject()
        default: state.set(.notReady(reason: "no project — use the menu to open or create one"))
        }
    }

    private func promptNewProject() {
        let panel = NSSavePanel()
        panel.title = "New Studio Runner Project"
        panel.message = "Choose a name and location for your project."
        panel.nameFieldStringValue = "My Project"
        if let uti = UTType("com.giacecco.studiorunner.project") {
            panel.allowedContentTypes = [uti]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            state.set(.notReady(reason: "no project — use the menu to open or create one"))
            return
        }
        Config.settings.save(to: url)
        Config.setProjectRoot(url.deletingLastPathComponent())
        bootstrap()
        showSettings()
    }

    private func promptOpenProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Studio Runner Project"
        panel.message = "Select a .studiorunner project file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let uti = UTType("com.giacecco.studiorunner.project") {
            panel.allowedContentTypes = [uti]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            state.set(.notReady(reason: "no project — use the menu to open or create one"))
            return
        }
        openProjectFile(url)
    }

    // MARK: - Project folder

    /// Called when the user double-clicks a `.studiorunner` file in Finder.
    /// Derives the project root from the file's parent directory.
    func openProjectFile(_ url: URL) {
        let root = url.deletingLastPathComponent()
        if isRunning { stopSession() }
        Config.setProjectRoot(root)
        bootstrap()
    }

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the project folder where studiorunner.md should live."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fileURL = ProjectSettings.projectFileURL(root: url)
        let isNew = !FileManager.default.fileExists(atPath: fileURL.path)
        // Create the settings file immediately so bootstrap() doesn't re-prompt.
        if isNew { Config.settings.save(to: fileURL) }
        Config.setProjectRoot(url)
        bootstrap()
        if isNew { showSettings() }
    }

    // MARK: - Session lifecycle

    func startSession() {
        Task { await self._startSession() }
    }

    private func _startSession() async {
        guard !isRunning else { return }
        guard case .idle = state.state else {
            log("start: not ready (\(state.state.label))")
            return
        }

        // 1. MIDI
        let client: MIDIClient
        do {
            client = try MIDIClient()
            try client.openAllSources()
        } catch {
            state.set(.error("MIDI: \(error.localizedDescription)"))
            return
        }
        self.midi = client

        // 2. MTC receiver — listens for DAW timeline position
        self.mtcReceiver = MTCReceiver(client: client, sourceName: Config.mtcSourceName)

        // 3. Bindings — load or learn (MTC receiver is step 2 above)
        let pair: MIDIBindingsStore.Pair
        if let saved = MIDIBindingsStore.load() {
            pair = saved
        } else {
            guard let learned = await learnBindings(client: client) else {
                client.shutdown(); self.midi = nil
                state.set(.idle)
                return
            }
            pair = learned
            MIDIBindingsStore.save(memo: pair.memo, ask: pair.ask)
        }

        // 4. Mic
        let micDevID: AudioDeviceID?
        if Config.micDeviceName.isEmpty {
            micDevID = nil
        } else if let id = CoreAudioDevice.findInputDevice(named: Config.micDeviceName) {
            micDevID = id
        } else {
            log("mic device '\(Config.micDeviceName)' not found — falling back to system default")
            micDevID = nil
        }
        let micRec: MicRecorder
        do {
            micRec = try MicRecorder(gainDb: Config.micGainDb, deviceID: micDevID)
            try micRec.start()
        } catch {
            log("mic start failed: \(error)")
            state.set(.error("Mic: \(error.localizedDescription)"))
            client.shutdown(); self.midi = nil
            return
        }
        self.mic = micRec

        // 5. DAW (optional — log and continue if missing)
        if !Config.dawDeviceName.isEmpty,
           let dawID = CoreAudioDevice.findInputDevice(named: Config.dawDeviceName) {
            do {
                let rec = try DAWRecorder(deviceID: dawID)
                try rec.start()
                self.daw = rec
            } catch {
                log("DAW capture unavailable (\(error.localizedDescription)) — continuing mic-only")
                self.daw = nil
            }
        } else {
            log("DAW device '\(Config.dawDeviceName)' not found — continuing mic-only")
            self.daw = nil
        }

        // 6. Flows
        let onStateBg: @Sendable (SessionState) -> Void = { [stateStore = state] s in
            stateStore.setFromAnyThread(s)
        }
        let onLogBg: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.log(msg) }
        }
        let consolidator = Consolidator(onState: onStateBg, onLog: onLogBg)
        let onConsolidate: @Sendable () -> Void = { Task { await consolidator.schedule() } }
        let memoFlow = MemoFlow(
            mic: micRec.buffer,
            daw: self.daw?.buffer,
            onState: onStateBg,
            onConsolidate: onConsolidate,
            onLog: onLogBg
        )
        let askFlow = AskFlow(
            mic: micRec.buffer,
            speaker: speaker,
            onState: onStateBg,
            onLog: onLogBg
        )
        self.memoFlow = memoFlow
        self.askFlow = askFlow
        self.consolidator = consolidator

        // 7. Gate
        let gate = MIDIGate(client: client, memo: pair.memo, ask: pair.ask)
        let cursors = self.cursors
        let mtcRecv = self.mtcReceiver   // captured once; read on midi.queue alongside MTC updates
        gate.onPressDown = { [stateStore = state] which in
            let now = Date().timeIntervalSince1970 * 1000
            switch which {
            case .memo:
                cursors.memoStart = now
                cursors.memoDawPosition = mtcRecv?.position
                stateStore.setFromAnyThread(.recordingMemo)
            case .ask:
                cursors.askStart = now
                stateStore.setFromAnyThread(.recordingAsk)
            }
        }
        gate.onPressUp = { which in
            let now = Date().timeIntervalSince1970 * 1000
            switch which {
            case .memo:
                let s = cursors.memoStart
                let pos = cursors.memoDawPosition
                Task { await memoFlow.handle(startMs: s, endMs: now, dawPosition: pos) }
            case .ask:
                let s = cursors.askStart
                Task { await askFlow.handle(startMs: s, endMs: now) }
            }
        }
        gate.start()
        self.gate = gate

        isRunning = true
        state.set(.idle)
        log("session started — memo: \(pair.memo.human), ask: \(pair.ask.human)")
    }

    func stopSession() {
        gate?.stop(); gate = nil
        mtcReceiver?.stop(); mtcReceiver = nil
        mic?.stop(); mic = nil
        daw?.stop(); daw = nil
        memoFlow = nil
        askFlow = nil
        consolidator = nil
        midi?.shutdown(); midi = nil
        isRunning = false
        state.set(.idle)
        log("session stopped")
    }

    func relearnBindings() {
        Task {
            if isRunning { stopSession() }
            MIDIBindingsStore.clear()
            await _startSession()
        }
    }

    private func learnBindings(client: MIDIClient) async -> MIDIBindingsStore.Pair? {
        let device = Config.midiDeviceName
        state.set(.learningMemo)
        do {
            let memo = try await captureBinding(client: client, excluding: nil, deviceName: device)
            state.set(.learningAsk)
            let ask = try await captureBinding(client: client, excluding: memo, deviceName: device)
            return MIDIBindingsStore.Pair(memo: memo, ask: ask)
        } catch {
            state.set(.error("MIDI learn failed: \(error.localizedDescription)"))
            return nil
        }
    }

    // MARK: - Settings

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(coordinator: self)
        }
        settingsWindow?.show()
    }

    /// Called from the settings window after the API key is saved. Transitions
    /// out of `.notReady` without requiring a restart if the key was the only
    /// missing piece.
    func notifyApiKeySet() {
        if case .notReady = state.state { bootstrap() }
    }

    /// Called from the settings window when the DAW device name changes. If a
    /// session is currently running, bounce it so the DAW recorder rebinds.
    /// Memo + ask flows hold a reference to the old DAW buffer, so a full
    /// stop / start is the simplest way to swap them out cleanly.
    func applyDAWDeviceChange() {
        bounceIfRunning()
    }

    /// Same idea for the mic input device. MemoFlow and AskFlow both hold the
    /// mic buffer, so a bounce is the simplest path to a clean swap.
    func applyMicDeviceChange() {
        bounceIfRunning()
    }

    /// Called when the user picks a different MIDI controller device in Settings.
    /// Clears the saved bindings (they reference the old device's portName) and
    /// bounces the session so the learn flow runs against the new device.
    func applyMidiDeviceChange() {
        MIDIBindingsStore.clear()
        bounceIfRunning()
    }

    /// Recreate the MTC receiver when the user picks a different source in Settings.
    /// The old receiver unsubscribes on deinit; the new one subscribes immediately.
    func applyMtcSourceChange() {
        guard let client = midi else { return }
        mtcReceiver?.stop()
        mtcReceiver = MTCReceiver(client: client, sourceName: Config.mtcSourceName)
    }

    private func bounceIfRunning() {
        guard isRunning else { return }
        Task {
            stopSession()
            await _startSession()
        }
    }

    // MARK: - Misc actions

    func openNotes() { NSWorkspace.shared.open(Config.notesFile) }
    func openChat()  { NSWorkspace.shared.open(Config.chatFile) }
    func openRaw()   { NSWorkspace.shared.open(Config.rawFile) }
    func revealProjectInFinder() {
        NSWorkspace.shared.open(Config.projectRoot)
    }

    func runPrune() {
        do {
            let dropped = try RawStream.prune()
            log("pruned \(dropped) consolidated entr\(dropped == 1 ? "y" : "ies") from raw.md")
        } catch {
            log("prune failed: \(error)")
        }
    }

    func clearSession() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear session?"
        alert.informativeText = "Resets the session timeline, raw stream, and chat history. Track notes, TODOs, and open questions are kept. This cannot be undone."
        alert.addButton(withTitle: "Clear Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try "<!-- consolidated_through: none -->\n\n".write(
                to: Config.rawFile, atomically: true, encoding: .utf8)
        } catch {
            log("clear session: reset raw.md failed — \(error)")
        }

        if FileManager.default.fileExists(atPath: Config.chatFile.path) {
            do {
                try "".write(to: Config.chatFile, atomically: true, encoding: .utf8)
            } catch {
                log("clear session: clear chat.md failed — \(error)")
            }
        }

        guard let content = try? String(contentsOf: Config.notesFile, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(where: { $0 == "## Session timeline" }) else {
            log("clear session: section not found in \(Config.notesFilename)")
            return
        }
        let afterHeading = headingIdx + 1
        if let nextSection = lines[afterHeading...].firstIndex(where: { $0.hasPrefix("## ") }) {
            lines.removeSubrange(afterHeading..<nextSection)
        } else {
            lines.removeSubrange(afterHeading...)
            lines.append("")
        }
        do {
            try lines.joined(separator: "\n").write(to: Config.notesFile, atomically: true, encoding: .utf8)
            log("session cleared")
        } catch {
            log("clear session: write failed — \(error)")
        }
    }

    func shutdown() {
        stopSession()
    }

    // MARK: - Logging

    private func log(_ message: String) {
        FileHandle.standardError.write(Data(("studio-runner: " + message + "\n").utf8))
    }
}
