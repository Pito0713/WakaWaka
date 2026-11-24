import Foundation

/// Terminal.app: raise the window and tab whose tty is the agent's.
extension AgentWindowFocus {
    // MARK: - Terminal.app

    /// Raises the tab whose tty matches, by window id so a window opening or
    /// closing between the two scripts cannot redirect the second one.
    static func raiseTerminalTab(tty: String) -> Outcome {
        guard let listing = terminalTabListing() else {
            return .failed("無法讀取 Terminal.app 視窗（可能需要在系統設定授權自動化）")
        }
        return raiseTerminalTab(tty: tty, listing: listing)
    }

    static func terminalTabListing() -> String? {
        // `count of windows` also counts windows that have no scripting object
        // behind them (a ghost entry Terminal keeps after some panels close).
        // Asking one of those for its id raises -1728/-10000, which would fail
        // the whole listing and look like a missing Automation grant. Skip them.
        let query = """
        tell application "Terminal"
          set out to ""
          repeat with w from 1 to count of windows
            try
              set windowID to id of window w
              repeat with t from 1 to count of tabs of window w
                set out to out & windowID & " " & t & " " & (tty of tab t of window w) & linefeed
              end repeat
            end try
          end repeat
          return out
        end tell
        """
        return run("/usr/bin/osascript", ["-e", query])
    }

    static func raiseTerminalTab(tty: String, listing: String) -> Outcome {
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
}
