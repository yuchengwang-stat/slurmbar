import Foundation

public struct SlurmJob: Hashable, Sendable {
    public var id: String
    public var name: String
    public var state: String
    public var elapsed: Int?
    public var limit: Int?
    public var cpus: Int?
    public var partition: String
    public var reason: String?
    public var submit: Date?
    public var start: Date?
    public var end: Date?
    public var exitCode: String?

    public init(id: String, name: String, state: String, elapsed: Int? = nil, limit: Int? = nil,
                cpus: Int? = nil, partition: String = "", reason: String? = nil, submit: Date? = nil,
                start: Date? = nil, end: Date? = nil, exitCode: String? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.elapsed = elapsed
        self.limit = limit
        self.cpus = cpus
        self.partition = partition
        self.reason = reason
        self.submit = submit
        self.start = start
        self.end = end
        self.exitCode = exitCode
    }

    /// "123_4" and "123_[5-9]" both belong to array 123.
    public var arrayID: String? {
        guard let u = id.firstIndex(of: "_") else { return nil }
        return String(id[..<u])
    }

    /// A waiting array prints once as "123_[5-9%2]", so one line can stand for many tasks.
    public var taskCount: Int {
        guard let open = id.firstIndex(of: "["), let close = id.lastIndex(of: "]"), open < close else { return 1 }
        var spec = id[id.index(after: open)..<close]
        if let pct = spec.firstIndex(of: "%") { spec = spec[..<pct] }
        var n = 0
        for part in spec.split(separator: ",") {
            let pieces = part.split(separator: ":")
            let step = pieces.count > 1 ? max(Int(pieces[1]) ?? 1, 1) : 1
            let bounds = pieces[0].split(separator: "-").compactMap { Int($0) }
            n += bounds.count == 2 ? (bounds[1] - bounds[0]) / step + 1 : 1
        }
        return max(n, 1)
    }

    public var isRunning: Bool { JobState.running.contains(state) }
    public var isPending: Bool { JobState.waiting.contains(state) }
    public var isFinished: Bool { JobState.finished.contains(state) }
    public var isProblem: Bool { JobState.problems.contains(state) }

    /// Share of the time limit used so far.
    public var fraction: Double? {
        guard let e = elapsed, let l = limit, l > 0 else { return nil }
        return min(1, Double(e) / Double(l))
    }
}

public enum JobState {
    public static let running: Set<String> = ["RUNNING", "COMPLETING", "CONFIGURING", "STAGE_OUT", "SIGNALING"]
    public static let waiting: Set<String> = ["PENDING", "REQUEUED", "REQUEUE_HOLD", "REQUEUE_FED", "SUSPENDED",
                                              "STOPPED", "RESIZING", "RESV_DEL_HOLD"]
    public static let finished: Set<String> = ["COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL",
                                               "PREEMPTED", "BOOT_FAIL", "DEADLINE", "REVOKED", "SPECIAL_EXIT"]
    public static let problems: Set<String> = ["FAILED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL", "PREEMPTED",
                                               "BOOT_FAIL", "DEADLINE"]

    /// sacct prints "CANCELLED by 1234"; keep the first word.
    public static func normalize(_ s: String) -> String {
        let word = s.split(separator: " ").first.map(String.init) ?? s
        return word.hasSuffix("+") ? String(word.dropLast()) : word
    }
}

/// What squeue and sacct said at one moment.
public struct JobsSnapshot: Sendable {
    public var queue: [SlurmJob]
    public var recent: [SlurmJob]

    public init(queue: [SlurmJob], recent: [SlurmJob]) {
        self.queue = queue
        self.recent = recent
    }

    static let squeueFormat = "%i|%j|%T|%M|%l|%D|%C|%P|%r|%V|%S"
    static let sacctFormat = "JobID,JobName,State,Elapsed,Timelimit,End,ExitCode,Partition,AllocCPUS"

    /// Everything the jobs panel needs, in one ssh round trip.
    public static func command(finishedHours: Int) -> String {
        "date +%z; echo @@SQUEUE; squeue -u \"$USER\" --noheader --format='\(squeueFormat)'; " +
        "echo @@SACCT; sacct -X --noheader --parsable2 --starttime now-\(max(1, finishedHours))hours --format=\(sacctFormat)"
    }

