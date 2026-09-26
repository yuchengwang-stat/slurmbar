import SlurmBarCore
import SwiftUI

/// Disk use from PSC's `my_quotas`. A good example to copy when adding a panel.
@MainActor @Observable
final class QuotaWidget: ClusterWidget {
    let spec: WidgetSpec
    let status = WidgetStatus()
    var quotas: [DiskQuota] = []

    init(spec: WidgetSpec) { self.spec = spec }

    var backgroundInterval: Int? { configured(3600) }
    var staleAfter: Int { 900 }

    func refresh(_ runner: CommandRunner) async throws {
        let command = spec.command ?? Storage.quotaCommand
        let found = Storage.parseMyQuotas(try await runner.run(command))
        if found.isEmpty { throw ParseError("No quotas in the output of `\(command)`") }
        quotas = found
    }

    var view: AnyView { AnyView(QuotaView(widget: self)) }
}

struct QuotaView: View {
    let widget: QuotaWidget

    var body: some View {
        Panel(title: widget.spec.title ?? "Storage", status: widget.status) {
            if widget.quotas.isEmpty { Placeholder(status: widget.status) }
            ForEach(widget.quotas) { QuotaRow(quota: $0) }
        }
    }
}

struct QuotaRow: View {
    let quota: DiskQuota

    var body: some View {
        let f = quota.fraction ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quota.label.replacingOccurrences(of: " directory", with: ""))
                    .font(.system(size: 12.5, weight: .medium))
                Text(quota.path).caption().lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(Storage.format(quota.usedBytes)) of \(Storage.format(quota.quotaBytes))").caption().monospacedDigit()
            }
            Bar(fraction: f, tint: f >= 0.9 ? .red : f >= 0.75 ? .orange : .accentColor)
            if let limit = quota.filesQuota, limit > 0, let files = quota.filesUsed {
                Text("\(Fmt.compact(Double(files))) of \(Fmt.compact(Double(limit))) files").caption()
            }
        }
    }
}
