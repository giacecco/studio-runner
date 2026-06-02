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
    enum Kind { case noteOn, noteOff, ccDown, ccUp, other }
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
final class MIDIClient {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var sources: [MIDIEndpointRef] = []
    private(set) var sourceNames: [String] = []

    private let queue = DispatchQueue(label: "studio-runner.midi.dispatch")
    private var handlers: [UUID: (MIDIEvent) -> Void] = [:]

    init() throws {
        var status = MIDIClientCreateWithBlock("StudioRunner" as CFString, &client) { _ in }
        guard status == noErr else { throw MIDIError.clientFailed(status) }
        status = MIDIInputPortCreateWithBlock(client, "in" as CFString, &inputPort) { [weak self] pktList, srcRefCon in
            self?.read(pktList: pktList, srcRefCon: srcRefCon)
        }
        guard status == noErr else { throw MIDIError.portFailed(status) }
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
    excluding: MIDIBinding?
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
                if let excl = excluding, c == excl { return }
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

/// Routes live MIDI events to memo / ask press handlers while a session is
/// running. Only emits a press once an active binding has had its full
/// down-then-up cycle observed.
final class MIDIGate {
    enum Which { case memo, ask }

    private weak var client: MIDIClient?
    private let memoBinding: MIDIBinding
    private let askBinding: MIDIBinding

    var onPressDown: ((Which) -> Void)?
    var onPressUp: ((Which) -> Void)?

    private var subscription: UUID?
    private var activeBinding: Which?

    init(client: MIDIClient, memo: MIDIBinding, ask: MIDIBinding) {
        self.client = client
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
        activeBinding = nil
    }

    private func handle(_ evt: MIDIEvent) {
        if let which = match(evt, against: memoBinding) {
            if which == .down { pressDown(.memo) } else { pressUp(.memo) }
            return
        }
        if let which = match(evt, against: askBinding) {
            if which == .down { pressDown(.ask) } else { pressUp(.ask) }
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

    private func pressDown(_ which: Which) {
        if activeBinding != nil { return }  // ignore simultaneous presses
        activeBinding = which
        onPressDown?(which)
    }

    private func pressUp(_ which: Which) {
        guard activeBinding == which else { return }
        activeBinding = nil
        onPressUp?(which)
    }
}

// MARK: - Persistence

enum MIDIBindingsStore {
    struct Pair: Codable {
        let memo: MIDIBinding
        let ask: MIDIBinding
    }

    static func load() -> Pair? {
        guard let data = try? Data(contentsOf: Config.bindingsFile) else { return nil }
        return try? JSONDecoder().decode(Pair.self, from: data)
    }

    static func save(memo: MIDIBinding, ask: MIDIBinding) {
        try? FileManager.default.createDirectory(at: Config.runnerDir, withIntermediateDirectories: true)
        let pair = Pair(memo: memo, ask: ask)
        guard let data = try? JSONEncoder().encode(pair) else { return }
        try? data.write(to: Config.bindingsFile, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: Config.bindingsFile)
    }
}
