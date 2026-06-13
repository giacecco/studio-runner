import Foundation

/// Serial, debounced worker that rewrites studiorunner.md from the
/// post-watermark slice of memos.md. Multiple memo presses while a
/// consolidation is in flight collapse to at most one extra pass.
actor Consolidator {
    private var pending = false
    private var running = false
    private let onState: (SessionState) -> Void
    private let onLog: (String) -> Void

    init(
        onState: @escaping (SessionState) -> Void,
        onLog: @escaping (String) -> Void
    ) {
        self.onState = onState
        self.onLog = onLog
    }

    /// Request another consolidation pass. Safe to call from anywhere.
    func schedule() {
        pending = true
        if running { return }
        running = true
        Task { await self.drain() }
    }

    private func drain() async {
        while pending {
            pending = false
            await runOne()
        }
        running = false
    }

    private static let systemPrompt = """
    You maintain a markdown document capturing the live state of a music-production session.
    Always preserve these four sections in this exact order:

    ## TODO
    Checkbox list of action items the producer has mentioned (e.g. "- [ ] tame vocal sibilance bar 32"). Tick items the producer has marked done.

    ## Track notes
    General considerations and decisions about the track (BPM, key, arrangement, mix decisions, sound choices). Free-form prose or short bullets.

    ## Open questions
    Things the producer wondered aloud but hasn't decided. Remove an item once it's been answered or resolved.

    ## Session timeline
    Chronological summary, oldest first, with two levels of granularity:
    - For days BEFORE the latest production day represented in the timeline: exactly ONE bullet per day, format:
      `- YYYY-MM-DD — <prose summary of every meaningful utterance from that day, in a few sentences>`
      When a new production day's utterances arrive, COLLAPSE any per-utterance bullets that were previously written for older days into this one-per-day form. Preserve the meaning; drop minute-level timestamps and DAW positions from the collapsed text.
    - For the latest production day (the day of the most recent utterance): one bullet per meaningful utterance, format:
      `- YYYY-MM-DD HH:MM[ at <daw_pos>][ (audio: <path>)] — <short paraphrase>`
      Include " at <daw_pos>" (e.g. " at 2:58") only when the source entry has a `daw_pos:` value; otherwise omit it entirely.
      Include " (audio: <path>)" only when the source entry has an `audio:` field; use the path verbatim. Omit it for `Studio Runner:` entries (they have no audio clip).
      Date and time come from the entry's `## YYYY-MM-DD HH:MM:SS` header line (truncate to HH:MM).
    Do NOT include screenshot paths in timeline bullets.

    Memo entries are labelled by speaker. `The Producer:` lines are authoritative. `Studio Runner:` lines are your own earlier spoken answers to the producer's questions — use them to recognise what has already been answered (a question that received a satisfactory answer does not belong in Open questions), but never derive TODOs, track notes, or timeline facts from a Studio Runner line alone, and never include a Studio Runner line as a timeline bullet. A producer question that went unanswered, or whose answer said the context was missing, belongs in Open questions. A purely conversational exchange (the producer asking the assistant something and getting an answer) is not a meaningful timeline event unless it records a decision or new fact about the track that has not already been captured.

    When a new entry explicitly corrects a named detail in an earlier timeline bullet (e.g. "corrected a past note: it's X, not Y"), update that earlier bullet in place to use the correct term, and do NOT add a separate correction bullet — the correction itself is not a meaningful production event.

    The producer may also hand-edit Session timeline bullets directly. If you find a bullet that lacks both a `YYYY-MM-DD` prefix and an existing `(before HH:MM)` marker, prepend `(before HH:MM)` using the consolidation time provided in the user message — i.e. format the bullet as `- (before HH:MM) — <producer text verbatim>`. This records that you noticed the entry by that time but can't pin down exactly when it was written. Keep the producer's wording and the bullet's position in the list. Once a bullet carries `(before HH:MM)`, leave that marker untouched on subsequent passes.

    Keep prior content unless the new utterances explicitly supersede it. Do NOT include a `## Work time` section — it is managed programmatically and appended after your output. Output ONLY the full updated markdown document — no preamble, no explanation, no code fence.
    """

    private func runOne() async {
        let snap: MemoStreamSnapshot
        do {
            snap = try MemoStream.read()
        } catch {
            onLog("consolidate: read failed — \(error)")
            return
        }
        let unprocessed = snap.unprocessed
        if unprocessed.isEmpty { return }

        onState(.consolidating)
        defer { onState(.idle) }

        let state = (try? String(contentsOf: Config.notesFile, encoding: .utf8)) ?? ""
        let memos = unprocessed.map { "\($0.body)\n---" }.joined(separator: "\n\n")
        let user = """
        === Consolidation time ===
        \(Timestamps.human())

        === Current state ===
        \(state.isEmpty ? "(empty — first consolidation)" : state)

        === New memo entries ===
        \(memos)

        Output the updated document.
        """

        let updated: String
        do {
            updated = try await AIClient.call(systemPrompt: Self.systemPrompt, userPrompt: user)
        } catch {
            onLog("consolidate: AI call failed — \(error)")
            return
        }

        let toWrite = updated.hasSuffix("\n") ? updated : updated + "\n"
        do {
            try toWrite.write(to: Config.notesFile, atomically: true, encoding: .utf8)
            // Max, not file-order last: concurrent transcriptions can land in
            // memos.md out of chronological order, and a watermark older than
            // an already-consolidated entry would re-include it next pass.
            let newWatermark = unprocessed.map(\.human).max()!
            try MemoStream.advanceWatermark(to: newWatermark)
        } catch {
            onLog("consolidate: write failed — \(error)")
            return
        }

        // Re-inject the work time section the AI was told to omit.
        let workLog = WorkTimeLog.load(from: Config.workTimeFile)
        if workLog.totalSeconds > 0,
           let current = try? String(contentsOf: Config.notesFile, encoding: .utf8) {
            let reinjected = WorkTimeLog.inject(into: current, log: workLog)
            try? reinjected.write(to: Config.notesFile, atomically: true, encoding: .utf8)
        }

        onLog("consolidated \(unprocessed.count) entr\(unprocessed.count == 1 ? "y" : "ies")")
    }
}
