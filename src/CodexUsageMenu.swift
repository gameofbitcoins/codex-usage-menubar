import Cocoa
import Foundation
import Darwin

private struct UsageWindow {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: TimeInterval?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var label: String {
        guard let minutes = durationMinutes else { return "Limit" }
        if minutes % 10080 == 0 { return "\(minutes / 10080)w" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

private struct UsageSnapshot {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let resetCredits: Int?
    let fetchedAt: Date
}

private enum MonitorError: LocalizedError {
    case codexNotFound
    case appServerExited(String)
    case invalidResponse(String)
    case rpc(String)
    case noRateLimits

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "No Codex app-server binary was found. Install/update the ChatGPT or Codex desktop app, or install the Codex CLI."
        case .appServerExited(let details):
            return details.isEmpty ? "Codex app-server exited before returning usage." : "Codex app-server exited: \(details)"
        case .invalidResponse(let details):
            return "Unexpected Codex response: \(details)"
        case .rpc(let details):
            return "Codex returned an error: \(details)"
        case .noRateLimits:
            return "Codex did not return a 5-hour or weekly usage window."
        }
    }
}

private final class JSONLineReader {
    private let fd: Int32
    private var buffer = Data()

    init(handle: FileHandle) {
        self.fd = handle.fileDescriptor
    }

    func nextObject() throws -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)

                guard !line.isEmpty else { continue }
                let value = try JSONSerialization.jsonObject(with: Data(line))
                if let object = value as? [String: Any] {
                    return object
                }
                continue
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &bytes, bytes.count)

            if count > 0 {
                buffer.append(contentsOf: bytes[0..<count])
                continue
            }

            if count == 0 {
                if buffer.isEmpty { return nil }
                let value = try JSONSerialization.jsonObject(with: buffer)
                buffer.removeAll()
                return value as? [String: Any]
            }

            if errno == EINTR {
                continue
            }

            throw MonitorError.invalidResponse(
                "read from Codex app-server failed: \(String(cString: strerror(errno)))"
            )
        }
    }

    func response(id: Int) throws -> [String: Any] {
        while let object = try nextObject() {
            if let responseID = object["id"] as? NSNumber, responseID.intValue == id {
                if let error = object["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? String(describing: error)
                    throw MonitorError.rpc(message)
                }
                return object
            }
            // Notifications are expected and intentionally ignored here.
        }
        throw MonitorError.invalidResponse(
            "app-server connection closed while waiting for response \(id)"
        )
    }
}

private final class CodexUsageService {
    private func appServerLogHandle() -> FileHandle? {
        let fm = FileManager.default
        let logs = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        let file = logs.appendingPathComponent("CodexUsage-appserver.log")

        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: file) else {
            return nil
        }
        _ = try? handle.seekToEnd()

