import SlurmBarCore
import SwiftUI

@MainActor @Observable
final class WidgetStatus {
    var lastUpdated: Date?
    var error: String?
    var loading = false
}

/// A panel in the popover.
///
/// To add a new kind of panel: write a class that conforms to this protocol (see QuotaWidget
/// for a short one), then add a line for it in WidgetFactory. For anything a shell command can
/// print, you don't need Swift at all: a "command" panel in the config does it.
@MainActor
protocol ClusterWidget: AnyObject {
    var spec: WidgetSpec { get }
    var status: WidgetStatus { get }
    /// Seconds between background refreshes, or nil to refresh only when the panel opens.
    /// Keep it as long as the panel allows: every refresh is a query on a shared cluster.
    var backgroundInterval: Int? { get }
    /// When the panel opens, refresh if the data is older than this many seconds.
    var staleAfter: Int { get }
    /// False for panels that never talk to the cluster.
    var usesCluster: Bool { get }
    func refresh(_ runner: CommandRunner) async throws
    /// Short text for the menu bar, or nil.
    var menuBarText: String? { get }
    var view: AnyView { get }
}

extension ClusterWidget {
    var usesCluster: Bool { true }
    var menuBarText: String? { nil }

    /// refreshSeconds in the config wins over a panel's default, but never below a minute.
    func configured(_ fallback: Int?) -> Int? {
        spec.refreshSeconds.map { max(60, $0) } ?? fallback
    }
}

@MainActor
enum WidgetFactory {
    static func make(_ spec: WidgetSpec, cluster: ClusterConfig, services: Services) -> any ClusterWidget {
        switch spec.type.lowercased() {
        case "jobs": return JobsWidget(spec: spec, cluster: cluster, services: services)
        case "allocation", "allocations": return AllocationWidget(spec: spec, cluster: cluster, services: services)
        case "quota", "quotas", "storage": return QuotaWidget(spec: spec)
        case "partition", "partitions": return PartitionWidget(spec: spec)
        case "command": return CommandWidget(spec: spec)
        default: return UnknownWidget(spec: spec)
        }
    }
}

/// Whether anyone is looking. Polling pauses while the screen is locked or asleep.
@MainActor @Observable
final class Activity {
    var panelOpen = false
    var paused = false
}

/// What panels need from the app: a way to notify, the saved allocation history, and the activity state.
@MainActor
final class Services {
    let activity = Activity()
    var notify: (FinishedBatch, String) -> Void = { _, _ in }
    private(set) var history = UsageHistory()
    private let historyURL: URL?

    init(historyURL: URL?) {
        self.historyURL = historyURL
        if let url = historyURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(UsageHistory.self, from: data) {
            history = saved
        }
    }

    func record(_ key: String, remaining: Double) {
        history.record(key, remaining: remaining)
        guard let url = historyURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: url, options: .atomic)
    }

    func seed(_ key: String, _ samples: [UsageSample]) {
        history.series[key] = samples
    }
}

@MainActor @Observable
final class UnknownWidget: ClusterWidget {
    let spec: WidgetSpec
    let status = WidgetStatus()

    init(spec: WidgetSpec) { self.spec = spec }

    var backgroundInterval: Int? { nil }
    var staleAfter: Int { .max }
    var usesCluster: Bool { false }
    func refresh(_ runner: CommandRunner) async throws {}

    var view: AnyView {
        AnyView(Panel(title: spec.title ?? spec.type, status: status) {
            Text("Unknown panel type \"\(spec.type)\". Known types: jobs, allocation, quota, partition, command.")
                .caption()
                .fixedSize(horizontal: false, vertical: true)
        })
    }
}
