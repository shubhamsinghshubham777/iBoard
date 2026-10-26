import Foundation
import Testing
@testable import IBoardOTP

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

@Suite struct OTPStoreTests {
    func make() -> (OTPWriter, OTPReader, TestClock, InMemoryOTPStorage) {
        let c = TestClock(); let s = InMemoryOTPStorage()
        return (OTPWriter(storage: s, clock: { c.now }), OTPReader(storage: s, clock: { c.now }), c, s)
    }

    @Test func keepsLastThreeNewestFirst() {
        let (w, r, c, _) = make()
        for i in 1...5 { w.record(code: "11111\(i)", sender: "S"); c.advance(1) }
        #expect(r.freshCodes().map(\.code) == ["111115", "111114", "111113"])
    }

    @Test func expiresAfterDefaultTTL() {
        let (w, r, c, _) = make()
        w.record(code: "123456", sender: "Bank")
        c.advance(599); #expect(r.freshCodes().count == 1)
        c.advance(2); #expect(r.freshCodes().isEmpty)
    }

    @Test func ttlIsSetting() {
        let (w, r, c, _) = make()
        w.setTTL(30); w.record(code: "123456", sender: nil)
        c.advance(31); #expect(r.freshCodes().isEmpty)
    }

    @Test func consumedExcludedWhenClearAfterInsert() {
        let (w, r, _, _) = make()
        let e = w.record(code: "123456", sender: "A")
        #expect(r.freshCodes(excluding: [e.id]).isEmpty)
        w.setClearAfterInsert(false)
        #expect(r.freshCodes(excluding: [e.id]).count == 1)
    }

    @Test func storesOnlyCodeSenderTimestamp() throws {
        let (w, _, _, s) = make()
        w.capture(text: "Your OTP is 482913. Do not share SECRETBODYMARKER", sender: "HDFCBK")
        let data = try #require(s.data(forKey: OTPStoreConfig.codesKey))
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("482913"))
        #expect(!raw.contains("SECRETBODYMARKER"))
        let objs = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(Set(objs[0].keys) == ["code", "sender", "timestamp"])
    }

    @Test func nonCodeMessageStoresNothing() {
        let (w, r, _, _) = make()
        #expect(w.capture(text: "See you at lunch", sender: "Mum") == nil)
        #expect(r.freshCodes().isEmpty)
    }

    @Test func duplicateReplaced() {
        let (w, r, c, _) = make()
        w.record(code: "123456", sender: "A"); c.advance(5); w.record(code: "123456", sender: "A")
        #expect(r.freshCodes().count == 1)
    }

    @Test func readerNeverWrites() {
        let (w, r, _, s) = make()
        w.record(code: "123456", sender: "A")
        let before = s.data(forKey: OTPStoreConfig.codesKey)
        _ = r.freshCodes()
        #expect(s.data(forKey: OTPStoreConfig.codesKey) == before)
    }
}
