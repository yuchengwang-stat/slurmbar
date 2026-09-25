import Foundation

/// Made-up cluster output in the real formats. Demo mode, screenshots and slurmbar-check all use it.
public enum Fixtures {
    static let offset = -4 * 3600

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: offset)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: d)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public static func jobs(now: Date = Date()) -> String {
        let ago = { (s: Double) in stamp(now.addingTimeInterval(-s)) }
        var lines = ["-0400", "@@SQUEUE",
            "51230001|fit_model|RUNNING|13:24:40|16:00:00|1|32|RM-shared|None|\(ago(48_400))|\(ago(48_280))",
            "51234567_3|sim_grid|RUNNING|2:52:45|16:00:00|1|2|RM-shared|None|\(ago(10_400))|\(ago(10_365))",
            "51234567_9|sim_grid|RUNNING|2:52:45|16:00:00|1|2|RM-shared|None|\(ago(10_400))|\(ago(10_365))",
            "51234567_[10-24%4]|sim_grid|PENDING|0:00|16:00:00|1|2|RM-shared|JobArrayTaskLimit|\(ago(10_400))|N/A",
            "51240002|bootstrap_ci|PENDING|0:00|4:00:00|1|16|RM-shared|Priority|\(ago(900))|\(stamp(now.addingTimeInterval(9_300)))",
            "51241000|preprocess|RUNNING|0:39|1:00:00|1|4|RM-shared|None|\(ago(45))|\(ago(39))",
            "@@SACCT",
        ]
        for i in 1...46 {
            lines.append("51220000_\(i)|fc_post|COMPLETED|00:00:0\(i % 7 + 3)|00:30:00|\(ago(720 + Double(i % 5)))|0:0|RM-shared|2")
        }
        lines += [
            "51221111|preprocess|COMPLETED|00:41:08|01:00:00|\(ago(1_250))|0:0|RM-shared|4",
            "51221112|preprocess|COMPLETED|00:38:51|01:00:00|\(ago(2_400))|0:0|RM-shared|4",
            "51221113|preprocess|COMPLETED|00:40:02|01:00:00|\(ago(3_100))|0:0|RM-shared|4",
            "51226666|qc_report|FAILED|00:00:12|00:30:00|\(ago(3_900))|1:0|RM-shared|2",
            "51225555|train_gpu|TIMEOUT|08:00:12|08:00:00|\(ago(18_500))|0:15|GPU-shared|5",
            "51219999|old_run|CANCELLED by 70001|00:03:10|02:00:00|\(ago(30_000))|0:0|RM-shared|4",
            "51230001|fit_model|RUNNING|13:24:40|16:00:00|Unknown|0:0|RM-shared|32",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    public static let demoRemaining = 185_400.0
    public static let demoBurnPerDay = 7_400.0

    public static func projects(now: Date = Date()) -> String {
        let end = day(now.addingTimeInterval(29 * 86_400))
        return """
        {"ABC123P": {"chargeId": "abc123p", "default": true, "grantNumber": "ABC123P",
          "title": "Example project", "pi": "A. Researcher",
          "allocations": [
            {"allocationActive": true, "endDate": "\(end)", "resourceName": "B2-REGULAR",
             "resourceDisplayName": "Bridges 2 Regular Memory", "resourceType": "MULTI",
             "suAllocated": 500000.0, "suRemaining": \(demoRemaining), "userActive": true},
            {"allocationActive": true, "endDate": "\(end)", "resourceName": "B2-OCEAN",
             "resourceDisplayName": "Bridges 2 Ocean Storage", "resourceType": "STORAGE",
             "suAllocated": 52422.0, "suRemaining": 18661.2, "userActive": true, "path": "/ocean/projects/abc123p"}
          ]}}
        """
    }

    /// A week of balances falling at demoBurnPerDay.
    public static func history(now: Date = Date()) -> [UsageSample] {
        (0...14).reversed().map { k in
            let days = Double(k) / 2
            return UsageSample(t: now.addingTimeInterval(-days * 86_400), remaining: demoRemaining + days * demoBurnPerDay)
        }
    }

    public static let quotas = """
    The quota for Home directory /jet/home/demo
    Storage quota: 25.00GiB
     Storage used: 17.35GiB
      Inode quota: 0
      Inodes used: 303,361

    The quota for Project directory /ocean/projects/abc123p
    Storage quota: 51.19TiB
     Storage used: 32.97TiB
      Inode quota: 318,201,540
      Inodes used: 1,571,712
    """

    public static let partitions = (["RM-shared|up|43153/4847/2688/50688", "@@WAITING"]
        + Array(repeating: "RM-shared", count: 1204)).joined(separator: "\n")

    public static let commandOutput = """
    epoch 37/50   train loss 0.2143   val loss 0.2610
    about 1h 52m to go
    """

    public static var demoConfig: AppConfig {
        AppConfig(notifications: false, clusters: [
            ClusterConfig(name: "bridges2", host: "bridges2.psc.edu", user: "demo", widgets: [
                WidgetSpec(type: "jobs"),
                WidgetSpec(type: "allocation"),
                WidgetSpec(type: "quota"),
                WidgetSpec(type: "partition", options: ["partitions": "RM-shared"]),
                WidgetSpec(type: "command", title: "fit_model progress", command: "tail -n 2 ~/runs/fit_model/progress.log"),
            ]),
        ])
    }
}

/// Answers every command from the fixtures.
public struct DemoRunner: CommandRunner {
    public init() {}

    public func run(_ command: String) async throws -> String {
        try? await Task.sleep(for: .milliseconds(120))
        if command.contains("@@SQUEUE") || command.contains("@@SACCT") { return Fixtures.jobs() }
        if command.contains("projects") { return Fixtures.projects() }
        if command.contains("my_quotas") { return Fixtures.quotas }
        if command.contains("sinfo") { return Fixtures.partitions }
        return Fixtures.commandOutput
    }

    public func isConnected() async -> Bool { true }
}
