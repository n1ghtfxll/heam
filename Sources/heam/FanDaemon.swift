import Darwin
import Foundation

/// Fan writes need root. On first use the app installs a copy of its own binary as a
/// LaunchDaemon (one admin prompt) and talks to it over a Unix socket owned by the user.
///
/// Protocol, one line per connection:
///   set <rpm>,<rpm>,...   manual targets per fan
///   auto                  hand control back to macOS
///   ping                  replies "ok <version>"
enum FanDaemon {
    static let socketPath = "/var/run/heam-fan.sock"
    /// Without a heartbeat for this long, assume the app died and restore automatic control.
    static let heartbeatTimeout: TimeInterval = 20
    /// Bump when the protocol or fan logic changes so the app reinstalls the helper.
    static let version = 3

    static func run(ownerUID: uid_t) -> Never {
        guard getuid() == 0 else {
            FileHandle.standardError.write("heam: --fan-daemon must run as root\n".data(using: .utf8)!)
            exit(1)
        }
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in Fans.setAutomatic(); unlink(FanDaemon.socketPath); exit(0) }
        }

        unlink(socketPath)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = unixAddress(socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard server >= 0, bound == 0, listen(server, 4) == 0 else { exit(1) }
        chown(socketPath, ownerUID, gid_t.max)
        chmod(socketPath, 0o600)

        var manual = false
        var lastHeartbeat = Date()
        while true {
            var pfd = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 1000) > 0 {
                let client = accept(server, nil, nil)
                if client >= 0 {
                    let command = readLine(client)
                    lastHeartbeat = Date()
                    let reply: String
                    switch command.split(separator: " ").first {
                    case "set":
                        let targets = command.dropFirst(4).split(separator: ",").compactMap { Double($0) }
                        let ok = manual ? Fans.setTargets(targets) : Fans.setManual(targets)
                        manual = true
                        reply = ok ? "ok" : "error"
                    case "auto":
                        manual = false
                        Fans.setAutomatic()
                        reply = "ok"
                    case "ping":
                        reply = "ok \(version)"
                    default:
                        reply = "ok"
                    }
                    _ = writeAll(client, reply + "\n")
                    close(client)
                }
            }
            if manual, Date().timeIntervalSince(lastHeartbeat) > heartbeatTimeout {
                manual = false
                Fans.setAutomatic()
            }
        }
    }
}

enum FanClient {
    /// Sends one command to the daemon. Returns its reply, or nil if it is not running.
    @discardableResult
    static func send(_ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = unixAddress(FanDaemon.socketPath)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, writeAll(fd, command + "\n") else { return nil }
        return readLine(fd)
    }

    static let label = "is.bored.heam.fanhelper"
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    /// The installed helper is running and speaks this build's protocol.
    static var isCurrent: Bool { send("ping") == "ok \(FanDaemon.version)" }

    /// Copies this binary to a root-owned location and registers it with launchd.
    /// Root-owned matters: a root daemon must never run a file the user (or malware) can rewrite.
    static func installHelper() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperPath, "--fan-daemon", String(getuid())],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: staged)) != nil else { return false }
        let script = [
            "launchctl bootout system/\(label) 2>/dev/null",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(quote(exe)) \(helperPath)",
            "chown root:wheel \(helperPath)",
            "chmod 755 \(helperPath)",
            "cp \(quote(staged.path)) \(plistPath)",
            "chown root:wheel \(plistPath)",
            "chmod 644 \(plistPath)",
            "launchctl bootstrap system \(plistPath)",
        ].joined(separator: "; ")
        guard runAsAdmin(script) else { return false }
        for _ in 0..<50 {
            if isCurrent { return true }
            usleep(100_000)
        }
        return false
    }

    static func uninstallHelper() -> Bool {
        send("auto")
        return runAsAdmin("launchctl bootout system/\(label) 2>/dev/null; rm -f \(plistPath) \(helperPath) \(FanDaemon.socketPath)")
    }

    /// Runs a shell command through the standard administrator password prompt.
    private static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0 // non-zero when the user cancels
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Socket helpers

private func unixAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        path.utf8CString.withUnsafeBytes { src in
            dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dst.count - 1)))
        }
    }
    return addr
}

private func writeAll(_ fd: Int32, _ string: String) -> Bool {
    let bytes = Array(string.utf8)
    return bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
}

private func readLine(_ fd: Int32) -> String {
    var timeout = timeval(tv_sec: 10, tv_usec: 0) // setManual can take a few seconds
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var data = [UInt8]()
    var byte: UInt8 = 0
    while data.count < 1024, read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
        data.append(byte)
    }
    return String(decoding: data, as: UTF8.self)
}
