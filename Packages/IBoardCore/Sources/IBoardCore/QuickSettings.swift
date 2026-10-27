import Foundation

/// One change made in the keyboard's Quick Settings panel. Contains no typed text.
public enum QuickSettingsEdit: Sendable, Equatable {
    case hapticPack(HapticPack)
    case numberRow(Bool)
    case autocorrect(AutocorrectLevel)
    case swipeTyping(Bool)
    case landscapeSideKeys(Bool)

    public func apply(to s: inout IBoardSettings) {
        switch self {
        case .hapticPack(let v): s.hapticPack = v
        case .numberRow(let v): s.numberRow = v
        case .autocorrect(let v): s.autocorrect = v
        case .swipeTyping(let v): s.swipeTyping = v
        case .landscapeSideKeys(let v): s.landscapeSideKeys = v
        }
    }
}

/// Extension-local overrides merged OVER the app-written settings (Quick Settings panel). Every field is optional:
/// nil means "use the app's value". Stored only in the keyboard's own container (always writable, P-23).
public struct SettingsOverrides: Codable, Sendable, Equatable {
    public var hapticPack: HapticPack?
    public var numberRow: Bool?
    public var autocorrect: AutocorrectLevel?
    public var swipeTyping: Bool?
    public var landscapeSideKeys: Bool?

    public init() {}

    public var isEmpty: Bool { self == SettingsOverrides() }

    public func applied(to base: IBoardSettings) -> IBoardSettings {
        var s = base
        if let v = hapticPack { s.hapticPack = v }
        if let v = numberRow { s.numberRow = v }
        if let v = autocorrect { s.autocorrect = v }
        if let v = swipeTyping { s.swipeTyping = v }
        if let v = landscapeSideKeys { s.landscapeSideKeys = v }
        return s
    }

    public mutating func record(_ edit: QuickSettingsEdit) {
        switch edit {
        case .hapticPack(let v): hapticPack = v
        case .numberRow(let v): numberRow = v
        case .autocorrect(let v): autocorrect = v
        case .swipeTyping(let v): swipeTyping = v
        case .landscapeSideKeys(let v): landscapeSideKeys = v
        }
    }

    public mutating func clear(_ edit: QuickSettingsEdit) {
        switch edit {
        case .hapticPack: hapticPack = nil
        case .numberRow: numberRow = nil
        case .autocorrect: autocorrect = nil
        case .swipeTyping: swipeTyping = nil
        case .landscapeSideKeys: landscapeSideKeys = nil
        }
    }
}

/// Settings the keyboard shows and edits: app settings (App Group, read-only without Full Access) with the
/// extension-local overrides on top.
///
/// Rules (P-23): without Full Access an edit lives only in the override layer; the app does not see it, and the
/// override masks a later change of the same setting made in the app. With Full Access the edit is also written to the
/// App Group blob (the app sees it) and, on success, the override for that field is dropped so the app is
/// authoritative again. No typed text is involved anywhere.
public struct QuickSettingsStore: @unchecked Sendable {
    public static let overridesKey = "iboard.local.settingsOverrides"
    private let local: UserDefaults
    private let group: SettingsStore

    public init(local: UserDefaults = .standard, group: SettingsStore = SettingsStore()) {
        self.local = local
        self.group = group
    }

    public func overrides() -> SettingsOverrides {
        guard let d = local.data(forKey: Self.overridesKey),
              let o = try? JSONDecoder().decode(SettingsOverrides.self, from: d) else { return SettingsOverrides() }
        return o
    }

    private func save(_ o: SettingsOverrides) {
        if o.isEmpty { local.removeObject(forKey: Self.overridesKey); return }
        if let d = try? JSONEncoder().encode(o) { local.set(d, forKey: Self.overridesKey) }
    }

    /// App settings with the local overrides applied.
    public func effective() -> IBoardSettings { overrides().applied(to: group.load()) }

    /// Applies an edit and returns the new effective settings.
    @discardableResult
    public func apply(_ edit: QuickSettingsEdit, hasFullAccess: Bool) -> IBoardSettings {
        var o = overrides()
        o.record(edit)
        save(o)
        if hasFullAccess {
            var app = group.load()
            edit.apply(to: &app)
            if group.save(app) {
                o.clear(edit)
                save(o)
            }
        }
        return o.applied(to: group.load())
    }
}
