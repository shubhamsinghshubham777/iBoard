import Foundation
import Testing
import IBoardCore

/// Micro-benchmark helper: runs `body` repeatedly, returns per-iteration nanoseconds sorted ascending.
enum Benchmark {
    static func run(warmup: Int = 10, iterations: Int = 200, _ body: () -> Void) -> [UInt64] {
        for _ in 0..<warmup { body() }
        var samples = [UInt64]()
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let t = Perf.nowNanos()
            body()
            samples.append(Perf.nowNanos() &- t)
        }
        return samples.sorted()
    }

    static func p95Milliseconds(_ sorted: [UInt64]) -> Double {
        Double(sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]) / 1_000_000
    }

    /// Fails the test if p95 exceeds `budgetMilliseconds * slack`. Slack is loose (macOS host vs iPhone 12,
    /// debug builds); tighten when real engine code lands.
    static func expectP95(_ metric: PerfMetric, slack: Double = 10, _ body: () -> Void,
                          sourceLocation: SourceLocation = #_sourceLocation) {
        let p95 = p95Milliseconds(run(body))
        #expect(p95 <= metric.budgetMilliseconds * slack,
                "\(metric.label) p95 \(p95) ms exceeds \(metric.budgetMilliseconds * slack) ms",
                sourceLocation: sourceLocation)
    }
}

extension Benchmark {
    /// Enforces a roadmap budget (no slack) only in optimised builds. Debug builds on a loaded macOS host are
    /// not representative, so there the figure is reported and never fails the test (R-11). Release thresholds
    /// are unchanged. Run strict: `swift test -c release`.
    static func assertBudget(_ p95: Double, _ budgetMilliseconds: Double,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #if DEBUG
        if p95 > budgetMilliseconds {
            print("BENCH NOTE: p95 \(p95) ms exceeds budget \(budgetMilliseconds) ms in a DEBUG build (reporting only; enforced in release)")
        }
        #else
        #expect(p95 <= budgetMilliseconds, "p95 \(p95) ms exceeds budget \(budgetMilliseconds) ms",
                sourceLocation: sourceLocation)
        #endif
    }

    static func p50Milliseconds(_ sorted: [UInt64]) -> Double { Double(sorted[sorted.count / 2]) / 1_000_000 }

    /// Runs `body`, prints "BENCH name: p50 .. ms p95 .. ms (n ops/iter)" and returns the p95 in ms.
    /// `opsPerIteration` only scales the printed per-op figure.
    @discardableResult
    static func measure(_ name: String, warmup: Int = 20, iterations: Int = 300, opsPerIteration: Int = 1,
                        _ body: () -> Void) -> Double {
        let s = run(warmup: warmup, iterations: iterations, body)
        let p95 = p95Milliseconds(s)
        let perOp = p95 * 1_000_000 / Double(opsPerIteration)
        print("BENCH \(name): p50 \(String(format: "%.4f", p50Milliseconds(s))) ms, p95 \(String(format: "%.4f", p95)) ms per iteration"
              + (opsPerIteration > 1 ? " (\(opsPerIteration) ops, p95 \(String(format: "%.0f", perOp)) ns/op)" : ""))
        return p95
    }
}
