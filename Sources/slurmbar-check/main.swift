// Checks the parsers against the fixtures. With --live it also queries the clusters in your config.
import Foundation
import SlurmBarCore

var failures = 0

func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let d = detail()
    print("\(ok ? "ok  " : "FAIL")  \(label)\(d.isEmpty ? "" : "   [\(d)]")")
    if !ok { failures += 1 }
}

// durations
check("M:SS", SlurmTime.seconds("0:39") == 39)
check("H:MM:SS", SlurmTime.seconds("2:52:45") == 10_365)
check("D-HH:MM:SS", SlurmTime.seconds("2-00:00:00") == 172_800)
check("D-HH", SlurmTime.seconds("1-12") == 129_600)
check("UNLIMITED", SlurmTime.seconds("UNLIMITED") == nil)
check("short format", SlurmTime.short(12_280) == "3h 24m", SlurmTime.short(12_280))

// jobs
let now = Date()
let snap = JobsSnapshot.parse(Fixtures.jobs(now: now))
check("squeue lines", snap.queue.count == 6, "\(snap.queue.count)")
let queue = JobGrouping.queue(snap.queue)
check("running rows", queue.running.count == 3, "\(queue.running.map(\.name))")
check("running array folds", queue.running.first { $0.name == "sim_grid" }?.tasks == 2)
check("waiting array counts its tasks", queue.waiting.first { $0.name == "sim_grid" }?.tasks == 15,
      "\(queue.waiting.map { "\($0.name) \($0.tasks)" })")
check("closest to its time limit comes first", queue.running.first?.name == "fit_model")
check("running jobs are not listed as finished", !snap.recent.contains { $0.isRunning || $0.name == "fit_model" })
let finished = JobGrouping.finished(snap.recent)
check("46 array tasks fold into one row", finished.first { $0.name == "fc_post" }?.tasks == 46)
check("repeated job names fold", finished.first { $0.name == "preprocess" }?.jobs.count == 3)
check("newest finished first", finished.first?.name == "fc_post", "\(finished.map(\.name))")
check("CANCELLED by", JobState.normalize("CANCELLED by 12345") == "CANCELLED")
let started = snap.queue.first { $0.name == "preprocess" }?.start
check("times use the cluster's offset", abs((started ?? .distantPast).timeIntervalSince(now.addingTimeInterval(-39))) < 2,
      "\(String(describing: started))")
let odd = JobsSnapshot.parse("-0400\n@@SQUEUE\n7|a|b|RUNNING|0:10|1:00:00|1|1|RM|None|N/A|N/A\n@@SACCT\n")
check("a job name with | in it", odd.queue.first?.name == "a|b" && odd.queue.first?.state == "RUNNING")

// notifications: every finished job is reported once, from sacct
var watcher = FinishWatcher()
check("the first finished list only sets the baseline", watcher.update(snap.recent, now: now).isEmpty)
var later = snap.recent
later.insert(SlurmJob(id: "51230001", name: "fit_model", state: "COMPLETED", elapsed: 50_000, limit: 57_600,
                      partition: "RM-shared", end: now, exitCode: "0:0"), at: 0)
later.insert(SlurmJob(id: "51234567_3", name: "sim_grid", state: "FAILED", elapsed: 11_000, limit: 57_600,
                      partition: "RM-shared", end: now, exitCode: "1:0"), at: 0)
later.insert(SlurmJob(id: "51250000", name: "typo_job", state: "CANCELLED", elapsed: 0, partition: "RM-shared", end: now), at: 0)
let batches = watcher.update(later, now: now)
check("new finished jobs are reported", batches.map(\.name).sorted() == ["fit_model", "sim_grid"], "\(batches.map(\.name))")
check("a job cancelled before it ran is not reported", !batches.contains { $0.name == "typo_job" })
check("failure is flagged", batches.first { $0.name == "sim_grid" }?.problems == 1)
let text = NotificationText.make(batches.first { $0.name == "sim_grid" }!)
check("failure wording", text.title == "✗ sim_grid failed" && text.body.hasPrefix("exit 1:0"), "\(text)")
check("each job is reported once", watcher.update(later, now: now).isEmpty)

