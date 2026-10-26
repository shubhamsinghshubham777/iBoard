import Foundation
import Synchronization

/// Injectable time source (seconds since the Unix epoch) so decay and the 30-day forget window are testable.
public protocol PersonalClock: Sendable {
    func now() -> Double
}

public struct SystemPersonalClock: PersonalClock {
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 }
}

/// Manually advanced clock for tests and previews.
public final class ManualPersonalClock: PersonalClock {
    private let value: Mutex<Double>
    public init(start: Double = 1_700_000_000) { value = Mutex(start) }
    public func now() -> Double { value.withLock { $0 } }
    public func set(_ t: Double) { value.withLock { $0 = t } }
    public func advance(days: Double) { value.withLock { $0 += days * 86_400 } }
    public func advance(seconds: Double) { value.withLock { $0 += seconds } }
}
