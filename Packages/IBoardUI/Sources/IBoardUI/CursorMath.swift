import Foundation

// Cursor and delete maths for the spacebar cursor (M5-02) and backspace swipe-delete (M5-03). Pure and UIKit-free.
//
// P-24: `adjustTextPosition(byCharacterOffset:)` counts UTF-16 units and can split emoji / ZWJ sequences, so every
// move here is planned in grapheme clusters (`Character`) over the document context and then converted to the UTF-16
// offset of exactly those clusters. Context strings are only inspected in memory, never stored or logged.

public enum CursorMath {
    /// UTF-16 offset that moves the cursor `graphemes` clusters (negative: left, positive: right), clamped to what
    /// the visible context holds. Never ends inside a cluster.
    ///
    /// `crossingLineEnd`: hosts hand a keyboard only the rest of the CURRENT line as `documentContextAfterInput`
    /// (the line break itself is not in it), so a rightwards drag at the end of a line would stop there while the
    /// leftwards drag wraps up (the context before the cursor spans lines). When the visible text after the cursor
    /// runs out before the requested steps do, one more UTF-16 unit is added: the line break (or, at the very end of
    /// the document, a move the host clamps to nothing). Only one unit per call; the next move re-reads the context.
    public static func utf16Offset(graphemes: Int, before: String, after: String, crossingLineEnd: Bool = false) -> Int {
        if graphemes < 0 {
            return -before.suffix(-graphemes).reduce(0) { $0 + $1.utf16.count }
        }
        let moved = after.prefix(graphemes).reduce(0) { $0 + $1.utf16.count }
        if crossingLineEnd, graphemes > 0, !after.contains("\n"), after.count < graphemes { return moved + 1 }
        return moved
    }

    /// UTF-16 offset that jumps one HARD line (separated by a newline) up or down keeping the column, or nil when
    /// the context does not contain that line (the host never guesses across a truncated context or soft wraps).
    public static func lineJumpOffset(up: Bool, before: String, after: String) -> Int? {
        let beforeLines = before.split(separator: "\n", omittingEmptySubsequences: false)
        let current = beforeLines.last.map(Array.init) ?? []
        let column = current.count
        if up {
            guard beforeLines.count >= 2 else { return nil }
            let previous = Array(beforeLines[beforeLines.count - 2])
            let target = min(column, previous.count)
            // From the cursor back to the target column of the previous line: rest of that line + newline + column.
            let back = previous[target...].reduce(0) { $0 + $1.utf16.count } + 1 + current.reduce(0) { $0 + $1.utf16.count }
            return -back
        }
        let afterLines = after.split(separator: "\n", omittingEmptySubsequences: false)
        guard afterLines.count >= 2 else { return nil }
        let rest = Array(afterLines[0])
        let next = Array(afterLines[1])
        let target = min(column, next.count)
        return rest.reduce(0) { $0 + $1.utf16.count } + 1 + next[..<target].reduce(0) { $0 + $1.utf16.count }
    }
}

/// Converts finger travel on the spacebar into cursor steps. Speed scaling: slow drags move one cluster per
/// `stepWidth`, fast drags multiply (up to `maxMultiplier`). Vertical travel past `lineHeight` asks for a line jump.
public struct SpacebarCursorDrag: Sendable {
    public var stepWidth: CGFloat = 9
    public var lineHeight: CGFloat = 28
    public var maxMultiplier: CGFloat = 4
    /// Speed (pt/s) above which the multiplier starts to grow, and how fast it grows per extra pt/s.
    public var speedKnee: CGFloat = 250
    public var speedSlope: CGFloat = 1.0 / 250

    private var last: CGPoint
    private var lastTime: TimeInterval
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0
    private var speed: CGFloat = 0

    public init(start: CGPoint, time: TimeInterval) { last = start; lastTime = time }

    public struct Step: Sendable, Equatable {
        /// Grapheme steps, negative = left.
        public var horizontal: Int
        /// Line jumps, negative = up.
        public var vertical: Int
    }

    public mutating func move(to p: CGPoint, time: TimeInterval) -> Step {
        let dx = p.x - last.x, dy = p.y - last.y
        let dt = max(time - lastTime, 0.001)
        // Light smoothing so one jittery sample does not make the cursor leap.
        speed = 0.6 * speed + 0.4 * (abs(dx) / CGFloat(dt))
        last = p; lastTime = time
        let multiplier = min(max(1, 1 + (speed - speedKnee) * speedSlope), maxMultiplier)
        accX += dx * multiplier
        accY += dy
        // A mostly vertical drag does not also nudge the cursor sideways.
        let h = abs(dx) >= abs(dy) || abs(accY) < lineHeight ? Int((accX / stepWidth).rounded(.towardZero)) : 0
        if h != 0 { accX -= CGFloat(h) * stepWidth }
        var v = 0
        if abs(accY) >= lineHeight { v = Int((accY / lineHeight).rounded(.towardZero)); accY -= CGFloat(v) * lineHeight }
        return Step(horizontal: h, vertical: v)
    }
}

/// Backspace swipe-delete (M5-03): how many words a leftwards drag covers and what they say.
public struct BackspaceSwipePlan: Sendable, Equatable {
    /// Extra drag per additional word (pt).
    public static let wordStep: CGFloat = 38

    public var words: Int
    /// Graphemes the release deletes (whitespace before each word included, same rule as `wordDeleteCount`).
    public var graphemes: Int
    /// What will be deleted, for the strip preview (in memory only).
    public var preview: String

    /// Secure (password) fields: the text is not visible to the keyboard, so the drag deletes single characters.
    public var characters: Bool

    public init(words: Int, graphemes: Int, preview: String, characters: Bool = false) {
        self.words = words; self.graphemes = graphemes; self.preview = preview; self.characters = characters
    }

    /// Extra drag per additional character in a secure field (pt).
    public static let characterStep: CGFloat = 14

    /// Plan for a field whose text cannot be read: one character, plus one per `characterStep` of drag.
    public static func characterPlan(extraDistance distance: CGFloat) -> BackspaceSwipePlan {
        let n = 1 + Int(max(0, distance) / characterStep)
        return BackspaceSwipePlan(words: 0, graphemes: n, preview: "", characters: true)
    }

    /// `distance`: leftwards travel beyond the start threshold (pt), >= 0.
    public static func plan(before: String, extraDistance distance: CGFloat) -> BackspaceSwipePlan {
        let wanted = 1 + Int(max(0, distance) / wordStep)
        var remaining = Substring(before)
        var count = 0
        var words = 0
        while words < wanted, !remaining.isEmpty {
            let n = wordDeleteCount(before: String(remaining))
            if n == 0 { break }
            remaining = remaining.dropLast(n)
            count += n
            words += 1
        }
        return BackspaceSwipePlan(words: words, graphemes: count, preview: String(before.suffix(count)))
    }
}
