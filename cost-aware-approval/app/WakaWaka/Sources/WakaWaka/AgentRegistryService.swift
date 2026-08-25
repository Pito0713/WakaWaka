import Foundation

/// Reads the agent registry written by the lifecycle hooks and turns it into
/// rows for the active-agents panel.
///
/// Called from `AppDelegate.poll()`, which already enumerates the same state
/// directory once a second looking for pending approvals — the registry files
/// live alongside them, so this adds no directory walk of its own.
///
/// Liveness is decided by pid rather than recency: a crashed agent leaves a
/// file identical to a live idle one. Only entries quiet for
/// `livenessGracePeriod` are checked, which skips the syscalls entirely for the
/// sessions that are actually busy. A long-idle entry is re-checked every poll;
/// that is two syscalls per row per second, bounded by `maxRows`, and an entry
/// that fails is deleted rather than re-checked.
enum AgentRegistryService {
    static let supportedSchema = 1

    /// Entries fresher than this are trusted without a pid check.
    static let livenessGracePeriod: TimeInterval = 60

    /// An entry this quiet whose process cannot be confirmed is swept, so a
    /// machine that slept through a crash does not accumulate dead rows.
    static let staleThreshold: TimeInterval = 30 * 60

    static let maxRows = 5

    /// Builds the snapshot from an already-enumerated directory listing.
    ///
    /// Largest registry file worth reading. Entries are a few hundred bytes;
    /// anything approaching this is not one, and reading it would stall a poll
    /// that runs on the main thread.
    static let maxEntryBytes = 64 * 1024

    /// - Parameters:
    ///   - urls: everything in the state directory, from the caller's own scan.
    ///   - pending: the approval queue, used to overlay `waitingApproval`.
    ///   - scanError: whatever stopped the caller from listing the directory.
    ///     Without it an unreadable directory is indistinguishable from an empty
    ///     one, and the panel would quietly claim no agents are running.
    static func snapshot(
        from urls: [URL],
        pending: [PendingData],
        now: Date = Date(),
        scanError: Error? = nil,
        forceVerify: Bool = false
    ) -> ActiveAgentsSnapshot {
        if let scanError { return ActiveAgentsSnapshot(rows: [], status: status(for: scanError)) }

        var rows: [ActiveAgentRow] = []
        var schemaMismatch: Int?
        let blocked = blockedSessionKeys(pending)

        for url in urls where isRegistryFile(url) {
            guard let data = readEntry(at: url) else { continue }
            guard let entry = decode(data) else {
                // A half-written or corrupt file is skipped, not fatal: the
                // writer is a separate process and rename() is atomic, so this
                // should be transient.
                continue
            }
            guard entry.schema == supportedSchema else {
                schemaMismatch = entry.schema
                continue
            }
            guard isAlive(entry, now: now, removing: url,
                          modifiedAt: modificationDate(of: url), forceVerify: forceVerify)
            else { continue }

            rows.append(makeRow(entry, blocked: blocked))
        }

        if let found = schemaMismatch {
            return ActiveAgentsSnapshot(
                rows: sorted(rows),
                status: .schemaIncompatible(found: found, expected: supportedSchema)
            )
        }
        return ActiveAgentsSnapshot(rows: sorted(rows), status: .ok)
    }

    /// Most recently active first, so the row the user is watching stays on top.
    private static func sorted(_ rows: [ActiveAgentRow]) -> [ActiveAgentRow] {
        rows.sorted { $0.heartbeatAt > $1.heartbeatAt }
    }

