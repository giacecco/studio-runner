import Foundation

/// FIFO chain of async operations: each enqueued operation starts only after
/// the previous one has finished, no matter which thread enqueues or where
/// the operation suspends. Unlike an actor, exclusivity is held across
/// awaits, so a read–modify–write that spans a network call cannot interleave
/// with another writer.
///
/// Used for:
///  - `Coordinator.notesFileQueue` — studiorunner.md has three writers (the
///    consolidator, the work-time injector, the clear-session timeline
///    collapse), two of which hold a file snapshot across an AI call.
///  - `Coordinator`'s gate-event queue — MIDI press/release handling runs on
///    the main actor in arrival order, so a quick session tap can never
///    execute its stop before its start.
enum NotesFile {
    /// The single gate every studiorunner.md transaction must pass through.
    static let queue = SerialTaskQueue()
}

final class SerialTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Fire-and-forget: schedules `operation` after everything already queued.
    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        _ = makeTask(operation)
    }

    /// Schedules `operation` and waits for it (and everything before it).
    func enqueueAndWait(_ operation: @escaping @Sendable () async -> Void) async {
        await makeTask(operation).value
    }

    private func makeTask(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}
