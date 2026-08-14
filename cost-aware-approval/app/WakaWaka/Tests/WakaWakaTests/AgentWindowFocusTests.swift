import Foundation
import Testing
@testable import WakaWaka

/// Focusing a window means running `ps`, `tmux` and `osascript` against the
/// live desktop, so the end-to-end path cannot be asserted here. What can be —
/// and what would actually hurt — is the handling of the text those commands
/// return: tmux session and window names are user-authored, and the tty comes
/// from a process WakaWaka does not own.
struct AgentWindowFocusTests {
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
        /dev/ttys007\t$1\t@1\t%1
        /dev/ttys004\t$2\t@2\t%2
        /dev/ttys002\t$0\t@5\t%9
        """
        let pane = AgentWindowFocus.parsePane(listing, tty: "/dev/ttys002")
        #expect(pane?.sessionID == "$0")
        #expect(pane?.windowID == "@5")
        #expect(pane?.paneID == "%9")

        #expect(AgentWindowFocus.parsePane(listing, tty: "/dev/ttys999") == nil,
                "an agent outside tmux must not match a pane")
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

    // MARK: - Finding a view window that is already open

    /// Clicking the same agent twice must raise the window that is already
    /// there rather than stacking another one on top of it.
    @Test func anAlreadyOpenViewIsFoundByExactSessionName() {
        let clients = """
        /dev/ttys000\tWakaWaka
        /dev/ttys004\twakawaka-view-3
        """
        #expect(AgentWindowFocus.parseClientTTY(clients, forSession: "wakawaka-view-3")
                == "/dev/ttys004")
        #expect(AgentWindowFocus.parseClientTTY(clients, forSession: "wakawaka-view-9") == nil)
    }

    /// tmux's own `has-session` matches by prefix, so it would answer yes for
    /// `wakawaka-view-3` when only `wakawaka-view-30` exists — and the click
    /// would try to raise a window that is not there. The comparison is done
    /// here instead, exactly.
    @Test func aPrefixIsNotAMatch() {
        let clients = "/dev/ttys004\twakawaka-view-30"
        #expect(AgentWindowFocus.parseClientTTY(clients, forSession: "wakawaka-view-3") == nil)
    }

    @Test func aClientWithAnUnusableTTYIsSkipped() {
        let clients = """
        (none)\twakawaka-view-3
        /dev/ttys004\twakawaka-view-3
        """
        #expect(AgentWindowFocus.parseClientTTY(clients, forSession: "wakawaka-view-3")
                == "/dev/ttys004")
    }

    // MARK: - Ownership of view sessions

    /// View sessions are named with a per-install token, and marked. Both,
    /// because a name alone is a guess: if a user session happened to carry the
    /// name, reusing or killing it would act on their work.
    @Test func onlyMarkedSessionsCountAsOurs() {
        let listing = """
        WakaWaka\t
        wakawaka-abc123-view-2\t1
        wakawaka-abc123-view-9\t
        """
        let owned = AgentWindowFocus.parseOwnedSessions(listing)
        #expect(owned == ["wakawaka-abc123-view-2"])
        #expect(!owned.contains("wakawaka-abc123-view-9"), "same shape, no marker, not ours")
    }

    /// A window that never opened leaves a session nobody is attached to —
    /// `do script` cannot report that it failed. Only ours are swept.
    @Test func onlyOurUnattachedSessionsAreSwept() {
        let listing = """
        WakaWaka\t\t0
        wakawaka-abc123-view-2\t1\t0
        wakawaka-abc123-view-5\t1\t1
        """
        #expect(AgentWindowFocus.parseOrphanedViews(listing) == ["wakawaka-abc123-view-2"])
    }

    @Test func viewNamesAreScopedToThisInstall() {
        let name = AgentWindowFocus.viewSessionName(token: "abc123", paneID: "%42")
        #expect(name == "wakawaka-abc123-view-42")
        #expect(AgentWindowFocus.isSafeForAppleScriptLiteral(AgentWindowFocus.quoted(name)))
        // Two installs must not fight over the same session.
        #expect(name != AgentWindowFocus.viewSessionName(token: "def456", paneID: "%42"))
    }

    // MARK: - What reaches the shell and the script

    /// The command is embedded in an AppleScript string literal and then run by
    /// a shell. A tmux id is single-quoted so `$3` is not eaten as a positional
    /// parameter, and nothing may carry a quote, a backslash or a newline that
    /// could end the literal early.
    @Test func theGeneratedCommandCannotEscapeItsScriptLiteral() {
        #expect(AgentWindowFocus.quoted("$3") == "'$3'")
        #expect(AgentWindowFocus.quoted("wakawaka-view-9:@2") == "'wakawaka-view-9:@2'")

        #expect(AgentWindowFocus.isSafeForAppleScriptLiteral(
            "'/opt/homebrew/bin/tmux' new-session -t '$3' -s 'wakawaka-view-9'"))

        #expect(!AgentWindowFocus.isSafeForAppleScriptLiteral("tmux -t \"evil\""))
        #expect(!AgentWindowFocus.isSafeForAppleScriptLiteral("tmux -t x\\"))
        #expect(!AgentWindowFocus.isSafeForAppleScriptLiteral("tmux\nactivate"))
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
    }

    @Test func aNonNumericTerminalLineIsIgnored() {
        #expect(AgentWindowFocus.parseTerminalTab("abc 1 /dev/ttys000", tty: "/dev/ttys000") == nil)
        #expect(AgentWindowFocus.parseTerminalTab("130977 x /dev/ttys000", tty: "/dev/ttys000") == nil)
    }
}



