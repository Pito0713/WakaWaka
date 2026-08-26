import Foundation
import Testing
@testable import WakaWaka

struct ContextUsageTests {
    @Test func aMissingDenominatorHasNoUsageAtAll() {
        #expect(ContextUsage(usedTokens: 1_000, limitTokens: 0) == nil,
                "no denominator must be absent, not 0% — an empty bar reads as an empty context")
        #expect(ContextUsage(usedTokens: 1_000, limitTokens: -1) == nil)
        #expect(ContextUsage(usedTokens: -1, limitTokens: 200_000) == nil)
    }

    @Test func percentIsRoundedFromTheRealNumbers() {
        #expect(ContextUsage(usedTokens: 60_467, limitTokens: 258_400)?.percent == 23,
                "the measured Codex session this feature was built against")
        #expect(ContextUsage(usedTokens: 0, limitTokens: 200_000)?.percent == 0)
    }

    /// A model reporting more than its own stated window means the window is
    /// wrong; showing "117%" hands that confusion to the user to decode.
    @Test func aWindowSmallerThanTheUsageReadsAsFull() {
        let usage = ContextUsage(usedTokens: 234_000, limitTokens: 200_000)
        #expect(usage?.fraction == 1)
        #expect(usage?.percent == 100)
        #expect(usage?.band == .critical)
    }

    @Test(arguments: [
        (0, ContextBand.normal), (69, .normal),
        (70, .warning), (84, .warning),
        (85, .critical), (100, .critical),
    ])
    func eachBandStartsWhereItSays(percent: Int, expected: ContextBand) {
        #expect(ContextBand(percent: percent) == expected)
    }

    /// The colour is chosen from the percent the user can read, so the two can
    /// never disagree — 84.6% displays as 85% and must therefore be critical.
    @Test func theBandFollowsTheDisplayedNumberNotTheRawFraction() {
        let usage = ContextUsage(usedTokens: 169_200, limitTokens: 200_000)
        #expect(usage?.percent == 85)
        #expect(usage?.band == .critical)
    }
}

struct CodexContextParsingTests {
    /// Shape captured from a real `~/.codex/sessions/**/rollout-*.jsonl`
    /// (codex-cli 0.149.1, 2026-08-25). Hand-written JSON would drift from the
    /// producer without anyone noticing.
    private let realLine = """
    {"timestamp":"2026-08-25T02:59:34.428Z","type":"event_msg","payload":{"type":"token_count",\
    "info":{"total_token_usage":{"input_tokens":759552,"cached_input_tokens":691968,\
    "output_tokens":5610,"total_tokens":765162},"last_token_usage":{"input_tokens":60467,\
    "cached_input_tokens":58112,"output_tokens":239,"total_tokens":60706},\
    "model_context_window":258400},"rate_limits":{"primary":{"used_percent":30.0,\
    "window_minutes":10080,"resets_at":1788158054}}}}
    """

    @Test func theLastTurnDecidesOccupancyNotTheRunningTotal() throws {
        let usage = try #require(CodexUsageService.parseContextUsage(realLine))
        #expect(usage.usedTokens == 60_467, "the running total would climb past the window within an hour")
        #expect(usage.limitTokens == 258_400)
        #expect(usage.percent == 23)
        #expect(usage.band == .normal)
    }

    @Test func aLineWithoutTheTokenBlockYieldsNothing() {
        // Older Codex builds emit token_count with rate limits only.
        let noInfo = """
        {"timestamp":"2026-08-25T02:59:34.428Z","type":"event_msg","payload":{"type":"token_count",\
        "rate_limits":{"primary":{"used_percent":30.0,"window_minutes":10080}}}}
        """
        #expect(CodexUsageService.parseContextUsage(noInfo) == nil)
        #expect(CodexUsageService.parseContextUsage("not json at all") == nil)
        #expect(CodexUsageService.parseContextUsage("") == nil)
    }

    @Test func aWindowOfZeroIsNotAMeter() {
        let zeroWindow = """
        {"timestamp":"2026-08-25T02:59:34.428Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":10},"model_context_window":0}}}
        """
        #expect(CodexUsageService.parseContextUsage(zeroWindow) == nil)
    }

    @Test func theNewestReadingInTheFileWins() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("rollout.jsonl")
        let later = realLine.replacingOccurrences(of: "\"input_tokens\":60467",
                                                  with: "\"input_tokens\":193800")
        try "\(realLine)\n{\"type\":\"response_item\"}\n\(later)\n".write(to: file, atomically: true, encoding: .utf8)

        let usage = try #require(CodexUsageService.contextUsage(inTranscriptAt: file))
        #expect(usage.usedTokens == 193_800, "the transcript is append-only: the last reading is current")
        #expect(usage.percent == 75)
        #expect(usage.band == .warning)
    }
}

