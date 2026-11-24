import Foundation

/// Turns a raw tool_input into the one-line summary and the coloured diff sections the popover shows.
extension PendingData {
    // MARK: - Summary（單行標題）

    /// 單行，顯示在 popover 標題區：路徑縮短版或指令前段
    static func buildSummary(toolName: String?, raw: [String: JSONValue]?) -> String {
        guard let raw else { return "(no input)" }
        switch toolName {
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit",
             "write_to_file", "replace_file_content", "multi_replace_file_content", "view_file":
            let path = raw["file_path"]?.str ?? raw["TargetFile"]?.str ?? raw["AbsolutePath"]?.str ?? raw["path"]?.str
            return path.map { shortenPath($0) } ?? "(no path)"
        case "Bash":
            let cmd = raw["command"]?.str ?? raw["CommandLine"]?.str ?? "(no command)"
            // 只取第一行，最多 80 字
            let firstLine = cmd.split(separator: "\n").first.map(String.init) ?? cmd
            return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        case "apply_patch":
            return patchSummary(raw["command"]?.str)
        case "WebFetch":
            return raw["url"]?.str ?? "(no url)"
        case "WebSearch":
            return raw["query"]?.str ?? "(no query)"
        default:
            // 取第一個有值的 string 欄位
            let first = raw.sorted { $0.key < $1.key }.compactMap { k, v -> String? in
                guard let s = v.str, !s.isEmpty else { return nil }
                return "\(k): \(s.prefix(60))"
            }.first
            return first ?? "(no input)"
        }
    }

    // MARK: - Sections（帶顏色的結構化內容區塊）

