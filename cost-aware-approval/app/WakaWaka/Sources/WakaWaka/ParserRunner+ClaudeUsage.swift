import Foundation

/// Server-verified usage: runs `claude -p "/usage"` and parses its session and weekly lines.
extension ParserRunner {
    // MARK: - claude -p "/usage"

    /// Path to the `claude` CLI binary, found via the same PATH as the parser.
    /// Looked up on every call (every ten minutes) so that reinstalling the CLI
    /// a different way — npm → native, a moved symlink — is picked up without
    /// restarting an app that may have been running for days.
    static var claudePath: String? {
        findExecutable(named: "claude", searchPath: buildEnv()["PATH"] ?? "")
    }

    static func findExecutable(named name: String, searchPath: String) -> String? {
        for dir in searchPath.split(separator: ":").map(String.init) {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs `claude -p "/usage"` and parses the output for server-side session % and reset time.
    /// Blocks up to 15 s. Returns nil if the binary is not found or output is unparseable.
    static func runClaudeUsage() -> ClaudeUsageInfo? {
        guard let exe = claudePath else {
            NSLog("[WakaWaka] claude CLI not found on PATH — server-verified usage unavailable")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments     = ["-p", "/usage"]
        process.environment   = buildEnv()
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        do { try process.run() } catch {
            NSLog("[WakaWaka] claude -p \"/usage\" failed to launch: %@", error.localizedDescription)
            return nil
        }

        var stderrData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }

        let timeoutItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutItem)

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()
        errGroup.wait()

        let text = String(data: data, encoding: .utf8) ?? ""
        if let info = parseUsageOutput(text) { return info }

        // Returning nil freezes the Claude bar on the local JSONL estimate until
        // the next 10-minute poll. Without this line nothing anywhere says why —
        // the bar just sits at a number the user cannot reconcile with the CLI.
        NSLog("[WakaWaka] claude -p \"/usage\" gave no session %% (exit %d) — stdout: %@ | stderr: %@",
              process.terminationStatus,
              excerpt(text),
              excerpt(String(data: stderrData, encoding: .utf8) ?? ""))
        return nil
    }

    /// Keeps a failure log to one readable line; these outputs run to many lines.
    static func excerpt(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<empty>" }
        return String(trimmed.prefix(300)).replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    static func parseUsageOutput(_ text: String) -> ClaudeUsageInfo? {
        var sessionPct: Int? = nil
        var sessionReset: Date? = nil
        var weeklyPct: Int? = nil
        var weeklyReset: Date? = nil

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

            // Take the first "Current week" line (all models); it drives the weekly cap.
            if line.hasPrefix("Current week"), weeklyPct == nil {
                let ns = line as NSString
                if let m = pctRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let r = Range(m.range(at: 1), in: line) {
                    weeklyPct = Int(line[r])
                }
                if let m = resetRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                   let r = Range(m.range(at: 1), in: line) {
                    weeklyReset = parseClaudeDate(String(line[r]))
                }
            }
        }

        guard let pct = sessionPct else { return nil }
        return ClaudeUsageInfo(sessionPct: pct, sessionReset: sessionReset,
                               weeklyPct: weeklyPct, weeklyReset: weeklyReset, fetchedAt: Date())
    }

    /// Parses Claude's reset date strings, e.g. "Jun 20 at 5:50pm (Asia/Taipei)" or "Jun 25 at 10am (UTC)".
    static func parseClaudeDate(_ raw: String) -> Date? {
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
}