        let stamp = "\n--- \(ISO8601DateFormatter().string(from: Date())) app-server launch ---\n"
        if let data = stamp.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        return handle
    }

    func fetch() throws -> UsageSnapshot {
        let codexPath = try resolveCodexPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "stdio://"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderrHandle = appServerLogHandle()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderrHandle ?? FileHandle.nullDevice

        try process.run()

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: timeout)

        defer {
            timeout.cancel()
            try? stdin.fileHandleForWriting.close()
            try? stderrHandle?.close()
            if process.isRunning {
                process.terminate()
            }
        }

        let reader = JSONLineReader(handle: stdout.fileHandleForReading)

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex_usage_menubar",
                    "title": "Codex Usage Menu",
                    "version": "1.0.10"
                ],
                "capabilities": [
                    "experimentalApi": false
                ]
            ]
        ], to: stdin.fileHandleForWriting)

        _ = try reader.response(id: 1)

        try send([
            "method": "initialized"
        ], to: stdin.fileHandleForWriting)

        try send([
            "id": 2,
            "method": "account/rateLimits/read"
        ], to: stdin.fileHandleForWriting)

        let response = try reader.response(id: 2)

        guard let result = response["result"] as? [String: Any] else {
            if !process.isRunning {
                throw MonitorError.appServerExited(
                    "See ~/Library/Logs/CodexUsage-appserver.log for backend details."
                )
            }
            throw MonitorError.invalidResponse("missing result")
        }

        // Prefer the explicit shared Codex bucket when available. This prevents
        // model-specific buckets from being mistaken for the main account quota.
        var bucket: [String: Any]?
        if let byID = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] as? [String: Any] {
            bucket = codex
        }
        if bucket == nil {
            bucket = result["rateLimits"] as? [String: Any]
        }

        guard let rateLimits = bucket else {
            throw MonitorError.invalidResponse("missing rateLimits")
        }

        let primary = parseWindow(rateLimits["primary"])
        let secondary = parseWindow(rateLimits["secondary"])

        if primary == nil && secondary == nil {
            throw MonitorError.noRateLimits
        }

        var creditCount: Int?
        if let credits = result["rateLimitResetCredits"] as? [String: Any],
           let count = credits["availableCount"] as? NSNumber {
            creditCount = count.intValue
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            resetCredits: creditCount,
            fetchedAt: Date()
        )
    }

    private func parseWindow(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = object["usedPercent"] as? NSNumber else {
            return nil
        }

        let duration = (object["windowDurationMins"] as? NSNumber)?.intValue
        let reset = (object["resetsAt"] as? NSNumber)?.doubleValue

        return UsageWindow(
            usedPercent: used.intValue,
            durationMinutes: duration,
            resetsAt: reset
        )
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)

        let fd = handle.fileDescriptor
        try line.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }

            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )

                if written > 0 {
                    offset += written
                    continue
                }

                if written < 0 && errno == EINTR {
                    continue
                }

                throw MonitorError.invalidResponse(
                    "write to Codex app-server failed: \(String(cString: strerror(errno)))"
                )
            }
        }
    }

    private func resolveCodexPath() throws -> String {
        let fm = FileManager.default

        // Best source: the installer records the exact executable path while
        // running inside the user's Terminal environment.
        let recorded = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Usage/codex-path")

        if let contents = try? String(contentsOf: recorded, encoding: .utf8) {
            let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        let known = [
            // Current ChatGPT/Codex desktop apps bundle the local app-server
            // executable here. Prefer these before requiring a standalone CLI.
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex",

            // Standalone Codex installs.
            NSHomeDirectory() + "/.codex/packages/standalone/current/codex",
            NSHomeDirectory() + "/.codex/packages/standalone/current/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            NSHomeDirectory() + "/.npm-global/bin/codex",
            NSHomeDirectory() + "/bin/codex"
        ]

        for path in known where fm.isExecutableFile(atPath: path) {
            return path
        }

        // GUI apps don't inherit Terminal's PATH. Use an interactive login zsh
        // so setups from .zprofile/.zshrc (nvm, fnm, asdf, Homebrew, etc.) load.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-ilc", "command -v codex 2>/dev/null || true"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = Pipe()

        try? shell.run()
        shell.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""

        // Startup scripts can print extra lines; choose the last executable path.
        for raw in text.split(separator: "\n").reversed() {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("/"), fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw MonitorError.codexNotFound
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = CodexUsageService()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var lastSnapshot: UsageSnapshot?

    private let launchAgentLabel = "com.codexusage.menubar"

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private var launchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log("applicationDidFinishLaunching")

        // Creating NSStatusItem during AppDelegate property initialization can be
        // too early for a hand-built app bundle. Create it only after Cocoa has
        // completed application launch.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.menu = menu

        if let button = statusItem.button {
            button.title = "Codex…"
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
            button.toolTip = "Codex usage"
        }

        rebuildMenu(message: "Loading usage…")

        refreshTimer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )

        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("applicationWillTerminate")
        refreshTimer?.invalidate()
    }

    @objc private func timerFired() {
        refresh()
    }

    @objc private func refreshClicked() {
        refresh()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func launchAtLoginClicked(_ sender: NSMenuItem) {
        do {
            try setLaunchAtLogin(!launchAtLoginEnabled)
            sender.state = launchAtLoginEnabled ? .on : .off
            log("Launch at Login set to \(launchAtLoginEnabled)")
        } catch {
            log("Launch at Login update failed: \(error.localizedDescription)")
            rebuildMenu(message: "Couldn’t update Launch at Login: \(error.localizedDescription)")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) throws {
        let fm = FileManager.default
        let url = launchAgentURL

        if !enabled {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            return
        }

        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let appPath = Bundle.main.bundlePath
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [
                "/usr/bin/open",
                "-g",
                appPath
            ],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        log("refresh started")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try self.service.fetch()
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.lastSnapshot = snapshot
                    self.log("refresh succeeded")
                    self.apply(snapshot)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.log("refresh failed: \(error.localizedDescription)")
                    self.apply(error: error)
                }
            }
        }
    }

    private func apply(_ snapshot: UsageSnapshot) {
        var percentages: [String] = []
        if let primary = snapshot.primary {
            percentages.append("\(primary.remainingPercent)%")
        }
        if let secondary = snapshot.secondary {
            percentages.append("\(secondary.remainingPercent)%")
        }

        statusItem.button?.title = percentages.isEmpty
            ? "Codex—"
            : "Codex " + percentages.joined(separator: "·")

        menu.removeAllItems()

        addWindow(snapshot.primary)
        if snapshot.primary != nil && snapshot.secondary != nil {
            menu.addItem(.separator())
        }
        addWindow(snapshot.secondary)

        if let credits = snapshot.resetCredits, credits > 0 {
            menu.addItem(.separator())
            let title = "\(credits) reset credit" + (credits == 1 ? "" : "s")
            menu.addItem(disabledItem(title))
        }

        menu.addItem(.separator())
        let updated = RelativeDateTimeFormatter().localizedString(
            for: snapshot.fetchedAt,
            relativeTo: Date()
        )
        menu.addItem(disabledItem("Updated \(updated)"))

        addActions()
    }

    private func apply(error: Error) {
        statusItem.button?.title = "Codex—"
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        rebuildMenu(message: message)
    }

    private func addWindow(_ window: UsageWindow?) {
        guard let window else { return }

        let title = "\(window.label): \(window.remainingPercent)% left"
        menu.addItem(disabledItem(title))

        if let resetsAt = window.resetsAt {
            let date = Date(timeIntervalSince1970: resetsAt)
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
            formatter.timeStyle = .short

            let relative = relativeReset(date)
            menu.addItem(disabledItem("Resets \(formatter.string(from: date)) · \(relative)"))
        }
    }

    private func relativeReset(_ date: Date) -> String {
        let interval = max(0, Int(date.timeIntervalSinceNow))
        let days = interval / 86400
        let hours = (interval % 86400) / 3600
        let minutes = (interval % 3600) / 60

        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }

    private func rebuildMenu(message: String) {
        menu.removeAllItems()
        menu.addItem(disabledItem(message))
        menu.addItem(.separator())
        addActions()
    }

    private func addActions() {
        let refresh = NSMenuItem(
            title: isRefreshing ? "Refreshing…" : "Refresh Now",
            action: #selector(refreshClicked),
            keyEquivalent: "r"
        )
        refresh.target = self
        refresh.isEnabled = !isRefreshing
        menu.addItem(refresh)

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(launchAtLoginClicked(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLogin)

        let quit = NSMenuItem(
            title: "Quit Codex Usage",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func log(_ message: String) {
        let fm = FileManager.default
        let logs = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        let file = logs.appendingPathComponent("CodexUsage.log")

        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if fm.fileExists(atPath: file.path),
           let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// A child app-server can close stdin while starting up. By default, a write to
// that closed pipe terminates the entire menu-bar app with SIGPIPE. Ignore the
// signal so FileHandle.write surfaces an ordinary error that our UI can show.
signal(SIGPIPE, SIG_IGN)

// Explicit application entry point. Keeping a strong reference to the delegate
// makes this hand-built menu-bar bundle behave the same way as an Xcode app.
let application = NSApplication.shared
private let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
