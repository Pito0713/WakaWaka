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

    @Test func focusErrorChangePublishes() {
        let model = makeModel()
        var didPublish = false
        let observation = model.objectWillChange.sink { didPublish = true }

        model.focusError = "找不到對應的終端機視窗"

        #expect(didPublish)
        _ = observation
    }

    @Test func initialValuesMatchPreferences() {
        let snapshot = ActiveAgentsSnapshot(rows: [], status: .permissionDenied)
        let model = FloatingPanelModel(snapshot: snapshot, baseOpacity: 0.72)

        #expect(model.snapshot.status == snapshot.status)
        #expect(model.baseOpacity == 0.72)
        #expect(model.focusError == nil)
    }

    private func makeModel() -> FloatingPanelModel {
        FloatingPanelModel(snapshot: .empty, baseOpacity: 0.85)
    }
}
