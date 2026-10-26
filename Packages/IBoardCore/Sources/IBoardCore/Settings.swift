import Foundation

/// Versioned user settings written by the companion app and read by the keyboard (works WITHOUT Full Access;
/// keyboard->app writes do not work, see docs/spikes/device-session-2026-10-26.md). Contains no typed text.
public struct IBoardSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaults = IBoardSettings()

    public var version: Int
    /// Haptic key feedback. Only effective when the keyboard has Full Access.
    public var haptics: Bool
    public var keyClickSound: Bool

    public init(version: Int = IBoardSettings.currentVersion, haptics: Bool = true, keyClickSound: Bool = false) {
        self.version = version
        self.haptics = haptics
        self.keyClickSound = keyClickSound
    }

    private enum CodingKeys: String, CodingKey { case version, haptics, keyClickSound }

    /// Tolerant decoding: missing fields fall back to defaults; older versions are migrated to current.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IBoardSettings.defaults
        let v = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard v <= IBoardSettings.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Newer settings version \(v)")
        }
        // Migration: v0 (unversioned) -> v1 keeps known fields, fills the rest.
        self.version = IBoardSettings.currentVersion
        self.haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        self.keyClickSound = try c.decodeIfPresent(Bool.self, forKey: .keyClickSound) ?? d.keyClickSound
    }
}

/// App Group backed store. All keys are prefixed. Reads never fail: any problem yields DEFAULTS.
public struct SettingsStore: @unchecked Sendable {
    public static let appGroup = "group.app.iBoard"
    public static let keyPrefix = "iboard.settings."
    public static let key = keyPrefix + "blob"

    private let defaults: UserDefaults?

    public init(suiteName: String? = SettingsStore.appGroup) {
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) }
    }

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> IBoardSettings {
        guard let data = defaults?.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(IBoardSettings.self, from: data) else { return .defaults }
        return s
    }

    @discardableResult
    public func save(_ settings: IBoardSettings) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(settings) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
