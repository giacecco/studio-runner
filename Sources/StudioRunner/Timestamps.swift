import Foundation

enum Timestamps {
    /// YYMMDDHHMMSS — used for filenames.
    static func compact(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyMMddHHmmss"
        return f.string(from: date)
    }

    /// YYYY-MM-DD HH:MM:SS — header lines in raw entries and chat.md.
    static func human(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// Parse the compact form back to a Date for human-rendering.
    static func date(fromCompact ts: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyMMddHHmmss"
        return f.date(from: ts)
    }
}
