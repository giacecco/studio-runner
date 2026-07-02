import Foundation

// en_US_POSIX is the only locale with a stability guarantee (fixed Gregorian
// 24-hour rendering, immune to the user's 12/24-hour override); the
// previously used "en_GB_POSIX" is not a real locale and resolved to plain
// en_GB. Timestamps stay in local time by design — during the autumn DST
// fall-back hour they can repeat, which asset-filename call sites guard
// against by uniquifying the stem (see UtteranceFlow).
enum Timestamps {
    /// YYMMDDHHMMSS — used for filenames.
    static func compact(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMddHHmmss"
        return f.string(from: date)
    }

    /// YYYY-MM-DD HH:MM:SS — header lines in memo entries and chat.md.
    static func human(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// Parse the compact form back to a Date for human-rendering.
    static func date(fromCompact ts: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMddHHmmss"
        return f.date(from: ts)
    }
}
