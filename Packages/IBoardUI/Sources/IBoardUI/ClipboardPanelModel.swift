import Foundation

/// M9-03: pure presentation model of the clipboard history panel (rows, ages, footer text). The UIKit view only draws it.
public struct ClipboardPanelModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: UUID
        /// Text pasted on tap (the full item).
        public var text: String
        /// Short single-line preview shown in the row.
        public var preview: String
        public var pinned: Bool
        public var isCode: Bool
        /// "now", "5 min ago", "2 h ago"; pinned items show "Pinned".
        public var age: String
        /// What VoiceOver reads for the row.
        public var accessibilityLabel: String
    }

    public var rows: [Row]
    /// Shown instead of rows when there are none.
    public var emptyMessage: String
    /// "Unpinned items clear after 1 hour." (the TTL actually in force).
    public var footer: String
    public var canClear: Bool

    public static let previewLength = 80

    public init(history: ClipboardHistory, now: Date) {
        rows = history.visible(at: now).map { item in
            let preview = ClipboardHistory.preview(item.text, maxLength: Self.previewLength)
            let age = item.pinned ? "Pinned" : Self.age(from: item.date, to: now)
            let label = (item.pinned ? "Pinned. " : "") + (item.isCode ? "Code. " : "") + preview + ". " + (item.pinned ? "" : age)
            return Row(id: item.id, text: item.text, preview: preview, pinned: item.pinned, isCode: item.isCode, age: age,
                       accessibilityLabel: label.trimmingCharacters(in: .whitespaces))
        }
        emptyMessage = "Nothing copied yet. Text you copy appears here."
        footer = Self.footer(ttl: history.ttl)
        canClear = !rows.isEmpty
    }

    public static func age(from date: Date, to now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int(s / 3600)) h ago"
    }

    public static func footer(ttl: TimeInterval) -> String {
        let minutes = Int((ttl / 60).rounded())
        let span: String
        if minutes < 60 { span = minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        else if minutes % 60 == 0 { span = minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        else { span = "\(minutes) minutes" }
        return "Unpinned items clear after \(span). Codes after \(Int(min(ClipboardHistory.codeTTL, ttl) / 60)) min."
    }
}

/// Dynamic Type for the fixed-height strip: the system scale is honoured but capped, so text never outgrows the strip.
public enum StripTypeScale {
    /// Largest factor applied to the strip's base sizes.
    public static let maxFactor: CGFloat = 1.35

    /// `scaled` is the size UIFontMetrics returned for `base`.
    public static func size(base: CGFloat, scaled: CGFloat, maxFactor: CGFloat = StripTypeScale.maxFactor) -> CGFloat {
        guard base > 0 else { return base }
        return min(max(scaled, base), base * maxFactor)
    }
}

/// Text replacements (M3-05): when does the typed token expand on space. Pure.
public enum TextReplacementPolicy {
    /// Tokens longer than this are never shortcuts.
    public static let maxShortcutLength = 40

    public static func shouldExpand(token: String, secure: Bool, enabled: Bool) -> Bool {
        enabled && !secure && !token.isEmpty && token.count <= maxShortcutLength && !token.contains(where: \.isWhitespace)
    }
}

/// M3-05: the lexicon fingerprint is persisted as a decimal string (UserDefaults has no unsigned 64-bit type).
public enum SystemLexiconFingerprintStore {
    public static func encode(_ value: UInt64) -> String { String(value) }
    public static func decode(_ s: String?) -> UInt64? { s.flatMap { UInt64($0) } }
}
