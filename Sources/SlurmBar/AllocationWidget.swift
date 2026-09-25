import SlurmBarCore
import SwiftUI

/// SU balance from PSC's `projects --format json`, with how fast it has been going.
@MainActor @Observable
final class AllocationWidget: ClusterWidget {
    let spec: WidgetSpec
    let status = WidgetStatus()
    let clusterName: String
    var projects: [PSCProject] = []
    var rates: [String: Double] = [:]
    @ObservationIgnored private let services: Services

    init(spec: WidgetSpec, cluster: ClusterConfig, services: Services) {
        self.spec = spec
        clusterName = cluster.name
        self.services = services
    }

    var backgroundInterval: Int? { configured(3600) }
    var staleAfter: Int { 900 }
    var includeStorage: Bool { spec.option("storage") == "true" }

    func key(_ p: PSCProject, _ a: PSCAllocation) -> String { "\(clusterName)/\(p.id)/\(a.id)" }

    func refresh(_ runner: CommandRunner) async throws {
        var found = try PSC.projects(try await runner.run(spec.command ?? PSC.projectsCommand))
        if let only = spec.option("project")?.lowercased() {
            found = found.filter { $0.id.lowercased() == only || ($0.grantNumber ?? "").lowercased() == only }
        }
        var r: [String: Double] = [:]
        for p in found {
            for a in p.allocations where !a.isStorage {
                if let left = a.suRemaining { services.record(key(p, a), remaining: left) }
                r[key(p, a)] = services.history.perDay(key(p, a))
            }
        }
        rates = r
        projects = found
    }

    var menuBarText: String? {
        guard spec.menuBar == true,
              let a = projects.first?.allocations.first(where: { !$0.isStorage }),
              let used = a.usedFraction else { return nil }
        return "SU \(Int(((1 - used) * 100).rounded()))%"
    }

    var view: AnyView { AnyView(AllocationView(widget: self)) }
}

struct AllocationView: View {
    let widget: AllocationWidget

    var body: some View {
        Panel(title: widget.spec.title ?? "Allocation", trailing: widget.projects.first?.id, status: widget.status) {
            if widget.projects.isEmpty, widget.status.error == nil {
                Text("Loading…").caption()
            }
            ForEach(widget.projects) { p in
                ForEach(p.allocations.filter { widget.includeStorage || !$0.isStorage }) { a in
                    AllocationRow(allocation: a, perDay: widget.rates[widget.key(p, a)],
                                  project: widget.projects.count > 1 ? p.id : nil)
                }
            }
        }
    }
}

struct AllocationRow: View {
    let allocation: PSCAllocation
    let perDay: Double?
    let project: String?

    var body: some View {
        let used = allocation.usedFraction ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                Text("\(Int((used * 100).rounded()))% used").caption()
            }
            Bar(fraction: used, tint: used >= 0.9 ? .red : used >= 0.75 ? .orange : .accentColor)
            Text(amountLine).caption()
            if let line = timeLine { Text(line).caption() }
            if let pace = paceLine {
                Text(pace.text)
                    .font(.system(size: 11))
                    .foregroundStyle(pace.warn ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var title: String {
        let name = allocation.resourceDisplayName ?? allocation.id
        return project.map { "\($0) · \(name)" } ?? name
    }

    var unit: String { allocation.isStorage ? "GB" : "SU" }

    var amountLine: String {
        let left = allocation.suRemaining ?? 0
        let total = allocation.suAllocated ?? 0
        return "\(Fmt.int(left)) of \(Fmt.int(total)) \(unit) left"
    }

    var daysLeft: Int? {
        guard let end = allocation.end else { return nil }
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: end)).day ?? 0)
    }

    var timeLine: String? {
        guard let end = allocation.end, let d = daysLeft else { return nil }
        return "Ends \(Fmt.day(end)) · \(d) day\(d == 1 ? "" : "s") left"
    }

    var paceLine: (text: String, warn: Bool)? {
        guard let rate = perDay, let left = allocation.suRemaining else { return nil }
        let lasts = left / rate
        let pace = "~\(Fmt.compact(rate)) \(unit)/day this week"
        guard let d = daysLeft, let end = allocation.end else {
            return ("\(pace), about \(Int(lasts)) days at that pace", false)
        }
        if lasts < Double(d) {
            let out = Date().addingTimeInterval(lasts * 86_400)
            let early = d - Int(lasts)
            return ("\(pace). At that pace it runs out around \(Fmt.day(out)), \(early) day\(early == 1 ? "" : "s") before it ends.", true)
        }
        return ("\(pace), enough to last past \(Fmt.day(end)).", false)
    }
}
