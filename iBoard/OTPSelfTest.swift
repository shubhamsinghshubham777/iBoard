import Foundation
import Observation
import IBoardOTP

/// Pure state machine for the setup self-test: "send yourself a code and see it arrive".
/// Detects only codes that were not already in the store when the test started.
/// Holds codes in memory for display; nothing is logged or persisted.
struct OTPSelfTest: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case waiting(since: Date)
        case received(StoredCode)
        case timedOut
    }

    static let timeout: TimeInterval = 120

    private(set) var state: State = .idle
    private var baseline: Set<String> = []

    mutating func start(existing: [StoredCode], now: Date) {
        baseline = Set(existing.map(\.id))
        state = .waiting(since: now)
    }

    mutating func poll(codes: [StoredCode], now: Date) {
        guard case .waiting(let since) = state else { return }
        if let new = codes.first(where: { !baseline.contains($0.id) }) {
            state = .received(new)
        } else if now.timeIntervalSince(since) > Self.timeout {
            state = .timedOut
        }
    }

    mutating func reset() { state = .idle; baseline = [] }
}

/// Drives the self-test from the App Group store (the app can read it, P-23 / M6-02).
@MainActor @Observable
final class OTPSelfTestModel {
    private(set) var test = OTPSelfTest()
    private var task: Task<Void, Never>?
    private let reader: OTPReader

    init(reader: OTPReader = OTPReader()) { self.reader = reader }

    func start() {
        task?.cancel()
        test.start(existing: reader.freshCodes(), now: Date())
        let reader = self.reader
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.test.poll(codes: reader.freshCodes(), now: Date())
                if case .waiting = self.test.state { continue }
                return
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    func reset() { stop(); test.reset() }
}
