import Foundation

// MARK: - Registry file format (written by hooks/agent-registry.mjs)

enum AgentKind: String, Decodable {
    case claudeCode = "claude-code"
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }
}

enum AgentState: Equatable {
    case working          // mid-turn
    case idle             // alive, waiting for input
    case waitingApproval  // blocked on a WakaWaka approval (overlaid from pending)
}

enum SkillSource: String, Decodable {
    case tool, slash

    var explanation: String {
        switch self {
        case .tool:  return "由 Skill 工具呼叫"
        case .slash: return "由 slash command 啟動"
        }
    }
}

/// One `agent_<kind>_<sessionId>.json` file.
///
/// Deliberately metadata-only — no prompt text, no tool input. `state` is a raw
/// string because the file is written by a separate program: an unrecognised
/// value must degrade to `idle` rather than fail the whole decode.
struct AgentRegistryEntry: Decodable {
    let schema: Int
    let kind: AgentKind
    let sessionId: String
    let cwd: String
    let gitBranch: String?
    let model: String?
    let pid: Int32
    let pidStartedAt: Int64?
    let state: String
    let skill: String?
    let skillSource: SkillSource?
    let lastTool: String?
    let startedAt: Date
    let heartbeatAt: Date
}

// MARK: - Display model

struct ActiveAgentRow: Identifiable, Equatable {
    let id: String            // "<kind>_<sessionId>"
    let kind: AgentKind
    /// Kept so a click can find the terminal this agent is running in — with
    /// the start time, because by then the row may be up to a minute old and a
    /// recycled pid would send the click to a stranger's window.
    let pid: Int32
    let pidStartedAt: Int64?
    let projectName: String   // last path component; the full path is tooltip-only
    let fullPath: String
    let gitBranch: String?
    let model: String?
    let skill: String?
    let skillSource: SkillSource?
    let lastTool: String?
    let state: AgentState
    let heartbeatAt: Date
}

/// A failure to read must never look like "no agents are running" — a silent
/// empty panel is indistinguishable from a working one showing nothing.
enum SourceStatus: Equatable {
    /// Carries no scan timestamp on purpose. It used to, and because the whole
    /// snapshot is `Equatable` that made every poll compare unequal — the panel
    /// republished and re-laid-out once a second while nothing had changed.
    case ok
    case unavailable
    case permissionDenied
    case schemaIncompatible(found: Int, expected: Int)

    /// Nil when there is nothing to explain to the user.
    var message: String? {
        switch self {
        case .ok: return nil
        case .unavailable: return "找不到 agent 狀態目錄，請重跑 start.sh"
        case .permissionDenied: return "無法讀取 agent 狀態目錄（權限不足）"
        case .schemaIncompatible(let found, let expected):
            return "registry schema 不相容（檔案 v\(found)，本版支援 v\(expected)），請重跑 start.sh"
        }
    }
}

struct ActiveAgentsSnapshot: Equatable {
    let rows: [ActiveAgentRow]
    let status: SourceStatus

    static let empty = ActiveAgentsSnapshot(rows: [], status: .ok)

    var isEmpty: Bool { rows.isEmpty && status.message == nil }
}

// MARK: - Process liveness

/// Whether the process that wrote a registry entry is still alive.
///
/// A crashed agent leaves a file that looks exactly like a live idle one, so
/// recency cannot answer this — the previous design could not tell the two
/// apart and showed weeks-old sessions as active. Both checks are plain
/// syscalls; neither forks.
enum ProcessLiveness {
    /// `kill(pid, 0)` tests for existence without signalling.
    static func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to another user.
        return errno == EPERM
    }

    /// Boot-relative start time in epoch seconds, or nil when unreadable.
    /// Matches `ps -o lstart=` under `LC_ALL=C`, which is what the hook records.
    static func startedAt(pid: Int32) -> Int64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return Int64(info.kp_proc.p_starttime.tv_sec)
    }

    /// The three answers a pid check can give.
    ///
    /// `unverifiable` is the one that matters: treating it as `alive` — which
    /// this did — means a dead session whose pid gets recycled by any unrelated
    /// process stays on screen forever, which is precisely the failure the pid
    /// check exists to prevent. It has to be its own answer so the caller can
    /// time-box it instead of trusting it indefinitely.
    enum Identity: Equatable {
        case alive
        case gone
        case unverifiable
    }

    /// Whether this pid is still the process the entry was written for.
    ///
    /// pids are recycled, so a live pid alone is not proof: without the start
    /// time comparison an unrelated process inheriting the number looks alive.
    static func check(pid: Int32, startedAt recorded: Int64?) -> Identity {
        guard isRunning(pid: pid) else { return .gone }
        // Written before the start-time guard existed, or the kernel would not
        // say — either way identity cannot be established.
        guard let recorded, let actual = startedAt(pid: pid) else { return .unverifiable }
        return abs(actual - recorded) <= 1 ? .alive : .gone   // one second of clock slack
    }
}
