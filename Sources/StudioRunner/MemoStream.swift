import Foundation

/// Append-only stream of utterances at `.studiorunner.d/memos.md`. Each entry
/// is a markdown block delimited by `---`, headed by a `## YYYY-MM-DD HH:MM:SS`
/// line and metadata fields the consolidator reads back.
///
/// The first line is a watermark comment:
///
///     <!-- consolidated_through: 2026-06-01 19:30:45 -->
///
/// The consolidator advances the watermark after writing studiorunner.md;
/// `prune` removes entries whose heading timestamp is `<=` the watermark.
struct MemoEntry {
    let human: String       // YYYY-MM-DD HH:MM:SS
    let body: String        // full block including `##` and metadata fields
    let dawPosition: String? // DAW timeline position e.g. "2:03", nil if MTC unavailable
    let audioRel: String?
    let screenshotRel: String?
}

struct MemoStreamSnapshot {
    let watermark: String   // "none" before any consolidation
    let entries: [MemoEntry]

    var unprocessed: [MemoEntry] {
        watermark == "none" ? entries : entries.filter { $0.human > watermark }
    }
}

enum MemoStream {
    // MARK: - Read

    static func read() throws -> MemoStreamSnapshot {
        let content = (try? String(contentsOf: Config.memosFile, encoding: .utf8)) ?? ""
        return parse(content)
    }

    static func parse(_ content: String) -> MemoStreamSnapshot {
        let lines = content.components(separatedBy: "\n")
        var watermark = "none"
        var start = 0
        if let first = lines.first, first.hasPrefix("<!-- consolidated_through:") {
            if let prefix = first.range(of: "consolidated_through:"),
               let suffix = first.range(of: "-->") {
                let inner = first[prefix.upperBound..<suffix.lowerBound]
                let token = inner.trimmingCharacters(in: .whitespaces)
                if !token.isEmpty { watermark = token }
            }
            start = 1
        }

        var entries: [MemoEntry] = []
        var buf: [String] = []
        for i in start..<lines.count {
            let ln = lines[i]
            if ln == "---" {
                if !buf.isEmpty {
                    let block = buf.joined(separator: "\n")
                    if let entry = parseEntry(block: block) {
                        entries.append(entry)
                    }
                }
                buf.removeAll(keepingCapacity: true)
            } else {
                buf.append(ln)
            }
        }
        return MemoStreamSnapshot(watermark: watermark, entries: entries)
    }

