import SwiftUI

/// How full this agent's context window is: a fixed-width bar and its percent.
///
/// Fixed width rather than proportional, and tabular digits for the number, so
/// a row's layout never shifts as the value climbs — the meters also line up
/// down the list, which is what makes one full context findable at a glance.
struct ContextMeter: View {
    let usage: ContextUsage

    static let trackWidth: CGFloat = 54
    private let trackHeight: CGFloat = 5

    var body: some View {
        HStack(spacing: 6) {
            track
            Text("\(usage.percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(numberColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("上下文已使用 \(usage.percent)%")
    }

    private var track: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: Self.trackWidth, height: trackHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fillColor)
                    .frame(width: Self.trackWidth * usage.fraction, height: trackHeight)
            }
    }

    /// The state dot deliberately keeps its own palette: it says what the agent
    /// is doing, this says how full it is. Sharing colours would make neither
    /// readable.
    private var fillColor: Color {
        switch usage.band {
        case .normal:   return .secondary
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private var numberColor: Color {
        switch usage.band {
        case .normal:   return .secondary
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}
