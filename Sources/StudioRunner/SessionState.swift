import Foundation

/// One discrete state the session can be in. Drives the menu bar icon
/// (`symbolName` + `tint`) and the disabled status row in the menu.
enum SessionState: Equatable {
    case notReady(reason: String)
    case idle
    case learningSession
    case learningMemo
    case learningAsk
    case recordingMemo
    case processingMemo
    case recordingAsk
    case askThinking
    case askSpeaking
    case consolidating
    case error(String)

    /// SF Symbol name shown in the menu bar. Idle is overridden in StatusItem
    /// with a composite waveform + coffee-cup image.
    var symbolName: String {
        switch self {
        case .notReady:          return "exclamationmark.triangle"
        case .idle:              return "waveform"
        case .learningSession,
             .learningMemo,
             .learningAsk:       return "hand.raised"
        case .recordingMemo,
             .recordingAsk:      return "mic.fill"
        case .processingMemo,
             .askThinking,
             .consolidating:     return "waveform.path.ecg"
        case .askSpeaking:       return "speaker.wave.2.fill"
        case .error:             return "exclamationmark.octagon"
        }
    }

    /// One-line label shown as a disabled menu item at the top of the menu.
    var label: String {
        switch self {
        case .notReady(let reason):  return "Not ready — \(reason)"
        case .idle:                  return "Idle"
        case .learningSession:       return "Press the session button…"
        case .learningMemo:          return "Press the talk button…"
        case .learningAsk:           return "Press the answer button…"
        case .recordingMemo:         return "Recording"
        case .processingMemo:        return "Transcribing"
        case .recordingAsk:          return "Recording (will answer)"
        case .askThinking:           return "Thinking…"
        case .askSpeaking:           return "Speaking"
        case .consolidating:         return "Consolidating notes"
        case .error(let msg):        return "Error: \(msg)"
        }
    }
}

/// Single mutable holder for the current state. Observers are invoked on the
/// main thread.
@MainActor
final class SessionStateStore {
    private(set) var state: SessionState = .idle
    private var observers: [(SessionState) -> Void] = []

    func observe(_ block: @escaping (SessionState) -> Void) {
        observers.append(block)
        block(state)
    }

    func set(_ newState: SessionState) {
        state = newState
        for obs in observers { obs(newState) }
    }

    /// Thread-safe entry point — schedules onto the main actor.
    nonisolated func setFromAnyThread(_ newState: SessionState) {
        Task { @MainActor in self.set(newState) }
    }
}
