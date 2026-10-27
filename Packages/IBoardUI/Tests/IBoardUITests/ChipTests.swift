import Foundation
import Testing
import IBoardEngine
import IBoardOTP
@testable import IBoardUI

@Suite struct ChipTests {
    private let code = StoredCode(code: "123456", sender: "HDFC", timestamp: Date(timeIntervalSince1970: 1000))
    private let info = PersonalInfo(fullName: "Asha Rao", emails: ["a@x.com", "b@y.org"], phones: ["+91 98765 43210"],
                                    addresses: [PersonalAddress(street: "1 MG Road", city: "Pune", region: "MH", postalCode: "411001")])
    private func field(_ ct: String? = nil, _ kb: FieldKeyboardKind = .default, secure: Bool = false, empty: Bool = true) -> ChipField {
        ChipField(contentType: ct, keyboard: kb, isSecure: secure, isEmpty: empty)
    }

    @Test func oneTimeCodeFieldGetsProminentFirstSlot() {
        let plan = ChipPlanner.plan(codes: [code], info: info, field: field("oneTimeCode"))
        #expect(plan[0]?.insert == "123456" && plan[0]?.emphasized == true)
        #expect(plan[0]?.display == "123456 \u{00B7} HDFC")
        #expect(plan[1] == nil && plan[2] == nil)
    }

    @Test func numericFieldIsProminentToo() {
        for kb in [FieldKeyboardKind.numberPad, .asciiCapableNumberPad, .decimalPad] {
            #expect(ChipPlanner.plan(codes: [code], info: .empty, field: field(nil, kb))[0]?.emphasized == true)
        }
        #expect(ChipPlanner.plan(codes: [code], info: .empty, field: field(nil, .phonePad))[0] == nil)
    }

    @Test func ordinaryFieldShowsNonProminentChipInLastSlot() {
        let plan = ChipPlanner.plan(codes: [code], info: info, field: field())
        #expect(plan[0] == nil && plan[1] == nil)
        #expect(plan[2]?.insert == "123456" && plan[2]?.emphasized == false)
        let phrase = SuggestionSlot(text: "hello there", role: .phrase)
        #expect(ChipPlanner.plan(codes: [code], info: info, field: field(), suggestions: [nil, nil, phrase])[2] == nil)
    }

    @Test func noCodesNoChip() {
        #expect(ChipPlanner.plan(codes: [], info: .empty, field: field("oneTimeCode")) == [nil, nil, nil])
    }

    @Test func secureFieldsGetNothingExceptOneTimeCode() {
        #expect(ChipPlanner.plan(codes: [code], info: info, field: field("password", secure: true)) == [nil, nil, nil])
        #expect(ChipPlanner.plan(codes: [code], info: info, field: field("emailAddress", secure: true)) == [nil, nil, nil])
        #expect(ChipPlanner.plan(codes: [code], info: info, field: field("oneTimeCode", secure: true))[0] != nil)
    }

    @Test func personalChipsOnlyForMatchingContentTypes() {
        func texts(_ ct: String?) -> [String] { ChipPlanner.plan(codes: [], info: info, field: field(ct)).compactMap { $0?.insert } }
        #expect(texts("emailAddress") == ["a@x.com", "b@y.org"])
        #expect(texts("EmailAddress") == ["a@x.com", "b@y.org"])
        #expect(texts("telephoneNumber") == ["+91 98765 43210"])
        #expect(texts("name") == ["Asha Rao"])
        #expect(texts("givenName") == ["Asha"])
        #expect(texts("familyName") == ["Rao"])
        #expect(texts("postalCode") == ["411001"])
        #expect(texts("fullStreetAddress") == ["1 MG Road, Pune, MH, 411001"])
        #expect(texts("addressCity") == ["Pune"])
        for none in [nil, "", "username", "password", "organizationName", "creditCardNumber", "oneTimeCode", "url", "jobTitle"] {
            #expect(texts(none) == [], "content type \(String(describing: none))")
        }
    }

    @Test func personalChipsOnlyInEmptyFieldAndNeverWhenSecure() {
        #expect(ChipPlanner.plan(codes: [], info: info, field: field("emailAddress", empty: false)) == [nil, nil, nil])
        #expect(ChipPlanner.plan(codes: [], info: info, field: field("emailAddress", secure: true)) == [nil, nil, nil])
        #expect(ChipPlanner.plan(codes: [], info: .empty, field: field("emailAddress")) == [nil, nil, nil])
    }

    @Test func infoStorageRoundTripAndTolerantDecode() {
        let store = InMemoryPersonalInfoStorage()
        #expect(PersonalInfoReader(storage: store).load().isEmpty)
        PersonalInfoWriter(storage: store).save(info)
        #expect(PersonalInfoReader(storage: store).load() == info)
        store.set(Data("{\"emails\":[\"q@z.io\"]}".utf8), forKey: PersonalInfoStore.key)
        #expect(PersonalInfoReader(storage: store).load().emails == ["q@z.io"])
        store.set(Data("garbage".utf8), forKey: PersonalInfoStore.key)
        #expect(PersonalInfoReader(storage: store).load().isEmpty)
        PersonalInfoWriter(storage: store).save(.empty)
        #expect(store.data(forKey: PersonalInfoStore.key) == nil)
    }

    @Test func entryCountIsCapped() {
        let many = PersonalInfo(emails: (0..<20).map { "e\($0)@x.com" })
        #expect(many.values(forContentType: "emailAddress").count == PersonalInfo.maxEntries)
    }

    @Test func insertedCodeIsHiddenAfterwardsViaConsumedIDs() {
        let storage = InMemoryOTPStorage()
        let now = Date(timeIntervalSince1970: 5000)
        let writer = OTPWriter(storage: storage, clock: { now })
        let a = writer.record(code: "111111", sender: "A")
        let reader = OTPReader(storage: storage, clock: { now.addingTimeInterval(30) })
        var consumed = Set<String>()
        #expect(reader.freshCodes(excluding: consumed).map(\.code) == ["111111"])
        consumed.insert(a.id)
        #expect(reader.freshCodes(excluding: consumed).isEmpty)
        let reader2 = OTPReader(storage: storage, clock: { now.addingTimeInterval(11 * 60) })
        #expect(reader2.freshCodes().isEmpty) // expired
    }
}
