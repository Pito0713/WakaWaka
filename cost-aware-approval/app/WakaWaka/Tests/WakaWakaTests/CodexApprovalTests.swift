import XCTest
@testable import WakaWaka

final class CodexApprovalTests: XCTestCase {
    private func decodePending(_ json: String) throws -> PendingData {
        try JSONDecoder().decode(PendingData.self, from: Data(json.utf8))
    }

    func testCodexAgentHasStableDisplayLabel() throws {
        let pending = try decodePending(#"{"agent":"codex","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)

        XCTAssertEqual(pending.agentDisplayLabel, "Codex")
    }

    func testApplyPatchBuildsFileSummaryAndColoredSections() throws {
        let json = #"{"agent":"codex","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-old\n+new\n*** End Patch"}}"#
        let pending = try decodePending(json)

        XCTAssertEqual(pending.toolInputSummary, "Sources/App.swift")
        XCTAssertTrue(pending.toolInputSections.contains { $0.kind == .removed && $0.text.contains("-old") })
        XCTAssertTrue(pending.toolInputSections.contains { $0.kind == .added && $0.text.contains("+new") })
    }

    func testMissingEnforcementRemainsReviewable() throws {
        let pending = try decodePending(#"{"agent":"codex","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)

        XCTAssertNil(pending.enforcement)
        XCTAssertFalse(pending.isPolicyDenied)
        XCTAssertTrue(pending.canBeAllowed)
    }

    func testDenyEnforcementIsNotReviewable() throws {
        let pending = try decodePending(#"{"agent":"codex","enforcement":"deny","tool_name":"Bash","tool_input":{"command":"shutdown"}}"#)

        XCTAssertTrue(pending.isPolicyDenied)
        XCTAssertFalse(pending.canBeAllowed)
        XCTAssertFalse(canWriteAllowDecision(for: pending))
        XCTAssertFalse(canWriteAlwaysAllowDecision(for: pending))
    }

    func testExpiredItemCannotWriteAllowDecisions() throws {
        let pending = try decodePending(#"{"agent":"codex","hookExited":true,"risk_level":"medium","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)

        XCTAssertFalse(canWriteAllowDecision(for: pending))
        XCTAssertFalse(canWriteAlwaysAllowDecision(for: pending))
    }

    func testAlwaysAllowRequiresMediumBash() throws {
        let mediumBash = try decodePending(#"{"agent":"codex","risk_level":"medium","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)
        let highBash = try decodePending(#"{"agent":"codex","risk_level":"high","tool_name":"Bash","tool_input":{"command":"sudo reboot"}}"#)
        let mediumPatch = try decodePending(#"{"agent":"codex","risk_level":"medium","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}}"#)

        XCTAssertTrue(canWriteAlwaysAllowDecision(for: mediumBash))
        XCTAssertFalse(canWriteAlwaysAllowDecision(for: highBash))
        XCTAssertFalse(canWriteAlwaysAllowDecision(for: mediumPatch))
    }

    func testSettingsDecodeDefaultsMissingCodexToDisabled() throws {
        let json = #"{"autoMode":{"claude-code":{"enabled":true,"expiresAt":null},"agy":{"enabled":false,"expiresAt":null}}}"#
        let settings = try JSONDecoder().decode(WakaWakaSettings.self, from: Data(json.utf8))

        XCTAssertTrue(settings.autoMode.claudeCode.enabled)
        XCTAssertEqual(settings.autoMode.codex, .disabled)
    }

    func testViewModelKeepsThreeAutoModesIsolated() {
        let model = PopoverViewModel()
        let settings = WakaWakaSettings(autoMode: .init(
            claudeCode: .init(enabled: true, expiresAt: "claude"),
            agy: .init(enabled: false, expiresAt: nil),
            codex: .init(enabled: true, expiresAt: "codex")
        ))

        model.applyAutoMode(from: settings)

        XCTAssertEqual(model.claudeCodeAutoMode.expiresAt, "claude")
        XCTAssertFalse(model.agyAutoMode.enabled)
        XCTAssertEqual(model.codexAutoMode.expiresAt, "codex")
    }

    func testSettingsEncodeKeepsThreeAgentKeysSeparate() throws {
        let settings = WakaWakaSettings(autoMode: .init(
            claudeCode: .init(enabled: true, expiresAt: "claude"),
            agy: .init(enabled: false, expiresAt: nil),
            codex: .init(enabled: true, expiresAt: "codex")
        ))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        let autoMode = try XCTUnwrap(object["autoMode"] as? [String: Any])

        XCTAssertEqual(autoMode.keys.sorted(), ["agy", "claude-code", "codex"])
        XCTAssertEqual((autoMode["codex"] as? [String: Any])?["expiresAt"] as? String, "codex")
        XCTAssertEqual((autoMode["claude-code"] as? [String: Any])?["expiresAt"] as? String, "claude")
    }
}
