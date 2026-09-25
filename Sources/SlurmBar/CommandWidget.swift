import SlurmBarCore
import SwiftUI

/// Runs any command on the cluster and shows what it prints. This is the no-Swift way to add a panel:
///
///     { "type": "command", "title": "Training loss", "command": "tail -n 3 ~/run/log.txt" }
@MainActor @Observable
final class CommandWidget: ClusterWidget {
    let spec: WidgetSpec
    let status = WidgetStatus()
    var lines: [String] = []
    var truncated = false

    init(spec: WidgetSpec) { self.spec = spec }

    var defaultRefresh: Int { 300 }
    var maxLines: Int { max(1, Int(spec.option("lines") ?? "") ?? 6) }

    func refresh(_ runner: CommandRunner) async throws {
        guard let command = spec.command, !command.isEmpty else {
            throw ParseError("This panel needs a \"command\" in the config.")
        }
        let all = try await runner.run(command).split(whereSeparator: \.isNewline).map(String.init)
        lines = Array(all.prefix(maxLines))
        truncated = all.count > maxLines
    }

    var menuBarText: String? {
        guard spec.menuBar == true, let first = lines.first else { return nil }
        return first.count > 24 ? String(first.prefix(23)) + "…" : first
    }

    var view: AnyView { AnyView(CommandView(widget: self)) }
}

struct CommandView: View {
    let widget: CommandWidget

    var body: some View {
        Panel(title: widget.spec.title ?? "Command", status: widget.status) {
            if widget.lines.isEmpty {
                if widget.status.error == nil {
                    Text(widget.status.lastUpdated == nil ? "Loading…" : "No output.").caption()
                }
            } else {
                Text(widget.lines.joined(separator: "\n") + (widget.truncated ? "\n…" : ""))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}
