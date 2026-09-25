import Foundation

/// One project from PSC's `projects --format json`.
public struct PSCProject: Decodable, Sendable, Identifiable {
    public var chargeId: String?
    public var grantNumber: String?
    public var title: String?
    public var pi: String?
    public var isDefault: Bool?
    public var allocations: [PSCAllocation]

    public var id: String { chargeId ?? grantNumber ?? title ?? "project" }

    enum CodingKeys: String, CodingKey {
        case chargeId, grantNumber, title, pi, allocations
        case isDefault = "default"
    }
}

public struct PSCAllocation: Decodable, Sendable, Identifiable {
    public var allocationActive: Bool?
    public var endDate: String?
    public var resourceName: String?
    public var resourceDisplayName: String?
    public var resourceType: String?
    public var suAllocated: Double?
    public var suRemaining: Double?
    public var userActive: Bool?
    public var path: String?

    public var id: String { resourceName ?? resourceDisplayName ?? "allocation" }
    public var isStorage: Bool { resourceType?.uppercased() == "STORAGE" }

    public var usedFraction: Double? {
        guard let a = suAllocated, let r = suRemaining, a > 0 else { return nil }
        return max(0, min(1, (a - r) / a))
    }

    /// endDate is a plain day; count it as the end of that day, local time.
    public var end: Date? {
        guard let s = endDate, s.count >= 10 else { return nil }
        return SlurmClock(offset: "").date(String(s.prefix(10)) + "T23:59:59")
    }
}

public enum PSC {
    public static let projectsCommand = "projects --format json"

    public static func projects(_ output: String) throws -> [PSCProject] {
        guard let start = output.firstIndex(of: "{") else { throw ParseError("`projects` printed no JSON") }
        let all = try JSONDecoder().decode([String: PSCProject].self, from: Data(output[start...].utf8))
        return all.values.sorted { a, b in
            if (a.isDefault ?? false) != (b.isDefault ?? false) { return a.isDefault ?? false }
            return a.id < b.id
        }
    }
}

public struct ParseError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct UsageSample: Codable, Sendable {
    public var t: Date
    public var remaining: Double

    public init(t: Date, remaining: Double) {
        self.t = t
        self.remaining = remaining
    }
}

/// Balances seen over time, so SlurmBar can say how fast an allocation is going.
public struct UsageHistory: Codable, Sendable {
    public var series: [String: [UsageSample]] = [:]

    public init() {}

    public mutating func record(_ key: String, remaining: Double, at t: Date = Date()) {
        var s = series[key] ?? []
        if let last = s.last {
            if remaining > last.remaining + 1 {
                s = []  // topped up or renewed, so the old trend no longer applies
            } else if t.timeIntervalSince(last.t) < 1800 {
                return  // one sample per half hour is plenty
            }
        }
        s.append(UsageSample(t: t, remaining: remaining))
        s.removeAll { t.timeIntervalSince($0.t) > 30 * 86_400 }
        series[key] = s
    }

    /// Units used per day over the last week, or nil until there is at least half a day of history.
    public func perDay(_ key: String, window: TimeInterval = 7 * 86_400, minSpan: TimeInterval = 12 * 3600) -> Double? {
        guard let s = series[key], let latest = s.last,
              let first = s.first(where: { latest.t.timeIntervalSince($0.t) <= window }) else { return nil }
        let span = latest.t.timeIntervalSince(first.t)
        guard span >= minSpan else { return nil }
        let rate = (first.remaining - latest.remaining) / (span / 86_400)
        return rate > 0 ? rate : nil
    }
}
