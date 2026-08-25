import Foundation
import Testing
@testable import WakaWaka

/// Focusing a window means running `ps`, `tmux` and `osascript` against the
/// live desktop, so the end-to-end path cannot be asserted here. What can be —
/// and what would actually hurt — is the handling of the text those commands
/// return: tmux session and window names are user-authored, and the tty comes
/// from a process WakaWaka does not own.
struct AgentWindowFocusTests {
    private func row(_ projectName: String, kind: AgentKind) -> ActiveAgentRow {
        ActiveAgentRow(
            id: "\(kind.rawValue):test", kind: kind, pid: 1, pidStartedAt: nil,
            projectName: projectName, fullPath: "/workspace/\(projectName)",
            gitBranch: nil, model: nil, skill: nil, skillSource: nil, lastTool: nil,
            state: .working, heartbeatAt: Date()
        )
    }

    // MARK: - What a click can tell the user

    @Test func everyFailureExplainsItself() {
        // A click that silently does nothing is indistinguishable from a broken
        // panel, so every outcome except success carries a message.
        #expect(AgentWindowFocus.Outcome.focused.message == nil)

        for outcome: AgentWindowFocus.Outcome in [
            .gone, .noTTY, .unknownTerminal, .failed("boom"),
        ] {
            #expect(outcome.message?.isEmpty == false, "\(outcome) says nothing")
        }
    }

    // MARK: - tty validation

    @Test func onlyRealTTYPathsAreAccepted() {
        #expect(AgentWindowFocus.isValidTTY("/dev/ttys002"))
        #expect(AgentWindowFocus.isValidTTY("/dev/ttyp0"))

        #expect(!AgentWindowFocus.isValidTTY("??"), "ps prints this when there is none")
        #expect(!AgentWindowFocus.isValidTTY(""))
        #expect(!AgentWindowFocus.isValidTTY("/dev/ttys002; rm -rf ~"))
        #expect(!AgentWindowFocus.isValidTTY("/dev/../etc/passwd"))
        #expect(!AgentWindowFocus.isValidTTY("/dev/ttys002 -t evil"))
    }

    // MARK: - tmux target validation

    /// Targets are addressed by tmux id (`$3`, `@7`, `%2`) rather than by name.
    /// A session called `-t` or `; rm -rf ~` is a legal tmux name, and passing
    /// one as a target would be read as a flag at best.
    @Test func onlyTmuxIDsAreAcceptedAsTargets() {
        #expect(AgentWindowFocus.isValidTmuxID("$0"))
        #expect(AgentWindowFocus.isValidTmuxID("@12"))
        #expect(AgentWindowFocus.isValidTmuxID("%7"))

        #expect(!AgentWindowFocus.isValidTmuxID("WakaWaka"), "a name is not an id")
        #expect(!AgentWindowFocus.isValidTmuxID("-t"))
        #expect(!AgentWindowFocus.isValidTmuxID("$3; rm -rf ~"))
        #expect(!AgentWindowFocus.isValidTmuxID("$"))
        #expect(!AgentWindowFocus.isValidTmuxID(""))
    }

    // MARK: - Parsing what tmux prints

