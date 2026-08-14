import Foundation
import Testing
@testable import WakaWaka

/// Tests for the registry reader (plan §9-11..20).
///
/// Each case builds a throwaway state directory, so nothing here touches the
/// live `~/.wakawaka` the running app is polling.
struct AgentRegistryServiceTests {
    private func makeStateDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes one registry file. `pid` defaults to this process, which is by
    /// definition alive and whose start time matches — the "healthy" case.
    @discardableResult
    private func writeEntry(
        in dir: URL,
        kind: String = "claude-code",
        sessionId: String = "sess-1",
        cwd: String = "~/lake-ui-kit",
        gitBranch: String? = "main",
        model: String? = "claude-opus-5",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        pidStartedAt: Int64? = nil,
        pidStartedAtIsNull: Bool = false,
        state: String = "working",
        skill: String? = nil,
        skillSource: String? = nil,
        lastTool: String? = "Bash",
        heartbeatAgo: TimeInterval = 0,
        schema: Int = 1
    ) throws -> URL {
        let started = pidStartedAt ?? ProcessLiveness.startedAt(pid: pid) ?? 0
        let iso = ISO8601DateFormatter()
        let heartbeat = iso.string(from: Date().addingTimeInterval(-heartbeatAgo))

        var fields: [String] = [
            "\"schema\":\(schema)",
            "\"kind\":\"\(kind)\"",
            "\"sessionId\":\"\(sessionId)\"",
            "\"cwd\":\"\(cwd)\"",
            "\"pid\":\(pid)",
            "\"pidStartedAt\":\(pidStartedAtIsNull ? "null" : String(started))",
            "\"state\":\"\(state)\"",
            "\"lastTool\":\(lastTool.map { "\"\($0)\"" } ?? "null")",
            "\"gitBranch\":\(gitBranch.map { "\"\($0)\"" } ?? "null")",
            "\"model\":\(model.map { "\"\($0)\"" } ?? "null")",
            "\"skill\":\(skill.map { "\"\($0)\"" } ?? "null")",
            "\"skillSource\":\(skillSource.map { "\"\($0)\"" } ?? "null")",
            "\"startedAt\":\"\(iso.string(from: Date().addingTimeInterval(-3600)))\"",
            "\"heartbeatAt\":\"\(heartbeat)\"",
        ]
        let url = dir.appendingPathComponent("agent_\(kind)_\(sessionId).json")
        try "{\(fields.joined(separator: ","))}".write(to: url, atomically: true, encoding: .utf8)
        fields.removeAll()
        return url
    }

    private func listing(_ dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    }

    private func pending(
        sessionId: String? = nil,
        codexSessionId: String? = nil,
        agent: String = "claude-code",
        hookExited: Bool = false
    ) throws -> PendingData {
        var fields = ["\"agent\":\"\(agent)\"", "\"tool_name\":\"Bash\""]
        if let sessionId { fields.append("\"session_id\":\"\(sessionId)\"") }
        if let codexSessionId { fields.append("\"codex_session_id\":\"\(codexSessionId)\"") }
        if hookExited { fields.append("\"hookExited\":true") }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(PendingData.self, from: Data(json.utf8))
    }

    // MARK: - Happy path

    @Test func aLiveSessionBecomesARow() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir, skill: "code-review", skillSource: "tool")

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])

        #expect(snapshot.rows.count == 1)
        let row = snapshot.rows[0]
        #expect(row.projectName == "lake-ui-kit", "only the last path component is shown")
        #expect(row.fullPath == "~/lake-ui-kit")
        #expect(row.gitBranch == "main")
        #expect(row.model == "opus-5", "the claude- prefix is dropped for a 480pt popover")
        #expect(row.skill == "code-review")
        #expect(row.skillSource == .tool)
        #expect(row.state == .working)
        #expect(snapshot.status.message == nil, "a healthy read reports nothing to the user")
        if case .ok = snapshot.status {} else {
            Issue.record("expected .ok, got \(snapshot.status)")
        }
    }

    @Test func rowsAreOrderedByMostRecentActivity() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir, sessionId: "older", heartbeatAgo: 30)
        try writeEntry(in: dir, sessionId: "newer", heartbeatAgo: 1)

        let rows = AgentRegistryService.snapshot(from: try listing(dir), pending: []).rows
        #expect(rows.map(\.id) == ["claude-code_newer", "claude-code_older"])
    }

    // MARK: - §9-11, 12: liveness

    @Test func aDeadProcessIsDroppedAndItsFileRemoved() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // pid 0 is never a live user process; the entry is old enough to be checked.
        let url = try writeEntry(in: dir, pid: 0, pidStartedAt: 0, heartbeatAgo: 120)

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])

        #expect(snapshot.rows.isEmpty, "a crashed session must not look active")
        #expect(!FileManager.default.fileExists(atPath: url.path), "the stale file is swept")
    }

    @Test func aRecycledPidIsTreatedAsDead() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // This pid is alive, but the recorded start time belongs to a process
        // that exited and whose number was reused.
        try writeEntry(in: dir, pidStartedAt: 1, heartbeatAgo: 120)

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])
        #expect(snapshot.rows.isEmpty, "a live pid alone is not proof of the same process")
    }

    @Test func aFreshEntryIsTrustedWithoutCheckingTheProcess() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Dead pid, but it reported in seconds ago: the grace period skips the
        // syscall, which is the throttle the plan's performance budget assumes.
        try writeEntry(in: dir, pid: 0, pidStartedAt: 0, heartbeatAgo: 1)

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])
        #expect(snapshot.rows.count == 1)
    }

    @Test func processLivenessRejectsAMismatchedStartTime() {
        let mine = ProcessInfo.processInfo.processIdentifier
        #expect(ProcessLiveness.isRunning(pid: mine))
        #expect(ProcessLiveness.check(pid: mine, startedAt: ProcessLiveness.startedAt(pid: mine)) == .alive)
        #expect(ProcessLiveness.check(pid: mine, startedAt: 1) == .gone)
        #expect(ProcessLiveness.check(pid: 0, startedAt: nil) == .gone)
        #expect(!ProcessLiveness.isRunning(pid: 0))
    }

    /// A live pid with no recorded start time cannot be identified. It used to
    /// be trusted outright, which let a recycled pid keep a dead session on
    /// screen forever; it is now trusted only up to `staleThreshold`.
    @Test func anUnverifiablePidIsTrustedOnlyUntilItGoesStale() throws {
        let mine = ProcessInfo.processInfo.processIdentifier
        #expect(ProcessLiveness.check(pid: mine, startedAt: nil) == .unverifiable)

        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeEntry(
            in: dir, sessionId: "no-start-time",
            pidStartedAtIsNull: true,
            heartbeatAgo: AgentRegistryService.livenessGracePeriod + 10)

        #expect(AgentRegistryService.snapshot(from: try listing(dir), pending: []).rows.count == 1,
                "still shown while it is plausibly recent")
        #expect(FileManager.default.fileExists(atPath: url.path))

        // The same entry, now quiet past the stale threshold.
        let old = Date().addingTimeInterval(AgentRegistryService.staleThreshold + 60)
        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [], now: old)
        #expect(snapshot.rows.isEmpty, "an unverifiable pid is not trusted indefinitely")
        #expect(!FileManager.default.fileExists(atPath: url.path), "and the file is swept")
    }

    /// A row is trusted for up to a minute without a pid check, so by the time
    /// it is clicked the process may be gone and its pid reused. The click path
    /// re-verifies, which needs the start time to be on the row.
    @Test func aRowCarriesWhatIsNeededToProveItsProcess() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir)

        let row = AgentRegistryService.snapshot(from: try listing(dir), pending: []).rows[0]
        #expect(row.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(row.pidStartedAt == ProcessLiveness.startedAt(pid: row.pid))
        #expect(ProcessLiveness.check(pid: row.pid, startedAt: row.pidStartedAt) == .alive)
    }

    /// The writer replaces entries atomically, so between reading a file and
    /// deciding to delete it the agent may have re-registered at the same path.
    /// Deleting that replacement is permanent: the lifecycle hooks update
    /// entries but refuse to create them, so the session would never come back.
    @Test func aFileReplacedAfterBeingReadIsNotDeleted() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeEntry(in: dir)

        func modifiedAt() throws -> Date {
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        }

        // What the scan saw, then the replacement landing underneath it.
        let asRead = try modifiedAt()
        try FileManager.default.setAttributes(
            [.modificationDate: asRead.addingTimeInterval(1)], ofItemAtPath: url.path)

        AgentRegistryService.removeIfUnchanged(url, since: asRead)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "a file rewritten since it was read is somebody else's now")

        // Unchanged since the read: this is the entry that was judged dead.
        AgentRegistryService.removeIfUnchanged(url, since: try modifiedAt())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Degraded reads must not look like "no agents"

    @Test func anUnreadableDirectoryIsReportedRatherThanShownAsEmpty() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        let a = AgentRegistryService.snapshot(from: [], pending: [], scanError: denied)
        #expect(a.status == .permissionDenied)
        #expect(!a.isEmpty, "a failed read must still render something")

        let b = AgentRegistryService.snapshot(from: [], pending: [], scanError: missing)
        #expect(b.status == .unavailable)

        // The healthy empty case stays silent.
        #expect(AgentRegistryService.snapshot(from: [], pending: []).isEmpty)
    }

    @Test func anOversizedFileIsSkipped() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir, sessionId: "good")

        // A fully valid entry — it would decode and render — that has been
        // padded past the cap. The decoder ignores the unknown key, so only the
        // size guard can reject this; a malformed blob would prove nothing
        // because the decoder rejects that on its own.
        let valid = try String(contentsOf: try writeEntry(in: dir, sessionId: "huge"), encoding: .utf8)
        let padding = String(repeating: "x", count: AgentRegistryService.maxEntryBytes)
        let padded = valid.replacingOccurrences(of: "{", with: "{\"pad\":\"\(padding)\",", options: [], range: valid.startIndex..<valid.index(after: valid.startIndex))
        #expect(padded.utf8.count > AgentRegistryService.maxEntryBytes)
        try padded.write(to: dir.appendingPathComponent("agent_claude-code_huge.json"),
                         atomically: true, encoding: .utf8)

        let rows = AgentRegistryService.snapshot(from: try listing(dir), pending: []).rows
        #expect(rows.count == 1, "the padded entry is rejected on size, not on decoding")
        #expect(rows[0].id == "claude-code_good")
    }

    // MARK: - §9-15, 16: pending overlay

    @Test func anApprovalMarksItsSessionAsWaiting() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir, sessionId: "sess-1")

        let snapshot = AgentRegistryService.snapshot(
            from: try listing(dir),
            pending: [try pending(sessionId: "sess-1")]
        )
        #expect(snapshot.rows[0].state == .waitingApproval)
    }

    @Test func codexApprovalsOverlayViaCodexSessionId() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir, kind: "codex", sessionId: "codex-real-id")

        // The pending file's own session_id is the approval UUID; keying on it
        // would silently overlay nothing.
        let snapshot = AgentRegistryService.snapshot(
            from: try listing(dir),
            pending: [try pending(sessionId: "approval-uuid", codexSessionId: "codex-real-id", agent: "codex")]
        )
        #expect(snapshot.rows[0].state == .waitingApproval)
    }

    @Test func aTombstonedApprovalDoesNotOverlay() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir, sessionId: "sess-1", state: "working")

        let snapshot = AgentRegistryService.snapshot(
            from: try listing(dir),
            pending: [try pending(sessionId: "sess-1", hookExited: true)]
        )
        #expect(snapshot.rows[0].state == .working, "nobody is waiting on a dead hook")
    }

    // MARK: - §9-17..20: degraded sources

    @Test func anUnknownSchemaIsReportedRatherThanGuessedAt() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEntry(in: dir, schema: 99)

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])

        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.status == .schemaIncompatible(found: 99, expected: 1))
        #expect(snapshot.status.message?.contains("start.sh") == true, "the user is told how to fix it")
    }

    @Test func aCorruptFileIsSkippedWithoutCrashing() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{ half writ".write(
            to: dir.appendingPathComponent("agent_claude-code_broken.json"),
            atomically: true, encoding: .utf8)
        try writeEntry(in: dir, sessionId: "good")

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])
        #expect(snapshot.rows.map(\.id) == ["claude-code_good"], "one bad file hides nothing else")
    }

    @Test func anEmptyDirectoryIsAHealthyEmptySnapshot() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.status.message == nil, "nothing running is not an error")
    }

    @Test func aSymlinkedRegistryFileIsIgnored() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = try writeEntry(in: dir, sessionId: "real")
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("agent_claude-code_linked.json"),
            withDestinationURL: real)

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])
        #expect(snapshot.rows.map(\.id) == ["claude-code_real"], "the app must not follow links out")
    }

    @Test func unrelatedFilesInTheStateDirectoryAreIgnored() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("pending_x.json"),
                       atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("decision_x.json"),
                       atomically: true, encoding: .utf8)

        let snapshot = AgentRegistryService.snapshot(from: try listing(dir), pending: [])
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.status.message == nil)
    }

    // MARK: - Display hardening

    @Test func displayStringsAreStrippedAndCapped() throws {
        let dir = try makeStateDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A branch name is attacker-influenced in a shared repo; control
        // characters and unbounded length must not reach the panel.
        try writeEntry(in: dir, gitBranch: String(repeating: "b", count: 80))

        let row = AgentRegistryService.snapshot(from: try listing(dir), pending: []).rows[0]
        #expect(row.gitBranch!.count <= 24)
        #expect(row.gitBranch!.hasSuffix("…"))
    }
}
