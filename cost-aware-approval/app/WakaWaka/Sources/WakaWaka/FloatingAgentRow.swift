import SwiftUI

/// A HUD row keeps its own clock-driven relative label because registry snapshots
/// intentionally stop publishing while an idle agent remains otherwise unchanged.
struct FloatingAgentRow: View {
    let row: ActiveAgentRow
    let onFocus: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onFocus) {
            content
        }
        .buttonStyle(.plain)
        .background(isHovering ? Color.secondary.opacity(0.12) : .clear)
        .onHover { isHovering = $0 }
        .help(tooltip)
    }

    /// Hover only paints a highlight here — it must never change the row's size,
    /// or the list would reflow beneath the pointer that is aiming at it.
    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                stateIndicator
                Text(row.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let gitBranch = row.gitBranch {
                    Text(gitBranch)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 6) {
                detail
                Spacer(minLength: 8)
                relativeHeartbeat
            }
            .padding(.leading, 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var stateIndicator: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 7, height: 7)
    }

    /// A running skill is the most specific useful detail; falling back through
    /// tool, model, and kind avoids replacing known activity with generic metadata.
    @ViewBuilder
    private var detail: some View {
        if let skill = row.skill {
            Label(skill, systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let lastTool = row.lastTool {
            HStack(spacing: 4) {
                Text(lastTool).font(.caption).foregroundStyle(.secondary)
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

    /// SwiftUI advances this label independently of snapshot publication, so an
    /// unchanged idle heartbeat cannot leave a stale age frozen on screen.
    private var relativeHeartbeat: some View {
        Text(row.heartbeatAt, style: .relative)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }

    private var stateColor: Color {
        switch row.state {
        case .working: return .green
        case .idle: return .secondary
        case .waitingApproval: return .orange
        }
    }

    private var stateText: String {
        switch row.state {
        case .working: return "執行中"
        case .idle: return "閒置"
        case .waitingApproval: return "等待審批"
        }
    }

    /// The full path stays off the row itself while remaining available for
    /// disambiguating projects that share the same final directory name.
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
}
