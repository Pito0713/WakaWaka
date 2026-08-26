import SwiftUI

/// The HUD keeps empty and failed registry states visible because disappearance
/// would make "nothing is running" indistinguishable from "the HUD is broken."
/// It renders one form only — the full detail list — so nothing about the layout
/// depends on where the pointer happens to be.
struct FloatingAgentsView: View {
    @ObservedObject var model: FloatingPanelModel
    let onFocus: (ActiveAgentRow) -> Void
    let onClose: () -> Void
    let onSetOpacity: (Double) -> Void

    init(
        model: FloatingPanelModel,
        onFocus: @escaping (ActiveAgentRow) -> Void,
        onClose: @escaping () -> Void = {},
        onSetOpacity: @escaping (Double) -> Void = { _ in }
    ) {
        self.model = model
        self.onFocus = onFocus
        self.onClose = onClose
        self.onSetOpacity = onSetOpacity
    }

    var body: some View {
        agentList
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(effectiveOpacity)
            .contextMenu {
                Menu("透明度") {
                    opacityButton(title: "不透明", value: 1.0)
                    opacityButton(title: "稍微透明", value: 0.85)
                    opacityButton(title: "最透明", value: 0.5)
                }
                Divider()
                Button("關閉懸浮面板", systemImage: "xmark", action: onClose)
            }
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

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(model.snapshot.rows.prefix(AgentRegistryService.maxRows)) { row in
                FloatingAgentRow(row: row,
                                 contextUsage: model.contextUsage[row.id]) { onFocus(row) }
            }
            if model.snapshot.rows.count > AgentRegistryService.maxRows {
                Text("另有 \(model.snapshot.rows.count - AgentRegistryService.maxRows) 個")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 5)
            }
            if let statusMessage = model.snapshot.status.message {
                statusNote(statusMessage)
            }
            if let focusError = model.focusError {
                statusNote(focusError)
            }
        }
    }

    private func statusNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 5)
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
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("關閉懸浮面板（可從 menubar popover 重新開啟）")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
