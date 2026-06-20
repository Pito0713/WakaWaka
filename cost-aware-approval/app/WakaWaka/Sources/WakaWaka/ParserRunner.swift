import Foundation

enum ParserRunner {
    // Resolution order:
    //   1. WAKAWAKA_PARSER_DIR env var (explicit override)
    //   2. Relative to binary: <repo>/cost-aware-approval/app/WakaWaka/.build/<cfg>/WakaWaka
    //      → navigate up 5 levels → <repo>/cost-aware-approval/parser/
    //   3. ~/WakaWaka/cost-aware-approval/parser/ (conventional fallback)
    private static let parserDir: String = {
        let fm = FileManager.default

        if let env = ProcessInfo.processInfo.environment["WAKAWAKA_PARSER_DIR"],
           fm.fileExists(atPath: "\(env)/usage-calculator.ts") {
            return env
        }

        let binaryURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = binaryURL
            .deletingLastPathComponent()          // <cfg>/ (debug or release)
            .deletingLastPathComponent()          // .build/
            .deletingLastPathComponent()          // WakaWaka/
            .deletingLastPathComponent()          // app/
            .deletingLastPathComponent()          // cost-aware-approval/
            .appendingPathComponent("parser")
            .path
        if fm.fileExists(atPath: "\(candidate)/usage-calculator.ts") { return candidate }

        let home = fm.homeDirectoryForCurrentUser.path
        return "\(home)/WakaWaka/cost-aware-approval/parser"
    }()

    private static let calculatorPath = "\(parserDir)/usage-calculator.ts"
    private static let p90Path        = "\(parserDir)/p90-detector.ts"

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

    // MARK: - Shared process runner

    /// Runs `npx tsx <scriptPath> [extraArgs]` and returns stdout Data, or nil on error/timeout.
    private static func runScript(scriptPath: String, extraArgs: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "--yes", "tsx", scriptPath] + extraArgs
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

    // MARK: - claude -p "/usage"

    /// Resolved path to the `claude` CLI binary, found via the same PATH as the parser.
    private static let claudePath: String? = {
        let env = buildEnv()
        for dir in (env["PATH"] ?? "").split(separator: ":").map(String.init) {
            let p = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    /// Runs `claude -p "/usage"` and parses the output for server-side session % and reset time.
    /// Blocks up to 15 s. Returns nil if the binary is not found or output is unparseable.
    static func runClaudeUsage() -> ClaudeUsageInfo? {
        guard let exe = claudePath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments     = ["-p", "/usage"]
        process.environment   = buildEnv()
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        do { try process.run() } catch { return nil }

        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }

        let timeoutItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutItem)

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()
        errGroup.wait()

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return parseUsageOutput(text)
    }

    private static func parseUsageOutput(_ text: String) -> ClaudeUsageInfo? {
        var sessionPct: Int? = nil
        var sessionReset: Date? = nil
        var weeklyPct: Int? = nil

        let pctRe   = try! NSRegularExpression(pattern: #"(\d+)% used"#)
        let resetRe = try! NSRegularExpression(pattern: #"resets (.+)$"#)

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Current session:") {
                let ns = line as NSString
                if let m = pctRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let r = Range(m.range(at: 1), in: line) {
                    sessionPct = Int(line[r])
                }
                if let m = resetRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let r = Range(m.range(at: 1), in: line) {
                    sessionReset = parseClaudeDate(String(line[r]))
                }
            }

            if line.hasPrefix("Current week") {
                let ns = line as NSString
                if let m = pctRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let r = Range(m.range(at: 1), in: line) {
                    weeklyPct = Int(line[r])
                }
            }
        }

        guard let pct = sessionPct else { return nil }
        return ClaudeUsageInfo(sessionPct: pct, sessionReset: sessionReset,
                               weeklyPct: weeklyPct, fetchedAt: Date())
    }

    /// Parses Claude's reset date strings, e.g. "Jun 20 at 5:50pm (Asia/Taipei)" or "Jun 25 at 10am (UTC)".
    private static func parseClaudeDate(_ raw: String) -> Date? {
        var str = raw.trimmingCharacters(in: .whitespaces)
        var tz  = TimeZone.current

        let tzRe  = try! NSRegularExpression(pattern: #"\(([^)]+)\)"#)
        let nsStr = str as NSString
        if let m = tzRe.firstMatch(in: str, range: NSRange(location: 0, length: nsStr.length)),
           let r = Range(m.range(at: 1), in: str),
           let zone = TimeZone(identifier: String(str[r])) {
            tz  = zone
            str = tzRe.stringByReplacingMatches(
                    in: str, options: [],
                    range: NSRange(location: 0, length: (str as NSString).length),
                    withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
        }

        let year     = Calendar.current.component(.year, from: Date())
        let withYear = "\(str) \(year)"

        let df = DateFormatter()
        df.locale   = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        for fmt in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy",
                    "MMM d 'at' h:mm a yyyy", "MMM d 'at' h a yyyy"] {
            df.dateFormat = fmt
            if let d = df.date(from: withYear) { return d }
        }
        return nil
    }

    // Builds PATH that covers nvm's active node version, Homebrew, and the inherited PATH.
    private static func buildEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var extras: [String] = []

        if let nvmBin = resolveNvmBin(home: home, env: env) {
            extras.append(nvmBin)
        }
        extras += ["/opt/homebrew/bin", "/usr/local/bin"]

        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        return env
    }

    // Resolves the active nvm node bin dir, respecting NVM_DIR and recursive alias chains.
    // Handles direct versions ("v20.14.0"), bare versions ("20.14.0"), and named aliases
    // ("node", "lts/*") by following alias files up to 5 levels deep.
    // Falls back to the semantically newest installed version when aliases can't be resolved.
    // Returns nil when nvm is not installed.
    private static func resolveNvmBin(home: String, env: [String: String]) -> String? {
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