    public static func parse(_ output: String) -> JobsSnapshot {
        var offset = ""
        var section = 0
        var squeueLines: [String] = []
        var sacctLines: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line == "@@SQUEUE" { section = 1; continue }
            if line == "@@SACCT" { section = 2; continue }
            switch section {
            case 1: squeueLines.append(line)
            case 2: sacctLines.append(line)
            default: if SlurmClock.isOffset(line) { offset = line }
            }
        }
        let clock = SlurmClock(offset: offset)
        let queue = squeueLines.compactMap { squeueJob($0, clock) }
        let queued = Set(queue.map(\.id))
        let recent = sacctLines.compactMap { sacctJob($0, clock) }
            .filter { $0.isFinished && !queued.contains($0.id) }
            .sorted { ($0.end ?? .distantPast) > ($1.end ?? .distantPast) }
        return JobsSnapshot(queue: queue, recent: recent)
    }

    /// Splits on "|", gluing back a job name that itself contains "|".
    static func fields(_ line: String, count: Int) -> [String]? {
        var f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= count else { return nil }
        let extra = f.count - count
        if extra > 0 {
            f[1] = f[1...(1 + extra)].joined(separator: "|")
            f.removeSubrange(2...(1 + extra))
        }
        return f
    }

    static func squeueJob(_ line: String, _ clock: SlurmClock) -> SlurmJob? {
        guard let f = fields(line, count: 11) else { return nil }
        return SlurmJob(id: f[0], name: f[1], state: JobState.normalize(f[2]),
                        elapsed: SlurmTime.seconds(f[3]), limit: SlurmTime.seconds(f[4]), cpus: Int(f[6]),
                        partition: f[7], reason: f[8] == "None" ? nil : f[8],
                        submit: clock.date(f[9]), start: clock.date(f[10]))
    }

    static func sacctJob(_ line: String, _ clock: SlurmClock) -> SlurmJob? {
        guard let f = fields(line, count: 9) else { return nil }
        return SlurmJob(id: f[0], name: f[1], state: JobState.normalize(f[2]),
                        elapsed: SlurmTime.seconds(f[3]), limit: SlurmTime.seconds(f[4]), cpus: Int(f[8]),
                        partition: f[7], end: clock.date(f[5]), exitCode: f[6])
    }
}

/// One row in the panel: a single job, or all tasks of an array in the same state.
public struct JobGroup: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var state: String
    public var jobs: [SlurmJob]
    public var isArray: Bool

    public var tasks: Int { jobs.reduce(0) { $0 + $1.taskCount } }
    public var longest: SlurmJob? { jobs.max { ($0.elapsed ?? 0) < ($1.elapsed ?? 0) } }
    public var lastEnd: Date? { jobs.compactMap(\.end).max() }
    public var expectedStart: Date? { jobs.compactMap(\.start).min() }
    public var reason: String? { jobs.compactMap(\.reason).first }
    public var cpus: Int { jobs.reduce(0) { $0 + ($1.cpus ?? 0) * $1.taskCount } }
}

public enum JobGrouping {
    /// Running and waiting jobs, array tasks folded into one row per array.
    public static func queue(_ jobs: [SlurmJob]) -> (running: [JobGroup], waiting: [JobGroup]) {
        let running = fold(jobs.filter(\.isRunning), state: "RUNNING") { $0.arrayID ?? $0.id }
            .sorted { ($0.longest?.fraction ?? 0) > ($1.longest?.fraction ?? 0) }
        let waiting = fold(jobs.filter(\.isPending), state: "PENDING") { $0.arrayID ?? $0.id }
        return (running, waiting)
    }

    /// Finished jobs: arrays fold by array id and plain jobs by name, each split by final state.
    public static func finished(_ jobs: [SlurmJob]) -> [JobGroup] {
        var groups: [JobGroup] = []
        for state in Set(jobs.map(\.state)) {
            groups += fold(jobs.filter { $0.state == state }, state: state) { $0.arrayID ?? "name:\($0.name)" }
        }
        return groups.sorted { ($0.lastEnd ?? .distantPast) > ($1.lastEnd ?? .distantPast) }
    }

    static func fold(_ jobs: [SlurmJob], state: String, key: (SlurmJob) -> String) -> [JobGroup] {
        var order: [String] = []
        var map: [String: [SlurmJob]] = [:]
        for j in jobs {
            let k = key(j)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(j)
        }
        return order.map { k in
            let js = map[k]!
            return JobGroup(id: "\(state)|\(k)", name: js[0].name, state: state, jobs: js, isArray: js[0].arrayID != nil)
        }
    }
}

