import Combine
import Testing
@testable import WakaWaka

@MainActor
struct FloatingPanelModelTests {
    @Test func snapshotChangePublishes() {
        let model = makeModel()
        var didPublish = false
        let observation = model.objectWillChange.sink { didPublish = true }

        model.snapshot = ActiveAgentsSnapshot(rows: [], status: .permissionDenied)

        #expect(didPublish)
        _ = observation
    }

    @Test func preferredModeChangePublishes() {
        let model = makeModel()
        var didPublish = false
        let observation = model.objectWillChange.sink { didPublish = true }

        model.preferredMode = .expanded

        #expect(didPublish)
        _ = observation
    }

    @Test func initialValuesMatchPreferences() {
        let snapshot = ActiveAgentsSnapshot(rows: [], status: .permissionDenied)
        let model = FloatingPanelModel(
            snapshot: snapshot,
            preferredMode: .compact,
            isPinned: true,
            baseOpacity: 0.72
        )

        #expect(model.snapshot.status == snapshot.status)
        #expect(model.preferredMode == .compact)
        #expect(model.isPinned)
        #expect(model.baseOpacity == 0.72)
    }

    private func makeModel() -> FloatingPanelModel {
        FloatingPanelModel(
            snapshot: .empty,
            preferredMode: .compact,
            isPinned: false,
            baseOpacity: 0.85
        )
    }
}
