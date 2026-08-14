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

    var body: some View {
        if !snapshot.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(snapshot.rows.prefix(AgentRegistryService.maxRows)) { row in
                    AgentRow(row: row)
                }
                if snapshot.rows.count > AgentRegistryService.maxRows {
                    overflowNote(snapshot.rows.count - AgentRegistryService.maxRows)
                }
                if let message = snapshot.status.message {
                    statusNote(message)
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
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
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

    var body: some View {
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
