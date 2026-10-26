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

@Suite struct EngineBenchmarks {
    @Test func placeholderSuggestionLookupWithinBudget() {
        let words = (0..<5_000).map { "word\($0)" }
        nonisolated(unsafe) var sink = 0
        Benchmark.expectP95(.keystrokeToSuggestions) {
            sink &+= words.firstIndex(of: "word4999") ?? 0   // stand-in until the engine exists
        }
        #expect(sink > 0)
    }
}
