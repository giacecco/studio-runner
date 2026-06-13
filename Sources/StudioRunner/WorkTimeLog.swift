import Foundation

struct SessionRecord: Codable {
    let startEpoch: Int
    let endEpoch: Int
    var sessionType: String?

    var duration: Int { endEpoch - startEpoch }
    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startEpoch)) }
    var endDate: Date   { Date(timeIntervalSince1970: TimeInterval(endEpoch)) }
}

/// Accumulates individual session records (start + end timestamp) for the
/// session-arm button. Persisted to `work_time.json` in `.studiorunner.d/`.
struct WorkTimeLog: Codable {
    var sessions: [SessionRecord] = []

    var totalSeconds: Int { sessions.reduce(0) { $0 + $1.duration } }

    /// Reclassifies all trailing unclassified sessions (walking backwards
    /// until a classified session is hit) to `type`. Call this when the
    /// producer says "continuing <type>", meaning the current work mode
    /// was already underway before they named it.
    mutating func reclassifyAdjacentUnclassified(as type: String) {
        var i = sessions.endIndex
        while i > sessions.startIndex {
            sessions.formIndex(before: &i)
            if sessions[i].sessionType == nil {
                sessions[i].sessionType = type
            } else {
                break
            }
        }
    }

    mutating func add(start: Date, end: Date, sessionType: String? = nil) {
        let d = Int(end.timeIntervalSince(start))
        guard d > 0 else { return }
        sessions.append(SessionRecord(
            startEpoch: Int(start.timeIntervalSince1970),
            endEpoch:   Int(end.timeIntervalSince1970),
            sessionType: sessionType
        ))
    }

    func todaySeconds(on date: Date = Date()) -> Int {
        let key = dayKey(date)
        return sessions
            .filter { dayKey($0.startDate) == key }
            .reduce(0) { $0 + $1.duration }
    }

    private func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d%02d%02d", (c.year ?? 0) % 100, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Persistence

    static func load(from url: URL) -> WorkTimeLog {
        guard let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(WorkTimeLog.self, from: data) else {
            return WorkTimeLog()
        }
        return log
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - studiorunner.md section

    static let sectionHeading = "## Work time"

    static func formatDuration(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let knownTypes = ["production", "mixing", "mastering"]

    /// Markdown block for the `## Work time` section.
    /// Sessions are listed newest-first; each line shows date, start–end, duration, and type.
    func formattedSection() -> String {
        var lines = [Self.sectionHeading, ""]
        for rec in sessions.sorted(by: { $0.startEpoch > $1.startEpoch }) {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: rec.startDate)
            let yy = String(format: "%02d", (c.year ?? 0) % 100)
            let mm = String(format: "%02d", c.month ?? 0)
            let dd = String(format: "%02d", c.day ?? 0)
            let start    = Self.timeFormatter.string(from: rec.startDate)
            let end      = Self.timeFormatter.string(from: rec.endDate)
            let duration = Self.formatDuration(rec.duration)
            let typeSuffix = rec.sessionType.map { ", \($0)" } ?? ""
            lines.append("- \(yy)-\(mm)-\(dd), \(start) — \(end) · \(duration)\(typeSuffix)")
        }
        if !sessions.isEmpty {
            lines.append("")
            // Per-type breakdown
            var byType: [String: Int] = [:]
            var unclassified = 0
            for rec in sessions {
                if let t = rec.sessionType, Self.knownTypes.contains(t) {
                    byType[t, default: 0] += rec.duration
                } else {
                    unclassified += rec.duration
                }
            }
            let total = totalSeconds
            for t in Self.knownTypes where (byType[t] ?? 0) > 0 {
                let secs = byType[t]!
                let pct  = secs * 100 / total
                lines.append("\(t.capitalized): \(Self.formatDuration(secs)) (\(pct)%)")
            }
            if unclassified > 0 {
                let pct = unclassified * 100 / total
                lines.append("Unclassified: \(Self.formatDuration(unclassified)) (\(pct)%)")
            }
            let h = total / 3600
            let m = (total % 3600) / 60
            let totalStr = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            lines.append("Total: \(totalStr)")
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces the existing `## Work time` section in `notes`, or appends it.
    static func inject(into notes: String, log: WorkTimeLog) -> String {
        guard log.totalSeconds > 0 else { return notes }
        let section = log.formattedSection()
        var lines = notes.components(separatedBy: "\n")

        if let headingIdx = lines.firstIndex(where: { $0 == sectionHeading }) {
            let afterHeading = headingIdx + 1
            let nextSection  = lines[afterHeading...].firstIndex(where: { $0.hasPrefix("## ") })
            let endIdx       = nextSection ?? lines.endIndex
            lines.replaceSubrange(headingIdx..<endIdx, with: section.components(separatedBy: "\n"))
        } else {
            while lines.last == "" { lines.removeLast() }
            lines += ["", ""] + section.components(separatedBy: "\n")
        }

        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}
