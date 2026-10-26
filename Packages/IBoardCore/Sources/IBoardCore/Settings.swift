import Foundation

/// Versioned user settings written by the companion app and read by the keyboard (works WITHOUT Full Access;
/// keyboard->app writes do not work, see docs/spikes/device-session-2026-10-26.md). Contains no typed text.
public struct IBoardSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 2
    public static let defaults = IBoardSettings()

    public var version: Int
    /// Haptic key feedback. Only effective when the keyboard has Full Access.
    public var haptics: Bool
    public var keyClickSound: Bool
    /// Number row above the letters (F1). Layout default is off (on for Duo inner portrait, applied by the host).
    public var numberRow: Bool
    /// Keyboard height multiplier (F11, D-18) per display class x orientation, keyed by `HeightKey.make`.
    /// Missing key means 1.0. Values are clamped to `HeightScale.range` on read.
    public var heightScales: [String: Double]

    public init(
        version: Int = IBoardSettings.currentVersion, haptics: Bool = true, keyClickSound: Bool = false,
        numberRow: Bool = false, heightScales: [String: Double] = [:]
    ) {
        self.version = version
        self.haptics = haptics
        self.keyClickSound = keyClickSound
        self.numberRow = numberRow
        self.heightScales = heightScales
    }

    /// Stored height multiplier for a key, clamped; 1 when none.
    public func heightScale(forKey key: String) -> Double {
        HeightScale.clamp(heightScales[key] ?? 1)
    }

    private enum CodingKeys: String, CodingKey { case version, haptics, keyClickSound, numberRow, heightScales }

    /// Tolerant decoding: missing fields fall back to defaults; older versions are migrated to current.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IBoardSettings.defaults
        let v = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard v <= IBoardSettings.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Newer settings version \(v)")
        }
        // Migration: v0 (unversioned) and v1 keep known fields; v2 adds numberRow + heightScales (defaults).
        self.version = IBoardSettings.currentVersion
        self.haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        self.keyClickSound = try c.decodeIfPresent(Bool.self, forKey: .keyClickSound) ?? d.keyClickSound
        self.numberRow = try c.decodeIfPresent(Bool.self, forKey: .numberRow) ?? d.numberRow
        self.heightScales = try c.decodeIfPresent([String: Double].self, forKey: .heightScales) ?? d.heightScales
    }
}

/// Resize bounds (F11): 80 % to 140 % of the native height.
public enum HeightScale {
    public static let range: ClosedRange<Double> = 0.8...1.4
    public static func clamp(_ v: Double) -> Double {
        v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : 1
    }
}

/// Storage key for per display class x orientation values (D-18). Plain strings so IBoardCore stays free of
/// IBoardLayout; the host passes the raw values of its layout enums.
public enum HeightKey {
    public static func make(displayClass: String, orientation: String) -> String { "\(displayClass).\(orientation)" }
}

/// Keyboard-local overrides written by the in-keyboard drag handle / number-row toggle. The extension cannot write
/// the App Group without Full Access (P-23) but can always write its own container, so live resizing persists
/// here and wins over the app-written value. Contains no typed text.
public struct LocalLayoutOverrides: @unchecked Sendable {
    public static let heightPrefix = "iboard.local.height."
    public static let numberRowKey = "iboard.local.numberRow"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func heightScale(forKey key: String) -> Double? {
        defaults.object(forKey: Self.heightPrefix + key) == nil ? nil : HeightScale.clamp(defaults.double(forKey: Self.heightPrefix + key))
    }

    public func setHeightScale(_ v: Double, forKey key: String) {
        defaults.set(HeightScale.clamp(v), forKey: Self.heightPrefix + key)
    }

    public var numberRow: Bool? {
        defaults.object(forKey: Self.numberRowKey) == nil ? nil : defaults.bool(forKey: Self.numberRowKey)
    }

    public func setNumberRow(_ on: Bool) { defaults.set(on, forKey: Self.numberRowKey) }
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