/// Jobs that stopped running between two snapshots, grouped by array.
public struct FinishedBatch: Sendable {
    public var name: String
    public var arrayID: String?
    public var jobs: [SlurmJob]

    public init(name: String, arrayID: String?, jobs: [SlurmJob]) {
        self.name = name
        self.arrayID = arrayID
        self.jobs = jobs
    }

    public var problems: Int { jobs.filter(\.isProblem).count }

    static func group(_ jobs: [SlurmJob]) -> [FinishedBatch] {
        var order: [String] = []
        var map: [String: [SlurmJob]] = [:]
        for j in jobs.sorted(by: { $0.id < $1.id }) {
            let k = j.arrayID ?? j.id
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(j)
        }
        return order.map { FinishedBatch(name: map[$0]![0].name, arrayID: map[$0]![0].arrayID, jobs: map[$0]!) }
    }
}

/// Remembers which jobs were running, so it can tell which ones just stopped.
public struct JobWatcher: Sendable {
    struct Unresolved: Sendable {
        var job: SlurmJob
        var tries: Int
    }

    private var running: [String: SlurmJob] = [:]
    private var unresolved: [String: Unresolved] = [:]
    private var primed = false

    public init() {}

    public mutating func update(_ snap: JobsSnapshot) -> [FinishedBatch] {
        var now: [String: SlurmJob] = [:]
        for j in snap.queue where j.isRunning { now[j.id] = j }
        defer {
            running = now
            primed = true
        }
        guard primed else { return [] }

        var stopped: [String: Unresolved] = [:]
        for (id, job) in running where now[id] == nil { stopped[id] = Unresolved(job: job, tries: 0) }
        for (id, u) in unresolved where now[id] == nil { stopped[id] = u }
        unresolved = [:]

        var finals: [String: SlurmJob] = [:]
        for j in snap.recent { finals[j.id] = j }
        let queued = Set(snap.queue.map(\.id))
        var done: [SlurmJob] = []
        for (id, u) in stopped {
            if let f = finals[id] {
                done.append(f)
            } else if queued.contains(id) {
                continue  // requeued, so it is waiting again
            } else if u.tries >= 2 {
                var j = u.job
                j.state = "ENDED"  // sacct never reported it; say it left the queue
                done.append(j)
            } else {
                unresolved[id] = Unresolved(job: u.job, tries: u.tries + 1)
            }
        }
        return FinishedBatch.group(done)
    }
}

/// Wording for the notification about a finished job or array.
public enum NotificationText {
    public static func make(_ b: FinishedBatch, cluster: String? = nil) -> (title: String, body: String) {
        let on = cluster.map { " on \($0)" } ?? ""
        if b.jobs.count == 1, let j = b.jobs.first {
            let took = j.elapsed.map { "after \(SlurmTime.short($0))" } ?? ""
            switch j.state {
            case "COMPLETED":
                return ("✓ \(j.name) finished\(on)", [took, j.partition].filter { !$0.isEmpty }.joined(separator: " · "))
            case "FAILED":
                return ("✗ \(j.name) failed\(on)", ["exit \(j.exitCode ?? "?")", took].filter { !$0.isEmpty }.joined(separator: " · "))
            case "TIMEOUT":
                return ("⏱ \(j.name) hit its time limit\(on)", j.limit.map { "limit \(SlurmTime.short($0))" } ?? "")
            case "OUT_OF_MEMORY":
                return ("✗ \(j.name) ran out of memory\(on)", took)
            case "CANCELLED":
                return ("\(j.name) was cancelled\(on)", took)
            case "ENDED":
                return ("\(j.name) left the queue\(on)", "sacct has no final state for it yet")
            default:
                return ("\(j.name): \(j.state.lowercased().replacingOccurrences(of: "_", with: " "))\(on)", took)
            }
        }
        let n = b.jobs.count
        let ok = b.jobs.filter { $0.state == "COMPLETED" }.count
        let longest = b.jobs.compactMap(\.elapsed).max().map { "longest \(SlurmTime.short($0))" } ?? ""
        if ok == n { return ("✓ \(b.name): \(n) tasks finished\(on)", longest) }
        let states = Dictionary(grouping: b.jobs, by: \.state)
            .map { "\($0.value.count) \($0.key.lowercased().replacingOccurrences(of: "_", with: " "))" }
            .sorted()
            .joined(separator: ", ")
        return ("✗ \(b.name): \(n - ok) of \(n) tasks did not finish\(on)", states)
    }
}
