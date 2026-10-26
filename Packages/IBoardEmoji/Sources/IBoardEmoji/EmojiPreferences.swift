import Foundation

/// Recently used emoji, most recent first. Pure value type; persistence is the caller's job.
public struct RecentEmoji: Codable, Sendable, Equatable {
    public static let defaultCapacity = 32
    public private(set) var items: [String]
    public let capacity: Int

    public init(items: [String] = [], capacity: Int = RecentEmoji.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.items = Array(items.prefix(self.capacity))
    }

    /// Moves `emoji` to the front (inserting it if new) and trims to capacity.
    public mutating func record(_ emoji: String) {
        guard !emoji.isEmpty else { return }
        items.removeAll { $0 == emoji }
        items.insert(emoji, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
    }

    public mutating func clear() { items.removeAll() }
}

/// Skin-tone memory: an optional global default plus per-emoji overrides keyed by the base emoji.
public struct SkinToneMemory: Codable, Sendable, Equatable {
    public static let maxOverrides = 200
    public var defaultTone: SkinTone?
    public private(set) var overrides: [String: SkinTone]
    /// Insertion order of override keys (oldest first), used to evict beyond `maxOverrides`.
    private var order: [String]

    public init(defaultTone: SkinTone? = nil) {
        self.defaultTone = defaultTone
        overrides = [:]
        order = []
    }

    /// The tone to apply for this entry: its own override, else the default, else none.
    public func tone(for entry: EmojiEntry) -> SkinTone? {
        guard entry.supportsSkinTone else { return nil }
        return overrides[entry.emoji] ?? defaultTone
    }

    /// The string to insert for `entry` with remembered tones applied.
    public func resolve(_ entry: EmojiEntry) -> String { entry.variant(tone(for: entry)) }

    /// Remember a pick from the tone picker. `asDefault` also makes it the default for all emoji.
    public mutating func remember(_ tone: SkinTone?, for entry: EmojiEntry, asDefault: Bool = false) {
        guard entry.supportsSkinTone else { return }
        if asDefault { defaultTone = tone }
        order.removeAll { $0 == entry.emoji }
        if let tone {
            overrides[entry.emoji] = tone
            order.append(entry.emoji)
            while order.count > Self.maxOverrides { overrides[order.removeFirst()] = nil }
        } else {
            overrides[entry.emoji] = nil
        }
    }

    public mutating func clear() {
        defaultTone = nil; overrides = [:]; order = []
    }
}

/// Everything the panel remembers. Holds emoji the user tapped in the panel, never typed text.
public struct EmojiPreferences: Codable, Sendable, Equatable {
    public var recents = RecentEmoji()
    public var skinTones = SkinToneMemory()
    public init() {}

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// Tolerant decode: corrupt or missing data yields defaults.
    public static func decode(_ data: Data?) -> EmojiPreferences {
        guard let data, let p = try? JSONDecoder().decode(EmojiPreferences.self, from: data) else {
            return EmojiPreferences()
        }
        return p
    }
}

public extension EmojiPreferences {
    /// Insert path: resolves the remembered tone, records it as recent, returns the string to insert.
    mutating func pick(_ entry: EmojiEntry) -> String {
        let s = skinTones.resolve(entry)
        recents.record(s)
        return s
    }
}
