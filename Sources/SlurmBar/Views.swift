import AppKit
import SlurmBarCore
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let text = model.menuBarText
        if text.isEmpty {
            Image(systemName: "server.rack")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                Text(text).monospacedDigit()
            }
        }
    }
}

struct PopoverView: View {
    let model: AppModel
    var renderMode = false
    var inWindow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.needsSetup {
                SetupView(model: model)
            } else if let message = model.configError {
                ConfigErrorView(model: model, message: message)
            } else if renderMode {
                clusters
            } else {
                FitScroll(maxHeight: 640) { clusters }
            }
            Divider()
            Footer(model: model)
            if inWindow {
                Text("This is the same panel as SlurmBar's menu bar icon, a small server rack at the top right. If a notch hides the icon, open SlurmBar again and this window comes back.")
                    .caption()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 380)
        .onAppear { if !renderMode { model.popoverOpened() } }
        .onDisappear { if !renderMode { model.popoverClosed() } }
    }

    var clusters: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.clusters) { c in
                ClusterSection(cluster: c)
                if c.id != model.clusters.last?.id { Divider() }
            }
        }
    }
}

struct ClusterSection: View {
    let cluster: ClusterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClusterHeader(cluster: cluster)
            if cluster.connected == false {
                ConnectBanner(cluster: cluster).padding(.horizontal, 14).padding(.bottom, 10)
            }
            ForEach(cluster.widgets.indices, id: \.self) { i in
                Divider().padding(.horizontal, 14).opacity(0.7)
                cluster.widgets[i].view
            }
        }
    }
}

struct ClusterHeader: View {
    let cluster: ClusterModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(cluster.config.name).font(.system(size: 13, weight: .semibold))
            Text(cluster.config.user ?? cluster.config.host)
                .caption()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                Text(cluster.lastSuccess == nil ? "" : "updated \(Ago.text(cluster.lastSuccess, now: ctx.date))").caption()
            }
            if isSnapshot {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await cluster.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(cluster.refreshing)
                .help("Refresh now")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    var dot: Color {
        switch cluster.connected {
        case true?: return .green
        case false?: return .red
        default: return .gray
        }
    }
}

struct ConnectBanner: View {
    let cluster: ClusterModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not connected", systemImage: "bolt.horizontal.circle").font(.system(size: 12, weight: .semibold))
            Text(cluster.canConnect
                 ? "SlurmBar joins an ssh connection you open yourself. Sign in once in Terminal and it picks the connection up."
                 : "ssh couldn't log in without a password, so SlurmBar stopped trying. Add a controlPath to the config or set up key-based login, then press refresh.")
                .caption()
                .fixedSize(horizontal: false, vertical: true)
            if cluster.canConnect {
                HStack(spacing: 8) {
                    Button("Connect in Terminal") { cluster.openConnectInTerminal() }
                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cluster.connectCommand, forType: .string)
                        copied = true
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.13)))
    }
}

struct SetupView: View {
    let model: AppModel
    @State private var host = "bridges2.psc.edu"
    @State private var user = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up SlurmBar").font(.headline)
            Text("Which cluster should it watch? SlurmBar runs squeue and friends over ssh, through a connection you open yourself. It never sees your password.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Login host", text: $host).textFieldStyle(.roundedBorder)
            TextField("Username", text: $user).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") { model.saveSetup(host: host, user: user) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || user.isEmpty)
                Button("Edit the config file instead") { model.openConfig() }.buttonStyle(.link)
            }
        }
        .padding(14)
    }
}

struct ConfigErrorView: View {
    let model: AppModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Config problem", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message).caption().fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

struct Footer: View {
    let model: AppModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // ImageRenderer can't draw AppKit controls, so the README images get look-alikes
            HStack(spacing: 12) {
                Text("Open config")
                Text("Reload")
                Spacer()
                Image(systemName: "gearshape")
                Text("Quit")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        } else {
            buttons
        }
    }

    var buttons: some View {
        HStack(spacing: 12) {
            Button("Open config") { model.openConfig() }
            Button("Reload") { model.load() }
            Spacer()
            Menu {
                Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                Button("Send a test notification") { model.sendTestNotification() }
                Divider()
                Button("SlurmBar on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/yuchengwang-stat/slurmbar")!)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: shared pieces

struct Panel<Content: View>: View {
    let title: String
    var trailing: String?
    let status: WidgetStatus
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).caption().lineLimit(1) }
            }
            if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SubHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 3)
    }
}

struct Bar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(tint).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

/// A scroll view that is only as tall as its content, up to maxHeight.
struct FitScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 320

    var body: some View {
        ScrollView {
            content.background(GeometryReader { g in
                Color.clear.preference(key: HeightKey.self, value: g.size.height)
            })
        }
        .frame(height: min(height, maxHeight))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

extension View {
    func caption() -> some View { font(.system(size: 11)).foregroundStyle(.secondary) }
}

enum Ago {
    static func text(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = Int(now.timeIntervalSince(date))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
}

enum Fmt {
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }
    static func int(_ v: Double) -> String { Int(v.rounded()).formatted() }

    /// 1.6M, 318M, 7.4k, 740
    static func compact(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e6 { return String(format: a >= 1e8 ? "%.0fM" : "%.1fM", v / 1e6) }
        if a >= 1e3 { return String(format: a >= 1e5 ? "%.0fk" : "%.1fk", v / 1e3) }
        return String(Int(v.rounded()))
    }
}
