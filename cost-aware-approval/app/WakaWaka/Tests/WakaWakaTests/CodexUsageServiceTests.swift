import Foundation
import Testing
@testable import WakaWaka

/// swift-testing rather than XCTest — see CodexApprovalTests for why.
///
/// XCTest's `addTeardownBlock` has no swift-testing equivalent, so temporary
/// directories are cleaned up with an explicit `defer` in each test. Every
/// fixture path is UUID-based, which also keeps these safe under swift-testing's
/// parallel execution.
struct CodexUsageServiceTests {
    private func event(percent: Double, timestamp: String, window: Int = 10_080) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\(percent),"window_minutes":\(window)}}}}
        """
    }

    private func timestamp(secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
    }

    /// Caller owns cleanup: `defer { try? FileManager.default.removeItem(at: dir) }`.
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func availableInfo(_ state: CodexUsageState) throws -> CodexUsageInfo {
        guard case .available(let info) = state else {
            throw NSError(domain: "CodexUsageServiceTests", code: 1)
        }
        return info
    }

    @Test func parsesAccountRateLimitSnapshot() throws {
        let line = """
        {"timestamp":"2026-07-23T03:30:59.917Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.4,"window_minutes":10080,"resets_at":1785373196}}}}
        """

        let result = try #require(CodexUsageService.parseEventLine(line))

        #expect(result.usedPercent == 42)
        #expect(result.windowMinutes == 10_080)
        #expect(result.resetsAt != nil)
    }

    @Test func rejectsContextOnlyTokenCount() {
        let line = """
        {"timestamp":"2026-07-23T03:30:59Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        """

        #expect(CodexUsageService.parseEventLine(line) == nil)
    }

    @Test func missingSessionsDirectoryIsUnavailable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        #expect(CodexUsageService.load(from: missing) == .unavailable)
    }

    @Test func unreadableSessionsPathIsError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        guard case .error = CodexUsageService.load(from: file) else {
            Issue.record("Expected an error state")
            return
        }
    }

    @Test func selectsNewestTimestampAcrossFilesNotNewestModificationDate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let olderEvent = directory.appendingPathComponent("newer-mtime.jsonl")
        let newerEvent = directory.appendingPathComponent("older-mtime.jsonl")
        try event(percent: 10, timestamp: timestamp(secondsAgo: 120)).write(to: olderEvent, atomically: true, encoding: .utf8)
        try event(percent: 80, timestamp: timestamp(secondsAgo: 60)).write(to: newerEvent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: olderEvent.path)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: newerEvent.path)

        #expect(try availableInfo(CodexUsageService.load(from: directory)).usedPercent == 80)
    }

    @Test func selectsNewestTimestampWithinFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let content = [
            event(percent: 70, timestamp: timestamp(secondsAgo: 60)),
            event(percent: 20, timestamp: timestamp(secondsAgo: 120)),
        ].joined(separator: "\n")
        try content.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        #expect(try availableInfo(CodexUsageService.load(from: directory)).usedPercent == 70)
    }

    @Test func corruptFileDoesNotHideValidFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "{invalid".write(
            to: directory.appendingPathComponent("corrupt.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try event(percent: 55, timestamp: timestamp(secondsAgo: 60)).write(
            to: directory.appendingPathComponent("valid.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        #expect(try availableInfo(CodexUsageService.load(from: directory)).usedPercent == 55)
    }

    @Test func rejectsSymlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try event(percent: 99, timestamp: timestamp(secondsAgo: 60)).write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.jsonl"),
            withDestinationURL: outside
        )

        #expect(CodexUsageService.load(from: directory) == .unavailable)
    }

    @Test func skipsOversizedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("oversized.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 50_000_001)
        try handle.close()

        #expect(CodexUsageService.load(from: directory) == .unavailable)
    }

    @Test func rejectsFutureTimestampAndInvalidBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(301))
        #expect(CodexUsageService.parseEventLine(event(percent: 50, timestamp: future), now: now) == nil)

        let current = ISO8601DateFormatter().string(from: now)
        #expect(CodexUsageService.parseEventLine(event(percent: -0.1, timestamp: current), now: now) == nil)
        #expect(CodexUsageService.parseEventLine(event(percent: 100.1, timestamp: current), now: now) == nil)
        #expect(CodexUsageService.parseEventLine(event(percent: 50, timestamp: current, window: 0), now: now) == nil)
        #expect(CodexUsageService.parseEventLine(event(percent: 50, timestamp: current, window: 525_601), now: now) == nil)
    }

    @Test func minuteWindowText() {
        let info = CodexUsageInfo(
            usedPercent: 1,
            windowMinutes: 59,
            resetsAt: nil,
            fetchedAt: Date()
        )
        #expect(info.windowText == "59m window")
    }
}
