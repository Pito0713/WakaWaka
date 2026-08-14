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
/// the AppleScript is built from integers only — no untrusted text is ever
/// interpolated into a script or a shell word.
enum AgentWindowFocus {
    enum Outcome: Equatable {
        case focused
        /// The agent exited between the last scan and the click.
        case gone
        /// The process has no controlling terminal (launched by a daemon, say).
        case noTTY
        /// A terminal WakaWaka cannot drive — VS Code's panel, another emulator.
        case unknownTerminal
        case failed(String)

        var message: String? {
            switch self {
            case .focused:         return nil
            case .gone:            return "這個 agent 已經結束了"
            case .noTTY:           return "這個 agent 沒有終端機"
            case .unknownTerminal: return "找不到對應的 Terminal 視窗（僅支援 Terminal.app 與 tmux）"
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
        return focus(pid: row.pid)
    }

    static func focus(pid: Int32) -> Outcome {
        guard let agentTTY = controllingTTY(of: pid) else { return .noTTY }

        // Inside tmux the pane must be selected before its window is raised,
        // otherwise the right window comes forward showing the wrong pane.
        guard let pane = tmuxPane(forTTY: agentTTY) else {
            return raiseTerminalTab(tty: agentTTY)
        }
        return openTmuxViewWindow(for: pane)
    }

    // MARK: - pid → tty

    private static let ttyPattern = try! NSRegularExpression(pattern: "^/dev/tty[a-zA-Z0-9]+$")

    static func isValidTTY(_ path: String) -> Bool { matches(ttyPattern, path) }

    private static func controllingTTY(of pid: Int32) -> String? {
        // `ps` prints the short form ("ttys002") and "??" when there is none.
        guard let out = run("/bin/ps", ["-p", String(pid), "-o", "tty="]) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "??" else { return nil }
        let path = name.hasPrefix("/") ? name : "/dev/\(name)"
        return isValidTTY(path) ? path : nil
    }

    // MARK: - tmux

    struct Pane: Equatable {
        let sessionID: String   // "$3"
        let windowID: String    // "@7"
        let paneID: String      // "%2"
    }

    private static let tmuxIDPattern = try! NSRegularExpression(pattern: "^[$@%][0-9]+$")

    /// `$3`, `@7`, `%2` — tmux's own stable ids. Names are never used as
    /// targets: a session may legally be called `-t` or `; rm -rf ~`.
    static func isValidTmuxID(_ text: String) -> Bool { matches(tmuxIDPattern, text) }

    /// tmux is optional; its absence just means the agent is not in a pane.
    private static let tmuxPath: String? = {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = "\(dir)/tmux"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    private static func tmuxPane(forTTY tty: String) -> Pane? {
        guard let tmux = tmuxPath else { return nil }
        // Ids rather than names: a session called `-t` or `; rm -rf ~` is a
        // legal tmux name and would otherwise become an argument or worse.
        let format = "#{pane_tty}\t#{session_id}\t#{window_id}\t#{pane_id}"
        guard let out = run(tmux, ["list-panes", "-a", "-F", format]) else { return nil }
        return parsePane(out, tty: tty)
    }

    static func parsePane(_ listing: String, tty: String) -> Pane? {
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[0] == tty else { continue }
            // One bad field disqualifies the whole line: these become argv.
            guard isValidTmuxID(f[1]), isValidTmuxID(f[2]), isValidTmuxID(f[3]) else { return nil }
            return Pane(sessionID: f[1], windowID: f[2], paneID: f[3])
        }
        return nil
    }

    /// A per-install token, so a view session can never collide with one the
    /// user made. Persisted rather than random per launch: clicking the same
    /// agent after a restart should still find the window already open.
    static var installToken: String {
        let key = "agentViewSessionToken"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(token, forKey: key)
        return token
    }

    /// Marks a session as ours. Checked before anything is reused or killed, so
    /// a name that somehow matches a real user session is still left alone.
    private static let ownershipOption = "@wakawaka-view"

    static func viewSessionName(token: String, paneID: String) -> String {
        "wakawaka-\(token)-view-\(paneID.dropFirst())"
    }

    /// Opens the agent's tmux window in a window of its own.
    ///
    /// `switch-client` was the obvious primitive and the wrong one: it moves the
    /// client the user is already sitting in. A *grouped* session was the second
    /// answer and only half right — current-window is per-session, so selecting
    /// the window is safe, but the **active pane is a property of the window**
    /// and grouped sessions share windows. Selecting the pane therefore moved
    /// the keyboard focus of anyone else viewing it, measurably, and the
    /// `active-pane` client flag does not prevent it either.
    ///
    /// So the pane is not selected. The new window opens on the agent's tmux
    /// window with the pane visible; if that window is split, focus stays
    /// wherever it already was. Showing the pane without stealing focus is the
    /// better half of that trade. The client flag is still set so the user's own
    /// navigation inside this window does not leak back the other way.
    private static func openTmuxViewWindow(for pane: Pane) -> Outcome {
        guard let tmux = tmuxPath else { return .failed("找不到 tmux") }
        let viewName = viewSessionName(token: installToken, paneID: pane.paneID)

        // A window opened earlier and never attached leaves a session behind;
        // clear ours out before making another.
        sweepOrphanedViews(tmux: tmux)

        if let tty = ownedViewClientTTY(viewName, tmux: tmux) {
            guard run(tmux, ["select-window", "-t", "\(viewName):\(pane.windowID)"]) != nil else {
                return .failed("無法切換到該 agent 的 tmux window")
            }
            return raiseTerminalTab(tty: tty)
        }

        // Created here rather than inside the Terminal command because
        // `do script` reports only that Terminal accepted the text — it cannot
        // say whether the command worked. Built through argv, a failure to group
        // (session gone, name taken) is visible right now.
        guard run(tmux, ["new-session", "-d", "-t", pane.sessionID, "-s", viewName]) != nil else {
            return .failed("無法建立 tmux 檢視 session")
        }
        _ = run(tmux, ["set-option", "-t", viewName, ownershipOption, "1"])
        guard run(tmux, ["select-window", "-t", "\(viewName):\(pane.windowID)"]) != nil else {
            killOwnedView(viewName, tmux: tmux)
            return .failed("無法切換到該 agent 的 tmux window")
        }

        // `destroy-unattached` is set from inside the chain: applied to a
        // session nobody has attached to yet it fires immediately and kills the
        // session out from under the window being opened.
        let command = [
            quoted(tmux), "attach-session",
            "-t", quoted(viewName),
            "-f", "active-pane",
            "';'", "set-option", "destroy-unattached", "on",
        ].joined(separator: " ")

        // Belt and braces: every value above is validated, and this guarantees
        // nothing can break out of the AppleScript string literal regardless.
        guard isSafeForAppleScriptLiteral(command) else {
            killOwnedView(viewName, tmux: tmux)
            return .failed("無法組出安全的 tmux 指令")
        }

        let script = """
        tell application "Terminal"
          activate
          do script "\(command)"
        end tell
        """
        guard run("/usr/bin/osascript", ["-e", script]) != nil else {
            killOwnedView(viewName, tmux: tmux)
            return .failed("無法開啟新的 Terminal 視窗（可能需要在系統設定授權自動化）")
        }
        return .focused
    }

    /// The tty of the client viewing our session of this name — and only ours.
    private static func ownedViewClientTTY(_ viewName: String, tmux: String) -> String? {
        guard isOwnedView(viewName, tmux: tmux) else { return nil }
        // `has-session` matches by prefix, so the name comparison happens here.
        guard let listing = run(tmux, ["list-clients", "-F", "#{client_tty}\t#{session_name}"])
        else { return nil }
        return parseClientTTY(listing, forSession: viewName)
    }

    private static func isOwnedView(_ viewName: String, tmux: String) -> Bool {
        guard let listing = run(tmux, ["list-sessions",
                                       "-F", "#{session_name}\t#{\(ownershipOption)}"])
        else { return false }
        return parseOwnedSessions(listing).contains(viewName)
    }

    /// Session names that carry our ownership marker.
    static func parseOwnedSessions(_ listing: String) -> Set<String> {
        var owned: Set<String> = []
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 2, f[1] == "1" else { continue }
            owned.insert(f[0])
        }
        return owned
    }

