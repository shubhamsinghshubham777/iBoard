import Foundation
import IBoardCore

// Typing insight counters (F16, M10-04) on the keyboard side. Aggregates only: the recorder sees `InsightEvent`s (no
// text) and a clock. The host persists the counters extension-locally and, with Full Access, mirrors them to the App
// Group for the app (P-23: shared defaults writes need Full Access).

@MainActor
public final class InsightRecorder {
    public private(set) var counters: InsightCounters
    /// Called with the counters when they changed and `persistInterval` has passed, and by `flush()`.
    public var persist: ((InsightCounters) -> Void)?
    public var persistInterval: TimeInterval = 10

    private let now: () -> TimeInterval
    private var sessionStart: TimeInterval?
    private var lastEvent: TimeInterval = 0
    private var sessionWords = 0
    private var dirty = false
    private var lastPersist: TimeInterval = -.infinity
    private var lastUnigramCount: Int?

    public init(counters: InsightCounters = InsightCounters(),
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.counters = counters
        self.now = now
    }

    public func handle(_ event: InsightEvent) {
        let t = now()
        switch event {
        case .word(let swiped):
            if sessionStart != nil, t - lastEvent > InsightCounters.sessionIdleGap { closeSession() }
            if sessionStart == nil { sessionStart = t }
            lastEvent = t
            sessionWords += 1
            counters.recordWord(swiped: swiped)
        case .autocorrect(let accepted):
            counters.recordAutocorrect(accepted: accepted)
        }
        dirty = true
        if t - lastPersist >= persistInterval { flush() }
    }

    /// Words the personal model gained since the last call (from its unigram count). The first call only sets the
    /// baseline, so words learned in earlier launches are not counted again.
    public func noteUnigramCount(_ count: Int) {
        defer { lastUnigramCount = count }
        guard let prev = lastUnigramCount, count > prev else { return }
        for _ in 0..<min(count - prev, 50) { counters.recordLearnedWord() }
        dirty = true
    }

    /// Closes the running typing session (keyboard hidden) and persists.
    public func endSession() {
        closeSession()
        dirty = true
        flush()
    }

    public func flush() {
        guard dirty else { return }
        dirty = false
        lastPersist = now()
        persist?(counters)
    }

    /// `resetInsights` command or a local reset: zero everything and persist at once.
    public func reset(at unixTime: Double) {
        counters.reset(at: unixTime)
        sessionStart = nil
        sessionWords = 0
        lastUnigramCount = nil
        dirty = true
        flush()
    }

    private func closeSession() {
        if let start = sessionStart { counters.recordSession(words: sessionWords, seconds: lastEvent - start) }
        sessionStart = nil
        sessionWords = 0
    }
}
