import Foundation
import os
import Synchronization

/// ROADMAP §6 metrics. Names are the stable signpost names.
public enum PerfMetric: Int, CaseIterable, Sendable {
    case touchDownToHighlight, touchUpToInsert, keystrokeToSuggestions
    case swipeLiftToCandidate, coldStart, warmShow

    public var name: StaticString {
        switch self {
        case .touchDownToHighlight: "touchDownToHighlight"
        case .touchUpToInsert: "touchUpToInsert"
        case .keystrokeToSuggestions: "keystrokeToSuggestions"
        case .swipeLiftToCandidate: "swipeLiftToCandidate"
        case .coldStart: "coldStart"
        case .warmShow: "warmShow"
        }
    }

    public var label: String { "\(name)" }

    /// §6 budget in milliseconds (p95 where the roadmap says p95; otherwise the hard limit).
    public var budgetMilliseconds: Double {
        switch self {
        case .touchDownToHighlight: 16.7
        case .touchUpToInsert: 20
        case .keystrokeToSuggestions: 25
        case .swipeLiftToCandidate: 60
        case .coldStart: 250
        case .warmShow: 80
        }
    }
}

/// Token returned by `Perf.begin`; pass to `Perf.end`. Plain value, no allocation.
public struct PerfInterval: Sendable {
    let metric: PerfMetric
    let startNanos: UInt64
    let state: OSSignpostIntervalState
}

public struct PerfSummary: Sendable {
    public let metric: PerfMetric
    public let count: Int
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
}

/// Signposts (subsystem `app.iBoard`) plus an in-memory ring of recent durations. Never records text.
public enum Perf {
    public static let subsystem = "app.iBoard"
    public static let ringCapacity = 256

    private static let signposter = OSSignposter(subsystem: subsystem, category: "perf")
    private static let rings = Mutex<[DurationRingBuffer]>(
        PerfMetric.allCases.map { _ in DurationRingBuffer(capacity: ringCapacity) })

    @inline(__always)
    public static func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    public static func begin(_ metric: PerfMetric) -> PerfInterval {
        PerfInterval(metric: metric, startNanos: nowNanos(),
                     state: signposter.beginInterval(metric.name, id: signposter.makeSignpostID()))
    }

    @discardableResult
    public static func end(_ interval: PerfInterval) -> UInt64 {
        let elapsed = nowNanos() &- interval.startNanos
        signposter.endInterval(interval.metric.name, interval.state)
        record(interval.metric, nanoseconds: elapsed)
        return elapsed
    }

    /// Times a synchronous closure as one interval.
    public static func measure<T>(_ metric: PerfMetric, _ body: () throws -> T) rethrows -> T {
        let i = begin(metric)
        defer { end(i) }
        return try body()
    }

    /// Point-in-time event (no duration).
    public static func event(_ metric: PerfMetric) {
        signposter.emitEvent(metric.name)
    }

    /// Records a duration measured elsewhere (also usable from tests).
    public static func record(_ metric: PerfMetric, nanoseconds: UInt64) {
        rings.withLock { $0[metric.rawValue].record(nanoseconds) }
    }

    public static func summary(_ metric: PerfMetric) -> PerfSummary {
        let ring = rings.withLock { $0[metric.rawValue] }
        func ms(_ v: UInt64?) -> Double? { v.map { Double($0) / 1_000_000 } }
        return PerfSummary(metric: metric, count: ring.count, p50Milliseconds: ms(ring.p50), p95Milliseconds: ms(ring.p95))
    }

    public static func summaries() -> [PerfSummary] { PerfMetric.allCases.map(summary) }

    public static func reset() {
        rings.withLock { for i in $0.indices { $0[i].removeAll() } }
    }

    /// Current process physical footprint in bytes (`task_vm_info.phys_footprint`), the number jetsam uses.
    public static func memoryFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    public static func memoryFootprintMB() -> Double { Double(memoryFootprintBytes()) / 1_048_576 }

    /// Emits the footprint as a signpost event for Instruments correlation.
    public static func emitMemoryEvent() {
        signposter.emitEvent("memoryFootprint", "\(memoryFootprintBytes() / 1024, privacy: .public) KB")
    }
}
