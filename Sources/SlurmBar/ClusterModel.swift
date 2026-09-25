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
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var busy: Set<ObjectIdentifier> = []

    nonisolated var id: String { config.name }

    init(config: ClusterConfig, runner: CommandRunner, services: Services) {
        self.config = config
        self.runner = runner
        widgets = (config.widgets ?? ClusterConfig.defaultWidgets(psc: config.host.hasSuffix("psc.edu")))
            .map { WidgetFactory.make($0, cluster: config, services: services) }
    }

    /// Each panel refreshes on its own clock.
    func start() {
        stop()
        for w in widgets where w.usesCluster {
            loops.append(Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh(w)
                    try? await Task.sleep(for: .seconds(w.interval))
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
        } catch {
            w.status.error = error.localizedDescription
        }
    }

    func refreshAll() async {
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for w in widgets where w.usesCluster {
                group.addTask { await self.refresh(w) }
            }
        }
    }

    func refreshJobs(ifOlderThan seconds: TimeInterval) {
        for w in widgets where w is JobsWidget {
            if let t = w.status.lastUpdated, Date().timeIntervalSince(t) < seconds { continue }
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
