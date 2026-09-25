import AppKit
import SlurmBarCore
import SwiftUI

@MainActor @Observable
final class ClusterModel: Identifiable {
    let config: ClusterConfig
    let runner: CommandRunner
    let widgets: [any ClusterWidget]
    var connected: Bool?
    var lastSuccess: Date?
    var refreshing = false
    /// Set when a direct login (no control socket) was refused. Background polling then stops until
    /// the user refreshes by hand, so SlurmBar never piles up failed logins.
    var loginRefused = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var busy: Set<ObjectIdentifier> = []
    @ObservationIgnored private let activity: Activity

    nonisolated var id: String { config.name }

    init(config: ClusterConfig, runner: CommandRunner, services: Services) {
        self.config = config
        self.runner = runner
        activity = services.activity
        widgets = (config.widgets ?? ClusterConfig.defaultWidgets(psc: config.host.hasSuffix("psc.edu")))
            .map { WidgetFactory.make($0, cluster: config, services: services) }
    }

    /// Panels with a background interval refresh on their own clock; the others wait for the panel
    /// to open. Nothing runs while the screen is locked or asleep.
    func start() {
        stop()
        for w in widgets where w.usesCluster && w.backgroundInterval != nil {
            loops.append(Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if !self.loginRefused, !self.activity.paused { await self.refresh(w) }
                    try? await Task.sleep(for: .seconds(w.backgroundInterval ?? 3600))
                }
            })
        }
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops = []
    }

    func refresh(_ w: any ClusterWidget) async {
        let key = ObjectIdentifier(w)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        w.status.loading = true
        defer {
            busy.remove(key)
            w.status.loading = false
        }
        do {
            try await w.refresh(runner)
            w.status.lastUpdated = Date()
            w.status.error = nil
            connected = true
            lastSuccess = Date()
        } catch let e as ShellError where e.isConnectionProblem {
            connected = false  // the banner explains; no need to repeat it in every panel
            if !canConnect, e.isLoginRefused { loginRefused = true }
        } catch {
            w.status.error = error.localizedDescription
        }
    }

    /// The refresh button and a new connection refresh everything. Catching up after a lock or
    /// sleep (`background`) leaves out the panels that only refresh while the panel is open.
    func refreshAll(background: Bool = false) async {
        if background, loginRefused { return }
        loginRefused = false
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for w in widgets where w.usesCluster && (!background || w.backgroundInterval != nil) {
                group.addTask { await self.refresh(w) }
            }
        }
    }

    /// When the panel opens, refresh whatever is out of date.
    func refreshStale() {
        guard !loginRefused else { return }
        for w in widgets where w.usesCluster {
            if let t = w.status.lastUpdated, Date().timeIntervalSince(t) < Double(w.staleAfter) { continue }
            Task { await refresh(w) }
        }
    }

    // MARK: connection

    var shell: RemoteShell? { runner as? RemoteShell }
    var connectCommand: String { shell?.connectCommand ?? "" }
    var canConnect: Bool { !(config.controlPath ?? "").isEmpty }

    /// Opens Terminal with the ssh command. The password and 2FA go into Terminal, never into SlurmBar.
    func openConnectInTerminal() {
        let safeName = config.name.filter { $0.isLetter || $0.isNumber }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("slurmbar-connect-\(safeName).command")
        let script = """
        #!/bin/bash
        echo "SlurmBar: opening a shared ssh connection to \(config.host)."
        echo "Sign in below. SlurmBar never sees your password."
        echo
        \(connectCommand) && echo && echo "Connected. You can close this window."
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(url)
        Task { await waitForConnection() }
    }

    func waitForConnection() async {
        for _ in 0..<100 {
            try? await Task.sleep(for: .seconds(3))
            if await runner.isConnected() {
                await refreshAll()
                return
            }
        }
    }

    func disconnect() async {
        await shell?.disconnect()
        connected = false
    }
}
