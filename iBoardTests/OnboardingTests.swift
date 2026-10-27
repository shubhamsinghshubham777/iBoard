import Foundation
import Testing
import IBoardOTP
@testable import iBoard

struct OnboardingTests {
    @Test func stepsMentionVerifiedSetupDetails() {
        for trigger in OTPTrigger.allCases {
            let text = OTPSetupGuide.steps(for: trigger).map { $0.title + " " + $0.detail + " " + ($0.note ?? "") }.joined(separator: " ")
            #expect(text.contains("Confirm Before Run"))
            #expect(text.contains("Capture Verification Code"))
            #expect(text.contains("Shortcuts"))
            #expect(text.contains("Message Text") && text.contains("Sender"))
            #expect(text.contains("restart"))
        }
        let mail = OTPSetupGuide.steps(for: .email).map(\.detail).joined()
        #expect(mail.contains("Subject Contains"))
        #expect(OTPSetupGuide.steps(for: .message).map(\.detail).joined().contains("Message Contains"))
    }

    @Test func stepIdsAreSequential() {
        #expect(OTPSetupGuide.steps(for: .message).map(\.id) == [1, 2, 3, 4, 5, 6])
    }

    @Test func selfTestDetectsOnlyNewCodes() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let old = StoredCode(code: "111111", sender: "a", timestamp: t0)
        var test = OTPSelfTest()
        test.start(existing: [old], now: t0)
        test.poll(codes: [old], now: t0.addingTimeInterval(5))
        #expect(test.state == .waiting(since: t0))
        let new = StoredCode(code: "482913", sender: "b", timestamp: t0.addingTimeInterval(8))
        test.poll(codes: [new, old], now: t0.addingTimeInterval(9))
        #expect(test.state == .received(new))
    }

    @Test func selfTestTimesOut() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var test = OTPSelfTest()
        test.start(existing: [], now: t0)
        test.poll(codes: [], now: t0.addingTimeInterval(OTPSelfTest.timeout + 1))
        #expect(test.state == .timedOut)
    }

    @Test func selfTestReadsFromStore() {
        let storage = InMemoryOTPStorage()
        let now = Date()
        let writer = OTPWriter(storage: storage, clock: { now })
        let reader = OTPReader(storage: storage, clock: { now })
        var test = OTPSelfTest()
        test.start(existing: reader.freshCodes(), now: now)
        writer.capture(text: OTPSetupGuide.selfTestSampleMessage, sender: "Bank")
        test.poll(codes: reader.freshCodes(), now: now)
        guard case .received(let c) = test.state else { Issue.record("not received"); return }
        #expect(c.code == "482913")
    }

    @Test func fullAccessMatrixCoversBothSides() {
        #expect(FullAccessMatrix.rows.contains { $0.withoutFullAccess })
        #expect(FullAccessMatrix.rows.contains { !$0.withoutFullAccess })
    }
}
