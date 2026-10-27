import Foundation

/// Versioned user settings written by the companion app and read by the keyboard (works WITHOUT Full Access;
/// keyboard->app writes do not work, see docs/spikes/device-session-2026-10-26.md). Contains no typed text.
public struct IBoardSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 3
    public static let defaults = IBoardSettings()

    public var version: Int
    /// Haptic key feedback. Only effective when the keyboard has Full Access.
    public var haptics: Bool
    /// Strength of key haptics (only used when `haptics` is on and Full Access is granted).
    public var hapticIntensity: HapticIntensity
    public var keyClickSound: Bool
    /// Character of key haptics (M8-03). Only used when `haptics` is on and Full Access is granted.
    public var hapticPack: HapticPack
    /// Number row above the letters (F1). Layout default is off (on for Duo inner portrait, applied by the host).
    public var numberRow: Bool
    /// Keyboard height multiplier (F11, D-18) per display class x orientation, keyed by `HeightKey.make`.
    /// Missing key means 1.0. Values are clamped to `HeightScale.range` on read.
    public var heightScales: [String: Double]
    /// Show the faint hint symbol on each letter key: what a long press (first choice) or an up flick types (F5). On by
    /// default (owner request 2026-10-27); the stored key is "keyHints", so an earlier saved "off" does not hide it.
    public var flickHints: Bool
    /// Autocorrect strength (D-12: conservative by default).
    public var autocorrect: AutocorrectLevel
    /// Double space inserts ". " (iOS default on).
    public var doubleSpacePeriod: Bool
    /// Smart quotes/dashes (iOS default on).
    public var smartPunctuation: Bool
    /// Swipe typing (F3). Default on once the feature ships.
    public var swipeTyping: Bool
    /// Start every text field in incognito (no learning) mode (F6).
    public var incognitoByDefault: Bool
    public var spellingVariant: SpellingVariantSetting
    /// iPhone Duo: split the keyboard in the inner display, per orientation (F12).
    public var duoSplitPortrait: Bool
    public var duoSplitLandscape: Bool
    /// Emoji suggestions on the strip (F8).
    public var emojiSuggestions: Bool
    /// Comma and period keys beside the space bar (hold either for quick punctuation). `(agent)` default on; the
    /// Native iPhone keyboard has none, so it can be switched off in the app.
    public var punctuationKeys: Bool
    /// How long a still touch must last before it counts as a long press (alternates, punctuation row).
    public var longPressDelay: LongPressDelay

    public init(
        version: Int = IBoardSettings.currentVersion, haptics: Bool = true, keyClickSound: Bool = false,
        numberRow: Bool = false, heightScales: [String: Double] = [:], hapticIntensity: HapticIntensity = .medium,
        flickHints: Bool = true, autocorrect: AutocorrectLevel = .conservative, doubleSpacePeriod: Bool = true,
        smartPunctuation: Bool = true, swipeTyping: Bool = true, incognitoByDefault: Bool = false,
        spellingVariant: SpellingVariantSetting = .auto, duoSplitPortrait: Bool = false,
        duoSplitLandscape: Bool = false, emojiSuggestions: Bool = true, punctuationKeys: Bool = true,
        longPressDelay: LongPressDelay = .standard, hapticPack: HapticPack = .standard
    ) {
        self.hapticPack = hapticPack
        self.version = version
        self.haptics = haptics
        self.keyClickSound = keyClickSound
        self.numberRow = numberRow
        self.heightScales = heightScales
        self.hapticIntensity = hapticIntensity
        self.flickHints = flickHints
        self.autocorrect = autocorrect
        self.doubleSpacePeriod = doubleSpacePeriod
        self.smartPunctuation = smartPunctuation
        self.swipeTyping = swipeTyping
        self.incognitoByDefault = incognitoByDefault
        self.spellingVariant = spellingVariant
        self.duoSplitPortrait = duoSplitPortrait
        self.duoSplitLandscape = duoSplitLandscape
        self.emojiSuggestions = emojiSuggestions
        self.punctuationKeys = punctuationKeys
        self.longPressDelay = longPressDelay
    }

    /// Stored height multiplier for a key, clamped; 1 when none.
    public func heightScale(forKey key: String) -> Double {
        HeightScale.clamp(heightScales[key] ?? 1)
    }

    /// Effective variant for a device locale identifier (e.g. "en_GB").
    public func effectiveSpellingVariant(localeIdentifier: String) -> SpellingVariant {
        spellingVariant.resolve(localeIdentifier: localeIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case version, haptics, keyClickSound, numberRow, heightScales, hapticIntensity, autocorrect
        case doubleSpacePeriod, smartPunctuation, swipeTyping, incognitoByDefault, spellingVariant
        case duoSplitPortrait, duoSplitLandscape, emojiSuggestions, punctuationKeys, longPressDelay
        case flickHints = "keyHints"
        case hapticPack
    }

    /// Tolerant decoding: missing or unknown fields fall back to defaults; older versions are migrated to current.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IBoardSettings.defaults
        let v = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard v <= IBoardSettings.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Newer settings version \(v)")
        }
        // Migration: v0 (unversioned) and v1 keep known fields; v2 adds numberRow + heightScales; v3 adds the
        // feature switches below. Every missing field takes its default.
        self.version = IBoardSettings.currentVersion
        self.haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        self.keyClickSound = try c.decodeIfPresent(Bool.self, forKey: .keyClickSound) ?? d.keyClickSound
        self.numberRow = try c.decodeIfPresent(Bool.self, forKey: .numberRow) ?? d.numberRow
        self.heightScales = try c.decodeIfPresent([String: Double].self, forKey: .heightScales) ?? d.heightScales
        self.hapticIntensity = (try? c.decodeIfPresent(HapticIntensity.self, forKey: .hapticIntensity)) ?? d.hapticIntensity
        self.flickHints = try c.decodeIfPresent(Bool.self, forKey: .flickHints) ?? d.flickHints
        self.autocorrect = (try? c.decodeIfPresent(AutocorrectLevel.self, forKey: .autocorrect)) ?? d.autocorrect
        self.doubleSpacePeriod = try c.decodeIfPresent(Bool.self, forKey: .doubleSpacePeriod) ?? d.doubleSpacePeriod
        self.smartPunctuation = try c.decodeIfPresent(Bool.self, forKey: .smartPunctuation) ?? d.smartPunctuation
        self.swipeTyping = try c.decodeIfPresent(Bool.self, forKey: .swipeTyping) ?? d.swipeTyping
        self.incognitoByDefault = try c.decodeIfPresent(Bool.self, forKey: .incognitoByDefault) ?? d.incognitoByDefault
        self.spellingVariant = (try? c.decodeIfPresent(SpellingVariantSetting.self, forKey: .spellingVariant)) ?? d.spellingVariant
        self.duoSplitPortrait = try c.decodeIfPresent(Bool.self, forKey: .duoSplitPortrait) ?? d.duoSplitPortrait
        self.duoSplitLandscape = try c.decodeIfPresent(Bool.self, forKey: .duoSplitLandscape) ?? d.duoSplitLandscape
        self.emojiSuggestions = try c.decodeIfPresent(Bool.self, forKey: .emojiSuggestions) ?? d.emojiSuggestions
        self.punctuationKeys = try c.decodeIfPresent(Bool.self, forKey: .punctuationKeys) ?? d.punctuationKeys
        self.longPressDelay = (try? c.decodeIfPresent(LongPressDelay.self, forKey: .longPressDelay)) ?? d.longPressDelay
        self.hapticPack = (try? c.decodeIfPresent(HapticPack.self, forKey: .hapticPack)) ?? d.hapticPack
    }
}

