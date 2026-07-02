import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers

private let soundMemo   = NSSound(named: "Tink")
private let soundAsk    = NSSound(named: "Pop")
private let soundMemoUp = NSSound(named: "Ping")
private let soundAskUp  = NSSound(named: "Glass")

/// Top-level controller. Owns the long-lived components and brokers
/// the session lifecycle.
///
/// The MIDI client is permanent — it starts at bootstrap and stays
/// connected until quit. A dedicated "session" button (learned alongside
/// talk and answer) controls the audio components: pressing it starts the
/// mic/DAW recorders and the utterance flow; releasing it stops them.
@MainActor
final class Coordinator {
    let state = SessionStateStore()
    let speaker = Speaker()

    // MIDI — permanent, live for the app's lifetime after bootstrap
    private var midi: MIDIClient?
    private var gate: MIDIGate?
    private var mtcReceiver: MTCReceiver?

    // Session components — live only while the session button is held
    private var mic: MicRecorder?
    private var daw: DAWRecorder?
    private var utteranceFlow: UtteranceFlow?
    private var consolidator: Consolidator?

    private var settingsWindow: SettingsWindowController?
    private(set) var isSessionActive = false
    private(set) var sessionArmTime: Date?
    private var workTimeLog = WorkTimeLog()

    private let cursors = Cursors()

    private final class Cursors {
        var utteranceStart = 0.0
        var utteranceDawPosition: String? = nil
        var utteranceDawTrack: String? = nil
    }

    /// Gate events hop from the MIDI queue to the main actor through this
    /// FIFO, so press/release pairs are processed strictly in arrival order.
    private let gateEvents = SerialTaskQueue()


    // MARK: - Bootstrap

    func bootstrap() {
        Config.loadProjectSettings()

        if Config.projectFileCorrupt {
            let name = ProjectSettings.projectFileURL(root: Config.projectRoot).lastPathComponent
            state.set(.notReady(reason: "\(name) is unreadable — fix or delete it, then reopen the project"))
            return
        }

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

        if !FileManager.default.fileExists(atPath: Config.whisperModel) {
            ensureWhisperModel()
            return
        }

        startMidi()
    }

