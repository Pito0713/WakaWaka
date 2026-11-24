import Foundation

/// Brings the terminal an agent is running in to the front.
///
/// A pid does not reach a window in one hop. An agent inside tmux shares its
/// pane's tty, and that pane is only on screen if some client is attached to
/// the session — the window to raise then belongs to the *client*, not to the
/// agent, and the pane still has to be selected first. Both hops are resolved
/// here.
///
/// Everything that reaches a command line or a script is checked before it gets
/// there. tmux session and window names are user-authored and can contain
/// anything, so targets are addressed by tmux's own ids (`$3`, `@7`, `%2`) and
/// command-bearing AppleScript is built from integers only. The custom title
/// is the sole external text interpolated into a script, and only after
/// `isSafeForAppleScriptLiteral` rejects literal-breaking characters.
enum AgentWindowFocus {
    enum Outcome: Equatable {
        case focused
        /// The agent exited between the last scan and the click.
        case gone
        /// The process has no controlling terminal (launched by a daemon, say).
        case noTTY
        /// A terminal WakaWaka cannot drive — VS Code's panel, another emulator.
        case unknownTerminal
        /// The session was reached, but its current window was left where it
        /// was. Reported rather than done silently: the user asked to see one
        /// window and is looking at another, and that needs saying.
        case sharedSession
        case failed(String)

        var message: String? {
            switch self {
            case .focused:         return nil
            case .gone:            return "這個 agent 已經結束了"
            case .noTTY:           return "這個 agent 沒有終端機"
            case .unknownTerminal: return "找不到對應的 Terminal 視窗（僅支援 Terminal.app 與 tmux）"
            case .sharedSession:   return "已跳到該 session；還有其他 client 在看，沒有替你切換 window"
            case .failed(let why): return why
            }
        }
    }

    // MARK: - Entry point

    /// Blocking; callers run it off the main thread.
    ///
    /// Identity is re-checked here rather than trusted from the row: entries
    /// younger than the liveness grace period are never pid-verified, so a row
    /// can be up to a minute stale. Clicking one whose process has exited and
    /// whose pid has been recycled would raise an unrelated window.
    static func focus(_ row: ActiveAgentRow) -> Outcome {
        guard ProcessLiveness.check(pid: row.pid, startedAt: row.pidStartedAt) != .gone else {
            return .gone
        }
        return focus(pid: row.pid, viewTitle: viewTitle(for: row))
    }

    static func focus(pid: Int32, viewTitle: String? = nil) -> Outcome {
        guard let agentTTY = controllingTTY(of: pid) else { return .noTTY }

        guard let pane = tmuxPane(forTTY: agentTTY) else {
            return raiseTerminalTab(tty: agentTTY)
        }

        return focusOriginalTmuxSession(pane, viewTitle: viewTitle)
    }

    static func viewTitle(for row: ActiveAgentRow) -> String {
        let candidate = String("\(row.projectName) · \(row.kind.displayName)".prefix(60))
        if isSafeForAppleScriptLiteral(candidate) { return candidate }

        // AgentKind supplies this fallback, so an unsafe directory name never
        // prevents the more important action of opening the agent's terminal.
        let fallback = String(row.kind.displayName.prefix(60))
        return isSafeForAppleScriptLiteral(fallback) ? fallback : ""
    }

    // MARK: - pid → tty

    static let ttyPattern = try! NSRegularExpression(pattern: "^/dev/tty[a-zA-Z0-9]+$")

    static func isValidTTY(_ path: String) -> Bool { matches(ttyPattern, path) }

    static func controllingTTY(of pid: Int32) -> String? {
        // `ps` prints the short form ("ttys002") and "??" when there is none.
        guard let out = run("/bin/ps", ["-p", String(pid), "-o", "tty="]) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "??" else { return nil }
        let path = name.hasPrefix("/") ? name : "/dev/\(name)"
        return isValidTTY(path) ? path : nil
    }

    // MARK: - Process helper

    /// Runs a command with arguments as argv — never through a shell — and
    /// returns stdout, or nil if it failed, timed out, or could not start.
    static func run(_ executable: String, _ arguments: [String],
                            timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // Drained on another thread. Reading inline would block until EOF, which
        // for a hung child never comes — the deadline below could then never be
        // reached, and a stuck `tmux` or `osascript` would pin this worker
        // forever. Draining also keeps a chatty child from filling the pipe and
        // deadlocking on its own write.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()   // closes the pipe so the reader finishes
            _ = drained.wait(timeout: .now() + 1)
            return nil
        }

        // The child is gone, so EOF is imminent; the bound is for a grandchild
        // that inherited the write end and outlived its parent.
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
