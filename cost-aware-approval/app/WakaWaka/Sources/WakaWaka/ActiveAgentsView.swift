import SwiftUI

/// The ACTIVE AGENTS panel, pinned above the approval queue.
///
/// Every value here comes from a hook event or a pid check, so nothing is
/// inferred — there is no "probably still running" state to draw, which is the
/// main thing this design bought over reading transcripts.
///
/// The whole section hides when there is nothing to say. A degraded read is
/// not nothing: a status message is shown even with no rows, because a silent
/// empty panel is indistinguishable from a working one.
struct ActiveAgentsView: View {
    let snapshot: ActiveAgentsSnapshot
    /// Bring this agent's terminal to the front. Defaults to nothing so the
    /// layout tests can build the view without a host.
    var onFocus: (ActiveAgentRow) -> Void = { _ in }
    /// Re-scan now, verifying every process rather than trusting the grace period.
    var onRefresh: () -> Void = {}
    var isRefreshing: Bool = false
    /// Why the last click did not reach a window. Shown rather than swallowed:
    /// a click that silently does nothing reads as a broken panel.
    var focusError: String? = nil

    var body: some View {
        if !snapshot.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(snapshot.rows.prefix(AgentRegistryService.maxRows)) { row in
                    AgentRow(row: row, onFocus: { onFocus(row) })
                }
                if snapshot.rows.count > AgentRegistryService.maxRows {
                    overflowNote(snapshot.rows.count - AgentRegistryService.maxRows)
                }
                if let message = snapshot.status.message {
                    statusNote(message)
                }
                if let focusError {
                    statusNote(focusError)
                }
            }
            .padding(.vertical, 8)
            Divider()
        }
    }

    private var header: some View {
        HStack {
            Text("ACTIVE AGENTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            Spacer()
            if !snapshot.rows.isEmpty {
                Text("\(snapshot.rows.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// The panel already refreshes every second, but a row only disappears once
    /// its process fails a check — and fresh-looking entries skip that check.
    /// This forces one, which is the difference between "wait a minute" and
    /// "tell me now" after an agent has crashed.
    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing
                           ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                           : .default,
                           value: isRefreshing)
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help("重新檢查所有 agent 是否還活著")
    }

    private func overflowNote(_ count: Int) -> some View {
        Text("+\(count) more")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 2)
    }

    /// Never silent: the user is told why the panel is not showing what they expect.
    private func statusNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 4)
    }
}

/// One agent: project and branch on top, what it is doing underneath.
private struct AgentRow: View {
    let row: ActiveAgentRow
    let onFocus: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onFocus) { content }
            .buttonStyle(.plain)
            .background(isHovering ? Color.secondary.opacity(0.12) : .clear)
            .onHover { isHovering = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                Text(row.projectName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let branch = row.gitBranch {
                    Text(branch)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                detail
                Spacer()
                Text(relativeHeartbeat)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 13)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .help(tooltip)
    }

    /// A running skill is the most specific thing to say; otherwise the last
    /// tool. Both are names only — no arguments ever reach this view.
    @ViewBuilder
    private var detail: some View {
        if let skill = row.skill {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill").font(.system(size: 8))
                Text(skill).font(.caption)
            }
            .foregroundStyle(.secondary)
        } else if let tool = row.lastTool {
            HStack(spacing: 4) {
                Text(tool).font(.caption).foregroundStyle(.secondary)
                if let model = row.model {
                    Text("· \(model)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else if let model = row.model {
            Text(model).font(.caption2).foregroundStyle(.tertiary)
        } else {
            Text(row.kind.displayName).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var stateColor: Color {
        switch row.state {
        case .working:         return .green
        case .idle:            return .secondary
        case .waitingApproval: return .orange
        }
    }

    private var stateText: String {
        switch row.state {
        case .working:         return "執行中"
        case .idle:            return "閒置"
        case .waitingApproval: return "等待審批"
        }
    }

    /// The full path lives here rather than in the row, per the UI spec.
    private var tooltip: String {
        var parts = ["\(row.kind.displayName) · \(stateText)", row.fullPath]
        if let model = row.model { parts.append("模型：\(model)") }
        if let skill = row.skill {
            let source = row.skillSource?.explanation ?? "skill"
            parts.append("Skill：\(skill)（\(source)）")
        }
        parts.append("點一下切換到這個 agent 的終端機視窗")
        return parts.joined(separator: "\n")
    }

    private var relativeHeartbeat: String {
        let seconds = Int(Date().timeIntervalSince(row.heartbeatAt))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