    @Test func theRightPaneIsPickedByTTY() {
        let listing = """
        /dev/ttys007\t$1\t@1\t%1\t
        /dev/ttys004\t$2\t@2\t%2\t1
        /dev/ttys002\t$0\t@5\t%9\t
        """
        let pane = AgentWindowFocus.parsePane(listing, tty: "/dev/ttys002")
        #expect(pane?.sessionID == "$0")
        #expect(pane?.windowID == "@5")
        #expect(pane?.paneID == "%9")

        #expect(AgentWindowFocus.parsePane(listing, tty: "/dev/ttys999") == nil,
                "an agent outside tmux must not match a pane")
    }

    @Test func aLegacyGroupedViewIsNotTreatedAsTheOriginalSession() {
        let listing = """
        /dev/ttys002\t$7\t@5\t%9\t1
        /dev/ttys002\t$0\t@5\t%9\t
        """
        #expect(AgentWindowFocus.parsePane(listing, tty: "/dev/ttys002")?.sessionID == "$0")
    }

    /// A pane line whose ids do not look like ids is refused outright rather
    /// than partially used — the ids are what end up on a command line.
    @Test func aMalformedPaneLineIsRefused() {
        #expect(AgentWindowFocus.parsePane("/dev/ttys002\tevil; rm -rf ~\t@5\t%9",
                                           tty: "/dev/ttys002") == nil)
        #expect(AgentWindowFocus.parsePane("/dev/ttys002\t$0\t@5", tty: "/dev/ttys002") == nil,
                "a truncated line has no pane id to select")
        #expect(AgentWindowFocus.parsePane("", tty: "/dev/ttys002") == nil)
    }

    // MARK: - Reusing the original session

    /// The bug this closes: every click built a grouped "view" session and a new
    /// Terminal window, even when the user was already looking at that pane. One
    /// click on an agent you are watching would leave two windows showing it.
    @Test func aClientAlreadyShowingTheWindowIsPreferred() {
        let pane = AgentWindowFocus.Pane(sessionID: "$0", windowID: "@1", paneID: "%2")
        let clients = """
        /dev/ttys005\t$0\t@1
        /dev/ttys006\t$0\t@0
        """
        #expect(AgentWindowFocus.parseOriginalClient(
            clients, pane: pane, terminalTTYs: ["/dev/ttys005", "/dev/ttys006"]
        ) == .init(tty: "/dev/ttys005", isShowingWindow: true))
    }

    @Test func aClientParkedOnAnotherWindowIsStillReused() {
        let pane = AgentWindowFocus.Pane(sessionID: "$0", windowID: "@1", paneID: "%2")
        #expect(AgentWindowFocus.parseOriginalClient(
            "/dev/ttys005\t$0\t@7", pane: pane, terminalTTYs: ["/dev/ttys005"]
        )
                == .init(tty: "/dev/ttys005", isShowingWindow: false))
    }

    @Test func aClientLineThatIsNotUsableIsSkipped() {
        let pane = AgentWindowFocus.Pane(sessionID: "$0", windowID: "@1", paneID: "%2")
        let clients = """
        (none)\t$0\t@1
        /dev/ttys005\t$0\t@1\t@1
        /dev/ttys006\t$0\t@1
        """
        #expect(AgentWindowFocus.parseOriginalClient(
            clients, pane: pane, terminalTTYs: ["/dev/ttys006"]
        )?.tty == "/dev/ttys006", "an unusable tty and a malformed line are both skipped")
        #expect(AgentWindowFocus.parseOriginalClient(
            "", pane: pane, terminalTTYs: ["/dev/ttys006"]
        ) == nil)
    }

    @Test func aNonTerminalClientDoesNotHideAnExistingTerminalClient() {
        let pane = AgentWindowFocus.Pane(sessionID: "$0", windowID: "@1", paneID: "%2")
        let clients = """
        /dev/ttys001\t$0\t@1
        /dev/ttys002\t$0\t@7
        """
        #expect(AgentWindowFocus.parseOriginalClient(
            clients, pane: pane, terminalTTYs: ["/dev/ttys002"]
        )?.tty == "/dev/ttys002")
        #expect(AgentWindowFocus.parseOriginalClient(
            clients, pane: pane, terminalTTYs: []
        ) == nil, "without a Terminal client the caller must attach the original session")
    }

    // MARK: - Whose screen this click is allowed to move

    /// tmux's current window belongs to the session, so every attached client
    /// follows it. These cases are the whole of the policy: move it only when
    /// the person who clicked is the only one watching.
    @Test func theOnlyClientWatchingMayBeMoved() {
        #expect(AgentWindowFocus.mayMoveCurrentWindow(
            sessionClients: ["/dev/ttys005"], raising: "/dev/ttys005"
        ))
        #expect(AgentWindowFocus.mayMoveCurrentWindow(sessionClients: [], raising: nil),
                "nobody attached: the window opened by this click is the only viewer")
    }

    @Test func anotherClientWatchingIsLeftAlone() {
        #expect(!AgentWindowFocus.mayMoveCurrentWindow(
            sessionClients: ["/dev/ttys005", "/dev/ttys009"], raising: "/dev/ttys005"
        ), "the second client would be dragged to a window it did not ask for")
        #expect(!AgentWindowFocus.mayMoveCurrentWindow(
            sessionClients: ["/dev/ttys009"], raising: nil
        ), "a new window must not select for a session someone is already in")
    }

    /// The listing failed. Not knowing who is attached is not the same as
    /// knowing nobody is, and the two must not collapse into the permissive one.
    @Test func anUnreadableClientListingCountsAsOccupied() {
        #expect(!AgentWindowFocus.mayMoveCurrentWindow(sessionClients: nil, raising: "/dev/ttys005"))
        #expect(!AgentWindowFocus.mayMoveCurrentWindow(sessionClients: nil, raising: nil))
    }

    /// A client in iTerm or VS Code cannot be raised, but it still follows the
    /// session's current window — for this question it counts like any other.
    @Test func aClientWeCannotDriveStillCounts() {
        let clients = """
        /dev/ttys005\t$0\t@1
        /dev/ttys009\t$0\t@3
        /dev/ttys077\t$9\t@4
        """
        #expect(AgentWindowFocus.parseSessionClientTTYs(clients, sessionID: "$0")
                == ["/dev/ttys005", "/dev/ttys009"],
                "clients of other sessions are not this session's business")
        #expect(AgentWindowFocus.parseSessionClientTTYs("", sessionID: "$0").isEmpty)
    }

    @Test func aClientAlreadyOnTheWindowNeedsNothingMoved() {
        let pane = AgentWindowFocus.Pane(sessionID: "$0", windowID: "@1", paneID: "%2")
        let match = AgentWindowFocus.parseOriginalClient(
            "/dev/ttys005\t$0\t@1", pane: pane, terminalTTYs: ["/dev/ttys005"]
        )
        #expect(match?.isShowingWindow == true,
                "raising the tab is the whole job; select-window would be a no-op")
    }

    // MARK: - What reaches the shell and the script

    /// The command is embedded in an AppleScript string literal and then run by
    /// a shell. A tmux id is single-quoted so `$3` is not eaten as a positional
    /// parameter, and nothing may carry a quote, a backslash or a newline that
    /// could end the literal early.
    @Test func theGeneratedCommandCannotEscapeItsScriptLiteral() {
        #expect(AgentWindowFocus.quoted("$3") == "'$3'")
        #expect(AgentWindowFocus.quoted("wakawaka-view-9:@2") == "'wakawaka-view-9:@2'")

        let command = AgentWindowFocus.attachCommand(
            tmux: "/opt/homebrew/bin/tmux",
            sessionID: "$3",
            windowID: "@7"
        )
        #expect(command == "'/opt/homebrew/bin/tmux' attach-session -t '$3:@7'")
        #expect(AgentWindowFocus.attachCommand(
            tmux: "/opt/homebrew/bin/tmux", sessionID: "$3", windowID: nil
        ) == "'/opt/homebrew/bin/tmux' attach-session -t '$3'",
                "no window target when the session's current window must stay put")
        #expect(!command.contains("select-window"))
        #expect(!command.contains("new-session"))
        #expect(AgentWindowFocus.isSafeForAppleScriptLiteral(command))

        #expect(!AgentWindowFocus.isSafeForAppleScriptLiteral("tmux -t \"evil\""))
        #expect(!AgentWindowFocus.isSafeForAppleScriptLiteral("tmux -t x\\"))
        #expect(!AgentWindowFocus.isSafeForAppleScriptLiteral("tmux\nactivate"))
    }

    @Test func viewTitleIdentifiesProjectAndAgentKind() {
        let title = AgentWindowFocus.viewTitle(for: row("WakaWaka", kind: .claudeCode))
        #expect(title.contains("WakaWaka"))
        #expect(title.contains("Claude Code"))
    }

    @Test func viewTitlesDistinguishAgentKindsInTheSameProject() {
        let claude = AgentWindowFocus.viewTitle(for: row("WakaWaka", kind: .claudeCode))
        let codex = AgentWindowFocus.viewTitle(for: row("WakaWaka", kind: .codex))
        #expect(claude != codex)
    }

    @Test(arguments: [#"he"llo"#, #"he\llo"#])
    func unsafeProjectNamesUseASafeTitle(projectName: String) {
        let title = AgentWindowFocus.viewTitle(for: row(projectName, kind: .claudeCode))
        #expect(AgentWindowFocus.isSafeForAppleScriptLiteral(title))
        #expect(title == "Claude Code")
    }

    @Test func viewTitleIsLimitedToSixtyCharacters() {
        let title = AgentWindowFocus.viewTitle(
            for: row(String(repeating: "LongProject", count: 20), kind: .claudeCode)
        )
        #expect(title.count <= 60)
    }

    // MARK: - Parsing what Terminal.app reports

    @Test func theTabIsFoundByTTYAndAddressedByWindowID() {
        let listing = """
        130977 1 /dev/ttys003
        129581 2 /dev/ttys000
        """
        let target = AgentWindowFocus.parseTerminalTab(listing, tty: "/dev/ttys000")
        // The window id, not its index: a window opening between the query and
        // the action would otherwise shift every index under us.
        #expect(target?.window == 129581)
        #expect(target?.tab == 2)

        #expect(AgentWindowFocus.parseTerminalTab(listing, tty: "/dev/ttys042") == nil,
                "a tty Terminal.app does not own is not ours to raise")
        #expect(AgentWindowFocus.parseTerminalTTYs(listing) == ["/dev/ttys003", "/dev/ttys000"])
    }

    @Test func aNonNumericTerminalLineIsIgnored() {
        #expect(AgentWindowFocus.parseTerminalTab("abc 1 /dev/ttys000", tty: "/dev/ttys000") == nil)
        #expect(AgentWindowFocus.parseTerminalTab("130977 x /dev/ttys000", tty: "/dev/ttys000") == nil)
    }
}
