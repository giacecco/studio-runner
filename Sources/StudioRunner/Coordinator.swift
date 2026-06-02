import AppKit
import CoreAudio
import Foundation

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
    private var memoFlow: MemoFlow?
    private var askFlow: AskFlow?
    private var consolidator: Consolidator?
    private(set) var isRunning = false

    private let cursors = Cursors()

    private final class Cursors {
        var memoStart = 0.0
        var askStart = 0.0
    }

    // MARK: - Bootstrap

    func bootstrap() {
        EnvFile.load(projectRoot: Config.projectRoot)
        do {
            try Layout.ensure()
        } catch {
            state.set(.notReady(reason: "can't write to project folder (\(Config.projectRoot.lastPathComponent))"))
            return
        }
        if Config.apiKey == nil {
            state.set(.notReady(reason: "STUDIORUNNER_AI_API_KEY missing — set in .env or environment"))
            return
        }
        state.set(.idle)
    }

    // MARK: - Project folder

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the project folder where studiorunner.md should live."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Config.setProjectRoot(url)
            bootstrap()
        }
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

        // 2. Bindings — load or learn
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

        // 3. Mic
        let micRec: MicRecorder
        do {
            micRec = try MicRecorder(gainDb: Config.micGainDb)
            try micRec.start()
        } catch {
            state.set(.error("Mic: \(error.localizedDescription)"))
            client.shutdown(); self.midi = nil
            return
        }
        self.mic = micRec

        // 4. DAW (optional — log and continue if missing)
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

        // 5. Flows
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

        // 6. Gate
        let gate = MIDIGate(client: client, memo: pair.memo, ask: pair.ask)
        let cursors = self.cursors
        gate.onPressDown = { [stateStore = state] which in
            let now = Date().timeIntervalSince1970 * 1000
            switch which {
            case .memo: cursors.memoStart = now; stateStore.setFromAnyThread(.recordingMemo)
            case .ask:  cursors.askStart = now;  stateStore.setFromAnyThread(.recordingAsk)
            }
        }
        gate.onPressUp = { which in
            let now = Date().timeIntervalSince1970 * 1000
            switch which {
            case .memo:
                let s = cursors.memoStart
                Task { await memoFlow.handle(startMs: s, endMs: now) }
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
        state.set(.learningMemo)
        do {
            let memo = try await captureBinding(client: client, excluding: nil)
            state.set(.learningAsk)
            let ask = try await captureBinding(client: client, excluding: memo)
            return MIDIBindingsStore.Pair(memo: memo, ask: ask)
        } catch {
            state.set(.error("MIDI learn failed: \(error.localizedDescription)"))
            return nil
        }
    }

    // MARK: - Misc actions

    func openNotes() { NSWorkspace.shared.open(Config.notesFile) }
    func openChat()  { NSWorkspace.shared.open(Config.chatFile) }
    func openRaw()   { NSWorkspace.shared.open(Config.rawFile) }
    func revealProjectInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Config.projectRoot])
    }

    func runPrune() {
        do {
            let dropped = try RawStream.prune()
            log("pruned \(dropped) consolidated entr\(dropped == 1 ? "y" : "ies") from raw.md")
        } catch {
            log("prune failed: \(error)")
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