// how often it asks
check("5 minutes with jobs in the queue", JobsSchedule.interval(queueEmpty: false, fixed: nil) == 300)
check("15 minutes with an empty queue", JobsSchedule.interval(queueEmpty: true, fixed: nil) == 900)
check("a fixed interval never goes below a minute", JobsSchedule.interval(queueEmpty: false, fixed: 10) == 60)
check("no sacct when nothing left the queue",
      !JobsSchedule.wantsFinished(somethingLeft: false, stillWaiting: false, listAge: 600, panelOpen: false))
check("sacct when a job left the queue",
      JobsSchedule.wantsFinished(somethingLeft: true, stillWaiting: false, listAge: 10, panelOpen: false))
check("the first look always fetches the finished list",
      JobsSchedule.wantsFinished(somethingLeft: false, stillWaiting: false, listAge: .infinity, panelOpen: false))
check("no sacct in the background just because the list is old",
      !JobsSchedule.wantsFinished(somethingLeft: false, stillWaiting: false, listAge: 7200, panelOpen: false))
check("sacct when the panel is open and the list is old",
      JobsSchedule.wantsFinished(somethingLeft: false, stillWaiting: false, listAge: 300, panelOpen: true))
check("squeue and sacct are separate calls",
      !JobsSnapshot.queueCommand.contains("sacct") && !JobsSnapshot.finishedCommand(hours: 24).contains("squeue"))

// PSC allocation
do {
    let projects = try PSC.projects("some banner line\n" + Fixtures.projects(now: now))
    check("projects JSON", projects.first?.allocations.count == 2)
    let used = projects.first?.allocations.first?.usedFraction ?? 0
    check("used share", abs(used - 0.6292) < 0.001, "\(used)")
    check("storage is marked", projects.first?.allocations.last?.isStorage == true)
} catch {
    check("projects JSON", false, "\(error)")
}

// burn rate
var h = UsageHistory()
for s in Fixtures.history(now: now) { h.record("su", remaining: s.remaining, at: s.t) }
check("burn rate", abs((h.perDay("su") ?? 0) - Fixtures.demoBurnPerDay) < 1, "\(h.perDay("su") ?? -1)")
var short = UsageHistory()
short.record("su", remaining: 100, at: now.addingTimeInterval(-3600))
short.record("su", remaining: 90, at: now)
check("no rate from under half a day", short.perDay("su") == nil)
var topUp = UsageHistory()
topUp.record("su", remaining: 100, at: now.addingTimeInterval(-86_400))
topUp.record("su", remaining: 500, at: now)
check("a top-up starts the history over", topUp.series["su"]?.count == 1)

// quotas
let quotas = Storage.parseMyQuotas(Fixtures.quotas)
check("two quota blocks", quotas.count == 2, "\(quotas.count)")
check("GiB", abs((quotas.first?.usedBytes ?? 0) - 17.35 * 0x1p30) < 1)
check("TiB", abs((quotas.last?.quotaBytes ?? 0) - 51.19 * 0x1p40) < 1e6)
check("inodes", quotas.last?.filesUsed == 1_571_712)
check("format", Storage.format(17.35 * 0x1p30) == "17.4 GiB", Storage.format(17.35 * 0x1p30))

// partitions
let parts = Partitions.parse(Fixtures.partitions)
check("partition CPUs", parts.first?.name == "RM-shared" && parts.first?.idle == 4847)
check("waiting jobs", parts.first?.waiting == 1204)
check("unsafe partition names are dropped", Partitions.clean(["RM-shared", "x; rm -rf ~"]) == ["RM-shared"])

