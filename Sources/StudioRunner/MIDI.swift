import CoreMIDI
import Foundation

// MARK: - Public types

/// A learned button binding. Stable across sessions when persisted to disk —
/// reuses the same port name + channel + note/cc to recognise the press.
struct MIDIBinding: Codable, Equatable {
    enum Kind: String, Codable { case note, cc }
    let kind: Kind
    let channel: Int    // 0..15
    let data1: Int      // note number for `.note`, controller number for `.cc`
    let portName: String

    var human: String {
        let what = kind == .note ? "Note \(data1)" : "CC \(data1)"
        return "\(portName) · \(what) ch\(channel + 1)"
    }
}

/// Parsed MIDI event surfaced to subscribers. `other` covers anything we don't
/// care about (pitch bend, sysex, clock).
struct MIDIEvent {
    enum Kind { case noteOn, noteOff, ccDown, ccUp, mtcQuarterFrame, other }
    let kind: Kind
    let channel: Int
    let data1: Int
    let data2: Int
    let portName: String
}

enum MIDIError: Error {
    case clientFailed(OSStatus)
    case portFailed(OSStatus)
    case noSources
    case cancelled
}

// MARK: - CoreMIDI wrapper

/// Owns a CoreMIDI client and a single virtual input port; connects every
/// available source on `openAllSources()` and broadcasts parsed events to
/// every subscriber.
///
/// CoreMIDI's read callback fires on a high-priority audio thread; the
/// wrapper hops to a private serial queue before fanning out to subscribers,
/// so subscriber code can safely touch shared state.
final class MIDIClient: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var virtualSource      = MIDIEndpointRef()  // "StudioRunner" source — Bitwig listens here
    private var virtualDestination = MIDIEndpointRef()  // "StudioRunner" destination — satisfies Bitwig's output requirement
    private var sources: [MIDIEndpointRef] = []
    private(set) var sourceNames: [String] = []
    /// Most recently selected Bitwig track name, pushed via SysEx F0 7D 01 … F7.
    private(set) var currentTrackName: String? = nil

    private let queue = DispatchQueue(label: "studio-runner.midi.dispatch")
    private var handlers: [UUID: (MIDIEvent) -> Void] = [:]

    init() throws {
        var status = MIDIClientCreateWithBlock("StudioRunner" as CFString, &client) { _ in }
        guard status == noErr else { throw MIDIError.clientFailed(status) }
        status = MIDIInputPortCreateWithBlock(client, "in" as CFString, &inputPort) { [weak self] pktList, srcRefCon in
            self?.read(pktList: pktList, srcRefCon: srcRefCon)
        }
        guard status == noErr else { throw MIDIError.portFailed(status) }
        MIDISourceCreate(client, "StudioRunner" as CFString, &virtualSource)
        MIDIDestinationCreateWithBlock(client, "StudioRunner" as CFString, &virtualDestination) { _, _ in }
    }

    /// Send CC 119 ch16 on the "StudioRunner" virtual source to signal Bitwig that the ask flow is done.
    func signalAskDone() {
        guard virtualSource != 0 else { return }
        var packet = MIDIPacket()
        packet.timeStamp = 0
        packet.length = 3
        packet.data.0 = 0xBF  // CC, channel 15 (0-indexed)
        packet.data.1 = 119
        packet.data.2 = 127
        var packetList = MIDIPacketList(numPackets: 1, packet: packet)
        MIDIReceived(virtualSource, &packetList)
    }

    /// Send CC 117 ch16 to signal Bitwig whether the session is armed (value=127) or not (value=0).
    func signalSessionArmed(_ armed: Bool) {
        guard virtualSource != 0 else { return }
        var packet = MIDIPacket()
        packet.timeStamp = 0
        packet.length = 3
        packet.data.0 = 0xBF  // CC, channel 15 (0-indexed)
        packet.data.1 = 117
        packet.data.2 = armed ? 127 : 0
        var packetList = MIDIPacketList(numPackets: 1, packet: packet)
        MIDIReceived(virtualSource, &packetList)
    }

    /// Send CC 116 (minutes) + CC 115 (seconds) + CC 114 trigger on ch16
    /// to tell the Bitwig script to jump the transport to the given wall-clock position.
    func signalGoto(minutes: Int, seconds: Int) {
        guard virtualSource != 0 else { return }
        func send(_ cc: UInt8, _ val: UInt8) {
            var packet = MIDIPacket()
            packet.timeStamp = 0
            packet.length = 3
            packet.data.0 = 0xBF  // CC, channel 15 (0-indexed)
            packet.data.1 = cc
            packet.data.2 = val
            var pktList = MIDIPacketList(numPackets: 1, packet: packet)
            MIDIReceived(virtualSource, &pktList)
        }
        send(116, UInt8(min(minutes, 127)))
        send(115, UInt8(min(seconds, 59)))
        send(114, 127)
    }

    func openAllSources() throws {
        let count = MIDIGetNumberOfSources()
        guard count > 0 else { throw MIDIError.noSources }
        for i in 0..<count {
            let src = MIDIGetSource(i)
            sources.append(src)
            sourceNames.append(Self.endpointName(src))
            // We tag each source with its 1-based index in our `sources` array so
            // the read callback can map back to a port name without re-querying.
            let refCon = UnsafeMutableRawPointer(bitPattern: i + 1)
            MIDIPortConnectSource(inputPort, src, refCon)
        }
    }

    func subscribe(_ handler: @escaping (MIDIEvent) -> Void) -> UUID {
        let id = UUID()
        queue.async { self.handlers[id] = handler }
        return id
    }

    func unsubscribe(_ id: UUID) {
        queue.async { self.handlers.removeValue(forKey: id) }
    }

    func shutdown() {
        for src in sources { MIDIPortDisconnectSource(inputPort, src) }
        sources.removeAll()
        sourceNames.removeAll()
        queue.sync { handlers.removeAll() }
        if virtualDestination != 0 { MIDIEndpointDispose(virtualDestination); virtualDestination = 0 }
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource); virtualSource = 0 }
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    // MARK: - Read callback

    private func read(pktList: UnsafePointer<MIDIPacketList>, srcRefCon: UnsafeMutableRawPointer?) {
        let bitPatternRefCon = srcRefCon.map { Int(bitPattern: $0) } ?? 0
        let idx = bitPatternRefCon - 1
        let portName = (idx >= 0 && idx < sourceNames.count) ? sourceNames[idx] : "unknown"

        var packet = pktList.pointee.packet
        for _ in 0..<pktList.pointee.numPackets {
            let length = Int(packet.length)
            let bytes: [UInt8] = withUnsafeBytes(of: &packet.data) { raw in
                let typed = raw.bindMemory(to: UInt8.self)
                return Array(typed.prefix(length))
            }
            // SysEx F0 7D 01 <ASCII name> F7 — track name from Bitwig.
            if bytes.first == 0xF0 {
                if bytes.count >= 4, bytes[1] == 0x7D, bytes[2] == 0x01, bytes.last == 0xF7 {
                    let nameBytes = Array(bytes[3..<(bytes.count - 1)])
                    let name = String(bytes: nameBytes, encoding: .ascii).map { $0.isEmpty ? nil : $0 } ?? nil
                    queue.async { self.currentTrackName = name }
                }
                packet = MIDIPacketNext(&packet).pointee
                continue
            }
            if let evt = Self.parse(bytes: bytes, portName: portName) {
                queue.async { [weak self] in
                    guard let self = self else { return }
                    for h in self.handlers.values { h(evt) }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private static func parse(bytes: [UInt8], portName: String) -> MIDIEvent? {
        guard let status = bytes.first else { return nil }
        // MTC quarter-frame (0xF1) — System Common, not a channel message.
        if status == 0xF1 {
            let d1 = bytes.count > 1 ? Int(bytes[1]) : 0
            return MIDIEvent(kind: .mtcQuarterFrame, channel: 0, data1: d1, data2: 0, portName: portName)
        }
        let type = status & 0xF0
        let channel = Int(status & 0x0F)
        let d1 = bytes.count > 1 ? Int(bytes[1]) : 0
        let d2 = bytes.count > 2 ? Int(bytes[2]) : 0
        switch type {
        case 0x90:
            return MIDIEvent(kind: d2 > 0 ? .noteOn : .noteOff,
                             channel: channel, data1: d1, data2: d2, portName: portName)
        case 0x80:
            return MIDIEvent(kind: .noteOff, channel: channel, data1: d1, data2: d2, portName: portName)
        case 0xB0:
            return MIDIEvent(kind: d2 >= 64 ? .ccDown : .ccUp,
                             channel: channel, data1: d1, data2: d2, portName: portName)
        default:
            return MIDIEvent(kind: .other, channel: channel, data1: d1, data2: d2, portName: portName)
        }
    }

    /// Enumerate available MIDI sources without creating a full client.
    /// Safe to call at any time, including from the settings window.
    static func listSourceNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).map { endpointName(MIDIGetSource($0)) }
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String {
        var param: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &param) == noErr,
           let name = param?.takeRetainedValue() as String? {
            return name
        }
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &param) == noErr,
           let name = param?.takeRetainedValue() as String? {
            return name
        }
        return "MIDI source"
    }
}