    private static func killOwnedView(_ viewName: String, tmux: String) {
        guard isOwnedView(viewName, tmux: tmux) else { return }
        _ = run(tmux, ["kill-session", "-t", viewName])
    }

    /// Removes view sessions of ours that nobody is attached to. `do script`
    /// cannot report failure, so a window that never opened would otherwise
    /// leave its session behind forever.
    private static func sweepOrphanedViews(tmux: String) {
        guard let listing = run(tmux, ["list-sessions",
                                       "-F", "#{session_name}\t#{\(ownershipOption)}\t#{session_attached}"])
        else { return }
        for name in parseOrphanedViews(listing) {
            _ = run(tmux, ["kill-session", "-t", name])
        }
    }

    static func parseOrphanedViews(_ listing: String) -> [String] {
        listing.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, f[1] == "1", f[2] == "0" else { return nil }
            return f[0]
        }
    }

    static func isSafeForAppleScriptLiteral(_ command: String) -> Bool {
        !command.contains("\"") && !command.contains("\\") && !command.contains("\n")
    }

    /// The tty of the client already viewing our window for this pane, if any.
    private static func existingViewClientTTY(_ viewName: String, tmux: String) -> String? {
        // `has-session` matches by prefix, so `wakawaka-view-1` would answer for
        // `wakawaka-view-19`. The name comparison happens here instead.
        guard let listing = run(tmux, ["list-clients", "-F", "#{client_tty}\t#{session_name}"])
        else { return nil }
        return parseClientTTY(listing, forSession: viewName)
    }

