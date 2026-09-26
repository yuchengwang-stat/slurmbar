import SlurmBarCore
import SwiftUI

/// How busy a partition is, which says roughly how long a new job will wait.
/// Counting waiting jobs lists the whole partition queue, so by default this only runs while the panel is open.
@MainActor @Observable
final class PartitionWidget: ClusterWidget {
    let spec: WidgetSpec
    let status = WidgetStatus()
    var loads: [PartitionLoad] = []

    init(spec: WidgetSpec) { self.spec = spec }

    var backgroundInterval: Int? { configured(nil) }
    var staleAfter: Int { 600 }
    var names: [String] { (spec.option("partitions") ?? "").split(separator: ",").map(String.init) }

    func refresh(_ runner: CommandRunner) async throws {
        loads = Partitions.parse(try await runner.run(Partitions.command(names))).sorted { $0.total > $1.total }
    }

    var view: AnyView { AnyView(PartitionView(widget: self)) }
}

struct PartitionView: View {
    let widget: PartitionWidget

    var body: some View {
        Panel(title: widget.spec.title ?? "Partitions", status: widget.status) {
            if widget.loads.isEmpty { Placeholder(status: widget.status) }
            ForEach(widget.loads.prefix(6)) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.name).font(.system(size: 12.5, weight: .medium))
                        if !p.isUp { Text("down").font(.system(size: 11)).foregroundStyle(.red) }
                        Spacer()
                        Text("\(Int((p.busy * 100).rounded()))% busy").caption()
                    }
                    Bar(fraction: p.busy, tint: .teal)
                    Text("\(p.idle.formatted()) CPUs free · \(p.waiting.formatted()) jobs waiting").caption()
                }
            }
        }
    }
}