// MARK: - Learn flow

/// Captures a single "press and release" cycle from the MIDI stream. The
/// `onPrompt` callback is invoked once at the start so the caller can update
/// the menu bar state to ask the user to press a button.
func captureBinding(
    client: MIDIClient,
    excluding: [MIDIBinding],
    deviceName: String? = nil
) async throws -> MIDIBinding {
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MIDIBinding, Error>) in
        final class Box { var captured: MIDIBinding?; var subscription: UUID?; var done = false }
        let box = Box()

        box.subscription = client.subscribe { evt in
            if box.done { return }

            // Phase 1: wait for a press-down that's eligible.
            if box.captured == nil {
                let candidate: MIDIBinding?
                switch evt.kind {
                case .noteOn:
                    candidate = MIDIBinding(kind: .note, channel: evt.channel,
                                            data1: evt.data1, portName: evt.portName)
                case .ccDown:
                    candidate = MIDIBinding(kind: .cc, channel: evt.channel,
                                            data1: evt.data1, portName: evt.portName)
                default:
                    candidate = nil
                }
                guard let c = candidate else { return }
                if excluding.contains(c) { return }
                if let dev = deviceName, c.portName != dev { return }
                box.captured = c
                return
            }

            // Phase 2: wait for the matching release on the same binding so the
            // session doesn't start mid-press.
            let cap = box.captured!
            let isMatch: Bool
            switch (cap.kind, evt.kind) {
            case (.note, .noteOff):
                isMatch = evt.channel == cap.channel && evt.data1 == cap.data1 && evt.portName == cap.portName
            case (.cc, .ccUp):
                isMatch = evt.channel == cap.channel && evt.data1 == cap.data1 && evt.portName == cap.portName
            default:
                isMatch = false
            }
            if isMatch {
                box.done = true
                if let sub = box.subscription { client.unsubscribe(sub) }
                continuation.resume(returning: cap)
            }
        }
    }
}

