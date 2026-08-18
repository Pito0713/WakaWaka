import SwiftUI

/// The HUD keeps empty and failed registry states visible because disappearance
/// would make "nothing is running" indistinguishable from "the HUD is broken."
struct FloatingAgentsView: View {
    @ObservedObject var model: FloatingPanelModel
    @State private var isHovering = false
    let onFocus: (ActiveAgentRow) -> Void
    let onToggleMode: () -> Void
    let onLayoutChange: (FloatingPanelMode) -> Void
    let onSetPinned: (Bool) -> Void
    let onSetOpacity: (Double) -> Void

    init(
        model: FloatingPanelModel,
        onFocus: @escaping (ActiveAgentRow) -> Void,
        onToggleMode: @escaping () -> Void,
        onLayoutChange: @escaping (FloatingPanelMode) -> Void,
        onSetPinned: @escaping (Bool) -> Void = { _ in },
        onSetOpacity: @escaping (Double) -> Void = { _ in }
    ) {
        self.model = model
        self.onFocus = onFocus
        self.onToggleMode = onToggleMode
        self.onLayoutChange = onLayoutChange
        self.onSetPinned = onSetPinned
        self.onSetOpacity = onSetOpacity
    }

    var body: some View {
        Group {
            switch effectiveMode {
            case .dot:
                dotContent
            case .compact:
                agentList(density: .compact)
            case .expanded:
                agentList(density: .expanded)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(effectiveOpacity)
        .onHover { isHovering = $0 }
        .onChange(of: effectiveMode) { _, mode in
            onLayoutChange(mode)
        }
        .contextMenu {
            Button {
                onSetPinned(!model.isPinned)
            } label: {
                Label(
                    model.isPinned ? "取消釘選形態" : "釘選目前形態",
                    systemImage: model.isPinned ? "checkmark" : "pin"
                )
            }

            Menu("透明度") {
                opacityButton(title: "不透明", value: 1.0)
                opacityButton(title: "稍微透明", value: 0.85)
                opacityButton(title: "最透明", value: 0.5)
            }
        }
    }

    private var effectiveMode: FloatingPanelMode {
        FloatingPanelLayout.effectiveMode(
            preferred: model.preferredMode,
            isPinned: model.isPinned,
            isHovering: isHovering,
            agentCount: model.snapshot.rows.count,
            isDegraded: model.snapshot.status.message != nil
        )
    }

    private var effectiveOpacity: Double {
        FloatingPanelLayout.opacity(
            agentCount: model.snapshot.rows.count,
            isDegraded: model.snapshot.status.message != nil,
            base: model.baseOpacity
        )
    }

    private func opacityButton(title: String, value: Double) -> some View {
        Button {
            onSetOpacity(value)
        } label: {
            Label(title, systemImage: model.baseOpacity == value ? "checkmark" : "circle")
        }
    }

    private var dotContent: some View {
        Button(action: onToggleMode) {
            HStack(spacing: 4) {
                Circle()
                    .fill(summaryColor)
                    .frame(width: 9, height: 9)
                if !model.snapshot.rows.isEmpty {
                    Text("\(model.snapshot.rows.count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.snapshot.status.message ?? "展開懸浮 Agent 面板")
    }

    private func agentList(density: FloatingAgentRowDensity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(model.snapshot.rows.prefix(AgentRegistryService.maxRows)) { row in
                FloatingAgentRow(row: row, density: density) { onFocus(row) }
            }
            if model.snapshot.rows.count > AgentRegistryService.maxRows {
                Text("另有 \(model.snapshot.rows.count - AgentRegistryService.maxRows) 個")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 5)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("執行中的 Agents")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(model.snapshot.rows.count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
            Button(action: onToggleMode) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("縮成狀態圓點")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var summaryColor: Color {
        if model.snapshot.status.message != nil { return .yellow }
        if model.snapshot.rows.contains(where: { $0.state == .waitingApproval }) { return .orange }
        if model.snapshot.rows.contains(where: { $0.state == .working }) { return .green }
        return .secondary
    }
}