/// Long-press hold time presets. Standard is a little shorter than the system keyboard (about 0.5 s).
public enum LongPressDelay: String, Codable, Sendable, CaseIterable {
    case short, standard, long

    public var seconds: Double {
        switch self {
        case .short: 0.3
        case .standard: 0.45
        case .long: 0.6
        }
    }
}

/// Haptic packs (M8-03): how each kind of key press feels. Resolved by `HapticPlan` in IBoardUI. Sound packs are not
/// possible in a keyboard extension beyond the system click (`playInputClick`, P-23), so there is no sound pack.
public enum HapticPack: String, Codable, Sendable, CaseIterable {
    /// The shipped feel.
    case standard
    /// Gentler: everything a step lighter and softer.
    case soft
    /// Sharper: letters and deletes use the rigid generator.
    case crisp
    /// Letters only; deletes, space and actions stay quiet.
    case lettersOnly
}

public enum HapticIntensity: String, Codable, Sendable, CaseIterable { case light, medium, strong }

/// How eagerly autocorrect replaces words (D-12). `conservative` is the default.
public enum AutocorrectLevel: String, Codable, Sendable, CaseIterable {
    /// Suggestions only, never replace.
    case off
    /// Only high-confidence typos.
    case conservative
    case balanced
    case aggressive
}

public enum SpellingVariant: String, Codable, Sendable, CaseIterable { case us, uk, `in` }

/// Stored choice: follow the device locale or pin a variant.
public enum SpellingVariantSetting: String, Codable, Sendable, CaseIterable {
    case auto, us, uk, `in`

    public func resolve(localeIdentifier: String) -> SpellingVariant {
        switch self {
        case .us: return .us
        case .uk: return .uk
        case .in: return .in
        case .auto: return SpellingVariant.forLocale(localeIdentifier)
        }
    }
}

extension SpellingVariant {
    /// en_IN -> in; British-style English regions -> uk; everything else (including non-English) -> us.
    public static func forLocale(_ identifier: String) -> SpellingVariant {
        let parts = identifier.replacingOccurrences(of: "-", with: "_").split(separator: "_").map(String.init)
        guard parts.first?.lowercased() == "en", let region = parts.last(where: { $0.count == 2 && $0 != parts[0] })?.uppercased()
        else { return .us }
        if region == "IN" { return .in }
        let uk: Set<String> = ["GB", "IE", "AU", "NZ", "ZA", "SG", "HK", "MY", "PK", "BD", "LK", "KE", "NG", "GH"]
        return uk.contains(region) ? .uk : .us
    }
}

/// Resize bounds (F11): 80 % to 140 % of the native height.
public enum HeightScale {
    public static let range: ClosedRange<Double> = 0.8...1.4
    public static func clamp(_ v: Double) -> Double {
        v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : 1
    }
}

/// The keyboard sizes the app offers in a picker (there is no drag handle). Each maps to a height scale inside
/// `HeightScale.range`; a stored value that is not exactly a preset (older slider values) shows as the nearest one.
public enum HeightPreset: String, CaseIterable, Sendable {
    case extraSmall, small, standard, large, extraLarge, maximum

    public var scale: Double {
        switch self {
        case .extraSmall: 0.8
        case .small: 0.9
        case .standard: 1.0
        case .large: 1.15
        case .extraLarge: 1.3
        case .maximum: 1.4
        }
    }

    public var title: String {
        switch self {
        case .extraSmall: "Extra small"
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        case .extraLarge: "Extra large"
        case .maximum: "Maximum"
        }
    }

    public static func nearest(to scale: Double) -> HeightPreset {
        allCases.min { abs($0.scale - scale) < abs($1.scale - scale) } ?? .standard
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