// MARK: - Push-to-talk gate

/// Routes live MIDI events to session / memo / ask press handlers.
///
/// The session binding is treated independently: holding it gates memo and
/// ask — those two are suppressed until the session button is down. This
/// lets the user hold a dedicated "session active" button and press memo or
/// ask freely without any mutual-exclusion constraint between them and the
/// session button.
///
/// Memo and ask remain mutually exclusive with each other (only one active
/// binding at a time via the `activeInner` slot).
final class MIDIGate {
    enum Which { case session, memo, ask }

    private weak var client: MIDIClient?
    private let sessionBinding: MIDIBinding
    private let memoBinding: MIDIBinding
    private let askBinding: MIDIBinding

    var onPressDown: ((Which) -> Void)?
    var onPressUp: ((Which) -> Void)?

    private var subscription: UUID?
    private var sessionDown = false   // session button currently held
    private var activeInner: Which?   // which of memo/ask is currently held

    init(client: MIDIClient, session: MIDIBinding, memo: MIDIBinding, ask: MIDIBinding) {
        self.client = client
        self.sessionBinding = session
        self.memoBinding = memo
        self.askBinding = ask
    }

    func start() {
        guard subscription == nil, let client = client else { return }
        subscription = client.subscribe { [weak self] evt in
            self?.handle(evt)
        }
    }

