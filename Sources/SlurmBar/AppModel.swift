import AppKit
import ServiceManagement
import SlurmBarCore
import SwiftUI

@MainActor @Observable
final class AppModel {
    enum Mode { case live, demo }

    let mode: Mode
    let configURL: URL
    var clusters: [ClusterModel] = []
    var configError: String?
    var needsSetup = false
    var unseenProblems = 0
    var notificationsOn = true
    var opensAtLogin = false
    @ObservationIgnored let services: Services
    @ObservationIgnored private var notifier: Notifier?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(mode: Mode, autostart: Bool = true) {
        self.mode = mode
        configURL = ConfigStore.url
        services = Services(historyURL: mode == .live
                            ? configURL.deletingLastPathComponent().appendingPathComponent("history.json") : nil)
        services.notify = { [weak self] batch, cluster in self?.deliver(batch, cluster: cluster) }
        if Bundle.main.bundleIdentifier != nil { opensAtLogin = SMAppService.mainApp.status == .enabled }
        load(start: autostart)
        if mode == .live {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshAll() }
            }
        }
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
        notificationsOn = config.notifications ?? true
        if mode == .live, notificationsOn, notifier == nil, Bundle.main.bundleIdentifier != nil {
            notifier = Notifier()
        }
        needsSetup = config.clusters.isEmpty || config.clusters.contains(where: \.needsSetup)
        guard !needsSetup else { return }
        clusters = config.clusters.map { c in
            ClusterModel(config: c, runner: mode == .demo ? DemoRunner() : RemoteShell(cluster: c), services: services)
        }
        if mode == .demo {
            for c in clusters { services.seed("\(c.config.name)/abc123p/B2-REGULAR", Fixtures.history()) }
        }
        if start { clusters.forEach { $0.start() } }
    }

    func refreshAll() async {
        for c in clusters { await c.refreshAll() }
    }

    var menuBarText: String {
        if needsSetup { return "set up" }
        if configError != nil { return "config?" }
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
        for c in clusters { c.refreshJobs(ifOlderThan: 60) }
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

    func setOpensAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func sendTestNotification() {
        if notifier == nil, Bundle.main.bundleIdentifier != nil { notifier = Notifier() }
        notifier?.post(title: "✓ SlurmBar test", body: "You'll get one like this when a job finishes.")
    }
}