struct ClaudeTranscriptTests {
    /// Shape captured from a real ~/.claude/projects/**/<session>.jsonl, with
    /// the numbers measured on 2026-08-25.
    private func assistant(input: Int, cacheRead: Int, cacheWrite: Int = 0,
                           model: String = "claude-opus-5", sidechain: Bool = false) -> String {
        """
        {"type":"assistant","isSidechain":\(sidechain),"sessionId":"s1",        "message":{"model":"\(model)","usage":{"input_tokens":\(input),        "cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead),        "output_tokens":1017}}}
        """
    }

    /// Cached tokens are a tenth of the price but occupy the window in full.
    /// Counting only uncached input reports this 229K context as 2 tokens.
    @Test func cachedTokensStillOccupyTheWindow() throws {
        let turn = try #require(ClaudeTranscriptReader.parseTurn(
            assistant(input: 2, cacheRead: 228_495, cacheWrite: 492)))
        #expect(turn.contextTokens == 228_989)
        #expect(turn.model == "claude-opus-5")
    }

    /// A sub-agent writes its own turns into the parent's transcript. Its usage
    /// belongs to its own context, and the last line of a busy transcript is
    /// very often one of these.
    @Test func aSubAgentTurnIsNotThisSessionsContext() {
        #expect(ClaudeTranscriptReader.parseTurn(
            assistant(input: 5, cacheRead: 180_000, sidechain: true)) == nil)
        #expect(ClaudeTranscriptReader.parseTurn(
            #"{"type":"user","message":{"content":"hi"}}"#) == nil)
        #expect(ClaudeTranscriptReader.parseTurn("") == nil)
    }

    @Test func theNewestNonSidechainTurnIsTheOneThatCounts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")

        try [
            assistant(input: 10, cacheRead: 100_000),
            assistant(input: 5, cacheRead: 400_000, sidechain: true),   // sub-agent, ignored
            assistant(input: 8, cacheRead: 299_992),                    // the real newest
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let usage = try #require(ClaudeTranscriptReader.contextUsage(inTranscriptAt: file,
                                                                    fallbackModel: nil))
        #expect(usage.usedTokens == 300_000)
        #expect(usage.limitTokens == 1_000_000, "claude-opus-5 holds 1M, not 200K")
        #expect(usage.percent == 30)
    }

    /// A model absent from pricing.json has no denominator, so it gets no
    /// meter — never a guessed window.
    @Test func anUnknownModelHasNoMeter() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        try assistant(input: 10, cacheRead: 90_000, model: "claude-from-the-future")
            .appending("\n").write(to: file, atomically: true, encoding: .utf8)

        #expect(ClaudeTranscriptReader.contextUsage(inTranscriptAt: file, fallbackModel: nil) == nil)
    }

    /// Rows carry the shortened name the panel shows; the table is keyed by the
    /// full id, and both have to resolve.
    @Test func aShortenedModelNameStillFindsItsWindow() {
        let table = ["claude-opus-5": 1_000_000, "claude-haiku-4-5": 200_000]
        #expect(ContextWindows.window(forModel: "claude-opus-5", in: table) == 1_000_000)
        #expect(ContextWindows.window(forModel: "opus-5", in: table) == 1_000_000)
        #expect(ContextWindows.window(forModel: "haiku-4-5", in: table) == 200_000)
        #expect(ContextWindows.window(forModel: "gpt-5.6-sol", in: table) == nil)
        #expect(ContextWindows.window(forModel: nil, in: table) == nil)
    }

    /// The shipped table is the one the app actually reads.
    @Test func theShippedTableCoversTheModelsInUse() {
        #expect(ContextWindows.window(forModel: "claude-opus-5") == 1_000_000)
        #expect(ContextWindows.window(forModel: "haiku-4-5") == 200_000)
    }
}

struct TranscriptDefenceTests {
    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func assistantLine(cacheRead: Int, padding: Int = 0) -> String {
        """
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5",\
        "usage":{"input_tokens":2,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":9},\
        "text":"\(String(repeating: "x", count: padding))"}}
        """
    }

    /// An assistant line carries the whole message, so one long code block can
    /// exceed any fixed tail window — and because a truncated first line must
    /// be dropped, a window smaller than that line yields nothing at all. The
    /// meter then vanishes on exactly the sessions that most need it.
    @Test func aLastLineLongerThanTheFirstWindowIsStillFound() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        try "\(assistantLine(cacheRead: 299_998, padding: 80_000))\n"
            .write(to: file, atomically: true, encoding: .utf8)

