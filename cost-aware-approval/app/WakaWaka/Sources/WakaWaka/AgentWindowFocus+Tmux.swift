import Foundation

/// tmux: find the pane on the agent's tty and bring its original session forward.
extension AgentWindowFocus {
    // MARK: - tmux

    struct Pane: Equatable {
        let sessionID: String   // "$3"
        let windowID: String    // "@7"
        let paneID: String      // "%2"
    }

    static let tmuxIDPattern = try! NSRegularExpression(pattern: "^[$@%][0-9]+$")

    /// `$3`, `@7`, `%2` — tmux's own stable ids. Names are never used as
    /// targets: a session may legally be called `-t` or `; rm -rf ~`.
    static func isValidTmuxID(_ text: String) -> Bool { matches(tmuxIDPattern, text) }

    /// tmux is optional; its absence just means the agent is not in a pane.
    static let tmuxPath: String? = {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = "\(dir)/tmux"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    static func tmuxPane(forTTY tty: String) -> Pane? {
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

    static func focusOriginalTmuxSession(_ pane: Pane, viewTitle: String?) -> Outcome {
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
}
