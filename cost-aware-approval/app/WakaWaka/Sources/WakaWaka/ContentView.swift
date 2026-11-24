import SwiftUI

// MARK: - Root view

struct ContentView: View {
    @ObservedObject var model: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pendingItems.isEmpty {
                idleView
            } else {
                // ── Header ──────────────────────────────────────────────
                HStack {
                    Text("待審批")
                        .font(.subheadline.weight(.semibold))
                    Text("\(model.pendingItems.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                // ── Queue list (scrolls; footer below stays pinned) ───────
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.pendingItems.indices, id: \.self) { idx in
                            QueueItemRow(
                                item:      model.pendingItems[idx],
                                index:     idx,
                                isExpanded: model.expandedIndex == idx,
                                usage:     model.expandedIndex == idx ? model.usage : nil,
                                isLoading: model.expandedIndex == idx ? model.isLoadingUsage : false,
                                agyQuota:  model.pendingItems[idx].agent == "agy" ? model.agyQuota : nil,
                                onToggle:  { model.onToggleExpand(idx) },
                                onAllow:   { model.onAllow(idx) },
                                onAlwaysAllow: { model.onAlwaysAllow(idx) },
                                onDeny:    { model.onDeny(idx) },
                                onDismiss: { model.onDismiss(idx) }
                            )
                            if idx < model.pendingItems.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                }
                .frame(maxHeight: 440)
            }

            // ── Always-visible footer (auto toggles + usage bars) ──────────
            PopoverFooter(model: model)

            // Last section in the popover: which agents are alive right now is
            // reference material, so it sits under the controls rather than
            // pushing the queue down the window.
            ActiveAgentsView(
                snapshot: model.activeAgents,
                onFocus: { model.onFocusAgent($0) },
                onRefresh: { model.onRefreshAgents() },
                isRefreshing: model.isRefreshingAgents,
                onToggleFloatingPanel: { isVisible in
                    model.isFloatingPanelVisible = isVisible
                    model.onToggleFloatingPanel(isVisible)
                },
                isFloatingPanelVisible: model.isFloatingPanelVisible,
                contextUsage: model.contextUsage,
                focusError: model.agentFocusError
            )
        }
        .frame(width: 480)
        // Opaque, appearance-adaptive background so the popover never flashes a bare
        // white frame before SwiftUI paints its content.
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: model.pendingItems.count)
        .animation(.easeOut(duration: 0.2), value: model.expandedIndex)
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            PacManIdleView(isAnimating: model.isPopoverShown)
            Text("No pending approval").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

}