        let usage = try #require(ClaudeTranscriptReader.contextUsage(inTranscriptAt: file,
                                                                    fallbackModel: nil))
        #expect(usage.usedTokens == 300_000)
        #expect(usage.percent == 30)
    }

    /// Swift's `+` traps on overflow, so three unbounded numbers read off disk
    /// are a crash waiting for a corrupt transcript. Rejected, not clamped: a
    /// clamped number would draw a confident meter out of nonsense.
    @Test func implausibleTokenCountsAreRefusedRatherThanSummed() {
        let huge = Int.max
        let line = """
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5",\
        "usage":{"input_tokens":\(huge),"cache_creation_input_tokens":\(huge),\
        "cache_read_input_tokens":\(huge),"output_tokens":1}}}
        """
        #expect(ClaudeTranscriptReader.parseTurn(line) == nil)

        let justOver = ClaudeTranscriptReader.plausibleTokenCeiling + 1
        let overLine = """
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5",\
        "usage":{"input_tokens":\(justOver),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":1}}}
        """
        #expect(ClaudeTranscriptReader.parseTurn(overLine) == nil)
        #expect(ClaudeTranscriptReader.parseTurn(assistantLine(cacheRead: 500))?.contextTokens == 502,
                "ordinary numbers still pass")
    }

    /// A fifo where a transcript used to be would block this thread on `open`,
    /// and one stuck thread arrives every five seconds.
    @Test func aFifoInPlaceOfATranscriptCannotBlockTheReader() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("session.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        #expect(TranscriptTailReader.tailLines(of: fifo).isEmpty)
        #expect(TranscriptTailReader.stamp(of: fifo) == nil)
    }

    /// `/.claude/` as a substring is satisfied by any directory anyone can
    /// create; the app must only open transcripts where transcripts live.
    @Test func aTranscriptPathOutsideTheHomeDirectoryIsRefused() {
        let home = "/tmp/agent-home"
        let check = { AgentRegistryService.validatedTranscriptPath($0, home: home) }

        #expect(check("\(home)/.claude/projects/-x/s.jsonl") == "\(home)/.claude/projects/-x/s.jsonl")
        #expect(check("\(home)/.codex/sessions/2026/r.jsonl") == "\(home)/.codex/sessions/2026/r.jsonl")
        #expect(check("/tmp/anywhere/.claude/s.jsonl") == nil, "a substring match is not a root")
        #expect(check("/tmp/another-home/.claude/s.jsonl") == nil, "another home is not this one")
        #expect(check("\(home)/.claude/../../etc/passwd") == nil)
        #expect(check("\(home)/Documents/notes.jsonl") == nil)
    }
}

struct ContextUsageCacheTests {
    private func row(id: String, kind: AgentKind, path: String, model: String?) -> ActiveAgentRow {
        ActiveAgentRow(
            id: id, kind: kind, pid: 1, pidStartedAt: nil,
            projectName: "demo", fullPath: "/demo", gitBranch: nil, model: model,
            transcriptPath: path, skill: nil, skillSource: nil, lastTool: nil,
            state: .idle, heartbeatAt: Date()
        )
    }

    /// The file is unchanged, but the row has gained the model that supplies
    /// its denominator. Keyed on the file alone, the cached "no meter" answer
    /// would outlive the reason it was given.
    @Test func gainingAModelInvalidatesACachedMiss() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("session.jsonl")
        // No model on the turn itself, so the row's own model decides.
        try #"""
        {"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":249990,"output_tokens":1}}}
        """#.appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let unknown = row(id: "a", kind: .claudeCode, path: file.path, model: nil)
        #expect(ContextUsageService.usage(for: [unknown]).isEmpty, "no denominator yet")

        let known = row(id: "a", kind: .claudeCode, path: file.path, model: "opus-5")
        let usage = try #require(ContextUsageService.usage(for: [known])["a"])
        #expect(usage.percent == 25)
    }

    @Test func aSessionThatEndsLeavesNothingBehind() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        try #"""
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":99990,"output_tokens":1}}}
        """#.appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let live = row(id: "b", kind: .claudeCode, path: file.path, model: nil)
        #expect(ContextUsageService.usage(for: [live])["b"] != nil)
        #expect(ContextUsageService.usage(for: []).isEmpty)
    }
}

struct TranscriptTailReaderTests {
    private func write(_ contents: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Reading from the middle of a file lands mid-line. Half a JSON object is
    /// not a record, and keeping it would make every large transcript look
    /// corrupt.
    @Test func aPartialFirstLineIsDropped() throws {
        let file = try write("aaaaaaaaaaaaaaaa\nbbbb\ncccc\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        // 12 bytes back lands inside the first line: "a\nbbbb\ncccc\n".
        #expect(TranscriptTailReader.tailLines(of: file, limitBytes: 12) == ["bbbb", "cccc"])
        #expect(TranscriptTailReader.tailLines(of: file) == ["aaaaaaaaaaaaaaaa", "bbbb", "cccc"],
                "a whole file has no partial first line to drop")
    }

    @Test func aMissingFileIsEmptyRatherThanFatal() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")
        #expect(TranscriptTailReader.tailLines(of: missing).isEmpty)
        #expect(TranscriptTailReader.stamp(of: missing) == nil)
    }

    @Test func aDirectoryIsNotATranscript() throws {
        let file = try write("x\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(TranscriptTailReader.stamp(of: file.deletingLastPathComponent()) == nil,
                "only regular files: a fifo here would block the reader forever")
        #expect(TranscriptTailReader.stamp(of: file) != nil)
    }
}