    static func buildSections(toolName: String?, raw: [String: JSONValue]?, full: Bool) -> [DiffSection] {
        guard let raw, !raw.isEmpty else { return [] }

        switch toolName {

        case "Edit":
            let file    = raw["file_path"]?.str ?? "?"
            let old     = raw["old_string"]?.str ?? ""
            let new     = raw["new_string"]?.str ?? ""
            let replace = raw["replace_all"]?.displayString
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            if let r = replace, r == "true" {
                sections.append(.init(kind: .header, text: "replace_all: true"))
            }
            sections += lineDiff(old: old, new: new, full: full)
            return sections

        case "MultiEdit":
            let file = raw["file_path"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            if case .array(let edits) = raw["edits"] {
                for (i, edit) in edits.enumerated() {
                    if case .object(let e) = edit {
                        sections.append(.init(kind: .header, text: "── 修改 \(i + 1) ──"))
                        sections += lineDiff(old: e["old_string"]?.str ?? "",
                                             new: e["new_string"]?.str ?? "",
                                             full: full)
                    }
                }
            }
            return sections

        case "Write", "write_to_file", "write_file", "create_file":
            let file    = raw["file_path"]?.str ?? raw["TargetFile"]?.str ?? raw["path"]?.str ?? "?"
            let content = raw["content"]?.str ?? raw["CodeContent"]?.str ?? ""
            let shown   = full ? content : cap(content, 1000)
            return [
                .init(kind: .header, text: "📄 \(file)"),
                .init(kind: .plain,  text: content.isEmpty ? "(empty file)" : shown),
            ]

        case "Bash", "run_command", "run_shell_command":
            return [.init(kind: .plain, text: raw["command"]?.str ?? raw["cmd"]?.str ?? raw["CommandLine"]?.str ?? "(no command)")]

        case "apply_patch":
            return patchSections(raw["command"]?.str, full: full)

        case "WebFetch":
            let url    = raw["url"]?.str ?? "?"
            let method = raw["method"]?.str ?? "GET"
            var sections: [DiffSection] = [.init(kind: .header, text: "\(method)  \(url)")]
            if let body = raw["body"]?.str, !body.isEmpty {
                sections.append(.init(kind: .plain, text: full ? body : cap(body, 500)))
            }
            return sections

        case "WebSearch":
            let query = raw["query"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .plain, text: "query: \(query)")]
            if let l = raw["max_results"]?.displayString {
                sections.append(.init(kind: .plain, text: "max_results: \(l)"))
            }
            return sections

        case "Read", "view_file", "read_file":
            let filePath = raw["file_path"]?.str ?? raw["AbsolutePath"]?.str ?? raw["path"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(filePath)")]
            if let offset = raw["offset"]?.displayString { sections.append(.init(kind: .plain, text: "offset: \(offset)")) }
            if let lim    = raw["limit"]?.displayString  { sections.append(.init(kind: .plain, text: "limit: \(lim)")) }
            return sections

        case "NotebookEdit":
            let file = raw["notebook_path"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            let op = raw["new_source"]?.str.map { full ? $0 : cap($0, 400) } ?? raw["cell_type"]?.str
            if let op { sections.append(.init(kind: .plain, text: op)) }
            return sections

        case "replace_file_content", "edit_file":
            let file    = raw["path"]?.str ?? raw["TargetFile"]?.str ?? raw["file_path"]?.str ?? "?"
            let old     = raw["old_content"]?.str ?? raw["old_string"]?.str ?? raw["TargetContent"]?.str ?? ""
            let new     = raw["new_content"]?.str ?? raw["new_string"]?.str ?? raw["ReplacementContent"]?.str ?? ""
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            sections += lineDiff(old: old, new: new, full: full)
            return sections

        case "multi_replace_file_content":
            let file = raw["TargetFile"]?.str ?? "?"
            var sections: [DiffSection] = [.init(kind: .header, text: "📄 \(file)")]
            if case .array(let chunks) = raw["ReplacementChunks"] {
                for (i, chunk) in chunks.enumerated() {
                    if case .object(let c) = chunk {
                        sections.append(.init(kind: .header, text: "── 修改 \(i + 1) ──"))
                        sections += lineDiff(old: c["TargetContent"]?.str ?? "",
                                             new: c["ReplacementContent"]?.str ?? "",
                                             full: full)
                    }
                }
            }
            return sections

        default:
            return raw.sorted { $0.key < $1.key }.map { k, v in
                let val = v.str.map { full ? $0 : cap($0, 300) } ?? "[\(v.displayString)]"
                return DiffSection(kind: .plain, text: "[\(k)]\n\(val)")
            }
        }
    }

    // MARK: - Helpers

    static func patchSummary(_ command: String?) -> String {
        guard let command, !command.isEmpty else { return "(no patch)" }
        let prefixes = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]
        for line in command.components(separatedBy: "\n") {
            for prefix in prefixes where line.hasPrefix(prefix) {
                return shortenPath(String(line.dropFirst(prefix.count)))
            }
        }
        return "Patch (\(command.components(separatedBy: "\n").count) lines)"
    }

    static func patchSections(_ command: String?, full: Bool) -> [DiffSection] {
        guard let command, !command.isEmpty else { return [] }
        let shown = full ? command : cap(command, 2_000)
        var sections: [DiffSection] = []
        for line in shown.components(separatedBy: "\n") {
            let kind: DiffSection.Kind
            if line.hasPrefix("*** ") || line.hasPrefix("@@") {
                kind = .header
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .plain
            }
            if sections.last?.kind == kind, let previous = sections.popLast() {
                sections.append(.init(kind: kind, text: previous.text + "\n" + line))
            } else {
                sections.append(.init(kind: kind, text: line))
            }
        }
        return sections
    }

    /// LCS-based line diff: interleaves removed (red) and added (green) lines.
    /// Falls back to two-block display when either side exceeds 150 lines.
    /// `full: true` removes text caps and raises the fallback LCS line limit to 500.
    static func lineDiff(old: String, new: String, full: Bool = false) -> [DiffSection] {
        guard !old.isEmpty || !new.isEmpty else { return [] }
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let m = oldLines.count, n = newLines.count
        let lcsLimit = full ? 500 : 150

        guard m <= lcsLimit, n <= lcsLimit else {
            var out: [DiffSection] = []
            if !old.isEmpty { out.append(.init(kind: .removed, text: full ? old : cap(old, 800))) }
            if !new.isEmpty { out.append(.init(kind: .added,   text: full ? new : cap(new, 800))) }
            return out
        }

        // DP table for LCS
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = oldLines[i-1] == newLines[j-1]
                    ? dp[i-1][j-1] + 1
                    : max(dp[i-1][j], dp[i][j-1])
            }
        }

        // Backtrack → (kind, line) pairs
        var raw: [(DiffSection.Kind, String)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, oldLines[i-1] == newLines[j-1] {
                raw.append((.plain,   oldLines[i-1])); i -= 1; j -= 1
            } else if j > 0, (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                raw.append((.added,   newLines[j-1])); j -= 1
            } else {
                raw.append((.removed, oldLines[i-1])); i -= 1
            }
        }
        raw.reverse()

        // Group consecutive same-kind lines into DiffSections
        var sections: [DiffSection] = []
        var curKind: DiffSection.Kind? = nil
        var curLines: [String] = []
        for (kind, line) in raw {
            if kind == curKind {
                curLines.append(line)
            } else {
                if let k = curKind, !curLines.isEmpty {
                    sections.append(.init(kind: k, text: curLines.joined(separator: "\n")))
                }
                curKind  = kind
                curLines = [line]
            }
        }
        if let k = curKind, !curLines.isEmpty {
            sections.append(.init(kind: k, text: curLines.joined(separator: "\n")))
        }
        return sections
    }

    /// Shorten absolute path to last 3 components
    static func shortenPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 3 else { return path }
        return "…/" + parts.suffix(3).joined(separator: "/")
    }

    /// Cap string length; append a note if truncated
    static func cap(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let remaining = s.count - max
        return String(s.prefix(max)) + "\n\n…（還有 \(remaining) 個字元未顯示）"
    }
}
