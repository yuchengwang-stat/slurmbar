import AppKit
import ServiceManagement
import SlurmBarCore
import SwiftUI

@MainActor @Observable
final class AppModel {
    enum Mode { case live, demo }

    /// The model of the running app, for the window that shows the same panel.
    static weak var current: AppModel?

    let mode: Mode
    let configURL: URL
    var clusters: [ClusterModel] = []
    var configError: String?
    var needsSetup = false
    var unseenProblems = 0
    var notificationsOn = true
    /// Off by default: nothing reaches the cluster until you press Refresh.
    var autoRefresh = false
    var opensAtLogin = false
    @ObservationIgnored let services: Services
    @ObservationIgnored private var notifier: Notifier?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var lastCatchUp = Date.distantPast

    init(mode: Mode, autostart: Bool = true) {
        self.mode = mode
        configURL = ConfigStore.url
        services = Services(historyURL: mode == .live
                            ? configURL.deletingLastPathComponent().appendingPathComponent("history.json") : nil)
        services.notify = { [weak self] batch, cluster in self?.deliver(batch, cluster: cluster) }
        if Bundle.main.bundleIdentifier != nil { opensAtLogin = SMAppService.mainApp.status == .enabled }
        load(start: autostart)
        if autostart { AppModel.current = self }
        if mode == .live { watchScreen() }
    }

    /// Pause while the screen is locked or the display sleeps, and catch up once afterwards.
    /// The catch-up also sends notifications for jobs that ended in the meantime.
    private func watchScreen() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ act: @escaping (AppModel) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { act(self) } }
            })
        }
        on(distributed, .init("com.apple.screenIsLocked")) { $0.locked = true; $0.updatePause() }
        on(distributed, .init("com.apple.screenIsUnlocked")) { $0.locked = false; $0.updatePause() }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true; $0.updatePause() }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false; $0.updatePause() }
        on(workspace, NSWorkspace.didWakeNotification) { $0.catchUp() }
    }

    private func updatePause() {
        let wasPaused = services.activity.paused
        services.activity.paused = locked || displayAsleep
        if wasPaused, !services.activity.paused { catchUp() }
    }

    private func catchUp() {
        guard autoRefresh, !services.activity.paused, Date().timeIntervalSince(lastCatchUp) > 30 else { return }
        lastCatchUp = Date()
        Task { for c in clusters { await c.refreshAll(background: true) } }
    }

    func load(start: Bool = true) {
        clusters.forEach { $0.stop() }
        clusters = []
        configError = nil
        let config: AppConfig
        if mode == .demo {
            config = Fixtures.demoConfig
        } else {
            if !FileManager.default.fileExists(atPath: configURL.path) {
                try? ConfigStore.save(ConfigStore.starter(), to: configURL)
            }
            do {
                config = try ConfigStore.load(configURL)
            } catch {
                configError = "Couldn't read \(configURL.path): \(error.localizedDescription)"
                return
            }
        }
        autoRefresh = config.autoRefresh ?? false
        notificationsOn = config.notifications ?? true
        if mode == .live, autoRefresh, notificationsOn, notifier == nil, Bundle.main.bundleIdentifier != nil {
            notifier = Notifier()
        }
        needsSetup = config.clusters.isEmpty || config.clusters.contains(where: \.needsSetup)
        guard !needsSetup else { return }
        clusters = config.clusters.map { c in
            ClusterModel(config: c, runner: mode == .demo ? DemoRunner() : RemoteShell(cluster: c), services: services,
                         auto: autoRefresh)
        }
        if mode == .demo {
            for c in clusters { services.seed("\(c.config.name)/abc123p/B2-REGULAR", Fixtures.history()) }
        }
        guard start else { return }
        if autoRefresh {
            clusters.forEach { $0.start() }
        } else {
            for c in clusters { Task { await c.checkConnection() } }
        }
    }

    func refreshAll() async {
        for c in clusters { await c.refreshAll() }
    }

    var menuBarText: String {
        if needsSetup { return "set up" }
        if configError != nil { return "config?" }
        guard autoRefresh else { return "" }  // with manual refresh, counts would go stale up there
        var parts: [String] = []
        for c in clusters {
            if c.connected == false {
                parts.append(clusters.count > 1 ? "\(c.config.name) offline" : "offline")
                continue
            }
            parts += c.widgets.compactMap { $0.menuBarText }
        }
        if unseenProblems > 0 { parts.append("✗\(unseenProblems)") }
        return parts.joined(separator: "  ")
    }

    func deliver(_ batch: FinishedBatch, cluster: String) {
        if batch.problems > 0 { unseenProblems += 1 }
        guard notificationsOn, let notifier else { return }
        let text = NotificationText.make(batch, cluster: clusters.count > 1 ? cluster : nil)
        notifier.post(title: text.title, body: text.body)
    }

    func popoverOpened() {
        unseenProblems = 0
        services.activity.panelOpen = true
        for c in clusters {
            if autoRefresh {
                c.refreshStale()
            } else {
                Task { await c.checkConnection() }  // only asks the local ssh socket, not the cluster
            }
        }
    }

    func popoverClosed() {
        services.activity.panelOpen = false
    }

    func saveSetup(host: String, user: String) {
        var config = ConfigStore.starter(host: host.trimmingCharacters(in: .whitespaces),
                                         user: user.trimmingCharacters(in: .whitespaces))
        if let existing = try? ConfigStore.load(configURL) { config.notifications = existing.notifications }
        do {
            try ConfigStore.save(config, to: configURL)
            load()
        } catch {
            configError = "Couldn't save \(configURL.path): \(error.localizedDescription)"
        }
    }

    func openConfig() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", configURL.path]
        try? p.run()
    }

    func setAutoRefresh(_ on: Bool) {
        guard mode == .live else { return }
        do {
            try ConfigStore.set("autoRefresh", to: on, in: configURL)
            load()
        } catch {
            configError = "Couldn't update \(configURL.path): \(error.localizedDescription)"
        }
    }

    func setOpensAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func sendTestNotification() {
        if notifier == nil, Bundle.main.bundleIdentifier != nil { notifier = Notifier() }
        notifier?.post(title: "✓ SlurmBar test", body: "You'll get one like this when a job finishes.")
    }
}
