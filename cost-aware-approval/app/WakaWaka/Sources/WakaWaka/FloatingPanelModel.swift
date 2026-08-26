import SwiftUI

/// Holds mutable HUD inputs so registry refreshes preserve the hosted SwiftUI tree.
@MainActor
final class FloatingPanelModel: ObservableObject {
    @Published var snapshot: ActiveAgentsSnapshot
    @Published var baseOpacity: Double
    @Published var focusError: String?
    /// Keyed by row id; a missing key means no denominator, not zero.
    @Published var contextUsage: [String: ContextUsage] = [:]

    init(
        snapshot: ActiveAgentsSnapshot,
        baseOpacity: Double,
        focusError: String? = nil
    ) {
        self.snapshot = snapshot
        self.baseOpacity = baseOpacity
        self.focusError = focusError
    }
}