// config
let starter = ConfigStore.starter(host: "bridges2.psc.edu", user: "me")
check("starter config for PSC", starter.clusters.first?.widgets?.map(\.type) == ["jobs", "allocation", "quota", "partition"])
check("connect command", RemoteShell(cluster: starter.clusters[0]).connectCommand ==
      "ssh -fN -o ControlMaster=yes -o ControlPath='~/.ssh/slurmbar-%r@%h' -o ControlPersist=12h me@bridges2.psc.edu",
      RemoteShell(cluster: starter.clusters[0]).connectCommand)

check("with a control socket, ssh can't open a new connection",
      RemoteShell(cluster: starter.clusters[0]).arguments.contains("ProxyCommand=/usr/bin/false"))
check("refused login is told apart from a network problem",
      ShellError.failed(status: 255, message: "ywang@x: Permission denied (publickey).").isLoginRefused
      && !ShellError.failed(status: 255, message: "Connection closed by UNKNOWN port 65535").isLoginRefused)

let example = URL(fileURLWithPath: "examples/bridges2.json")
if FileManager.default.fileExists(atPath: example.path) {
    let widgets = (try? ConfigStore.load(example))?.clusters.first?.widgets?.map(\.type) ?? []
    check("example config loads", widgets == ["jobs", "allocation", "quota", "partition", "command"], "\(widgets)")
}

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")

// --live: run the real commands and print what SlurmBar would show
if CommandLine.arguments.contains("--live") {
    let url = ConfigStore.url
    guard let config = try? ConfigStore.load(url) else {
        print("no readable config at \(url.path)")
        exit(1)
    }
    for c in config.clusters {
        let sh = RemoteShell(cluster: c)
        print("\n== \(c.name) (\(sh.destination)) connected: \(await sh.isConnected())")
        do {
            let s = JobsSnapshot.parse(try await sh.run(JobsSnapshot.command(finishedHours: 24)))
            let q = JobGrouping.queue(s.queue)
            for g in q.running {
                let pct = Int(((g.longest?.fraction ?? 0) * 100).rounded())
                print("running   \(g.name) x\(g.tasks)  \(g.longest?.elapsed.map(SlurmTime.short) ?? "?") of \(g.longest?.limit.map(SlurmTime.short) ?? "?") (\(pct)%)")
            }
            for g in q.waiting { print("waiting   \(g.name) x\(g.tasks)  \(g.reason ?? "")") }
            for g in JobGrouping.finished(s.recent).prefix(8) {
                print("finished  \(g.state.lowercased()) \(g.name) x\(g.tasks)  ended \(g.lastEnd.map { "\(Int(-$0.timeIntervalSinceNow / 60))m ago" } ?? "?")")
            }
        } catch { print("jobs: \(error.localizedDescription)") }
        do {
            for p in try PSC.projects(try await sh.run(PSC.projectsCommand)) {
                for a in p.allocations {
                    print("allocation \(p.id) \(a.resourceDisplayName ?? a.id): \(Int(a.suRemaining ?? 0)) of \(Int(a.suAllocated ?? 0)) left, ends \(a.endDate ?? "?")")
                }
            }
        } catch { print("allocation: \(error.localizedDescription)") }
        do {
            for d in Storage.parseMyQuotas(try await sh.run(Storage.quotaCommand)) {
                print("quota     \(d.label) \(d.path): \(Storage.format(d.usedBytes)) of \(Storage.format(d.quotaBytes))")
            }
        } catch { print("quota: \(error.localizedDescription)") }
        do {
            for p in Partitions.parse(try await sh.run(Partitions.command(["RM-shared"]))) {
                print("partition \(p.name): \(Int(p.busy * 100))% busy, \(p.idle) CPUs idle, \(p.waiting) jobs waiting")
            }
        } catch { print("partition: \(error.localizedDescription)") }
    }
}

exit(failures == 0 ? 0 : 1)
