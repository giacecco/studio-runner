import Foundation

enum Timestamps {
    /// YYMMDDHHMMSS — used for filenames and the `ts:` field in raw entries.
    static func compact(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyMMddHHmmss"
        return f.string(from: date)
    }

    /// YY-MM-DD HH:MM:SS — header line in raw entries.
    static func human(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yy-MM-dd HH:mm:ss"
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