    /// Maps an enumeration failure onto something the panel can explain.
    private static func status(for error: Error) -> SourceStatus {
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return .unavailable }
        return ns.code == NSFileReadNoPermissionError ? .permissionDenied : .unavailable
    }

    private static func isRegistryFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("agent_"), name.hasSuffix(".json") else { return false }
        // Never follow a symlink out of the state directory, and never open
        // anything that is not a plain file: this runs on the main thread, so a
        // fifo or device node here would hang the whole app on read.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        return values?.isSymbolicLink != true && values?.isRegularFile == true
    }

    /// Reads a registry file, refusing anything too large to be one.
    private static func readEntry(at url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size, size <= maxEntryBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func decode(_ data: Data) -> AgentRegistryEntry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = isoWithFraction.date(from: text) ?? isoPlain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "bad date: \(text)"))
        }
        return try? decoder.decode(AgentRegistryEntry.self, from: data)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    /// Decides whether an entry represents a live session, deleting the file
    /// when it clearly does not.
    private static func isAlive(_ entry: AgentRegistryEntry, now: Date, removing url: URL,
                                modifiedAt: Date?, forceVerify: Bool) -> Bool {
        let quietFor = now.timeIntervalSince(entry.heartbeatAt)

        // Recently active: trust it without spending syscalls. A manual refresh
        // skips this — the reason to press it is a row that looks wrong, and
        // waiting out the grace period is exactly what the user is trying to
        // avoid.
        if !forceVerify, quietFor < livenessGracePeriod { return true }

        switch ProcessLiveness.check(pid: entry.pid, startedAt: entry.pidStartedAt) {
        case .alive:
            return true

        case .unverifiable:
            // Some process holds this pid but we cannot prove it is the same
            // one. Showing it is the lesser error briefly — a live session with
            // no start time recorded is a real case — but trusting it forever
            // lets a recycled pid pin a dead row on screen, so it is time-boxed.
            guard quietFor < staleThreshold else { break }
            return true

        case .gone:
            break
        }

        removeIfUnchanged(url, since: modifiedAt)
        return false
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Deletes only the file that was actually judged dead.
    ///
    /// The writer replaces entries atomically, so between reading one and
    /// deciding to delete it the agent may have re-registered under the same
    /// name. Deleting that replacement would be permanent: the lifecycle hooks
    /// update entries but refuse to create them, so the session would never
    /// come back until it restarted.
    static func removeIfUnchanged(_ url: URL, since modifiedAt: Date?) {
        guard let modifiedAt, let current = modificationDate(of: url), current == modifiedAt
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Sessions currently blocked on an approval, keyed the way the registry is.
    ///
    /// Codex needs care: a pending file's `session_id` is the approval's own
    /// UUID, and `codex_session_id` is the session. Keying on the wrong one
    /// silently overlays nothing.
    private static func blockedSessionKeys(_ pending: [PendingData]) -> Set<String> {
        var keys: Set<String> = []
        for item in pending {
            // A tombstoned or expired approval is not blocking anyone.
            if item.hookExited == true || item.isExpired { continue }
            switch item.agent {
            case "codex":
                if let sid = item.codex_session_id { keys.insert("codex_\(sid)") }
            default:
                if let sid = item.session_id { keys.insert("claude-code_\(sid)") }
            }
        }
        return keys
    }

    private static func makeRow(_ entry: AgentRegistryEntry, blocked: Set<String>) -> ActiveAgentRow {
        let id = "\(entry.kind.rawValue)_\(entry.sessionId)"
        let state: AgentState = blocked.contains(id)
            ? .waitingApproval
            : (entry.state == "working" ? .working : .idle)

        return ActiveAgentRow(
            id: id,
            kind: entry.kind,
            pid: entry.pid,
            pidStartedAt: entry.pidStartedAt,
            projectName: sanitize(lastPathComponent(entry.cwd), limit: 28),
            fullPath: sanitize(entry.cwd, limit: 120),
            gitBranch: entry.gitBranch.map { sanitize($0, limit: 24) },
            model: entry.model.map { sanitize(shortModelName($0), limit: 20) },
            tmuxSession: entry.tmuxSession.flatMap { sanitizedOptional($0, limit: 48) },
            skill: entry.skill.map { sanitize($0, limit: 24) },
            skillSource: entry.skillSource,
            lastTool: entry.lastTool.map { sanitize($0, limit: 20) },
            state: state,
            heartbeatAt: entry.heartbeatAt
        )
    }

    private static func lastPathComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// `claude-opus-5` reads as `opus-5` in a 480pt popover.
    private static func shortModelName(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }

    /// Registry values originate outside the app, so they are treated as
    /// untrusted display input: control characters are stripped and length is
    /// capped, otherwise a crafted branch or path could disrupt the panel.
    private static func sanitize(_ text: String, limit: Int) -> String {
        let cleaned = text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit - 1)) + "…"
    }

    private static func sanitizedOptional(_ text: String, limit: Int) -> String? {
        let sanitized = sanitize(text, limit: limit).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }
}
