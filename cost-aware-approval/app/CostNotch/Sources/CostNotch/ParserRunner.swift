import Foundation

enum ParserRunner {
    // TODO: replace hardcoded path with dynamic PATH resolution post-MVP
    private static let npxPath = "/Users/wits/.nvm/versions/node/v20.14.0/bin/npx"
    private static let calculatorPath: String = {
        // Resolve relative to this source file's directory: ../../../../parser/usage-calculator.ts
        // At runtime, use the known project path.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/TokenGremlin/cost-aware-approval/parser/usage-calculator.ts"
    }()

    /// Timeout for parser subprocess (10 seconds)
    private static let timeoutSeconds: TimeInterval = 10

    /// Synchronously runs the TypeScript parser and returns parsed UsageOutput, or nil on failure.
    static func run(transcriptPath: String) -> UsageOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npxPath)
        process.arguments = ["tsx", calculatorPath, transcriptPath]

        // Inject PATH so that tsx can find node and other tools
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/Users/wits/.nvm/versions/node/v20.14.0/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Kill process if it exceeds timeout to prevent zombie accumulation
        let timeoutWork = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)
        process.waitUntilExit()
        timeoutWork.cancel()

        guard process.terminationStatus == 0 else { return nil }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode(UsageOutput.self, from: data)
    }
}
