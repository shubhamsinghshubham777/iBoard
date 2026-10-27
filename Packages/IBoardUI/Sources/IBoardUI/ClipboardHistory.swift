import Foundation
import IBoardOTP

/// M9-03 / F9: clipboard history. Pure value model plus a file store seam.
///
/// - Records text items while the keyboard is visible (the host compares `UIPasteboard.changeCount` and reads the string
///   only when it changed, off the main thread: P-25).
/// - At most `maxItems` (20), newest first; unpinned items expire after `ttl` (1 h by default), code-like items after
///   `codeTTL` (the OTP TTL, 10 min). Pinned items stay. Expired items are removed from disk on every save.
/// - Never synced, never logged; the history lives only in the extension container (Full Access only).
public struct ClipboardItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var date: Date
    public var pinned: Bool
    public var isCode: Bool
}

public struct ClipboardHistory: Codable, Equatable, Sendable {
    public static let maxItems = 20
    public static let maxLength = 2000
    public static let defaultTTL: TimeInterval = 3600
    public static let codeTTL: TimeInterval = 600

    public private(set) var items: [ClipboardItem] = []
    /// `UIPasteboard.changeCount` last recorded, so an unchanged pasteboard is never read again.
    public var lastChangeCount: Int?
    public var ttl: TimeInterval = ClipboardHistory.defaultTTL

    public init(ttl: TimeInterval = ClipboardHistory.defaultTTL) { self.ttl = ttl }

    /// True when the pasteboard changed since the last recorded read (the host should then read it).
    public func needsRead(changeCount: Int) -> Bool { lastChangeCount != changeCount }

    /// Records `text` (when usable) and the change count. Returns true when an item was added or moved to the top.
    @discardableResult
    public mutating func record(_ text: String?, changeCount: Int, at now: Date) -> Bool {
        lastChangeCount = changeCount
        prune(at: now)
        guard let text else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= Self.maxLength else { return false }
        if let i = items.firstIndex(where: { $0.text == t }) {
            var it = items.remove(at: i)
            it.date = now
            items.insert(it, at: 0)
            return true
        }
        let code = ClipboardCode.extract(from: t) != nil && t.count <= 40
        items.insert(ClipboardItem(id: UUID(), text: t, date: now, pinned: false, isCode: code), at: 0)
        enforceCap()
        return true
    }

    /// Drops expired unpinned items.
    public mutating func prune(at now: Date) {
        items.removeAll { !$0.pinned && now.timeIntervalSince($0.date) > ($0.isCode ? min(Self.codeTTL, ttl) : ttl) }
    }

    public mutating func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = pinned
        enforceCap()
    }

    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Clear all (including pinned).
    public mutating func clearAll() { items.removeAll() }

    /// Items to show, newest first, pinned first.
    public func visible(at now: Date) -> [ClipboardItem] {
        var h = self
        h.prune(at: now)
        return h.items.filter(\.pinned) + h.items.filter { !$0.pinned }
    }

    /// The newest unpinned-or-pinned item for the strip chip (newest by date).
    public func newest(at now: Date) -> ClipboardItem? {
        var h = self
        h.prune(at: now)
        return h.items.max { $0.date < $1.date }
    }

    private mutating func enforceCap() {
        while items.count > Self.maxItems {
            if let i = items.lastIndex(where: { !$0.pinned }) { items.remove(at: i) } else { items.removeLast() }
        }
    }

    /// Short single-line preview for a chip.
    public static func preview(_ text: String, maxLength: Int = 18) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count <= maxLength ? one : String(one.prefix(maxLength - 1)) + "\u{2026}"
    }
}

/// File-backed store (extension container). Writes atomically; a corrupt or missing file reads as empty.
public struct ClipboardStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load(now: Date = Date()) -> ClipboardHistory {
        guard let data = try? Data(contentsOf: url), var h = try? JSONDecoder().decode(ClipboardHistory.self, from: data) else {
            return ClipboardHistory()
        }
        h.prune(at: now)
        return h
    }

    /// Saves after pruning, so expired items are gone from disk. An empty history deletes the file.
    public func save(_ history: ClipboardHistory, now: Date = Date()) {
        var h = history
        h.prune(at: now)
        if h.items.isEmpty, h.lastChangeCount == nil { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(h) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
