import Foundation
import Testing
@testable import WakaWaka

/// Uses swift-testing rather than XCTest: XCTest ships with Xcode, while
/// `Testing.framework` ships with the Command Line Tools, so these run on a
/// machine that has never installed Xcode. See README "測試" for the rationale.
struct CodexApprovalTests {
    private func decodePending(_ json: String) throws -> PendingData {
        try JSONDecoder().decode(PendingData.self, from: Data(json.utf8))
    }

    @Test func codexAgentHasStableDisplayLabel() throws {
        let pending = try decodePending(#"{"agent":"codex","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)

        #expect(pending.agentDisplayLabel == "Codex")
    }

    @Test func applyPatchBuildsFileSummaryAndColoredSections() throws {
        let json = #"{"agent":"codex","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-old\n+new\n*** End Patch"}}"#
        let pending = try decodePending(json)

        #expect(pending.toolInputSummary == "Sources/App.swift")
        #expect(pending.toolInputSections.contains { $0.kind == .removed && $0.text.contains("-old") })
        #expect(pending.toolInputSections.contains { $0.kind == .added && $0.text.contains("+new") })
    }

    @Test func missingEnforcementRemainsReviewable() throws {
        let pending = try decodePending(#"{"agent":"codex","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)

        #expect(pending.enforcement == nil)
        #expect(!pending.isPolicyDenied)
        #expect(pending.canBeAllowed)
    }

    @Test func denyEnforcementIsNotReviewable() throws {
        let pending = try decodePending(#"{"agent":"codex","enforcement":"deny","tool_name":"Bash","tool_input":{"command":"shutdown"}}"#)

        #expect(pending.isPolicyDenied)
        #expect(!pending.canBeAllowed)
        #expect(!canWriteAllowDecision(for: pending))
        #expect(!canWriteAlwaysAllowDecision(for: pending))
    }

    @Test func expiredItemCannotWriteAllowDecisions() throws {
        let pending = try decodePending(#"{"agent":"codex","hookExited":true,"risk_level":"medium","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)

        #expect(!canWriteAllowDecision(for: pending))
        #expect(!canWriteAlwaysAllowDecision(for: pending))
    }

    @Test func alwaysAllowRequiresMediumBash() throws {
        let mediumBash = try decodePending(#"{"agent":"codex","risk_level":"medium","tool_name":"Bash","tool_input":{"command":"pwd"}}"#)
        let highBash = try decodePending(#"{"agent":"codex","risk_level":"high","tool_name":"Bash","tool_input":{"command":"sudo reboot"}}"#)
        let mediumPatch = try decodePending(#"{"agent":"codex","risk_level":"medium","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}}"#)

        #expect(canWriteAlwaysAllowDecision(for: mediumBash))
        #expect(!canWriteAlwaysAllowDecision(for: highBash))
        #expect(!canWriteAlwaysAllowDecision(for: mediumPatch))
    }

    @Test func settingsDecodeDefaultsMissingCodexToDisabled() throws {
        let json = #"{"autoMode":{"claude-code":{"enabled":true,"expiresAt":null},"agy":{"enabled":false,"expiresAt":null}}}"#
        let settings = try JSONDecoder().decode(WakaWakaSettings.self, from: Data(json.utf8))

        #expect(settings.autoMode.claudeCode.enabled)
        #expect(settings.autoMode.codex == .disabled)
    }

    @Test func viewModelKeepsThreeAutoModesIsolated() {
        let model = PopoverViewModel()
        let settings = WakaWakaSettings(autoMode: .init(
            claudeCode: .init(enabled: true, expiresAt: "claude"),
            agy: .init(enabled: false, expiresAt: nil),
            codex: .init(enabled: true, expiresAt: "codex")
        ))

        model.applyAutoMode(from: settings)

        #expect(model.claudeCodeAutoMode.expiresAt == "claude")
        #expect(!model.agyAutoMode.enabled)
        #expect(model.codexAutoMode.expiresAt == "codex")
    }

    @Test func settingsEncodeKeepsThreeAgentKeysSeparate() throws {
        let settings = WakaWakaSettings(autoMode: .init(
            claudeCode: .init(enabled: true, expiresAt: "claude"),
            agy: .init(enabled: false, expiresAt: nil),
            codex: .init(enabled: true, expiresAt: "codex")
        ))

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        )
        let autoMode = try #require(object["autoMode"] as? [String: Any])

        #expect(autoMode.keys.sorted() == ["agy", "claude-code", "codex"])
        #expect((autoMode["codex"] as? [String: Any])?["expiresAt"] as? String == "codex")
        #expect((autoMode["claude-code"] as? [String: Any])?["expiresAt"] as? String == "claude")
    }
}
