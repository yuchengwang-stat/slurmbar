import Foundation

public enum SlurmTime {
    /// Reads Slurm durations: "M:SS", "H:MM:SS", "D-HH:MM:SS", "D-HH", "D-HH:MM" and plain minutes.
    /// Returns nil for UNLIMITED, N/A and anything else it can't read.
    public static func seconds(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        var days = 0
        var clock = Substring(t)
        let hasDays = t.contains("-")
        if hasDays, let dash = t.firstIndex(of: "-") {
            guard let d = Int(t[..<dash]) else { return nil }
            days = d
            clock = t[t.index(after: dash)...]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let p = parts.map { $0! }
        let secs: Int
        switch (p.count, hasDays) {
        case (3, _): secs = p[0] * 3600 + p[1] * 60 + p[2]
        case (2, true): secs = p[0] * 3600 + p[1] * 60
        case (2, false): secs = p[0] * 60 + p[1]
        case (1, true): secs = p[0] * 3600
        case (1, false): secs = p[0] * 60
        default: return nil
        }
        return days * 86_400 + secs
    }

    /// 45s, 12m, 3h 24m, 2d 4h
    public static func short(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60, h = m / 60, d = h / 24
        if d > 0 { return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h" }
        if h > 0 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return "\(m)m"
    }
}

/// Slurm prints wall-clock times without a zone. `date +%z` on the cluster tells us which one.
public struct SlurmClock: Sendable {
    public let offsetSeconds: Int?

    public init(offset: String) {
        let s = Array(offset.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.count == 5, s[0] == "+" || s[0] == "-",
           let hh = Int(String(s[1...2])), let mm = Int(String(s[3...4])) {
            offsetSeconds = (hh * 3600 + mm * 60) * (s[0] == "-" ? -1 : 1)
        } else {
            offsetSeconds = nil
        }
    }

    public static func isOffset(_ line: String) -> Bool {
        SlurmClock(offset: line).offsetSeconds != nil
    }

    /// "2026-09-25T13:18:49" -> Date. "Unknown", "N/A" and "None" -> nil.
    public func date(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count >= 19 else { return nil }
        func num(_ from: Int, _ to: Int) -> Int? {
            var v = 0
            for i in from..<to {
                guard b[i] >= 48, b[i] <= 57 else { return nil }
                v = v * 10 + Int(b[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
              let h = num(11, 13), let mi = num(14, 16), let s = num(17, 19) else { return nil }
        let local = Self.days(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s
        let offset = offsetSeconds ?? TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(local)))
        return Date(timeIntervalSince1970: TimeInterval(local - offset))
    }

    // days since 1970-01-01, from Howard Hinnant's days_from_civil
    static func days(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
