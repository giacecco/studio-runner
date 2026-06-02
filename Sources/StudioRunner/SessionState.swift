import Foundation

/// One discrete state the session can be in. Drives the menu bar icon
/// (`symbolName` + `tint`) and the disabled status row in the menu.
enum SessionState: Equatable {
    case notReady(reason: String)
    case idle
    case learningMemo
    case learningAsk
    case recordingMemo
    case processingMemo
    case recordingAsk
    case askThinking
    case askSpeaking
    case consolidating
    case error(String)

    /// SF Symbol name shown in the menu bar.
    var symbolName: String {
        switch self {
        case .notReady:          return "exclamationmark.triangle"
        case .idle:              return "waveform"
        case .learningMemo,
             .learningAsk:       return "questionmark.circle"
        case .recordingMemo,
             .recordingAsk:      return "record.circle.fill"
        case .processingMemo,
             .askThinking,
             .consolidating:     return "waveform.path.ecg"
        case .askSpeaking:       return "bubble.left.fill"
        case .error:             return "exclamationmark.octagon"
        }
    }

    /// One-line label shown as a disabled menu item at the top of the menu.
    var label: String {
        switch self {
        case .notReady(let reason):  return "Not ready — \(reason)"
        case .idle:                  return "Idle"
        case .learningMemo:          return "Press the memo button…"
        case .learningAsk:           return "Press the ask button…"
        case .recordingMemo:         return "Recording memo"
        case .processingMemo:        return "Transcribing memo"
        case .recordingAsk:          return "Recording question"
        case .askThinking:           return "Asking DeepSeek…"
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
