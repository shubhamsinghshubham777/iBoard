import Foundation

// Typing insights counters (F16, M10-04). Aggregate numbers only: no text, no word list. "Top learned words" are
// derived in the app from the dictionary snapshot, never stored here. The keyboard increments and persists its own
// copy; sharing it with the app needs Full Access (P-23), so the app shows an honest "not shared" state otherwise.

public struct InsightCounters: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = InsightCounters.currentVersion
    /// Words committed by any input method.
    public var wordsTyped = 0
    /// Words committed by swipe (subset of `wordsTyped`).
    public var swipeWords = 0
    /// Typing seconds with idle gaps excluded, and the words counted inside those sessions (for WPM).
    public var activeSeconds = 0.0
    public var sessionWords = 0
    public var sessions = 0
    public var autocorrectAccepted = 0
    public var autocorrectReverted = 0
    public var wordsLearned = 0
    /// Unix time of the last reset (0 = never).
    public var resetAt = 0.0

    public init() {}

    /// Idle gap that ends a typing session.
    public static let sessionIdleGap = 8.0
    /// Sessions shorter than this are ignored for WPM (too noisy).
    public static let minSessionSeconds = 3.0

    public mutating func recordWord(swiped: Bool) {
        wordsTyped = Self.inc(wordsTyped)
        if swiped { swipeWords = Self.inc(swipeWords) }
    }
    public mutating func recordAutocorrect(accepted: Bool) {
        if accepted { autocorrectAccepted = Self.inc(autocorrectAccepted) } else { autocorrectReverted = Self.inc(autocorrectReverted) }
    }
    public mutating func recordLearnedWord() { wordsLearned = Self.inc(wordsLearned) }

    /// Adds one finished typing session. Ignored when too short or not finite.
    public mutating func recordSession(words: Int, seconds: Double) {
        guard words > 0, seconds.isFinite, seconds >= Self.minSessionSeconds else { return }
        sessions = Self.inc(sessions)
        sessionWords = min(sessionWords + words, Int.max / 4)
        activeSeconds += seconds
    }

    /// Words per minute over all counted sessions; nil with no data.
    public var averageWPM: Double? {
        activeSeconds >= Self.minSessionSeconds && sessionWords > 0 ? Double(sessionWords) / (activeSeconds / 60) : nil
    }
    /// Reverted share of resolved autocorrections (0...1); nil before any.
    public var autocorrectRevertRate: Double? {
        let n = autocorrectAccepted + autocorrectReverted
        return n > 0 ? Double(autocorrectReverted) / Double(n) : nil
    }
    public var swipeShare: Double? {
        wordsTyped > 0 ? min(1, Double(swipeWords) / Double(wordsTyped)) : nil
    }
    public var isEmpty: Bool { wordsTyped == 0 && sessions == 0 && autocorrectAccepted + autocorrectReverted == 0 && wordsLearned == 0 }

    /// Zeroes every counter and stamps the reset time.
    public mutating func reset(at now: Double) {
        self = InsightCounters()
        resetAt = now
    }

    private static func inc(_ v: Int) -> Int { v < Int.max / 4 ? v + 1 : v }

    private enum CodingKeys: String, CodingKey {
        case version, wordsTyped, swipeWords, activeSeconds, sessionWords, sessions, autocorrectAccepted, autocorrectReverted, wordsLearned, resetAt
    }

    /// Tolerant: missing fields are zero, negative/non-finite values are clamped, newer versions are refused.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard v <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Newer insights version \(v)")
        }
        func i(_ k: CodingKeys) throws -> Int { max(0, try c.decodeIfPresent(Int.self, forKey: k) ?? 0) }
        func d(_ k: CodingKeys) throws -> Double {
            let x = try c.decodeIfPresent(Double.self, forKey: k) ?? 0
            return x.isFinite ? max(0, x) : 0
        }
        wordsTyped = try i(.wordsTyped); swipeWords = min(try i(.swipeWords), wordsTyped)
        activeSeconds = try d(.activeSeconds); sessionWords = try i(.sessionWords); sessions = try i(.sessions)
        autocorrectAccepted = try i(.autocorrectAccepted); autocorrectReverted = try i(.autocorrectReverted)
        wordsLearned = try i(.wordsLearned); resetAt = try d(.resetAt)
    }
}

/// App Group defaults store for the counters. The keyboard writes it only with Full Access; the app reads it.
public struct InsightsStore: @unchecked Sendable {
    public static let key = "iboard.insights.counters"
    private let defaults: UserDefaults?

    public init(suiteName: String? = SettingsStore.appGroup) { defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } }
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// nil when nothing was ever shared (or the data is unreadable): the UI shows the "not shared" state.
    public func load() -> InsightCounters? {
        guard let d = defaults?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(InsightCounters.self, from: d)
    }

    @discardableResult
    public func save(_ c: InsightCounters) -> Bool {
        guard let defaults, let d = try? JSONEncoder().encode(c) else { return false }
        defaults.set(d, forKey: Self.key)
        return true
    }

    /// Resets the shared copy and returns the zeroed value.
    @discardableResult
    public func reset(at now: Double = Date().timeIntervalSince1970) -> InsightCounters {
        var c = InsightCounters(); c.reset(at: now); save(c); return c
    }
}
