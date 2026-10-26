import Testing
@testable import IBoardCore

@Suite struct PerfTests {
    @Test func emptyHasNoPercentiles() {
        let r = DurationRingBuffer(capacity: 4)
        #expect(r.p50 == nil && r.p95 == nil && r.count == 0)
    }

    @Test func nearestRankPercentiles() {
        var r = DurationRingBuffer(capacity: 100)
        for v in 1...100 { r.record(UInt64(v)) }
        #expect(r.p50 == 50)
        #expect(r.p95 == 95)
        #expect(r.percentile(100) == 100)
        #expect(r.percentile(0) == 1)
    }

    @Test func wrapsAndKeepsNewest() {
        var r = DurationRingBuffer(capacity: 3)
        for v in 1...5 { r.record(UInt64(v)) }
        #expect(r.count == 3)
        #expect(r.values == [3, 4, 5])
        #expect(r.p50 == 4)
    }

    @Test func singleValue() {
        var r = DurationRingBuffer(capacity: 8)
        r.record(7)
        #expect(r.p50 == 7 && r.p95 == 7)
    }

    @Test func perfRecordsIntervals() {
        Perf.reset()
        let i = Perf.begin(.warmShow)
        Perf.end(i)
        Perf.record(.warmShow, nanoseconds: 2_000_000)
        let s = Perf.summary(.warmShow)
        #expect(s.count == 2)
        #expect(s.p95Milliseconds != nil)
    }

    @Test func memoryFootprintIsPositive() {
        #expect(Perf.memoryFootprintBytes() > 0)
    }
}