    private func ensureWhisperModel() {
        let name = Config.whisperModelFilename
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Download Whisper model?"
        alert.informativeText = """
The transcription model \(name) (~1.5 GB) is required but not yet on disk. \
Studio Runner can download it now from Hugging Face — this typically takes a \
few minutes on a fast connection. Progress is shown in the menu bar.
"""
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            state.set(.notReady(reason: "whisper model not installed — restart to retry"))
            return
        }
        startWhisperModelDownload()
    }

    /// Starts the model download in the background. Assumes the caller
    /// has already obtained user consent (NSAlert in `ensureWhisperModel`
    /// for bootstrap; pre-commit confirm in SettingsWindow for language
    /// switches). Updates `.notReady` with progress and re-runs
    /// `bootstrap` on success.
    private func startWhisperModelDownload() {
        let name = Config.whisperModelFilename
        state.set(.notReady(reason: "downloading \(name)… 0%"))
        Task { [stateStore = state] in
            do {
                var lastReported = -1
                try await WhisperModelDownloader.shared.ensureCurrentModel { p in
                    let pct = Int(p * 100)
                    if pct != lastReported {
                        lastReported = pct
                        stateStore.setFromAnyThread(.notReady(reason: "downloading \(name)… \(pct)%"))
                    }
                }
                await MainActor.run { self.bootstrap() }
            } catch {
                await MainActor.run {
                    self.state.set(.error("model download failed — \(error.localizedDescription)"))
                }
            }
        }
    }

    private func promptFirstProject() {
        let picker = ProjectPickerWindow()
        switch picker.runModal() {
        case .openRecent(let url): openProjectFile(url)
        case .new: promptNewProject()
        case .openExisting: promptOpenProject()
        case .cancel:
            state.set(.notReady(reason: "no project — use the menu to open or create one"))
        }
    }

    func promptNewProject() {
        let panel = NSSavePanel()
        panel.title = "New Studio Runner Project"
        panel.message = "Choose a name and location for your project."
        panel.nameFieldStringValue = "My Project"
        if let uti = UTType("com.giacecco.studiorunner.project") {
            panel.allowedContentTypes = [uti]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            if !hasCurrentProject {
                state.set(.notReady(reason: "no project — use the menu to open or create one"))
            }
            return
        }
        Config.settings.save(to: url)
        RecentProjects.note(url)
        if isSessionActive { stopSessionComponents() }
        Config.setProjectRoot(url.deletingLastPathComponent())
        bootstrap()
        showSettings()
    }

    func promptOpenProject() {
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
            if !hasCurrentProject {
                state.set(.notReady(reason: "no project — use the menu to open or create one"))
            }
            return
        }
        openProjectFile(url)
    }

    var hasCurrentProject: Bool {
        let url = ProjectSettings.projectFileURL(root: Config.projectRoot)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Project switching

    private var pendingModalOpenURL: URL?

    func openProjectFile(_ url: URL) {
        // Apple Events are delivered even while a modal (project picker,
        // open/save panel, alert) is running. Opening a project underneath
        // it would nest a bootstrap inside the modal and let the modal's
        // outcome run a second open/new flow on top. Defer until the modal
        // session ends.
        guard NSApp.modalWindow == nil else {
            pendingModalOpenURL = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.retryPendingOpen()
            }
            return
        }
        let root = url.deletingLastPathComponent()
        if isSessionActive { stopSessionComponents() }
        Config.setProjectRoot(root)
        RecentProjects.note(url)
        bootstrap()
    }

    private func retryPendingOpen() {
        guard let url = pendingModalOpenURL else { return }
        guard NSApp.modalWindow == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.retryPendingOpen()
            }
            return
        }
        pendingModalOpenURL = nil
        openProjectFile(url)
    }

    // MARK: - MIDI lifecycle (permanent)

    private func startMidi() {
        Task { await _startMidi() }
    }

    private func _startMidi() async {
        // Re-bootstrap (project switch, API-key retry): tear down any live
        // MIDI stack first. A second MIDIClient would create duplicate
        // virtual "StudioRunner" endpoints (which the DAW script may latch
        // onto) and leak the old CoreMIDI client, port and endpoints —
        // MIDIClient has no deinit, so shutdown() is the only disposal path.
        if isSessionActive { stopSessionComponents() }
        gate?.stop(); gate = nil
        mtcReceiver?.stop(); mtcReceiver = nil
        midi?.shutdown(); midi = nil

        let client: MIDIClient
        do {
            client = try MIDIClient()
            try client.openAllSources()
        } catch {
            state.set(.error("MIDI: \(error.localizedDescription)"))
            return
        }
        self.midi = client
        self.mtcReceiver = MTCReceiver(client: client, sourceName: Config.mtcSourceName)

        let pair: MIDIBindingsStore.Pair
        if let saved = MIDIBindingsStore.load() {
            pair = saved
        } else {
            guard let learned = await learnBindings(client: client) else {
                // learnBindings has already set .error — stamping .idle over
                // it would show a "ready" icon with no working buttons.
                return
            }
            pair = learned
            MIDIBindingsStore.save(session: pair.session!, memo: pair.memo, ask: pair.ask)
        }

        setupGate(client: client, pair: pair)
        state.set(.idle)
        log("MIDI ready — session: \(pair.session!.human), talk: \(pair.memo.human), answer: \(pair.ask.human)")
    }

    private func setupGate(client: MIDIClient, pair: MIDIBindingsStore.Pair) {
        guard let sessionBinding = pair.session else { return }

        let g = MIDIGate(client: client, session: sessionBinding, memo: pair.memo, ask: pair.ask)
        // The gate fires on the MIDI dispatch queue. Only the timestamp is
        // taken there; everything else hops to the main actor through the
        // FIFO queue, so Coordinator state (midi, mtcReceiver, utteranceFlow,
        // cursors) is never touched off its actor and a press/release pair
        // can never be processed out of order.
        g.onPressDown = { [gateEvents, weak self] which in
            let now = Date().timeIntervalSince1970 * 1000
            gateEvents.enqueue { @MainActor in
                await self?.handleGatePressDown(which, at: now)
            }
        }
        g.onPressUp = { [gateEvents, weak self] which in
            let now = Date().timeIntervalSince1970 * 1000
            gateEvents.enqueue { @MainActor in
                self?.handleGatePressUp(which, at: now)
            }
        }
        g.start()
        self.gate = g
    }

    private func handleGatePressDown(_ which: MIDIGate.Which, at now: Double) async {
        switch which {
        case .session:
            midi?.signalSessionArmed(true)
            await _startSessionComponents()
        case .memo:
            cursors.utteranceStart = now
            cursors.utteranceDawPosition = mtcReceiver?.position
            cursors.utteranceDawTrack = midi?.currentTrackName
            state.set(.recordingMemo)
            // Pressing while the assistant is speaking cuts it off — the
            // producer's voice takes priority, and the less TTS the mic
            // ring picks up, the cleaner the new transcription.
            speaker.stop()
            soundMemo?.volume = Config.ttsVolume ?? 1.0
            soundMemo?.play()
        case .ask:
            cursors.utteranceStart = now
            cursors.utteranceDawPosition = mtcReceiver?.position
            cursors.utteranceDawTrack = midi?.currentTrackName
            state.set(.recordingAsk)
            speaker.stop()
            soundAsk?.volume = Config.ttsVolume ?? 1.0
            soundAsk?.play()
        }
    }

    private func handleGatePressUp(_ which: MIDIGate.Which, at now: Double) {
        switch which {
        case .session:
            midi?.signalSessionArmed(false)
            stopSessionComponents()
        case .memo, .ask:
            let snd = which == .memo ? soundMemoUp : soundAskUp
            snd?.volume = Config.ttsVolume ?? 1.0
            snd?.play()
            let s = cursors.utteranceStart
            let pos = cursors.utteranceDawPosition
            let track = cursors.utteranceDawTrack
            let force = which == .ask
            // The pipeline is deliberately NOT run on the gate queue: it
            // spans transcription, AI and TTS, and further presses must be
            // able to land (and interrupt TTS) while it runs.
            let flow = utteranceFlow
            Task { await flow?.handle(startMs: s, endMs: now, dawPosition: pos, dawTrack: track, forceAnswer: force) }
        }
    }

    // MARK: - Session components

    private func _startSessionComponents() async {
        guard !isSessionActive else { return }

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
            let rec = try MicRecorder(gainDb: Config.micGainDb, deviceID: micDevID)
            // startRunning() is a documented blocking call — run it off the
            // main thread so the app doesn't beachball on a slow device grab.
            try await Task.detached { try rec.start() }.value
            micRec = rec
        } catch {
            log("mic start failed: \(error)")
            state.set(.error("Mic: \(error.localizedDescription)"))
            return
        }
        self.mic = micRec

        if !Config.dawDeviceName.isEmpty,
           let dawID = CoreAudioDevice.findInputDevice(named: Config.dawDeviceName) {
            do {
                let rec = try DAWRecorder(deviceID: dawID)
                try await Task.detached { try rec.start() }.value
                self.daw = rec
            } catch {
                log("DAW capture unavailable (\(error.localizedDescription)) — continuing mic-only")
                self.daw = nil
            }
        } else {
            self.daw = nil
        }

        let onStateBg: @Sendable (SessionState, [SessionState]) -> Void = { [stateStore = state] s, onlyIfCurrentIn in
            stateStore.setFromAnyThread(s, onlyIfCurrentIn: onlyIfCurrentIn)
        }
        let onLogBg: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.log(msg) }
        }
        let consolidator = Consolidator(onState: onStateBg, onLog: onLogBg)
        let onConsolidate: @Sendable () -> Void = { Task { await consolidator.schedule() } }
        self.utteranceFlow = UtteranceFlow(
            mic: micRec.buffer,
            daw: self.daw?.buffer,
            speaker: speaker,
            onState: onStateBg,
            onConsolidate: onConsolidate,
            onLog: onLogBg,
            onClearSession: { [weak self] in
                Task { @MainActor in self?.clearSessionHeadless() }
            },
            onGoto: { [midi = self.midi] minutes, seconds in
                midi?.signalGoto(minutes: minutes, seconds: seconds)
            },
            onAnswerDone: { [midi = self.midi] in
                midi?.signalAskDone()
            },
            onSessionType: { [weak self] type, isContinuing in
                Task { @MainActor in
                    Config.setCurrentSessionType(type)
                    if isContinuing {
                        self?.workTimeLog.reclassifyAdjacentUnclassified(as: type)
                        self?.workTimeLog.save(to: Config.workTimeFile)
                        self?.injectWorkTimeSection()
                    }
                }
            }
        )
        self.consolidator = consolidator

        workTimeLog = WorkTimeLog.load(from: Config.workTimeFile)
        sessionArmTime = Date()
        isSessionActive = true
        state.set(.idle)
        log("session started")
    }

    private func stopSessionComponents() {
        guard isSessionActive else { return }
        if let start = sessionArmTime {
            workTimeLog.add(start: start, end: Date(), sessionType: Config.currentSessionType)
            workTimeLog.save(to: Config.workTimeFile)
            sessionArmTime = nil
            injectWorkTimeSection()
        }
        mic?.stop(); mic = nil
        daw?.stop(); daw = nil
        utteranceFlow = nil
        consolidator = nil
        isSessionActive = false
        state.set(.idle)
        log("session stopped")
    }

    private func injectWorkTimeSection() {
        // Value copy: the transaction runs later, and must inject the log as
        // it was when the injection was requested.
        let logCopy = workTimeLog
        NotesFile.queue.enqueue {
            guard let notes = try? String(contentsOf: Config.notesFile, encoding: .utf8),
                  !notes.isEmpty else { return }
            let updated = WorkTimeLog.inject(into: notes, log: logCopy)
            try? updated.write(to: Config.notesFile, atomically: true, encoding: .utf8)
        }
    }

    /// Today's accumulated arm time: previous disarms this day plus the running
    /// current session. Read by StatusItemController for the live display.
    var accumulatedTodaySeconds: Int {
        let base = workTimeLog.todaySeconds()
        guard let start = sessionArmTime else { return base }
        return base + Int(Date().timeIntervalSince(start))
    }

    // MARK: - Re-learn

    func relearnBindings() {
        Task {
            if isSessionActive { stopSessionComponents() }
            gate?.stop(); gate = nil
            MIDIBindingsStore.clear()
            guard let client = midi else { return }
            guard let learned = await learnBindings(client: client) else { return }
            MIDIBindingsStore.save(session: learned.session!, memo: learned.memo, ask: learned.ask)
            setupGate(client: client, pair: learned)
            state.set(.idle)
        }
    }

    private func learnBindings(client: MIDIClient) async -> MIDIBindingsStore.Pair? {
        let device = Config.midiDeviceName
        state.set(.learningSession)
        do {
            let session = try await captureBinding(client: client, excluding: [], deviceName: device)
            state.set(.learningMemo)
            let memo = try await captureBinding(client: client, excluding: [session], deviceName: device)
            state.set(.learningAsk)
            let ask = try await captureBinding(client: client, excluding: [session, memo], deviceName: device)
            return MIDIBindingsStore.Pair(session: session, memo: memo, ask: ask)
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

    func notifyApiKeySet() {
        if case .notReady = state.state { bootstrap() }
    }

    func applyDAWDeviceChange() {
        if isSessionActive {
            stopSessionComponents()
            Task { await _startSessionComponents() }
        }
    }

    /// Triggered when the user changes the language in Settings. Each
    /// language family uses a different whisper model — English maps to
    /// `ggml-medium.en.bin`, everything else to the multilingual
    /// `ggml-medium.bin`. If the model for the new language isn't on
    /// disk yet, prompt + download before the next memo is recorded.
    ///
    /// If the model IS on disk, we still need to handle two stale-state
    /// cases: (a) MIDI hasn't started because bootstrap was previously
    /// halted by a cancel — resume bootstrap; (b) MIDI is running but
    /// state is stuck on `.notReady` from a prior cancel — restore idle.
    func applyLanguageChange() {
        guard FileManager.default.fileExists(atPath: Config.whisperModel) else {
            // SettingsWindow's `languageChanged` confirms the download
            // before committing the new language, so getting here means
            // the user already said yes — just start the transfer.
            startWhisperModelDownload()
            return
        }
        if midi == nil {
            bootstrap()
        } else if case .notReady = state.state {
            state.set(.idle)
        }
    }

    func applyMicDeviceChange() {
        if isSessionActive {
            stopSessionComponents()
            Task { await _startSessionComponents() }
        }
    }

    func applyMidiDeviceChange() {
        MIDIBindingsStore.clear()
        bounceMidi()
    }

    func applyMtcSourceChange() {
        guard let client = midi else { return }
        mtcReceiver?.stop()
        mtcReceiver = MTCReceiver(client: client, sourceName: Config.mtcSourceName)
    }

    private func bounceMidi() {
        Task {
            if isSessionActive { stopSessionComponents() }
            gate?.stop(); gate = nil
            mtcReceiver?.stop(); mtcReceiver = nil
            midi?.shutdown(); midi = nil
            await _startMidi()
        }
    }

    // MARK: - Misc actions

    func openNotes() { NSWorkspace.shared.open(Config.notesFile) }
    func openChat()  { NSWorkspace.shared.open(Config.chatFile) }
    func openMemos() { NSWorkspace.shared.open(Config.memosFile) }
    func revealProjectInFinder() {
        NSWorkspace.shared.open(Config.projectRoot)
    }

    func clearSessionHeadless() {
        performClear(logSuffix: " (voice command)")
    }

    func clearSession() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear session?"
        alert.informativeText = "Resets the memo stream, chat history, and all recorded audio and screenshots. Removes completed TODOs. The session timeline, track notes, open questions, and unchecked TODOs are kept. This cannot be undone."
        alert.addButton(withTitle: "Clear Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performClear(logSuffix: "")
    }

    private func performClear(logSuffix: String) {
        do {
            try "<!-- consolidated_through: none -->\n\n".write(
                to: Config.memosFile, atomically: true, encoding: .utf8)
        } catch {
            log("clear session: reset memos.md failed — \(error)")
        }

        if FileManager.default.fileExists(atPath: Config.chatFile.path) {
            do {
                try "".write(to: Config.chatFile, atomically: true, encoding: .utf8)
            } catch {
                log("clear session: clear chat.md failed — \(error)")
            }
        }

        for dir in [Config.audioDir, Config.screenshotsDir] {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
        }

        // The TODO strip and the timeline collapse form one exclusive
        // notes-file transaction: a consolidation racing in between could
        // otherwise be silently overwritten by the collapse's stale snapshot.
        NotesFile.queue.enqueue { @MainActor [weak self] in
            await self?.clearNotesExclusively(logSuffix: logSuffix)
        }
    }

    private func clearNotesExclusively(logSuffix: String) async {
        guard let content = try? String(contentsOf: Config.notesFile, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        if let todoIdx = lines.firstIndex(where: { $0 == "## TODO" }) {
            let start = todoIdx + 1
            let end = lines[start...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
            lines = lines.enumerated().compactMap { (i, line) in
                guard i >= start && i < end else { return line }
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- [X]") || t.hasPrefix("- [x]") { return nil }
                return line
            }
        }
        do {
            try lines.joined(separator: "\n").write(to: Config.notesFile, atomically: true, encoding: .utf8)
            log("session cleared\(logSuffix)")
        } catch {
            log("clear session: write failed — \(error)")
            return
        }
        await collapseTimelineAfterClear()
    }

    private static let timelineCollapsePrompt = """
    You compress the session timeline from a music-production log.
    For every day BEFORE today: output exactly one bullet in the form `- YYYY-MM-DD — <one-sentence summary of all meaningful work that day>`.
    For today: output each existing bullet unchanged.
    Output ONLY the bullet lines — no section heading, no blank lines at start or end, no preamble.
    """

    private func collapseTimelineAfterClear() async {
        guard let content = try? String(contentsOf: Config.notesFile, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(where: { $0 == "## Session timeline" }) else { return }
        let start = headingIdx + 1
        let end = lines[start...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let timelineText = lines[start..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timelineText.isEmpty else { return }

        let today = String(Timestamps.human(Date()).prefix(10))
        let user = "Today: \(today)\n\n=== Session timeline ===\n\(timelineText)"

        let collapsed: String
        do {
            collapsed = try await AIClient.call(
                systemPrompt: Self.timelineCollapsePrompt, userPrompt: user)
        } catch {
            log("clear session: timeline collapse failed — \(error)")
            return
        }

        var collapsedLines = collapsed.components(separatedBy: "\n")
        // Ensure a blank line before the next section heading.
        if !collapsedLines.last!.isEmpty { collapsedLines.append("") }
        lines.replaceSubrange(start..<end, with: collapsedLines)
        do {
            try lines.joined(separator: "\n").write(to: Config.notesFile, atomically: true, encoding: .utf8)
            log("clear session: timeline collapsed")
        } catch {
            log("clear session: timeline collapse write failed — \(error)")
        }
    }

    func shutdown() {
        if isSessionActive { stopSessionComponents() }
        gate?.stop(); gate = nil
        mtcReceiver?.stop(); mtcReceiver = nil
        midi?.shutdown(); midi = nil
    }

    // MARK: - Logging

    private func log(_ message: String) {
        NSLog("studio-runner: %@", message)
    }
}
