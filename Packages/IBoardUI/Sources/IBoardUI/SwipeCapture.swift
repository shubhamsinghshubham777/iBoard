import CoreGraphics
import Foundation
import IBoardEngine
import IBoardLayout

// Swipe gesture capture (M4-01). Pure logic, no UIKit, no clock of its own: the host feeds touch events with their
// timestamps. Typed text is never involved; only touch coordinates are held, in memory, for the one gesture, and are
// cleared on lift or cancel.

/// Tunable thresholds of the capture. All lengths are points in the layout's container coordinates.
public struct SwipeCaptureParameters: Sendable, Equatable {
    /// Raw samples closer than this to the previous accepted sample are dropped (noise / duplicate events).
    public var minSampleDistance: CGFloat = 1.5
    /// Hard cap of raw samples kept for the decoder. When reached the buffer is decimated 2:1 (ends preserved), so
    /// memory stays bounded for arbitrarily long drags.
    public var maxRawPoints = 512
    /// Spacing of the resampled polyline that is drawn as the trail.
    public var trailSpacing: CGFloat = 4
    /// Number of trail points kept; older points are dropped so a long drag shows a comet tail and never grows.
    public var maxTrailPoints = 120

    public init() {}
}

/// Result of feeding one touch event.
public enum SwipeCaptureUpdate: Sendable, Equatable {
    /// Nothing for the host to do.
    case none
    /// The touch just crossed into another letter key: it is a swipe from now on. The host cancels the key press.
    case began
    /// A swipe is in progress and the trail changed.
    case moved
}

/// Tracks one candidate swipe. A touch that goes down on a letter key is `undecided`; once it enters the touch region
/// of ANOTHER letter key it becomes a swipe (F5: "Crosses >= 1 other key"), and stays one until lift. Only one swipe
/// is tracked at a time (the first finger); other fingers type normally.
public struct SwipeCapture: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Down on a letter key, has not left it yet.
        case undecided
        case swiping
    }

    public var parameters: SwipeCaptureParameters
    public private(set) var phase: Phase = .idle
    public private(set) var touchID = -1
    /// Raw samples of the current gesture from touch-down (for the decoder).
    public private(set) var points: [SwipePoint] = []
    /// Equidistant samples for the trail (last element is the live finger position).
    public private(set) var trail: [CGPoint] = []

    private var startKey = -1
    private var lastRaw = CGPoint.zero
    private var lastTrail = CGPoint.zero

    public init(parameters: SwipeCaptureParameters = SwipeCaptureParameters()) {
        self.parameters = parameters
        points.reserveCapacity(parameters.maxRawPoints + 1)
        trail.reserveCapacity(parameters.maxTrailPoints + 2)
    }

    public var isSwiping: Bool { phase == .swiping }

    /// Whether `id` is the touch being tracked (candidate or swipe).
    public func tracks(_ id: Int) -> Bool { phase != .idle && id == touchID }

    /// A touch went down. Starts tracking when it hit a letter key of a letters layout and nothing is tracked yet.
    @discardableResult
    public mutating func begin(id: Int, at point: CGPoint, time: TimeInterval, layout: KeyboardLayout) -> Bool {
        guard phase == .idle, layout.kind == .letters, let hit = layout.hit(at: point),
              Self.isLetter(layout, hit.keyIndex) else { return false }
        phase = .undecided
        touchID = id
        startKey = hit.keyIndex
        points.removeAll(keepingCapacity: true)
        trail.removeAll(keepingCapacity: true)
        points.append(SwipePoint(point, t: time))
        lastRaw = point
        lastTrail = point
        trail.append(point)
        return true
    }

    public mutating func move(id: Int, to point: CGPoint, time: TimeInterval, layout: KeyboardLayout) -> SwipeCaptureUpdate {
        guard phase != .idle, id == touchID else { return .none }
        appendRaw(point, time: time)
        var update = SwipeCaptureUpdate.none
        if phase == .undecided {
            if let hit = layout.hit(at: point), hit.keyIndex != startKey, Self.isLetter(layout, hit.keyIndex) {
                phase = .swiping
                update = .began
            } else {
                // Still on the first key (or off the letters): keep sampling so a swipe that starts late is complete.
                appendTrail(point)
                return .none
            }
        }
        appendTrail(point)
        return update == .none ? .moved : update
    }

    /// Lift. Returns the samples when the touch was a swipe (including the lift point), else nil. Resets.
    public mutating func end(id: Int, at point: CGPoint, time: TimeInterval) -> [SwipePoint]? {
        guard phase != .idle, id == touchID else { return nil }
        defer { reset() }
        guard phase == .swiping else { return nil }
        appendRaw(point, time: time, force: true)
        return points
    }

    public mutating func cancel() { reset() }

    private mutating func reset() {
        phase = .idle
        touchID = -1
        startKey = -1
        points.removeAll(keepingCapacity: true)
        trail.removeAll(keepingCapacity: true)
    }

    // MARK: Resampling

    private mutating func appendRaw(_ p: CGPoint, time: TimeInterval, force: Bool = false) {
        guard force || Self.distance(p, lastRaw) >= parameters.minSampleDistance else { return }
        if points.count >= parameters.maxRawPoints { decimate() }
        points.append(SwipePoint(p, t: time))
        lastRaw = p
    }

    /// Keep every other sample (first and last preserved). Timestamps stay correct because samples are not moved.
    private mutating func decimate() {
        var out: [SwipePoint] = []
        out.reserveCapacity(points.count / 2 + 2)
        for i in stride(from: 0, to: points.count, by: 2) { out.append(points[i]) }
        if let last = points.last, out.last != last { out.append(last) }
        points = out
    }

    /// The trail is an equidistant polyline whose last point always follows the finger.
    private mutating func appendTrail(_ p: CGPoint) {
        var from = lastTrail
        var remaining = Self.distance(p, from)
        if trail.count > 1, remaining < parameters.trailSpacing {
            trail[trail.count - 1] = p // move the live head only
            return
        }
        if trail.count > 1 { trail.removeLast() } // drop the live head, re-added below
        let step = parameters.trailSpacing
        while remaining >= step {
            let f = step / remaining
            from = CGPoint(x: from.x + (p.x - from.x) * f, y: from.y + (p.y - from.y) * f)
            trail.append(from)
            remaining = Self.distance(p, from)
        }
        lastTrail = from
        trail.append(p)
        if trail.count > parameters.maxTrailPoints { trail.removeFirst(trail.count - parameters.maxTrailPoints) }
    }

    private static func isLetter(_ layout: KeyboardLayout, _ index: Int) -> Bool {
        guard index >= 0, index < layout.keys.count else { return false }
        if case .letter = layout.keys[index].identity { return true }
        return false
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