    private static func parseEntry(block: String) -> MemoEntry? {
        var human: String?
        var dawPosition: String?
        var audio: String?
        var screenshot: String?
        for line in block.components(separatedBy: "\n") {
            if human == nil, line.hasPrefix("## ") {
                human = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            if dawPosition == nil, line.hasPrefix("daw_pos:") {
                dawPosition = line.dropFirst("daw_pos:".count).trimmingCharacters(in: .whitespaces)
            }
            if audio == nil, line.hasPrefix("audio:") {
                audio = line.dropFirst("audio:".count).trimmingCharacters(in: .whitespaces)
            }
            if screenshot == nil, line.hasPrefix("screenshot:") {
                screenshot = line.dropFirst("screenshot:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let human = human else { return nil }
        return MemoEntry(human: human, body: block,
                         dawPosition: dawPosition, audioRel: audio, screenshotRel: screenshot)
    }

    // MARK: - Append

    struct NewEntry {
        let timestamp: String        // YYMMDDHHMMSS
        let speaker: String          // "The Producer", or "Studio Runner" for assistant answers
        let text: String
        let dawPosition: String?     // DAW timeline position e.g. "2:03", nil if MTC unavailable
        let audioRel: String?
        let screenshotRel: String?
    }

    /// Serialises all mutations of memos.md. `append` (FileHandle append,
    /// utterance actor) races the read–modify–atomic-rewrite in
    /// `advanceWatermark` / `prune` (consolidator actor): an append landing
    /// inside the read→write window is silently discarded when the rewrite
    /// replaces the file.
    private static let fileLock = NSLock()

    static func append(_ entry: NewEntry) throws {
        fileLock.lock()
        defer { fileLock.unlock() }
        try Layout.ensure()
        let human = humanise(timestamp: entry.timestamp)
        var lines: [String] = ["", "## \(human)"]
        if let pos = entry.dawPosition { lines.append("daw_pos: \(pos)") }
        if let a = entry.audioRel { lines.append("audio: \(a)") }
        if let s = entry.screenshotRel { lines.append("screenshot: \(s)") }
        lines.append("\(entry.speaker): \(entry.text)")
        lines.append("---")
        lines.append("")
        let appendage = lines.joined(separator: "\n")
        if let handle = try? FileHandle(forWritingTo: Config.memosFile) {
            try handle.seekToEnd()
            if let data = appendage.data(using: .utf8) { try handle.write(contentsOf: data) }
            try handle.close()
        } else {
            try appendage.write(to: Config.memosFile, atomically: true, encoding: .utf8)
        }
    }

    /// Returns the post-watermark slice of memos.md, formatted for the ask flow's
    /// prompt context. Empty string if no unconsolidated entries.
    static func unprocessedFormatted() throws -> String {
        let snap = try read()
        let pending = snap.unprocessed
        if pending.isEmpty { return "" }
        return pending.map { "\($0.body)\n---" }.joined(separator: "\n\n")
    }

    // MARK: - Watermark

    /// Advance the watermark to the largest timestamp W such that every entry
    /// after the old watermark with timestamp ≤ W was part of this
    /// consolidation pass. Timestamps are press-start based with one-second
    /// resolution, so an entry appended *during* the pass can carry a
    /// timestamp at or before the pass's maximum — a plain max() watermark
    /// would mark it consolidated (and prune it) without it ever being
    /// processed. Stopping below the first uncovered entry leaves it for the
    /// next pass; the covered entries beyond it may be re-fed once, which
    /// the consolidation prompt merges idempotently.
    static func advanceWatermark(covering consolidated: [String]) throws {
        fileLock.lock()
        defer { fileLock.unlock() }
        let content = (try? String(contentsOf: Config.memosFile, encoding: .utf8)) ?? ""
        let snap = parse(content)
        let consolidatedSet = Set(consolidated)
        let pending = (snap.watermark == "none"
            ? snap.entries
            : snap.entries.filter { $0.human > snap.watermark })
            .sorted { $0.human < $1.human }
        var newWatermark: String?
        for entry in pending {
            guard consolidatedSet.contains(entry.human) else { break }
            newWatermark = entry.human
        }
        guard let target = newWatermark else { return }

        var lines = content.components(separatedBy: "\n")
        let header = "<!-- consolidated_through: \(target) -->"
        if let first = lines.first, first.hasPrefix("<!-- consolidated_through:") {
            lines[0] = header
        } else {
            lines.insert("", at: 0)
            lines.insert(header, at: 0)
        }
        try lines.joined(separator: "\n").write(to: Config.memosFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Prune

    /// Drop entries whose heading timestamp is at or before the current watermark.
    @discardableResult
    static func prune() throws -> Int {
        fileLock.lock()
        defer { fileLock.unlock() }
        let content = (try? String(contentsOf: Config.memosFile, encoding: .utf8)) ?? ""
        let snap = parse(content)
        if snap.watermark == "none" { return 0 }
        let kept = snap.entries.filter { $0.human > snap.watermark }
        let dropped = snap.entries.count - kept.count
        let header = "<!-- consolidated_through: \(snap.watermark) -->"
        let body = kept.map { "\($0.body)\n---" }.joined(separator: "\n\n")
        let out = body.isEmpty ? "\(header)\n\n" : "\(header)\n\n\(body)\n"
        try out.write(to: Config.memosFile, atomically: true, encoding: .utf8)
        return dropped
    }

    // MARK: - Timestamp helper

    private static func humanise(timestamp ts: String) -> String {
        guard ts.count == 12,
              let date = Timestamps.date(fromCompact: ts) else { return ts }
        return Timestamps.human(date)
    }
}
