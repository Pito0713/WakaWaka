import Foundation

/// Context window sizes, read from the table the parser already maintains.
///
/// Claude Code states no window anywhere in its transcript — only what a turn
/// consumed — so the denominator has to come from outside. `pricing.json` is
/// where this project already keeps externally-sourced model facts, with a
/// `_date` beside them saying when they were last checked.
///
/// A model that is not in the table gets **no** meter. Guessing a default is
/// the worst option available: Claude Opus 5 holds 1M tokens, so a 200K guess
/// would render a perfectly healthy 229K session as 114% full, and the user
/// has no way to tell a wrong denominator from a real problem.
enum ContextWindows {
    private static let table: [String: Int] = load()

    static func window(forModel model: String?) -> Int? {
        guard let model else { return nil }
        if let exact = table[model] { return exact }
        // Rows carry the shortened name the panel displays ("opus-5"), while the
        // table is keyed by the full id. Transcripts give the full id, so this
        // only matters when falling back to the registry's own value.
        return table["claude-\(model)"]
    }

    /// Test seam: the table is read once from disk, so a case that wants to
    /// exercise the lookup rules supplies its own.
    static func window(forModel model: String?, in table: [String: Int]) -> Int? {
        guard let model else { return nil }
        return table[model] ?? table["claude-\(model)"]
    }

    private static func load() -> [String: Int] {
        // A missing or unreadable table means no meters, which is the same
        // outcome as an unknown model and needs no special reporting.
        guard let data = FileManager.default.contents(atPath: ParserRunner.pricingPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claude = root["claude"] as? [String: Any],
              let models = claude["models"] as? [String: Any] else { return [:] }

        return models.reduce(into: [:]) { table, entry in
            guard let spec = entry.value as? [String: Any],
                  let window = spec["contextWindow"] as? Int,
                  window > 0 else { return }
            table[entry.key] = window
        }
    }
}
