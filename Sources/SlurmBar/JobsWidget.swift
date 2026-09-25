import SlurmBarCore
import SwiftUI

@MainActor @Observable
final class JobsWidget: ClusterWidget {
    let spec: WidgetSpec
    let status = WidgetStatus()
    let clusterName: String
    /// Your jobs in the queue, nil until the first answer.
    var queue: [SlurmJob]?
    /// Jobs that ended within finishedHours, newest first.
    var recent: [SlurmJob] = []
    @ObservationIgnored private let fixedInterval: Int?
    @ObservationIgnored private let services: Services
    @ObservationIgnored private var watcher: FinishWatcher
    @ObservationIgnored private var listFetched: Date?
    /// Jobs that left the queue before sacct had their final state, with how many times we've asked.
    @ObservationIgnored private var awaiting: [String: Int] = [:]

    init(spec: WidgetSpec, cluster: ClusterConfig, services: Services) {
        self.spec = spec
        clusterName = cluster.name
        fixedInterval = spec.refreshSeconds ?? cluster.refreshSeconds
        self.services = services
        let hours = Int(spec.option("finishedHours") ?? "") ?? 24
        watcher = FinishWatcher(keep: Double(hours + 24) * 3600)
    }

    var finishedHours: Int { Int(spec.option("finishedHours") ?? "") ?? 24 }
    var backgroundInterval: Int? { JobsSchedule.interval(queueEmpty: (queue ?? []).isEmpty, fixed: fixedInterval) }
    var staleAfter: Int { 60 }

    /// squeue every time; sacct only when something left the queue or the finished list is old.
    func refresh(_ runner: CommandRunner) async throws {
        let before = Set((queue ?? []).map(\.id))
        let now = JobsSnapshot.parse(try await runner.run(JobsSnapshot.queueCommand)).queue
        let ids = Set(now.map(\.id))
        let left = before.subtracting(ids)
        for id in left where !id.contains("[") { awaiting[id] = awaiting[id] ?? 0 }
        queue = now

        let age = listFetched.map { Date().timeIntervalSince($0) } ?? .infinity
        guard JobsSchedule.wantsFinished(somethingLeft: !left.isEmpty, stillWaiting: !awaiting.isEmpty,
                                         listAge: age, panelOpen: services.activity.panelOpen) else { return }

        let finished = JobsSnapshot.parse(try await runner.run(JobsSnapshot.finishedCommand(hours: finishedHours))).recent
        listFetched = Date()
        recent = finished.filter { !ids.contains($0.id) }
        let found = Set(finished.map(\.id))
        awaiting = awaiting.filter { !found.contains($0.key) && $0.value < 2 }.mapValues { $0 + 1 }
        for batch in watcher.update(finished) { services.notify(batch, clusterName) }
    }

    var counts: (running: Int, waiting: Int) {
        guard let q = queue else { return (0, 0) }
        return (q.filter(\.isRunning).reduce(0) { $0 + $1.taskCount },
                q.filter(\.isPending).reduce(0) { $0 + $1.taskCount })
    }

    var menuBarText: String? {
        guard spec.menuBar ?? true, queue != nil else { return nil }
        let c = counts
        if c.running == 0, c.waiting == 0 { return nil }
        return c.waiting > 0 ? "\(c.running)R \(c.waiting)PD" : "\(c.running)R"
    }

    var view: AnyView { AnyView(JobsView(widget: self)) }
}

struct JobsView: View {
    let widget: JobsWidget

    var body: some View {
        let c = widget.counts
        Panel(title: widget.spec.title ?? "Jobs",
              trailing: widget.queue == nil ? nil : "\(c.running) running · \(c.waiting) waiting",
              status: widget.status) {
            if let queue = widget.queue {
                let groups = JobGrouping.queue(queue)
                let done = JobGrouping.finished(widget.recent)
                if groups.running.isEmpty, groups.waiting.isEmpty {
                    Text("Nothing in the queue.").caption()
                }
                ForEach(groups.running.prefix(6)) { RunningRow(group: $0) }
                if groups.running.count > 6 {
                    Text("and \(groups.running.count - 6) more running").caption()
                }
                if !groups.waiting.isEmpty {
                    SubHeading("Waiting")
                    ForEach(groups.waiting.prefix(4)) { WaitingRow(group: $0) }
                }
                if !done.isEmpty {
                    SubHeading("Finished in the last \(widget.finishedHours)h")
                    ForEach(done.prefix(5)) { FinishedRow(group: $0) }
                }
            } else if widget.status.error == nil {
                Text("Loading…").caption()
            }
        }
    }
}

