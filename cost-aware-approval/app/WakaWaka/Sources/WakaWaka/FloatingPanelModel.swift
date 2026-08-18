import SwiftUI

/// Holds mutable HUD inputs so registry refreshes preserve the hosted SwiftUI tree.
@MainActor
final class FloatingPanelModel: ObservableObject {
    @Published var snapshot: ActiveAgentsSnapshot
    @Published var preferredMode: FloatingPanelMode
    @Published var isPinned: Bool
    @Published var baseOpacity: Double
    @Published var focusError: String?

    init(
        snapshot: ActiveAgentsSnapshot,
        preferredMode: FloatingPanelMode,
        isPinned: Bool,
        baseOpacity: Double
    ) {
        self.snapshot = snapshot
        self.preferredMode = preferredMode
        self.isPinned = isPinned
        self.baseOpacity = baseOpacity
        self.focusError = nil
    }
}
