import Foundation

/// Context occupancy from a Claude Code transcript.
///
/// Unlike Codex, which states its own window, Claude Code records only what
/// each turn consumed — the denominator comes from `ContextWindows`.
enum ClaudeTranscriptReader {
    /// What one assistant turn had in front of it.
    struct Turn: Equatable {
        let model: String?
        /// Everything the model was sent: fresh input plus both halves of the
        /// cache. Cached tokens are cheap, but they still occupy the window —
        /// counting only uncached input would report a 229K context as 2.
        let contextTokens: Int
    }

    private struct Line: Decodable {
        let type: String?
        let isSidechain: Bool?
        let message: Message?

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }

    /// One transcript line, or nil when it is not an assistant turn this
    /// session is accountable for.
    ///
    /// Sidechain lines are sub-agent turns written into the same file. They
    /// carry their own usage against their own context, so counting them would
    /// attribute a sub-agent's full window to the session that spawned it —
    /// and the last line of a busy transcript is very often a sub-agent's.
    static func parseTurn(_ line: String) -> Turn? {
        guard let data = line.data(using: .utf8),
              data.count <= 1_000_000,
              let parsed = try? JSONDecoder().decode(Line.self, from: data),
              parsed.type == "assistant",
              parsed.isSidechain != true,
              let usage = parsed.message?.usage else { return nil }

        let tokens = (usage.inputTokens ?? 0)
            + (usage.cacheCreationInputTokens ?? 0)
            + (usage.cacheReadInputTokens ?? 0)
        guard tokens > 0 else { return nil }
        return Turn(model: parsed.message?.model, contextTokens: tokens)
    }

    /// The newest turn in the transcript, measured against its own model's
    /// window. `fallbackModel` covers a turn that names no model — the registry
    /// records one too, in the shortened form the panel displays.
    static func contextUsage(inTranscriptAt url: URL, fallbackModel: String?) -> ContextUsage? {
        guard let turn = TranscriptTailReader.tailLines(of: url)
            .reversed()
            .lazy
            .compactMap(parseTurn)
            .first else { return nil }

        guard let window = ContextWindows.window(forModel: turn.model ?? fallbackModel) else {
            return nil
        }
        return ContextUsage(usedTokens: turn.contextTokens, limitTokens: window)
    }
}
