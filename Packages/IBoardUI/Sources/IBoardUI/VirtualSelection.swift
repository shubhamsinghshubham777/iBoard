import Foundation

// Shift + space selection (M5-05, D-14/D-27). A keyboard cannot set a selection range (P-08), so the selection is
// virtual: the anchor is the cursor position when the gesture started, the real cursor travels with the finger (the
// proxy cursor IS the extent end) and this model tracks what lies between. Pure and UIKit-free.
//
// P-24 correctness: everything is planned in grapheme clusters (`Character`) over the context captured at gesture
// start (<= 500 chars before the cursor, host dependent after it), then converted to the UTF-16 offsets that
// `adjustTextPosition` counts, so a move never ends inside an emoji / ZWJ sequence / combining mark. The two context
// halves are kept as separate arrays and never re-segmented together. The text is only held in memory for the
// duration of the gesture, never stored or logged.

/// An action of the selection action row `[Cut] [Copy] [Delete] [Aa] [✕]`.
public enum SelectionAction: Int, CaseIterable, Sendable {
    case cut, copy, delete, cycleCase, dismiss

    public var title: String {
        switch self {
        case .cut: "Cut"
        case .copy: "Copy"
        case .delete: "Delete"
        case .cycleCase: "Aa"
        case .dismiss: "\u{2715}"
        }
    }

    /// Cut and Copy write the pasteboard string, which needs Full Access (P-23).
    public var needsFullAccess: Bool { self == .cut || self == .copy }
}

/// What the host must do for an action: move, delete backwards, insert, pasteboard. All counts are exact.
public struct SelectionEdit: Sendable, Equatable {
    /// UTF-16 offset to move the cursor first (positive = right), so it sits at the right end of the selection.
    public var moveUTF16 = 0
    /// Grapheme clusters to delete backwards after the move.
    public var deleteGraphemes = 0
    /// Text inserted after the deletion.
    public var insert: String?
    /// String for the pasteboard (Cut / Copy).
    public var pasteboardText: String?
    /// The selection is over after this edit (the action row closes).
    public var endsSelection = true
}

public enum SelectionCase {
    /// lower -> Title -> UPPER -> lower. Returns nil when the text has no cased letters (nothing would change).
    public static func cycle(_ text: String) -> String? {
        let lower = text.lowercased(), upper = text.uppercased()
        guard lower != upper else { return nil }
        let title = lower.capitalized
        let next: String
        if text == lower { next = title == lower ? upper : title }
        else if text == title { next = upper }
        else { next = lower }
        return next == text ? nil : next
    }
}

public enum SelectionBanner {
    /// `“…selected text…” · 42 chars`. Long text keeps its head and tail around an ellipsis. Line breaks show as spaces.
    public static func text(_ selected: String, count: Int, maxPreview: Int = 26) -> String {
        let flat = selected.replacingOccurrences(of: "\n", with: " ")
        let chars = Array(flat)
        let preview: String
        if chars.count <= maxPreview { preview = flat } else {
            let head = (maxPreview - 1) * 2 / 3, tail = maxPreview - 1 - head
            preview = String(chars.prefix(head)) + "\u{2026}" + String(chars.suffix(tail))
        }
        return "\u{201C}\(preview)\u{201D} \u{00B7} \(count) \(count == 1 ? "char" : "chars")"
    }
}

/// A real host selection (`selectedText` non-empty): the action row operates on it. The proxy deletes the whole
/// selection with one `deleteBackward`.
public struct HostSelection: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
    public var count: Int { text.count }
    public var banner: String { SelectionBanner.text(text, count: count) }

    public func edit(for action: SelectionAction) -> SelectionEdit? {
        var e = SelectionEdit()
        switch action {
        case .copy: e.pasteboardText = text; e.endsSelection = false
        case .cut: e.pasteboardText = text; e.deleteGraphemes = 1
        case .delete: e.deleteGraphemes = 1
        case .cycleCase:
            guard let next = SelectionCase.cycle(text) else { return nil }
            e.deleteGraphemes = 1; e.insert = next; e.endsSelection = false
        case .dismiss: break
        }
        return e
    }
}

public struct VirtualSelection: Sendable, Equatable {
    private var all: [Character]
    /// Index of the gesture start in `all` (where the host cursor was).
    public private(set) var anchor: Int
    /// Index of the host cursor now.
    public private(set) var cursor: Int

    /// `before` / `after`: the document context around the cursor at gesture start.
    public init(before: String, after: String) {
        all = Array(before) + Array(after)
        anchor = before.count
        cursor = before.count
    }

    /// Selected grapheme clusters; negative extent means the cursor is left of the anchor.
    public var extent: Int { cursor - anchor }
    public var count: Int { abs(extent) }
    public var isEmpty: Bool { cursor == anchor }
    private var range: Range<Int> { min(anchor, cursor)..<max(anchor, cursor) }
    public var selectedText: String { String(all[range]) }
    public var banner: String { SelectionBanner.text(selectedText, count: count) }

    private func utf16(_ r: Range<Int>) -> Int { all[r].reduce(0) { $0 + $1.utf16.count } }

    /// Moves the cursor end by `graphemes` clusters and `lines` hard-line jumps (negative = left / up), clamped to the
    /// captured context. Returns the UTF-16 offset to apply to the host cursor (0 when nothing moved).
    public mutating func move(graphemes: Int, lines: Int = 0) -> Int {
        let start = cursor
        for _ in 0..<abs(lines) {
            let b = String(all[..<cursor]), a = String(all[cursor...])
            guard let o = CursorMath.lineJumpOffset(up: lines < 0, before: b, after: a) else { break }
            var remaining = abs(o)
            if o < 0 {
                while remaining > 0, cursor > 0 { cursor -= 1; remaining -= all[cursor].utf16.count }
            } else {
                while remaining > 0, cursor < all.count { remaining -= all[cursor].utf16.count; cursor += 1 }
            }
        }
        cursor = max(0, min(all.count, cursor + graphemes))
        return cursor >= start ? utf16(start..<cursor) : -utf16(cursor..<start)
    }

    /// The host steps for `action`, or nil when it would change nothing. Does not mutate; call `apply` afterwards.
    public func edit(for action: SelectionAction) -> SelectionEdit? {
        guard !isEmpty || action == .dismiss else { return nil }
        var e = SelectionEdit()
        // Deleting works backwards from the right end: a selection made leftwards first needs the cursor moved over it.
        func deletePlan() {
            e.moveUTF16 = extent < 0 ? utf16(range) : 0
            e.deleteGraphemes = count
        }
        switch action {
        case .copy: e.pasteboardText = selectedText; e.endsSelection = false
        case .cut: e.pasteboardText = selectedText; deletePlan()
        case .delete: deletePlan()
        case .cycleCase:
            guard let next = SelectionCase.cycle(selectedText) else { return nil }
            deletePlan(); e.insert = next; e.endsSelection = false
        case .dismiss: break
        }
        return e
    }

    /// Updates the model after `edit` was carried out on the host.
    public mutating func apply(_ action: SelectionAction, edit: SelectionEdit) {
        switch action {
        case .cut, .delete:
            all.removeSubrange(range)
            anchor = min(anchor, cursor); cursor = anchor
        case .cycleCase:
            if let text = edit.insert {
                let r = range
                let new = Array(text)
                all.replaceSubrange(r, with: new)
                anchor = r.lowerBound; cursor = r.lowerBound + new.count // the cursor ends at the right end
            }
        case .copy, .dismiss: break
        }
    }
}
