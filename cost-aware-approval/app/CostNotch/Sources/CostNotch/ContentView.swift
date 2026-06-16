import SwiftUI

struct ContentView: View {
    let pending: PendingData?
    let usage: UsageOutput?
    let isLoading: Bool
    let onAllow: () -> Void
    let onAlwaysAllow: () -> Void
    let onDeny: () -> Void

    private var isBash: Bool { pending?.tool_name == "Bash" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pending {
                // ── Tool info ─────────────────────────────────────────
                Group {
                    Text("Tool: \(pending.tool_name ?? "unknown")")
                        .font(.headline)
                    Text(pending.toolInputSummary)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // ── Usage ─────────────────────────────────────────────
                if isLoading {
                    ProgressView("Calculating usage…")
                } else if let u = usage {
                    Group {
                        Text("累積用量").font(.caption).foregroundStyle(.secondary)
                        Text("input \(u.cumulativeInput) / output \(u.cumulativeOutput) / cache \(u.cumulativeCacheRead + u.cumulativeCacheCreation) tok")
                            .font(.system(.caption, design: .monospaced))
                        if let delta = u.lastTurnDelta {
                            Text("上一輪增量：約 \(delta.input + delta.output) tokens（僅供參考）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(String(format: "估算費用：$%.4f（依 2026-06-13 價格表）", u.estimatedCostUSD))
                            .font(.caption).bold()
                    }
                } else {
                    Text("Usage data unavailable").font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                // ── Buttons ───────────────────────────────────────────
                if isBash {
                    // Bash: Deny | Allow Once | Always Allow
                    HStack(spacing: 8) {
                        Button(action: onDeny) {
                            Label("Deny", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                        .keyboardShortcut(.escape, modifiers: [])

                        Spacer()

                        Button("Allow Once", action: onAllow)
                            .buttonStyle(.bordered)

                        Button(action: onAlwaysAllow) {
                            Label("Always Allow", systemImage: "checkmark.seal.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                } else {
                    // Non-Bash: Deny | Allow
                    HStack(spacing: 12) {
                        Button(action: onDeny) {
                            Label("Deny", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                        .keyboardShortcut(.escape, modifiers: [])

                        Spacer()

                        Button(action: onAllow) {
                            Label("Allow", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }

            } else {
                // ── Idle ──────────────────────────────────────────────
                VStack(spacing: 8) {
                    Image(systemName: "dollarsign.circle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No pending approval").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
