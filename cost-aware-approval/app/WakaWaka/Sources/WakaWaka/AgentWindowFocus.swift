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
        // The marker excludes grouped view sessions created by older WakaWaka
        // versions. Those sessions share the pane, but they are not the user's
        // original session and must never become the target again.
        let format = "#{pane_tty}\t#{session_id}\t#{window_id}\t#{pane_id}\t#{@wakawaka-view}"
        guard let out = run(tmux, ["list-panes", "-a", "-F", format]) else { return nil }
        return parsePane(out, tty: tty)
    }

    static func parsePane(_ listing: String, tty: String) -> Pane? {
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4 || f.count == 5, f[0] == tty else { continue }
            guard f.count == 4 || f[4] != "1" else { continue }
            // One bad field disqualifies the whole line: these become argv.
            guard isValidTmuxID(f[1]), isValidTmuxID(f[2]), isValidTmuxID(f[3]) else { return nil }
            return Pane(sessionID: f[1], windowID: f[2], paneID: f[3])
        }
        return nil
    }

    struct ClientMatch: Equatable {
        let tty: String
        /// Already looking at the agent's window, so nothing has to move for
        /// this click to land.
        let isShowingWindow: Bool
    }

    /// A Terminal client attached to the agent's own session. One already
    /// showing the target window wins; otherwise a client parked on another
    /// window is reused, because the click explicitly asks to go there.
    static func parseOriginalClient(_ listing: String, pane: Pane,
                                    terminalTTYs: Set<String>) -> ClientMatch? {
        var parked: ClientMatch?
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, f[1] == pane.sessionID,
                  terminalTTYs.contains(f[0]), isValidTTY(f[0]) else { continue }
            if f[2] == pane.windowID { return ClientMatch(tty: f[0], isShowingWindow: true) }
            parked = parked ?? ClientMatch(tty: f[0], isShowingWindow: false)
        }
        return parked
    }

    /// Every client attached to this session, whatever terminal it lives in.
    /// A client in iTerm or VS Code cannot be raised, but it still follows the
    /// session's current window — for the question "would moving that window
    /// disturb someone", it counts exactly as much as one in Terminal.app.
    static func parseSessionClientTTYs(_ listing: String, sessionID: String) -> Set<String> {
        var ttys: Set<String> = []
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, f[1] == sessionID, !f[0].isEmpty else { continue }
            ttys.insert(f[0])
        }
        return ttys
    }

    /// Whether this click may move the session's current window.
    ///
    /// The current window belongs to the **session**, not to a client, so every
    /// attached client follows it. Moving it is only ours to do when the person
    /// who clicked is the one watching — otherwise the click would yank someone
    /// else's screen, possibly on another machine, with nothing on it to say
    /// what happened. `nil` is the client listing we could not read: not
    /// knowing who is attached is not the same as knowing nobody is.
    static func mayMoveCurrentWindow(sessionClients: Set<String>?, raising tty: String?) -> Bool {
        guard let sessionClients else { return false }
        return sessionClients.subtracting(tty.map { Set([$0]) } ?? []).isEmpty
    }

    private static func focusOriginalTmuxSession(_ pane: Pane, viewTitle: String?) -> Outcome {
        guard let tmux = tmuxPath else { return .failed("找不到 tmux") }
        let clientFormat = "#{client_tty}\t#{session_id}\t#{window_id}"
        guard let terminalTabs = terminalTabListing() else {
            return .failed("無法讀取 Terminal.app 視窗（可能需要在系統設定授權自動化）")
        }
        let terminalTTYs = parseTerminalTTYs(terminalTabs)
        let clients = run(tmux, ["list-clients", "-F", clientFormat])
        // A listing we could not read is not evidence that nobody is watching;
        // `mayMoveCurrentWindow` reads that nil as occupied, so a failed lookup
        // costs the user one keystroke rather than costing someone else their
        // screen.
        let sessionClients = clients.map { parseSessionClientTTYs($0, sessionID: pane.sessionID) }

        if let clients, let match = parseOriginalClient(clients, pane: pane, terminalTTYs: terminalTTYs) {
            let raised = raiseTerminalTab(tty: match.tty, listing: terminalTabs)
            guard raised == .focused else { return raised }
            // Already on the agent's window: raising the tab was the whole job.
            if match.isShowingWindow { return .focused }
            guard mayMoveCurrentWindow(sessionClients: sessionClients, raising: match.tty) else {
                return .sharedSession
            }
            let targetWindow = "\(pane.sessionID):\(pane.windowID)"
            guard run(tmux, ["select-window", "-t", targetWindow]) != nil else {
                return .failed("無法切換到該 agent 的 tmux window")
            }
            return .focused
        }

        // No Terminal client to raise, so a window is opened. Attaching with a
        // window target selects it for the whole session, which is the same
        // move as `select-window` and gets the same answer.
        let isAlone = mayMoveCurrentWindow(sessionClients: sessionClients, raising: nil)
        let command = attachCommand(
            tmux: tmux,
            sessionID: pane.sessionID,
            windowID: isAlone ? pane.windowID : nil
        )

        guard isSafeForAppleScriptLiteral(command) else {
            return .failed("無法組出安全的 tmux 指令")
        }

        let titleCommands: String
        if let viewTitle, isSafeForAppleScriptLiteral(viewTitle) {
            titleCommands = """
              set custom title of createdTab to "\(viewTitle)"
              set title displays custom title of createdTab to true
            """
        } else {
            titleCommands = ""
        }
        let script = """
        tell application "Terminal"
          activate
          set createdTab to do script "\(command)"
        \(titleCommands)
        end tell
        """
        guard run("/usr/bin/osascript", ["-e", script]) != nil else {
            return .failed("無法開啟新的 Terminal 視窗（可能需要在系統設定授權自動化）")
        }
        return isAlone ? .focused : .sharedSession
    }

    /// Without a window the target is the session alone, which attaches
    /// wherever it already is and moves nobody.
    static func attachCommand(tmux: String, sessionID: String, windowID: String?) -> String {
        let target = windowID.map { "\(sessionID):\($0)" } ?? sessionID
        return [quoted(tmux), "attach-session", "-t", quoted(target)]
            .joined(separator: " ")
    }

    static func isSafeForAppleScriptLiteral(_ command: String) -> Bool {
        !command.contains("\"") && !command.contains("\\") && !command.contains("\n")
    }

    /// Single quotes only. Every caller passes a value already checked against a
    /// pattern that cannot contain a quote — and `$3` would otherwise be eaten
    /// by the shell as a positional parameter.
    static func quoted(_ value: String) -> String { "'\(value)'" }

    // MARK: - Terminal.app

    /// Raises the tab whose tty matches, by window id so a window opening or
    /// closing between the two scripts cannot redirect the second one.
    private static func raiseTerminalTab(tty: String) -> Outcome {
        guard let listing = terminalTabListing() else {
            return .failed("無法讀取 Terminal.app 視窗（可能需要在系統設定授權自動化）")
        }
        return raiseTerminalTab(tty: tty, listing: listing)
    }

    private static func terminalTabListing() -> String? {
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
        return run("/usr/bin/osascript", ["-e", query])
    }

    private static func raiseTerminalTab(tty: String, listing: String) -> Outcome {
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

    static func parseTerminalTTYs(_ listing: String) -> Set<String> {
        Set(listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 3, isValidTTY(fields[2]) else { return nil }
            return fields[2]
        })
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
