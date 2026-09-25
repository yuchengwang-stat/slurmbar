import Foundation

/// Anything that can run a command on the cluster. The app uses ssh; demo mode and tests use canned output.
public protocol CommandRunner: Sendable {
    func run(_ command: String) async throws -> String
    func isConnected() async -> Bool
}

public enum ShellError: Error, LocalizedError {
    case failed(status: Int32, message: String)
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .failed(_, let message): return message
        case .timedOut(let s): return "No answer from the cluster after \(s)s"
        }
    }

    /// ssh exits with 255 when it could not connect at all.
    public var isConnectionProblem: Bool {
        switch self {
        case .failed(let status, _): return status == 255
        case .timedOut: return true
        }
    }

    /// The server turned the login down, as opposed to the network being away.
    public var isLoginRefused: Bool {
        if case .failed(255, let message) = self { return message.contains("Permission denied") }
        return false
    }
}

/// Runs commands with the system ssh. It never asks for a password: BatchMode makes ssh fail instead,
/// so logging in (password, 2FA) always happens in a terminal the user controls.
public struct RemoteShell: CommandRunner {
    public var host: String
    public var user: String?
    public var controlPath: String?
    public var controlPersist: String
    public var extraOptions: [String]
    public var timeout: TimeInterval

    public init(host: String, user: String? = nil, controlPath: String? = nil, controlPersist: String = "12h",
                extraOptions: [String] = [], timeout: TimeInterval = 40) {
        self.host = host
        self.user = user
        self.controlPath = controlPath
        self.controlPersist = controlPersist
        self.extraOptions = extraOptions
        self.timeout = timeout
    }

    public init(cluster c: ClusterConfig) {
        self.init(host: c.host, user: c.user, controlPath: c.controlPath, controlPersist: c.controlPersist ?? "12h",
                  extraOptions: c.sshOptions ?? [])
    }

    public var destination: String {
        if let u = user, !u.isEmpty { return "\(u)@\(host)" }
        return host
    }

    var hasControlPath: Bool { !(controlPath ?? "").isEmpty }

    public var arguments: [String] {
        var o = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
        if hasControlPath {
            // Only ever join the connection the user opened. If it's gone, ProxyCommand=false makes
            // ssh fail at once instead of trying to log in, since a stream of failed logins can get
            // an IP blocked.
            o += ["-o", "ControlPath=\(controlPath!)", "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false"]
        } else {
            // a master that ssh backgrounds on its own would keep our pipes open
            o += ["-o", "ControlPersist=no"]
        }
        return o + extraOptions
    }

    public func run(_ command: String) async throws -> String {
        Self.log("\(destination) \(command)")
        let r = try await Subprocess.run("/usr/bin/ssh", arguments + [destination, command], timeout: timeout)
        guard r.status == 0 else {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.failed(status: r.status, message: msg.isEmpty ? "ssh exited with \(r.status)" : msg)
        }
        return r.stdout
    }

    public func isConnected() async -> Bool {
        if hasControlPath {
            let r = try? await Subprocess.run("/usr/bin/ssh", ["-o", "ControlPath=\(controlPath!)", "-O", "check", destination],
                                              timeout: 5)
            return r?.status == 0
        }
        return (try? await run("true")) != nil
    }

    /// What the user runs once, in a terminal, to open the shared connection.
    public var connectCommand: String {
        var parts = ["ssh", "-fN"]
        if hasControlPath {
            parts += ["-o", "ControlMaster=yes", "-o", "ControlPath=\(Self.quote(controlPath!))",
                      "-o", "ControlPersist=\(Self.quote(controlPersist))"]
        }
        parts += extraOptions.map(Self.quote)
        parts.append(Self.quote(destination))
        return parts.joined(separator: " ")
    }

    public func disconnect() async {
        guard hasControlPath else { return }
        _ = try? await Subprocess.run("/usr/bin/ssh", ["-o", "ControlPath=\(controlPath!)", "-O", "exit", destination], timeout: 5)
    }

    /// With SLURMBAR_LOG=/some/file, every command sent to a cluster is appended there, for anyone
    /// who wants to see exactly what SlurmBar runs and how often.
    static func log(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["SLURMBAR_LOG"], !path.isEmpty else { return }
        let bytes = Array("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        // O_APPEND keeps lines whole when several panels refresh at the same moment
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./@=:%,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum Subprocess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    final class Box: @unchecked Sendable {
        var out = Data()
        var err = Data()
        var timedOut = false
    }

    /// Runs a program and collects its output. Both pipes are drained while it runs,
    /// so a long sacct listing can't fill a pipe and stall ssh.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let box = Box()
            let group = DispatchGroup()
            group.enter()
            group.enter()
            p.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    if box.timedOut {
                        cont.resume(throwing: ShellError.timedOut(seconds: Int(timeout)))
                    } else {
                        cont.resume(returning: Output(status: proc.terminationStatus,
                                                      stdout: String(decoding: box.out, as: UTF8.self),
                                                      stderr: String(decoding: box.err, as: UTF8.self)))
                    }
                }
            }
            do {
                try p.run()
            } catch {
                group.leave()
                group.leave()
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().async {
                box.out = out.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            DispatchQueue.global().async {
                box.err = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    box.timedOut = true
                    p.terminate()
                }
            }
        }
    }
}
