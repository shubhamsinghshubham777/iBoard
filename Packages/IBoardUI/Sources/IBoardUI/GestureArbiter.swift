import CoreGraphics
import Foundation

// Gesture arbiter (M5-01): the F5 conflict matrix as a pure value type. No UIKit, no clock, no layout: the host
// feeds it one touch (start key kind, origin, samples) and acts on what it decides. Typed text is never involved.
//
//   Touch starts on | Gesture          | Rule (all thresholds in `GestureThresholds`)
//   ----------------+------------------+------------------------------------------------------------------------
//   Letter key      | tap              | movement < 10 pt and duration < long-press delay
//   Letter key      | flick up / down  | mostly vertical (|dy| > 1.5 |dx|), released within ~1 key height and < 220 ms;
//                   |                  | released on another key that forms a likely word: swipe typing instead
//   Letter key      | swipe typing     | crosses >= 1 other key (and is not a flick, see above)
//   Letter key      | long press       | >= 350 ms with < 10 pt movement
//   Spacebar        | cursor move      | drag > 12 pt (horizontal: speed-scaled steps, vertical: line jumps; host)
//   Spacebar+Shift  | selection        | as cursor move, extending a selection from the anchor
//   Backspace       | word delete      | drag left > 20 pt; dragging back right (or onto keys) cancels at release
//
// Decisions come in two stages: `move` / `tick` report a gesture the moment it is certain (so the host can start
// the trail, the cursor or the delete preview) and `end` reports the final result at lift.

/// What kind of key the touch went down on.
public enum GestureStart: Sendable, Equatable {
    case letter
    case space
    case delete
    /// Shift, layer switches, return, globe, symbols: only taps.
    case other
}

public enum Gesture: Sendable, Equatable {
    case tap
    case flickUp
    case flickDown
    case swipeTyping
    case longPress
    case spacebarCursor
    case spacebarSelection
    /// Backspace drag: words are previewed for deletion; at release this result deletes them.
    case backspaceSwipeDelete
    /// Backspace drag that was dragged back right or released over the keys: nothing is deleted.
    case backspaceSwipeCancel
}

/// Every number of the matrix; tuned in one place and covered by tests.
public struct GestureThresholds: Sendable, Equatable {
    /// Largest movement (pt) of a tap / long press.
    public var tapMovement: CGFloat = 10
    /// Hold time (s) that turns a still touch on a letter key into a long press.
    public var longPressDelay: TimeInterval = 0.45
    /// Flick: `|dy| > flickVerticalRatio * |dx|`.
    public var flickVerticalRatio: CGFloat = 1.5
    /// Flick: longest touch (s).
    public var flickMaxDuration: TimeInterval = 0.22
    /// Flick: farthest vertical travel, in key heights.
    public var flickMaxKeyHeights: CGFloat = 1.0
    /// Spacebar drag that starts the cursor / selection (pt).
    public var spacebarDragStart: CGFloat = 12
    /// Backspace drag to the left that starts the word-delete preview (pt).
    public var backspaceDragStart: CGFloat = 20
    /// Backspace: at release, a finger less than this far left of the start (it was dragged back right) cancels.
    public var backspaceCancelWithin: CGFloat = 10

    public init() {}
}

public struct GestureArbiter: Sendable {
    public let start: GestureStart
    public var thresholds: GestureThresholds
    /// Long press only exists on keys with alternates.
    public let hasAlternates: Bool
    /// Spacebar with Shift armed: the drag selects instead of moving the cursor.
    public let shiftArmed: Bool

    /// The gesture decided so far (nil while still ambiguous).
    public private(set) var decided: Gesture?

    private let origin: CGPoint
    private let t0: TimeInterval
    private let keyHeight: CGFloat
    private var last: CGPoint
    private var maxRadius: CGFloat = 0
    private var hasCrossed = false

    public init(start: GestureStart, origin: CGPoint, time: TimeInterval, keyHeight: CGFloat,
                hasAlternates: Bool = true, shiftArmed: Bool = false, thresholds: GestureThresholds = GestureThresholds()) {
        self.start = start
        self.origin = origin
        self.last = origin
        self.t0 = time
        self.keyHeight = keyHeight
        self.hasAlternates = hasAlternates
        self.shiftArmed = shiftArmed
        self.thresholds = thresholds
    }

    // MARK: Events

    /// A move sample. `crossedKeys` is true while the finger is over a letter key other than the one it started on.
    /// Returns the gesture that just became certain, once.
    public mutating func move(to p: CGPoint, time: TimeInterval, crossedKeys: Bool) -> Gesture? {
        last = p
        maxRadius = max(maxRadius, hypot(p.x - origin.x, p.y - origin.y))
        if decided != nil { return nil }
        switch start {
        case .letter:
            if crossedKeys { hasCrossed = true }
            // Crossing a key is swipe typing, unless the whole touch still looks like a short vertical flick: then
            // the decision waits for the lift (a likely word wins) or for the flick window to close.
            if hasCrossed, !looksLikeFlick(at: p, time: time) { return decide(.swipeTyping) }
            return nil
        case .space:
            if maxRadius > thresholds.spacebarDragStart { return decide(shiftArmed ? .spacebarSelection : .spacebarCursor) }
            return nil
        case .delete:
            if origin.x - p.x > thresholds.backspaceDragStart { return decide(.backspaceSwipeDelete) }
            return nil
        case .other:
            return nil
        }
    }

    /// Call while the touch is held without movement events (a display link / timer). Reports a long press.
    public mutating func tick(now: TimeInterval) -> Gesture? {
        guard decided == nil, start == .letter, hasAlternates, !hasCrossed,
              maxRadius < thresholds.tapMovement, now - t0 >= thresholds.longPressDelay else { return nil }
        return decide(.longPress)
    }

    /// The finger lifted at `p`. `endedOverKeys`: released over the key area (backspace cancel). `likelyWord`: the
    /// keys the path crossed spell a likely word (decided by the swipe decoder); only used to settle flick vs swipe.
    public mutating func end(at p: CGPoint, time: TimeInterval, endedOverKeys: Bool = false, likelyWord: Bool = false) -> Gesture {
        last = p
        maxRadius = max(maxRadius, hypot(p.x - origin.x, p.y - origin.y))
        // The lift point counts as a last sample for the drag gestures (spacebar, backspace).
        if decided == nil, start == .space || start == .delete { _ = move(to: p, time: time, crossedKeys: false) }
        if let d = decided {
            if d == .backspaceSwipeDelete {
                let draggedBack = origin.x - p.x < thresholds.backspaceCancelWithin
                return (draggedBack || endedOverKeys) ? .backspaceSwipeCancel : .backspaceSwipeDelete
            }
            return d
        }
        guard start == .letter else { return .tap }
        if looksLikeFlick(at: p, time: time), abs(p.y - origin.y) >= thresholds.tapMovement {
            if hasCrossed, likelyWord { return .swipeTyping }
            return p.y < origin.y ? .flickUp : .flickDown
        }
        if hasCrossed { return .swipeTyping }
        return .tap
    }

    // MARK: Rules

    private mutating func decide(_ g: Gesture) -> Gesture {
        decided = g
        return g
    }

    /// Mostly vertical, short in time and in height.
    private func looksLikeFlick(at p: CGPoint, time: TimeInterval) -> Bool {
        let dx = abs(p.x - origin.x), dy = abs(p.y - origin.y)
        return time - t0 < thresholds.flickMaxDuration
            && dy > thresholds.flickVerticalRatio * dx
            && dy <= thresholds.flickMaxKeyHeights * keyHeight
    }
}
