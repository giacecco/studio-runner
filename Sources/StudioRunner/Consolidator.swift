import Foundation

/// Serial, debounced worker that rewrites studiorunner.md from the
/// post-watermark slice of raw.md. Multiple memo presses while a
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
    Condensed chronological summary, one bullet per meaningful utterance, oldest first. Format each bullet as:
    - <position> — short paraphrase ([audio](<audio path>) · [screenshot](<screenshot path>), YY-MM-DD HH:MM)
    where <position> is the entry's daw_pos value if present (e.g. "2:03"), otherwise HH:MM from the ## header.
    The date in parentheses is always YY-MM-DD HH:MM taken from the ## header line.
    Paths come verbatim from the entry's "audio:" and "screenshot:" fields. Omit asset links if neither is present.

    Keep prior content unless the new utterances explicitly supersede it. Output ONLY the full updated markdown document — no preamble, no explanation, no code fence.
    """

    private func runOne() async {
        let snap: RawStreamSnapshot
        do {
            snap = try RawStream.read()
        } catch {
            onLog("consolidate: read failed — \(error)")
            return
        }
        let unprocessed = snap.unprocessed
        if unprocessed.isEmpty { return }

        onState(.consolidating)
        defer { onState(.idle) }

        let state = (try? String(contentsOf: Config.notesFile, encoding: .utf8)) ?? ""
        let raw = unprocessed.map { "\($0.body)\n---" }.joined(separator: "\n\n")
        let user = """
        === Current state ===
        \(state.isEmpty ? "(empty — first consolidation)" : state)

        === New raw utterances ===
        \(raw)

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
            let newWatermark = unprocessed.last!.ts
            try RawStream.advanceWatermark(to: newWatermark)
        } catch {
            onLog("consolidate: write failed — \(error)")
            return
        }

        onLog("consolidated \(unprocessed.count) entr\(unprocessed.count == 1 ? "y" : "ies")")
    }
}