    func stop() {
        if let sub = subscription { client?.unsubscribe(sub) }
        subscription = nil
        sessionDown = false
        activeInner = nil
    }

    private func handle(_ evt: MIDIEvent) {
        // Session button — independent of memo/ask state.
        if let edge = match(evt, against: sessionBinding) {
            if edge == .down, !sessionDown {
                sessionDown = true
                onPressDown?(.session)
            } else if edge == .up, sessionDown {
                sessionDown = false
                onPressUp?(.session)
            }
            return
        }

        // Memo and ask — only active while session button is held.
        guard sessionDown else { return }

        if let edge = match(evt, against: memoBinding) {
            if edge == .down { pressInner(.memo) } else { releaseInner(.memo) }
            return
        }
        if let edge = match(evt, against: askBinding) {
            if edge == .down { pressInner(.ask) } else { releaseInner(.ask) }
        }
    }

    private enum Edge { case down, up }

    private func match(_ evt: MIDIEvent, against b: MIDIBinding) -> Edge? {
        guard evt.portName == b.portName, evt.channel == b.channel, evt.data1 == b.data1 else { return nil }
        switch (b.kind, evt.kind) {
        case (.note, .noteOn):  return .down
        case (.note, .noteOff): return .up
        case (.cc, .ccDown):    return .down
        case (.cc, .ccUp):      return .up
        default:                return nil
        }
    }

    private func pressInner(_ which: Which) {
        if activeInner != nil { return }  // ignore simultaneous memo + ask
        activeInner = which
        onPressDown?(which)
    }

    private func releaseInner(_ which: Which) {
        guard activeInner == which else { return }
        activeInner = nil
        onPressUp?(which)
    }
}

// MARK: - MTC receiver

/// Assembles MTC quarter-frame messages (0xF1) into a DAW timeline position
/// string ("M:SS" or "H:MM:SS"). Updated once per full 8-message cycle
/// (~3–7 Hz depending on frame rate). Thread-safe: all state mutations happen
/// on MIDIClient's private serial queue, which is the same queue that fires
/// the gate's press-down callback, so reading `position` from there is safe.
final class MTCReceiver {
    /// Current DAW position as "M:SS" (or "H:MM:SS" once past the first hour).
    /// Nil until the first complete 8-message cycle has been received.
    private(set) var position: String? = nil

    private var nibbles = [Int](repeating: 0, count: 8)
    private var subscription: UUID?
    private weak var client: MIDIClient?
    private let sourceName: String?   // nil = accept from any source

    init(client: MIDIClient, sourceName: String?) {
        self.client = client
        self.sourceName = sourceName
        subscription = client.subscribe { [weak self] evt in self?.handle(evt) }
    }

    func stop() {
        if let sub = subscription { client?.unsubscribe(sub) }
        subscription = nil
    }

    deinit { stop() }

    // MARK: - Private

    private func handle(_ evt: MIDIEvent) {
        guard evt.kind == .mtcQuarterFrame else { return }
        if let src = sourceName, evt.portName != src { return }

        let msgNum = (evt.data1 >> 4) & 0x07
        let nibble  =  evt.data1       & 0x0F
        nibbles[msgNum] = nibble

        // Reconstruct only after the last message in each cycle arrives so we
        // always use a coherent, single-cycle snapshot.
        guard msgNum == 7 else { return }

        let seconds = nibbles[2] | (nibbles[3] << 4)
        let minutes = nibbles[4] | (nibbles[5] << 4)
        let hours   = nibbles[6] | ((nibbles[7] & 0x01) << 4)

        if hours > 0 {
            position = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            position = String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Persistence

enum MIDIBindingsStore {
    struct Pair: Codable {
        let session: MIDIBinding?  // nil in data saved before the session-button feature
        let memo: MIDIBinding
        let ask: MIDIBinding
    }

    static func load() -> Pair? {
        guard let pair = Config.midiBindings, pair.session != nil else { return nil }
        return pair
    }

    static func save(session: MIDIBinding, memo: MIDIBinding, ask: MIDIBinding) {
        Config.setMidiBindings(Pair(session: session, memo: memo, ask: ask))
    }

    static func clear() {
        Config.setMidiBindings(nil)
    }
}