    static func parseClientTTY(_ listing: String, forSession name: String) -> String? {
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 2, f[1] == name, isValidTTY(f[0]) else { continue }
            return f[0]
        }
        return nil
    }

    /// Single quotes only. Every caller passes a value already checked against a
    /// pattern that cannot contain a quote — and `$3` would otherwise be eaten
    /// by the shell as a positional parameter.
    static func quoted(_ value: String) -> String { "'\(value)'" }

    // MARK: - Terminal.app

    /// Raises the tab whose tty matches, by window id so a window opening or
    /// closing between the two scripts cannot redirect the second one.
    private static func raiseTerminalTab(tty: String) -> Outcome {
        let query = """
        tell application "Terminal"
          set out to ""
          repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
              set out to out & (id of window w) & " " & t & " " & (tty of tab t of window w) & linefeed
            end repeat
          end repeat
          return out
        end tell
        """
        guard let listing = run("/usr/bin/osascript", ["-e", query]) else {
            // Most often this is the Automation permission being denied.
            return .failed("無法讀取 Terminal.app 視窗（可能需要在系統設定授權自動化）")
        }

        guard let target = parseTerminalTab(listing, tty: tty) else { return .unknownTerminal }

        // Only integers reach this script.
        let action = """
        tell application "Terminal"
          activate
          set selected of tab \(target.tab) of window id \(target.window) to true
          set frontmost of window id \(target.window) to true
        end tell
        """
        guard run("/usr/bin/osascript", ["-e", action]) != nil else {
            return .failed("無法切換 Terminal.app 視窗")
        }
        return .focused
    }

    static func parseTerminalTab(_ listing: String, tty: String) -> (window: Int, tab: Int)? {
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 3, f[2] == tty,
                  let windowID = Int(f[0]), let tabIndex = Int(f[1]) else { continue }
            return (windowID, tabIndex)
        }
        return nil
    }

    // MARK: - Process helper

    /// Runs a command with arguments as argv — never through a shell — and
    /// returns stdout, or nil if it failed, timed out, or could not start.
    private static func run(_ executable: String, _ arguments: [String],
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

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
