import Foundation

enum ParserRunner {
    // Resolution order:
    //   1. WAKAWAKA_PARSER_DIR env var (explicit override)
    //   2. Relative to binary: <repo>/cost-aware-approval/app/WakaWaka/.build/<cfg>/WakaWaka
    //      → navigate up 5 levels → <repo>/cost-aware-approval/parser/
    //   3. ~/WakaWaka/cost-aware-approval/parser/ (conventional fallback)
    //
    // Re-resolved on every call rather than cached in a `static let`: the app
    // runs for days, and a cached path that goes stale never heals. A few
    // `fileExists` checks cost nothing next to the `npx tsx` launch they precede.
    static var parserDir: String {
        resolveParserDir(environment: ProcessInfo.processInfo.environment,
                         binaryPath: CommandLine.arguments[0],
                         home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func resolveParserDir(environment: [String: String], binaryPath: String, home: String) -> String {
        let fm = FileManager.default

        if let env = environment["WAKAWAKA_PARSER_DIR"],
           fm.fileExists(atPath: "\(env)/usage-calculator.ts") {
            return env
        }

        let binaryURL = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
        let candidate = binaryURL
            .deletingLastPathComponent()          // <cfg>/ (debug or release)
            .deletingLastPathComponent()          // .build/
            .deletingLastPathComponent()          // WakaWaka/
            .deletingLastPathComponent()          // app/
            .deletingLastPathComponent()          // cost-aware-approval/
            .appendingPathComponent("parser")
            .path
        if fm.fileExists(atPath: "\(candidate)/usage-calculator.ts") { return candidate }

        return "\(home)/WakaWaka/cost-aware-approval/parser"
    }

    static var calculatorPath: String { "\(parserDir)/usage-calculator.ts" }

    /// The rate and context-window table lives beside the parser that also
    /// reads it, so both find it by the same three-step search.
    static var pricingPath: String    { "\(parserDir)/pricing.json" }
    static var p90Path: String        { "\(parserDir)/p90-detector.ts" }
    static var dailyUsagePath: String { "\(parserDir)/daily-usage.ts" }
    static var phaseUsagePath: String { "\(parserDir)/phase-usage.ts" }

    // MARK: - Public API

    /// Synchronously runs the TypeScript usage parser; returns nil on failure.
    static func run(transcriptPath: String) -> UsageOutput? {
        runScript(scriptPath: calculatorPath, extraArgs: [transcriptPath], timeout: 10)
            .flatMap { try? JSONDecoder().decode(UsageOutput.self, from: $0) }
    }

    /// Aggregates session usage across ALL recent JSONL files in ~/.claude/projects.
    /// Fixes the single-file undercounting when multiple conversations are active.
    static func runAggregated() -> UsageOutput? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
        return runScript(scriptPath: calculatorPath,
                         extraArgs: ["--aggregate", projectsDir],
                         timeout: 20)
            .flatMap { try? JSONDecoder().decode(UsageOutput.self, from: $0) }
    }

    /// Runs the P90 plan-limit detector across all ~/.claude/projects/**\/*.jsonl.
    /// Blocks up to 60s; returns nil on failure or insufficient data.
    static func runP90Detector() -> P90Result? {
        runScript(scriptPath: p90Path, extraArgs: [], timeout: 60)
            .flatMap { try? JSONDecoder().decode(P90Result.self, from: $0) }
    }

    /// Aggregates per-day, per-agent usage over the last `days` days for the dashboard.
    /// Blocks up to 30s; returns nil on failure.
    static func runDailyUsage(days: Int) -> DailyUsage? {
        runScript(scriptPath: dailyUsagePath, extraArgs: ["--days", String(days)], timeout: 30)
            .flatMap { try? JSONDecoder().decode(DailyUsage.self, from: $0) }
    }

    /// Bucket the last `days` days of API calls by activity phase.
    /// Blocks up to 60s — it reads message content, not just usage totals, so
    /// it scans more of each transcript than `runDailyUsage`. Returns nil on failure.
    static func runPhaseUsage(days: Int) -> PhaseUsage? {
        runScript(scriptPath: phaseUsagePath, extraArgs: ["--days", String(days)], timeout: 60)
            .flatMap { try? JSONDecoder().decode(PhaseUsage.self, from: $0) }
    }

    // MARK: - Shared process runner

    /// The command that runs a parser script, before the script's own arguments.
    ///
    /// With the parser's pinned `tsx` installed (`npm ci` in parser/), node
    /// loads it directly. `npx` is the fallback only: resolving the package
    /// costs ~0.4s per launch, which was ~70% of every 60-second refresh.
    static func scriptCommand(parserDir: String, scriptPath: String) -> [String] {
        let localTsx = "\(parserDir)/node_modules/tsx/package.json"
        if FileManager.default.fileExists(atPath: localTsx) {
            return ["node", "--import", "tsx", scriptPath]
        }
        return ["npx", "--yes", "tsx", scriptPath]
    }

    /// Runs a parser script (see `scriptCommand`) and returns stdout Data, or nil on error/timeout.
    static func runScript(scriptPath: String, extraArgs: [String], timeout: TimeInterval) -> Data? {
        let dir = parserDir
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = scriptCommand(parserDir: dir, scriptPath: scriptPath) + extraArgs
        // `--import tsx` is a bare specifier, resolved from the working directory.
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.environment = buildEnv()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe
        // Close stdin so interactive prompts (e.g. tsx first-run) don't block indefinitely.
        process.standardInput  = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // Drain stderr on a background thread to prevent pipe buffer deadlock (64KB limit).
        // Captured content is logged via NSLog (visible in Console.app) when the script fails.
        var stderrData = Data()
        let stderrGroup = DispatchGroup()
        stderrGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrGroup.leave()
        }

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        // Read stdout BEFORE waitUntilExit: readDataToEndOfFile blocks until the pipe closes
        // (i.e. the process exits), so waitUntilExit returns immediately after. Reversing the
        // order risks deadlock when stdout approaches the 64KB pipe buffer limit.
        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        stderrGroup.wait()

        guard process.terminationStatus == 0 else {
            if let msg = String(data: stderrData, encoding: .utf8), !msg.isEmpty {
                NSLog("[WakaWaka] parser stderr: %@", msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        return output
    }

    // Builds PATH that covers nvm's active node version, Homebrew, and the inherited PATH.
    static func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var extras: [String] = []

        if let nvmBin = resolveNvmBin(home: home, env: env) {
            extras.append(nvmBin)
        }
        extras += ["/opt/homebrew/bin", "/usr/local/bin"]

        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")

        // Marks every child process as WakaWaka's own. `runClaudeUsage` shells
        // out to `claude -p "/usage"` every ten minutes, which fires the same
        // SessionStart/Stop hooks a real session does — without this the panel
        // would list WakaWaka as an active agent, blinking on a timer. The
        // lifecycle hooks check this variable and no-op.
        env["WAKAWAKA_INTERNAL"] = "1"
        return env
    }

    // Resolves the active nvm node bin dir, respecting NVM_DIR and recursive alias chains.
    // Handles direct versions ("v20.14.0"), bare versions ("20.14.0"), and named aliases
    // ("node", "lts/*") by following alias files up to 5 levels deep.
    // Falls back to the semantically newest installed version when aliases can't be resolved.
    // Returns nil when nvm is not installed.
    static func resolveNvmBin(home: String, env: [String: String]) -> String? {
        let nvmDir = env["NVM_DIR"] ?? "\(home)/.nvm"
        let fm = FileManager.default
        guard fm.fileExists(atPath: nvmDir) else { return nil }

        func resolveAlias(_ name: String, depth: Int = 0) -> String? {
            guard depth < 5 else { return nil }
            let aliasFile = "\(nvmDir)/alias/\(name)"
            guard let content = try? String(contentsOfFile: aliasFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }

            // If it looks like a version number, verify the directory exists.
            let ver = content.hasPrefix("v") ? content : "v\(content)"
            if ver.dropFirst().first?.isNumber == true {
                let path = "\(nvmDir)/versions/node/\(ver)/bin"
                if fm.fileExists(atPath: path) { return path }
            }

            // Follow as a nested alias ("node", "lts/*", etc.)
            return resolveAlias(content, depth: depth + 1)
        }

        if let bin = resolveAlias("default") { return bin }

        // Fallback: pick the semantically newest installed version.
        // Lexicographic sort breaks for v9.x vs v18.x; use semver comparison instead.
        let versionsDir = "\(nvmDir)/versions/node"
        guard let entries = try? fm.contentsOfDirectory(atPath: versionsDir) else { return nil }

        func semver(_ tag: String) -> (Int, Int, Int) {
            let parts = tag.dropFirst().split(separator: ".").compactMap { Int($0) }
            return (parts.indices.contains(0) ? parts[0] : 0,
                    parts.indices.contains(1) ? parts[1] : 0,
                    parts.indices.contains(2) ? parts[2] : 0)
        }

        let newest = entries
            .filter { $0.hasPrefix("v") }
            .sorted { semver($0) < semver($1) }
            .last
        return newest.map { "\(versionsDir)/\($0)/bin" }
    }
}
