import Foundation

enum CodexUsageService {
    private static let maximumFileCount = 20
    private static let maximumFileBytes: UInt64 = 50_000_000
    private static let maximumReadBytes: UInt64 = 4_000_000
    private static let maximumTotalReadBytes: UInt64 = 20_000_000
    private static let maximumFutureDrift: TimeInterval = 300
    private static let maximumTimestampAge: TimeInterval = 366 * 24 * 3600

    private struct Event: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits?
        let info: TokenInfo?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
            case info
        }
    }

    /// The half of `token_count` this service used to discard. Codex states its
    /// own context window here, which makes it the one agent whose meter needs
    /// no externally maintained table.
    private struct TokenInfo: Decodable {
        let lastTokenUsage: TurnUsage?
        let modelContextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case lastTokenUsage = "last_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    private struct TurnUsage: Decodable {
        /// Total input for that turn, cached portion included — Codex reports
        /// `cached_input_tokens` as a subset of this, not as an addition to it.
        let inputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
        }
    }

    private struct RateLimits: Decodable {
        let primary: Limit?
        let secondary: Limit?
    }

    private struct Limit: Decodable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }

    private struct ScanResult {
        var latest: CodexUsageInfo?
        var hadReadError = false
        var bytesRead: UInt64 = 0
    }

    private final class ErrorFlag {
        var occurred = false
    }

    static func load() -> CodexUsageState {
        let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        return load(from: sessionsDirectory)
    }

    static func load(from sessionsDirectory: URL) -> CodexUsageState {
        guard directoryExists(sessionsDirectory) else {
            return FileManager.default.fileExists(atPath: sessionsDirectory.path)
                ? .error("Local Codex sessions path is invalid") : .unavailable
        }
        let root = sessionsDirectory.resolvingSymlinksInPath().standardizedFileURL
        var scan = ScanResult()
        let candidates = candidateFiles(in: root)
        scan.hadReadError = candidates.hadError
        let files = candidates.files
        for file in files where scan.bytesRead < maximumTotalReadBytes {
            scanFile(file, root: root, result: &scan)
        }
        if let latest = scan.latest { return .available(latest) }
        return scan.hadReadError ? .error("Local Codex usage could not be read") : .unavailable
    }

    static func parseEventLine(_ line: String, now: Date = Date()) -> CodexUsageInfo? {
        guard let data = line.data(using: .utf8),
              data.count <= 1_000_000,
              let event = try? JSONDecoder().decode(Event.self, from: data),
              event.type == "event_msg",
              event.payload.type == "token_count",
              let rateLimits = event.payload.rateLimits,
              let primary = rateLimits.primary,
              isValid(primary),
              let fetchedAt = validTimestamp(event.timestamp, now: now) else {
            return nil
        }
        let secondary: CodexWindowUsage? = rateLimits.secondary.flatMap { limit in
            guard isValid(limit), limit.windowMinutes != primary.windowMinutes else { return nil }
            return windowUsage(from: limit, fetchedAt: fetchedAt)
        }
        return CodexUsageInfo(
            primary: windowUsage(from: primary, fetchedAt: fetchedAt),
            secondary: secondary,
            fetchedAt: fetchedAt
        )
    }

    private static func isValid(_ limit: Limit) -> Bool {
        limit.usedPercent.isFinite
            && (0...100).contains(limit.usedPercent)
            && (1...525_600).contains(limit.windowMinutes)
    }

    private static func windowUsage(from limit: Limit, fetchedAt: Date) -> CodexWindowUsage {
        CodexWindowUsage(
            usedPercent: Int(limit.usedPercent.rounded()),
            windowMinutes: limit.windowMinutes,
            resetsAt: limit.resetsAt.flatMap { validResetDate($0, relativeTo: fetchedAt) }
        )
    }

    /// Context occupancy from one `token_count` line, or nil if this is not one.
    ///
    /// The last turn's input is what occupied the window; the running total is
    /// a spend figure and would climb past 100% within an hour of work.
    static func parseContextUsage(_ line: String) -> ContextUsage? {
        guard let data = line.data(using: .utf8),
              data.count <= 1_000_000,
              let event = try? JSONDecoder().decode(Event.self, from: data),
              event.type == "event_msg",
              event.payload.type == "token_count",
              let info = event.payload.info,
              let used = info.lastTokenUsage?.inputTokens,
              let window = info.modelContextWindow else { return nil }
        return ContextUsage(usedTokens: used, limitTokens: window)
    }

    /// The newest context reading in a session's own transcript.
    static func contextUsage(inTranscriptAt url: URL) -> ContextUsage? {
        // Later lines win: the file is append-only, so the last `token_count`
        // is the current state of that session.
        TranscriptTailReader.newest(of: url, decode: parseContextUsage)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func candidateFiles(in root: URL) -> (files: [URL], hadError: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let errorFlag = ErrorFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in errorFlag.occurred = true; return true }
        ) else {
            return ([], true)
        }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { isSafeCandidate($0, root: root) }
            .sorted { modificationDate($0) > modificationDate($1) }
            .prefix(maximumFileCount).map { $0 }
        return (files, errorFlag.occurred)
    }

    private static func isSafeCandidate(_ url: URL, root: URL) -> Bool {
        guard url.pathExtension == "jsonl",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return false
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(root.path + "/")
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func scanFile(_ file: URL, root: URL, result: inout ScanResult) {
        guard isSafeCandidate(file, root: root) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard size <= maximumFileBytes else { return }
            let allowance = min(maximumReadBytes, maximumTotalReadBytes - result.bytesRead)
            let readCount = min(size, allowance)
            try handle.seek(toOffset: size - readCount)
            let data = try handle.read(upToCount: Int(readCount)) ?? Data()
            result.bytesRead += UInt64(data.count)
            updateLatest(from: data, isSuffix: readCount < size, result: &result)
        } catch {
            result.hadReadError = true
        }
    }

    private static func updateLatest(from data: Data, isSuffix: Bool, result: inout ScanResult) {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if isSuffix, !lines.isEmpty { lines.removeFirst() }
        for bytes in lines {
            guard let line = String(data: Data(bytes), encoding: .utf8) else {
                result.hadReadError = true
                continue
            }
            guard let snapshot = parseEventLine(line) else { continue }
            if result.latest == nil || snapshot.fetchedAt > result.latest!.fetchedAt {
                result.latest = snapshot
            }
        }
    }

    private static func validTimestamp(_ raw: String, now: Date) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = precise.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            return nil
        }
        let interval = date.timeIntervalSince(now)
        guard interval <= maximumFutureDrift, interval >= -maximumTimestampAge else { return nil }
        return date
    }

    private static func validResetDate(_ seconds: TimeInterval, relativeTo eventDate: Date) -> Date? {
        guard seconds.isFinite else { return nil }
        let reset = Date(timeIntervalSince1970: seconds)
        let interval = reset.timeIntervalSince(eventDate)
        guard interval >= -maximumFutureDrift, interval <= 366 * 24 * 3600 else { return nil }
        return reset
    }
}
