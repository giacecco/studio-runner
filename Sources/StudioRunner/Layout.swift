import Foundation

/// Creates the project-root layout the bun script established:
///
///     <projectRoot>/studiorunner.md            ← consolidated state
///     <projectRoot>/.studiorunner.d/
///       system.md                              ← per-project context for the AI
///       memos.md                               ← append-only memo stream (with watermark)
///       chat.md                                ← Q&A transcript (created on first ask)
///       screenshots/<ts>.png                   ← screenshot per memo
///       audio/<ts>.wav                         ← DAW clip per memo
enum Layout {
    static func ensure() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Config.runnerDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Config.screenshotsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Config.audioDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: Config.notesFile.path) {
            let scaffold = "# Studio Runner\n\n## TODO\n\n## Track notes\n\n## Open questions\n\n## Session timeline\n"
            try scaffold.write(to: Config.notesFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Config.memosFile.path) {
            try "<!-- consolidated_through: none -->\n\n".write(to: Config.memosFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Config.systemFile.path) {
            let stub = """
            # Project context

            Edit this file with general context about this music project. Its
            contents are prepended to every AI system prompt — both
            consolidation and Q&A — so the assistant gets your context on every
            call without you having to repeat it.

            Useful to record:
            - Track name, BPM, key signature, time signature
            - Genre, sonic references, mood
            - Production constraints (e.g. "no autotune", "vocals tracked at Studio X")
            - Collaborators (artist, engineer, label)
            - Deadlines and milestones
            - Strong preferences worth holding the line on

            When answering questions, look for and read any .md and .txt files
            in the project folder — they may contain relevant notes, lyrics,
            chord sheets, or references the producer has left there.

            Delete this guidance block once you've added your own.
            """
            try stub.write(to: Config.systemFile, atomically: true, encoding: .utf8)
        }
    }
}
