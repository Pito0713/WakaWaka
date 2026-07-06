import Foundation

// MARK: - Auto mode contract (shared with hooks/pretooluse.mjs loadAutoMode())
//
// Schema written to ~/.wakawaka/settings.json:
//   { "autoMode": { "claude-code": { "enabled": bool, "expiresAt": ISO8601|null },
//                    "agy":         { "enabled": bool, "expiresAt": ISO8601|null } } }
//
// The hook treats an agent as auto-approved when `enabled === true` AND
// (`expiresAt` is null OR the ISO timestamp has not yet passed). Do not
// rename these keys without updating the hook side too.

/// Identifies which agent's auto-mode window is being read or written.
/// Raw values are the exact JSON keys the hook expects.
enum AutoModeAgent: String {
    case claudeCode = "claude-code"
    case agy = "agy"
}

/// One agent's auto-mode window. `expiresAt` is always emitted explicitly
/// (including as JSON `null`) so the hook never has to distinguish
/// "key absent" from "key present but null".
struct AgentAutoMode: Equatable {
    var enabled: Bool
    var expiresAt: String?

    static let disabled = AgentAutoMode(enabled: false, expiresAt: nil)

    /// True once `expiresAt` has passed. An agent with no `expiresAt` never
    /// expires on its own (only an explicit toggle-off disables it).
    var isExpired: Bool {
        guard enabled, let expiresAt, let expiry = SettingsService.parseExpiry(expiresAt) else { return false }
        return expiry <= Date()
    }
}

extension AgentAutoMode: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, expiresAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant decode: a malformed/missing "enabled" falls back to false
        // rather than failing the whole settings file.
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        if let expiresAt {
            try c.encode(expiresAt, forKey: .expiresAt)
        } else {
            try c.encodeNil(forKey: .expiresAt)
        }
    }
}

/// Top-level shape of ~/.wakawaka/settings.json.
struct WakaWakaSettings: Equatable {
    struct AutoModeMap: Equatable {
        var claudeCode: AgentAutoMode
        var agy: AgentAutoMode
    }

    var autoMode: AutoModeMap

    static let empty = WakaWakaSettings(
        autoMode: AutoModeMap(claudeCode: .disabled, agy: .disabled)
    )
}

extension WakaWakaSettings.AutoModeMap: Codable {
    private enum CodingKeys: String, CodingKey {
        case claudeCode = "claude-code"
        case agy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeCode = try c.decodeIfPresent(AgentAutoMode.self, forKey: .claudeCode) ?? .disabled
        agy = try c.decodeIfPresent(AgentAutoMode.self, forKey: .agy) ?? .disabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claudeCode, forKey: .claudeCode)
        try c.encode(agy, forKey: .agy)
    }
}

extension WakaWakaSettings: Codable {
    private enum CodingKeys: String, CodingKey { case autoMode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoMode = try c.decodeIfPresent(AutoModeMap.self, forKey: .autoMode) ?? WakaWakaSettings.empty.autoMode
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(autoMode, forKey: .autoMode)
    }
}

// MARK: - SettingsService

/// Reads and writes ~/.wakawaka/settings.json — the file the PreToolUse hook
/// polls to decide whether a tool call should be auto-approved. Round-trips
/// must be resilient: a missing or corrupt file must never crash the app,
/// and a partial write must never be observable by the hook (atomic write).
final class SettingsService {
    static let shared = SettingsService()
    private init() {}

    /// Auto mode stays on for 30 minutes after the user flips the toggle.
    static let autoModeDurationSeconds: TimeInterval = 1800

    private var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wakawaka/settings.json")
    }

    /// Parses an `expiresAt` string. Tries the fractional-seconds format
    /// (what `setAutoMode` writes) first, then the plain ISO-8601 format,
    /// so timestamps written by an older build still parse.
    static func parseExpiry(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static func formatExpiry(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Loads current settings. A missing file or malformed JSON both fall
    /// back to all-disabled defaults instead of throwing — callers always
    /// get a usable value.
    func load() -> WakaWakaSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return .empty }
        guard let decoded = try? JSONDecoder().decode(WakaWakaSettings.self, from: data) else {
            fputs("[WakaWaka] WARN settings.json malformed, using defaults\n", stderr)
            return .empty
        }
        return decoded
    }

    /// Enables auto mode for `agent` for `autoModeDurationSeconds`, or
    /// disables it immediately. Read-modify-write so toggling one agent
    /// never clobbers the other agent's persisted state.
    func setAutoMode(agent: AutoModeAgent, enabled: Bool) {
        var settings = load()
        let newState = AgentAutoMode(
            enabled: enabled,
            expiresAt: enabled ? Self.formatExpiry(Date().addingTimeInterval(Self.autoModeDurationSeconds)) : nil
        )
        switch agent {
        case .claudeCode: settings.autoMode.claudeCode = newState
        case .agy:         settings.autoMode.agy = newState
        }
        write(settings)
    }

    /// Atomic write (`.atomic` writes to a temp file in the same directory,
    /// then renames it into place) so the hook never observes a half-written
    /// settings.json, mirroring the decision-file write pattern in AppDelegate.
    private func write(_ settings: WakaWakaSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            fputs("[WakaWaka] ERROR failed to encode settings.json\n", stderr)
            return
        }
        let dir = settingsURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        } catch {
            fputs("[WakaWaka] ERROR writing settings.json: \(error)\n", stderr)
        }
    }
}
