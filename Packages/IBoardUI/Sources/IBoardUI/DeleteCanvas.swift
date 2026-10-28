import Foundation

/// What the backspace-swipe canvas shows (M5-03): the text before the cursor with the words the release would delete
/// marked. Pure; the strings live in memory only for the gesture and are never stored or logged.
public struct DeleteCanvasModel: Sendable, Equatable {
    /// Text kept (shown muted), the tail of the left context before the doomed words; starts with "…" when cut.
    public var kept: String
    /// Text the release deletes (shown struck through); starts with "…" when it was cut for display.
    public var doomed: String
    /// "Delete 3 words" / hint when nothing is selected yet / "no preview" in fields without context.
    public var caption: String
    /// The plan reaches the start of the known context (the proxy exposes at most ~500 characters, P-24), so more text
    /// may be removed on release than is shown.
    public var contextLimited: Bool

    public static let keptLimit = 90
    public static let doomedLimit = 160
    /// documentContextBeforeInput is capped at 500 characters (P-24).
    public static let proxyContextCap = 500

    public static func make(base: String, plan: BackspaceSwipePlan) -> DeleteCanvasModel {
        if plan.characters {
            // Masked field: show only dots, never the (unreadable, private) text.
            let n = plan.graphemes
            return DeleteCanvasModel(kept: "", doomed: String(repeating: "\u{2022}", count: min(n, 40)),
                                     caption: n == 1 ? "Delete 1 character" : "Delete \(n) characters", contextLimited: false)
        }
        if base.isEmpty {
            return DeleteCanvasModel(kept: "", doomed: "", caption: "No preview in this field", contextLimited: false)
        }
        let doomedFull = plan.graphemes > 0 ? String(base.suffix(plan.graphemes)) : ""
        let keptFull = String(base.dropLast(plan.graphemes))
        let caption: String
        switch plan.words {
        case 0: caption = "Drag further left to choose words"
        case 1: caption = "Delete 1 word"
        default: caption = "Delete \(plan.words) words"
        }
        return DeleteCanvasModel(
            kept: clip(keptFull, keep: keptLimit),
            doomed: clip(doomedFull, keep: doomedLimit),
            caption: caption,
            contextLimited: plan.graphemes > 0 && base.count >= proxyContextCap - 10 && plan.graphemes >= base.count)
    }

    /// Newlines become a visible return glyph; long text keeps its end (nearest the cursor) behind an ellipsis, cut at a
    /// word boundary where one is close.
    static func clip(_ text: String, keep: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "\u{21B5}")
        guard flat.count > keep else { return flat }
        var tail = Substring(flat.suffix(keep))
        if let space = tail.prefix(20).firstIndex(of: " ") { tail = tail[tail.index(after: space)...] }
        return "\u{2026}" + tail
    }
}
