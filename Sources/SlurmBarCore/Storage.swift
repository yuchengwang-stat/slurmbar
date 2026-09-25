import Foundation

public struct DiskQuota: Sendable, Identifiable {
    public var label: String
    public var path: String
    public var usedBytes: Double
    public var quotaBytes: Double
    public var filesUsed: Int?
    public var filesQuota: Int?

    public var id: String { path }
    public var fraction: Double? { quotaBytes > 0 ? min(1, usedBytes / quotaBytes) : nil }
}

public enum Storage {
    public static let quotaCommand = "my_quotas"

    /// Reads PSC's `my_quotas`, which prints blocks like
    ///
    ///     The quota for Home directory /jet/home/me
    ///     Storage quota: 25.00GiB
    ///      Storage used: 17.35GiB
    public static func parseMyQuotas(_ text: String) -> [DiskQuota] {
        var out: [DiskQuota] = []
        var cur: DiskQuota?
        func flush() {
            if let c = cur, c.quotaBytes > 0 || c.usedBytes > 0 { out.append(c) }
            cur = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("The quota for ") {
                flush()
                let rest = line.dropFirst("The quota for ".count)
                if let slash = rest.firstIndex(of: "/") {
                    cur = DiskQuota(label: rest[..<slash].trimmingCharacters(in: .whitespaces),
                                    path: String(rest[slash...]).trimmingCharacters(in: .whitespaces),
                                    usedBytes: 0, quotaBytes: 0)
                }
                continue
            }
            guard cur != nil, let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch line[..<colon].lowercased() {
            case "storage quota": cur!.quotaBytes = bytes(value) ?? 0
            case "storage used": cur!.usedBytes = bytes(value) ?? 0
            case "inode quota": cur!.filesQuota = Int(value.replacingOccurrences(of: ",", with: ""))
            case "inodes used": cur!.filesUsed = Int(value.replacingOccurrences(of: ",", with: ""))
            default: break
            }
        }
        flush()
        return out
    }

    /// "25.00GiB", "51.19 TiB", "512MB" -> bytes
    public static func bytes(_ text: String) -> Double? {
        let s = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard let split = s.firstIndex(where: { $0.isLetter }) else { return Double(s) }
        guard let v = Double(s[..<split]) else { return nil }
        let units: [String: Double] = [
            "B": 1, "KIB": 0x1p10, "MIB": 0x1p20, "GIB": 0x1p30, "TIB": 0x1p40, "PIB": 0x1p50,
            "K": 0x1p10, "M": 0x1p20, "G": 0x1p30, "T": 0x1p40, "P": 0x1p50,
            "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
        ]
        return units[s[split...].uppercased()].map { v * $0 }
    }

    /// Binary units, since that is what quota tools report: "17.4 GiB"
    public static func format(_ bytes: Double) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var v = bytes
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(v)) B" }
        return (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)) + " " + units[i]
    }
}
