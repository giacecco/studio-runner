import Foundation

/// Append-only stream of utterances at `.studiorunner.d/raw.md`. Each entry
/// is a markdown block delimited by `---`, headed by a `## YYYY-MM-DD HH:MM:SS`
/// line and metadata fields the consolidator reads back.
///
/// The first line is a watermark comment:
///
///     <!-- consolidated_through: 2026-06-01 19:30:45 -->
///
/// The consolidator advances the watermark after writing studiorunner.md;
/// `prune` removes entries whose heading timestamp is `<=` the watermark.
struct RawEntry {
    let human: String       // YYYY-MM-DD HH:MM:SS
    let body: String        // full block including `##` and metadata fields
    let dawPosition: String? // DAW timeline position e.g. "2:03", nil if MTC unavailable
    let audioRel: String?
    let screenshotRel: String?
}

struct RawStreamSnapshot {
    let watermark: String   // "none" before any consolidation
    let entries: [RawEntry]

    var unprocessed: [RawEntry] {
        watermark == "none" ? entries : entries.filter { $0.human > watermark }
    }
}

enum RawStream {
    // MARK: - Read

    static func read() throws -> RawStreamSnapshot {
        let content = (try? String(contentsOf: Config.rawFile, encoding: .utf8)) ?? ""
        return parse(content)
    }

    static func parse(_ content: String) -> RawStreamSnapshot {
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

        var entries: [RawEntry] = []
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
        return RawStreamSnapshot(watermark: watermark, entries: entries)
    }

    private static func parseEntry(block: String) -> RawEntry? {
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
        return RawEntry(human: human, body: block,
                        dawPosition: dawPosition, audioRel: audio, screenshotRel: screenshot)
    }

    // MARK: - Append

    struct NewEntry {
        let timestamp: String        // YYMMDDHHMMSS
        let micText: String
        let dawPosition: String?     // DAW timeline position e.g. "2:03", nil if MTC unavailable
        let audioRel: String?
        let screenshotRel: String?
    }

    static func append(_ entry: NewEntry) throws {
        try Layout.ensure()
        let human = humanise(timestamp: entry.timestamp)
        var lines: [String] = ["", "## \(human)"]
        if let pos = entry.dawPosition { lines.append("daw_pos: \(pos)") }
        if let a = entry.audioRel { lines.append("audio: \(a)") }
        if let s = entry.screenshotRel { lines.append("screenshot: \(s)") }
        lines.append("The Producer: \(entry.micText)")
        lines.append("---")
        lines.append("")
        let appendage = lines.joined(separator: "\n")
        if let handle = try? FileHandle(forWritingTo: Config.rawFile) {
            try handle.seekToEnd()
            if let data = appendage.data(using: .utf8) { try handle.write(contentsOf: data) }
            try handle.close()
        } else {
            try appendage.write(to: Config.rawFile, atomically: true, encoding: .utf8)
        }
    }

    /// Returns the post-watermark slice of raw.md, formatted for the ask flow's
    /// prompt context. Empty string if no unconsolidated entries.
    static func unprocessedFormatted() throws -> String {
        let snap = try read()
        let pending = snap.unprocessed
        if pending.isEmpty { return "" }
        return pending.map { "\($0.body)\n---" }.joined(separator: "\n\n")
    }

    // MARK: - Watermark

    static func advanceWatermark(to newWatermark: String) throws {
        let content = (try? String(contentsOf: Config.rawFile, encoding: .utf8)) ?? ""
        var lines = content.components(separatedBy: "\n")
        let header = "<!-- consolidated_through: \(newWatermark) -->"
        if let first = lines.first, first.hasPrefix("<!-- consolidated_through:") {
            lines[0] = header
        } else {
            lines.insert("", at: 0)
            lines.insert(header, at: 0)
        }
        try lines.joined(separator: "\n").write(to: Config.rawFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Prune

    /// Drop entries whose heading timestamp is at or before the current watermark.
    @discardableResult
    static func prune() throws -> Int {
        let content = (try? String(contentsOf: Config.rawFile, encoding: .utf8)) ?? ""
        let snap = parse(content)
        if snap.watermark == "none" { return 0 }
        let kept = snap.entries.filter { $0.human > snap.watermark }
        let dropped = snap.entries.count - kept.count
        let header = "<!-- consolidated_through: \(snap.watermark) -->"
        let body = kept.map { "\($0.body)\n---" }.joined(separator: "\n\n")
        let out = body.isEmpty ? "\(header)\n\n" : "\(header)\n\n\(body)\n"
        try out.write(to: Config.rawFile, atomically: true, encoding: .utf8)
        return dropped
    }

    // MARK: - Timestamp helper

    private static func humanise(timestamp ts: String) -> String {
        guard ts.count == 12,
              let date = Timestamps.date(fromCompact: ts) else { return ts }
        return Timestamps.human(date)
    }
}
