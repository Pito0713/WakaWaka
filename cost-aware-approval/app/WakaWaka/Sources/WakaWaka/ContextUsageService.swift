import Foundation

/// Context occupancy for the rows the panel is showing, keyed by row id.
///
/// Kept out of `AgentRegistryService.snapshot` on purpose. That runs on the
/// **main thread** every second (`AppDelegate` polls the state directory there),
/// and reading a transcript per row per second is exactly the kind of work that
/// freezes a popover mid-click. This is called from a background queue on a
/// slower cadence instead, and the result is merged at render time.
enum ContextUsageService {
    private struct CacheEntry {
        let stamp: TranscriptTailReader.Stamp
        /// Cached even when nil: a transcript with no readable usage should be
        /// re-read when it changes, not on every pass.
        let usage: ContextUsage?
    }

    private static let lock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    /// Rows with no transcript, or whose transcript has nothing to say, are
    /// simply absent from the result — the view draws no meter for them.
    static func usage(for rows: [ActiveAgentRow]) -> [String: ContextUsage] {
        let snapshot = withLock { cache }
        var fresh: [String: CacheEntry] = [:]
        var result: [String: ContextUsage] = [:]

        for row in rows {
            guard let path = row.transcriptPath else { continue }
            let url = URL(fileURLWithPath: path)
            guard let stamp = TranscriptTailReader.stamp(of: url) else { continue }

            if let cached = snapshot[row.id], cached.stamp == stamp {
                fresh[row.id] = cached
                if let usage = cached.usage { result[row.id] = usage }
                continue
            }

            let usage = read(kind: row.kind, at: url, fallbackModel: row.model)
            fresh[row.id] = CacheEntry(stamp: stamp, usage: usage)
            if let usage { result[row.id] = usage }
        }

        // Replacing rather than merging drops sessions that have ended, so the
        // cache cannot outgrow the panel it serves.
        withLock { cache = fresh }
        return result
    }

    /// Each agent states its context differently: Codex writes its own window
    /// into the transcript, Claude Code writes only what a turn consumed and
    /// takes its denominator from `pricing.json`.
    private static func read(kind: AgentKind, at url: URL, fallbackModel: String?) -> ContextUsage? {
        switch kind {
        case .codex:
            return CodexUsageService.contextUsage(inTranscriptAt: url)
        case .claudeCode:
            return ClaudeTranscriptReader.contextUsage(inTranscriptAt: url, fallbackModel: fallbackModel)
        }
    }

    /// Test seam: the cache is process-wide, so a case that seeds a transcript
    /// must be able to start from nothing.
    static func resetCache() {
        withLock { cache = [:] }
    }

    @discardableResult
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
