import CoreGraphics
import Foundation
import IBoardLayout

/// One DEBUG touch-recorder entry. Never carries a character: only key index/kind, geometry, timing and counts.
public struct TouchLogRecord: Codable, Sendable, Equatable {
    /// "began" "moved" "ended" "cancelled" (touches) or "insert" "altBegan" "altMoved" "altEnded" "altCancelled"
    /// "openEmoji" "hlOn" "hlOff" (events the machine emitted).
    public var type: String
    public var id: Int
    /// `UITouch.timestamp` for touches; the handled touch's timestamp (or tick time) for events.
    public var ts: Double
    public var x: Double
    public var y: Double
    /// Resolved key index (touch hit test, or the event's key), -1 when none.
    public var ki: Int
    /// "letter" "space" "shift" "delete" "other" "none".
    public var kind: String
    /// Insert: character count. Otherwise 0.
    public var n: Int
    /// Main-thread lag in ms: CACurrentMediaTime minus the event timestamp when the handler ran.
    public var lagMs: Double

    public init(type: String, id: Int = 0, ts: Double, x: Double = 0, y: Double = 0, ki: Int = -1, kind: String = "none",
                n: Int = 0, lagMs: Double = 0) {
        self.type = type; self.id = id; self.ts = ts; self.x = x; self.y = y
        self.ki = ki; self.kind = kind; self.n = n; self.lagMs = lagMs
    }

    public static func kind(of identity: KeyIdentity?) -> String {
        guard let identity else { return "none" }
        switch identity {
        case .letter: return "letter"
        case .space: return "space"
        case .shift: return "shift"
        case .delete: return "delete"
        default: return "other"
        }
    }
}

public struct TouchLogFile: Codable, Sendable {
    public var containerWidth: Double
    public var containerHeight: Double
    public var needsGlobe: Bool
    public var longPressDelay: Double
    public var records: [TouchLogRecord]

    public init(containerWidth: Double, containerHeight: Double, needsGlobe: Bool, longPressDelay: Double,
                records: [TouchLogRecord]) {
        self.containerWidth = containerWidth; self.containerHeight = containerHeight
        self.needsGlobe = needsGlobe; self.longPressDelay = longPressDelay; self.records = records
    }
}

/// Fixed-size ring of the most recent records.
public struct TouchLogRing: Sendable {
    public private(set) var records: [TouchLogRecord] = []
    public let capacity: Int
    private var head = 0
    public init(capacity: Int = 400) { self.capacity = capacity }

    public mutating func append(_ r: TouchLogRecord) {
        if records.count < capacity { records.append(r) } else { records[head] = r; head = (head + 1) % capacity }
    }

    /// Oldest first.
    public var ordered: [TouchLogRecord] { Array(records[head...] + records[..<head]) }
}
