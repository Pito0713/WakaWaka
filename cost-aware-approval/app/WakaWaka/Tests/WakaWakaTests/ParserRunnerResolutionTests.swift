import Foundation
import Testing
@testable import WakaWaka

/// The app runs for days, so path lookups must notice a change on disk at the
/// next call. Each test mutates the filesystem between two lookups and expects
/// the second to differ — a cached result would fail them.
struct ParserRunnerResolutionTests {
    /// Caller owns cleanup: `defer { try? FileManager.default.removeItem(at: dir) }`.
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    @Test func findsExecutableInstalledAfterAnEarlierMiss() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let searchPath = "\(first.path):\(second.path)"

        #expect(ParserRunner.findExecutable(named: "claude", searchPath: searchPath) == nil)

        try makeExecutable(at: second.appendingPathComponent("claude"))
        #expect(ParserRunner.findExecutable(named: "claude", searchPath: searchPath)
                == second.appendingPathComponent("claude").path)
    }

    @Test func followsExecutableWhenItMovesToAnotherDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldInstall = root.appendingPathComponent("npm-bin/claude")
        let newInstall = root.appendingPathComponent("local-bin/claude")
        let searchPath = "\(oldInstall.deletingLastPathComponent().path):\(newInstall.deletingLastPathComponent().path)"

        try makeExecutable(at: oldInstall)
        #expect(ParserRunner.findExecutable(named: "claude", searchPath: searchPath) == oldInstall.path)

        try FileManager.default.removeItem(at: oldInstall)
        try makeExecutable(at: newInstall)
        #expect(ParserRunner.findExecutable(named: "claude", searchPath: searchPath) == newInstall.path)
    }

    @Test func skipsNonExecutableFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("claude").path,
                                       contents: Data(), attributes: [.posixPermissions: 0o644])

        #expect(ParserRunner.findExecutable(named: "claude", searchPath: root.path) == nil)
    }

    @Test func parserDirPrefersEnvOverrideOnlyWhileItHoldsTheParser() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let override = root.appendingPathComponent("override")
        try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
        let marker = override.appendingPathComponent("usage-calculator.ts")
        FileManager.default.createFile(atPath: marker.path, contents: Data())

        let environment = ["WAKAWAKA_PARSER_DIR": override.path]
        let binaryPath = root.appendingPathComponent("nowhere/WakaWaka").path
        let home = root.path
        let fallback = "\(home)/WakaWaka/cost-aware-approval/parser"

        #expect(ParserRunner.resolveParserDir(environment: environment, binaryPath: binaryPath, home: home)
                == override.path)

        try FileManager.default.removeItem(at: marker)
        #expect(ParserRunner.resolveParserDir(environment: environment, binaryPath: binaryPath, home: home)
                == fallback)
    }

    @Test func parserDirFindsRepoRelativeToBinary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("cost-aware-approval")
        let parser = repo.appendingPathComponent("parser")
        try FileManager.default.createDirectory(at: parser, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: parser.appendingPathComponent("usage-calculator.ts").path,
                                       contents: Data())
        let binaryPath = repo.appendingPathComponent("app/WakaWaka/.build/debug/WakaWaka").path

        #expect(ParserRunner.resolveParserDir(environment: [:], binaryPath: binaryPath, home: root.path)
                == parser.path)
    }
}
