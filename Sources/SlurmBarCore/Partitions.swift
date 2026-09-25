import Foundation

public struct PartitionLoad: Sendable, Identifiable {
    public var name: String
    public var isUp: Bool
    public var allocated: Int
    public var idle: Int
    public var other: Int
    public var total: Int
    public var waiting: Int = 0

    public var id: String { name }

    /// Allocated CPUs over the CPUs that can take work (drained and down nodes excluded).
    public var busy: Double {
        let usable = total - other
        return usable > 0 ? Double(allocated) / Double(usable) : 0
    }
}

public enum Partitions {
    /// Partition names go into a shell command, so keep only plain characters.
    public static func clean(_ names: [String]) -> [String] {
        names.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }
    }

    /// CPU counts per partition, then one line per waiting job naming its partition(s).
    public static func command(_ names: [String]) -> String {
        let list = clean(names).joined(separator: ",")
        let p = list.isEmpty ? "" : " -p \(list)"
        return "sinfo -h\(p) -o '%P|%a|%C'; echo @@WAITING; squeue -h -t PENDING\(p) -o '%P'"
    }

    public static func parse(_ out: String) -> [PartitionLoad] {
        var loads: [PartitionLoad] = []
        var waiting: [String: Int] = [:]
        var inWaiting = false
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "@@WAITING" {
                inWaiting = true
                continue
            }
            if inWaiting {
                for p in line.split(separator: ",") { waiting[String(p), default: 0] += 1 }
                continue
            }
            let f = line.split(separator: "|").map(String.init)
            guard f.count >= 3 else { continue }
            let cpus = f[2].split(separator: "/").compactMap { Int($0) }
            guard cpus.count == 4 else { continue }
            let name = f[0].hasSuffix("*") ? String(f[0].dropLast()) : f[0]
            if let i = loads.firstIndex(where: { $0.name == name }) {
                loads[i].allocated += cpus[0]
                loads[i].idle += cpus[1]
                loads[i].other += cpus[2]
                loads[i].total += cpus[3]
            } else {
                loads.append(PartitionLoad(name: name, isUp: f[1] == "up", allocated: cpus[0], idle: cpus[1],
                                           other: cpus[2], total: cpus[3]))
            }
        }
        for i in loads.indices { loads[i].waiting = waiting[loads[i].name] ?? 0 }
        return loads
    }
}
