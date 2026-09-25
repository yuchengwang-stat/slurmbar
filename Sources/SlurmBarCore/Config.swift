import Foundation

public struct AppConfig: Codable, Sendable {
    public var notifications: Bool?
    public var clusters: [ClusterConfig]

    public init(notifications: Bool? = true, clusters: [ClusterConfig]) {
        self.notifications = notifications
        self.clusters = clusters
    }
}

public struct ClusterConfig: Codable, Sendable, Identifiable {
    public var name: String
    public var host: String
    public var user: String?
    /// Socket of an ssh connection the user opened themselves. SlurmBar only ever joins it.
    public var controlPath: String?
    /// Used in the connect command SlurmBar suggests.
    public var controlPersist: String?
    public var sshOptions: [String]?
    /// A fixed interval for the jobs panel. Left out, it adapts: 5 minutes with jobs in the queue, 15 without.
    public var refreshSeconds: Int?
    public var widgets: [WidgetSpec]?

    public init(name: String, host: String, user: String? = nil, controlPath: String? = nil,
                controlPersist: String? = nil, sshOptions: [String]? = nil, refreshSeconds: Int? = nil,
                widgets: [WidgetSpec]? = nil) {
        self.name = name
        self.host = host
        self.user = user
        self.controlPath = controlPath
        self.controlPersist = controlPersist
        self.sshOptions = sshOptions
        self.refreshSeconds = refreshSeconds
        self.widgets = widgets
    }

    public var id: String { name }
    public var needsSetup: Bool { host.isEmpty || host.contains("YOUR_") || (user ?? "").contains("YOUR_") }

    public static func defaultWidgets(psc: Bool) -> [WidgetSpec] {
        if psc {
            return [WidgetSpec(type: "jobs"), WidgetSpec(type: "allocation"), WidgetSpec(type: "quota"),
                    WidgetSpec(type: "partition", options: ["partitions": "RM-shared"])]
        }
        return [WidgetSpec(type: "jobs"), WidgetSpec(type: "partition")]
    }
}

/// One panel in the popover. `type` picks the kind; the rest is optional.
public struct WidgetSpec: Codable, Sendable {
    public var type: String
    public var title: String?
    public var refreshSeconds: Int?
    public var command: String?
    public var menuBar: Bool?
    public var options: [String: String]?

    public init(type: String, title: String? = nil, refreshSeconds: Int? = nil, command: String? = nil,
                menuBar: Bool? = nil, options: [String: String]? = nil) {
        self.type = type
        self.title = title
        self.refreshSeconds = refreshSeconds
        self.command = command
        self.menuBar = menuBar
        self.options = options
    }

    public func option(_ key: String) -> String? { options?[key] }
}

public enum ConfigStore {
    /// ~/.config/slurmbar/config.json, or $SLURMBAR_CONFIG
    public static var url: URL {
        if let p = ProcessInfo.processInfo.environment["SLURMBAR_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slurmbar/config.json")
    }

    public static func load(_ url: URL) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    }

    public static func save(_ config: AppConfig, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(config).write(to: url, options: .atomic)
    }

    public static func starter(host: String = "YOUR_LOGIN_HOST", user: String = "YOUR_USERNAME") -> AppConfig {
        let name = host.split(separator: ".").first.map(String.init) ?? "cluster"
        return AppConfig(notifications: true, clusters: [
            ClusterConfig(name: name, host: host, user: user, controlPath: "~/.ssh/slurmbar-%r@%h",
                          controlPersist: "12h", widgets: ClusterConfig.defaultWidgets(psc: host.hasSuffix("psc.edu"))),
        ])
    }
}
