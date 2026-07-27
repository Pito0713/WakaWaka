import Foundation
import XCTest
@testable import WakaWaka

final class CodexUsageServiceTests: XCTestCase {
    private func event(percent: Double, timestamp: String, window: Int = 10_080) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\(percent),"window_minutes":\(window)}}}}
        """
    }

    private func timestamp(secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func availableInfo(_ state: CodexUsageState) throws -> CodexUsageInfo {
        guard case .available(let info) = state else {
            throw NSError(domain: "CodexUsageServiceTests", code: 1)
        }
        return info
    }

    func testParsesAccountRateLimitSnapshot() throws {
        let line = """
        {"timestamp":"2026-07-23T03:30:59.917Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.4,"window_minutes":10080,"resets_at":1785373196}}}}
        """

        let result = try XCTUnwrap(CodexUsageService.parseEventLine(line))

        XCTAssertEqual(result.usedPercent, 42)
        XCTAssertEqual(result.windowMinutes, 10_080)
        XCTAssertNotNil(result.resetsAt)
    }

    func testRejectsContextOnlyTokenCount() {
        let line = """
        {"timestamp":"2026-07-23T03:30:59Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        """

        XCTAssertNil(CodexUsageService.parseEventLine(line))
    }

    func testMissingSessionsDirectoryIsUnavailable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertEqual(CodexUsageService.load(from: missing), .unavailable)
    }

    func testUnreadableSessionsPathIsError() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        guard case .error = CodexUsageService.load(from: file) else {
            return XCTFail("Expected an error state")
        }
    }

    func testSelectsNewestTimestampAcrossFilesNotNewestModificationDate() throws {
        let directory = try temporaryDirectory()
        let olderEvent = directory.appendingPathComponent("newer-mtime.jsonl")
        let newerEvent = directory.appendingPathComponent("older-mtime.jsonl")
        try event(percent: 10, timestamp: timestamp(secondsAgo: 120)).write(to: olderEvent, atomically: true, encoding: .utf8)
        try event(percent: 80, timestamp: timestamp(secondsAgo: 60)).write(to: newerEvent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: olderEvent.path)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: newerEvent.path)

        XCTAssertEqual(try availableInfo(CodexUsageService.load(from: directory)).usedPercent, 80)
    }

    func testSelectsNewestTimestampWithinFile() throws {
        let directory = try temporaryDirectory()
        let content = [
            event(percent: 70, timestamp: timestamp(secondsAgo: 60)),
            event(percent: 20, timestamp: timestamp(secondsAgo: 120)),
        ].joined(separator: "\n")
        try content.write(to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try availableInfo(CodexUsageService.load(from: directory)).usedPercent, 70)
    }

    func testCorruptFileDoesNotHideValidFile() throws {
        let directory = try temporaryDirectory()
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

        XCTAssertEqual(try availableInfo(CodexUsageService.load(from: directory)).usedPercent, 55)
    }

    func testRejectsSymlink() throws {
        let directory = try temporaryDirectory()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try event(percent: 99, timestamp: timestamp(secondsAgo: 60)).write(to: outside, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linked.jsonl"),
            withDestinationURL: outside
        )

        XCTAssertEqual(CodexUsageService.load(from: directory), .unavailable)
    }

    func testSkipsOversizedFile() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("oversized.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 50_000_001)
        try handle.close()

        XCTAssertEqual(CodexUsageService.load(from: directory), .unavailable)
    }

    func testRejectsFutureTimestampAndInvalidBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(301))
        XCTAssertNil(CodexUsageService.parseEventLine(event(percent: 50, timestamp: future), now: now))

        let current = ISO8601DateFormatter().string(from: now)
        XCTAssertNil(CodexUsageService.parseEventLine(event(percent: -0.1, timestamp: current), now: now))
        XCTAssertNil(CodexUsageService.parseEventLine(event(percent: 100.1, timestamp: current), now: now))
        XCTAssertNil(CodexUsageService.parseEventLine(event(percent: 50, timestamp: current, window: 0), now: now))
        XCTAssertNil(CodexUsageService.parseEventLine(event(percent: 50, timestamp: current, window: 525_601), now: now))
    }

    func testMinuteWindowText() {
        let info = CodexUsageInfo(
            usedPercent: 1,
            windowMinutes: 59,
            resetsAt: nil,
            fetchedAt: Date()
        )
        XCTAssertEqual(info.windowText, "59m window")
    }
}
