import Foundation

/// In-field preview for the backspace swipe (owner bug 8). A keyboard cannot set a selection range (P-08, D-27), so a
/// host-drawn "selected" look is impossible; two in-field cues exist:
///
/// - `.live` (default): the words disappear from the field as the finger drags and come back if it drags back
///   (or is cancelled); the release just keeps the result. Visible in every host; the trade-off is that the host sees
///   the intermediate edits (its undo stack, textDidChange churn).
/// - `.marked`: the words are re-inserted as MARKED text, deleted on release. Measured on the iOS 27.0 simulator
///   (Safari textarea, Settings search field): the hosts draw marked text from a non-IME keyboard WITHOUT any
///   highlight, so it looks like plain text; kept as an opt-in only. Hosts that ignore marked text lose the words
///   until `verify()` puts them back.
///
/// - `show(plan)`: the planned graphemes are removed from the field and re-inserted as marked text (same visible
///   text, now marked). A bigger / smaller plan unmarks first and redoes it, so the field always holds the original
///   text plus one marked tail.
/// - `commit()`: the marked text is replaced by nothing: the words are deleted.
/// - `cancel()`: the marked text is unmarked: the words stay, nothing changed.
/// - `verify()`: hosts that ignore marked text would have lost the words on `show`; this checks that the text is
///   still in the field and otherwise puts it back and reports `false` (the caller then falls back to the strip
///   preview and the plain delete on release). The check reads the left context, which can lag a run-loop turn
///   (P-24), so call it after one turn. Text is only handled in memory and never stored or logged.
@MainActor
public final class MarkedDeletePreview {
    public enum Style: Sendable { case live, marked }

    private let proxy: TextProxy
    private let style: Style
    public private(set) var graphemes = 0
    private var text = ""

    public init(proxy: TextProxy, style: Style = .marked) { self.proxy = proxy; self.style = style }

    public var isActive: Bool { graphemes > 0 }

    public func show(_ plan: BackspaceSwipePlan) {
        guard plan.graphemes != graphemes || plan.preview != text else { return }
        if style == .live {
            if plan.graphemes > graphemes {
                for _ in 0..<(plan.graphemes - graphemes) { proxy.deleteBackwardOnce() }
            } else if plan.graphemes < graphemes {
                // The shorter plan is the tail of the longer one: type the front part back.
                proxy.insert(String(text.prefix(graphemes - plan.graphemes)))
            }
            graphemes = plan.graphemes
            text = plan.graphemes > 0 ? plan.preview : ""
            return
        }
        if isActive { proxy.unmarkText() } // back to plain text, cursor at its end
        graphemes = 0; text = ""
        guard plan.graphemes > 0, !plan.preview.isEmpty else { return }
        for _ in 0..<plan.graphemes { proxy.deleteBackwardOnce() }
        proxy.setMarkedText(plan.preview)
        graphemes = plan.graphemes
        text = plan.preview
    }

    /// The marked words are deleted. Returns the number of graphemes removed (0 when nothing was marked).
    @discardableResult
    public func commit() -> Int {
        guard isActive else { return 0 }
        let n = graphemes
        if style == .marked { proxy.setMarkedText(""); proxy.unmarkText() }
        graphemes = 0; text = ""
        return n
    }

    /// The words stay. If the host dropped the marked text, it is typed back so nothing is lost.
    public func cancel() {
        guard isActive else { return }
        let restore = text
        if style == .live {
            proxy.insert(restore)
            graphemes = 0; text = ""
            return
        }
        let kept = (proxy.contextBefore ?? "").hasSuffix(restore)
        proxy.unmarkText()
        if !kept { proxy.insert(restore) }
        graphemes = 0; text = ""
    }

    /// True when the marked words are visible in the field. When not, they are re-inserted as plain text, the
    /// preview is dropped and `false` is returned (host without marked-text support).
    public func verify() -> Bool {
        guard isActive, style == .marked else { return true }
        if (proxy.contextBefore ?? "").hasSuffix(text) { return true }
        let restore = text
        proxy.unmarkText()
        proxy.insert(restore)
        graphemes = 0; text = ""
        return false
    }
}