struct RunningRow: View {
    let group: JobGroup

    var body: some View {
        let lead = group.longest
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(group.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(group.isArray ? "array · \(tasksText(group.tasks))" : (lead?.id ?? "")).caption().lineLimit(1)
                Spacer(minLength: 6)
                Text(timeText(lead)).caption().monospacedDigit()
            }
            Bar(fraction: lead?.fraction ?? 0, tint: limitTint(lead?.fraction))
        }
    }

    func timeText(_ j: SlurmJob?) -> String {
        guard let j, let e = j.elapsed else { return "" }
        guard let l = j.limit else { return SlurmTime.short(e) }
        return "\(SlurmTime.short(e)) of \(SlurmTime.short(l))"
    }
}

func tasksText(_ n: Int) -> String { n == 1 ? "1 task" : "\(n) tasks" }

/// Blue while there's room, orange past 75% of the time limit, red past 90%.
func limitTint(_ f: Double?) -> Color {
    guard let f else { return .accentColor }
    return f >= 0.9 ? .red : f >= 0.75 ? .orange : .accentColor
}

struct WaitingRow: View {
    let group: JobGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "hourglass").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(group.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(group.isArray ? tasksText(group.tasks) : (group.jobs.first?.id ?? "")).caption().lineLimit(1)
            Spacer(minLength: 6)
            Text(detail).caption().lineLimit(1)
        }
    }

    var detail: String {
        var parts: [String] = []
        if let r = group.reason { parts.append(Self.friendly(r)) }
        if let s = group.expectedStart, s > Date() { parts.append("starts ~\(Fmt.time(s))") }
        return parts.joined(separator: " · ")
    }

    static func friendly(_ reason: String) -> String {
        switch reason {
        case "Priority": return "priority"
        case "Resources": return "waiting for nodes"
        case "Dependency": return "dependency"
        case "JobArrayTaskLimit": return "array limit"
        case "BeginTime": return "scheduled"
        case "AssocGrpBillingMinutes", "AssocGrpCPUMinutesLimit": return "allocation used up"
        case "QOSMaxCpuPerUserLimit", "AssocMaxCpuPerUserLimit", "QOSMaxJobsPerUserLimit", "AssocMaxJobsLimit":
            return "per-user limit"
        default: return reason.hasPrefix("ReqNodeNotAvail") ? "nodes unavailable" : reason
        }
    }
}

struct FinishedRow: View {
    let group: JobGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StateIcon(state: group.state)
            Text(group.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(detail).caption().lineLimit(1)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(Ago.text(group.lastEnd, now: ctx.date)).caption()
            }
        }
    }

    var detail: String {
        if group.isArray { return tasksText(group.tasks) }
        if group.jobs.count > 1 { return "×\(group.jobs.count)" }
        let j = group.jobs[0]
        switch j.state {
        case "COMPLETED": return j.elapsed.map { "took \(SlurmTime.short($0))" } ?? ""
        case "FAILED": return "exit \(j.exitCode ?? "?")"
        case "TIMEOUT": return "hit its time limit"
        case "OUT_OF_MEMORY": return "out of memory"
        case "CANCELLED": return "cancelled"
        default: return j.state.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct StateIcon: View {
    let state: String

    var body: some View {
        let look: (String, Color) = {
            switch state {
            case "COMPLETED": return ("checkmark.circle.fill", .green)
            case "TIMEOUT", "DEADLINE": return ("clock.badge.exclamationmark", .orange)
            case "CANCELLED": return ("minus.circle.fill", .secondary)
            case "PREEMPTED": return ("arrow.uturn.backward.circle.fill", .orange)
            default: return JobState.problems.contains(state) ? ("xmark.octagon.fill", .red) : ("circle.fill", .secondary)
            }
        }()
        Image(systemName: look.0).font(.system(size: 11)).foregroundStyle(look.1)
    }
}
