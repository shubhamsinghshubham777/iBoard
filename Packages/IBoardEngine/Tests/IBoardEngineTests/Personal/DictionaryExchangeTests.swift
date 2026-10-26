import Foundation
import Testing
@testable import IBoardEngine

private func makeStore(clock: ManualPersonalClock = ManualPersonalClock()) -> PersonalStore {
    PersonalStore(storage: InMemoryPersonalStorage(), clock: clock)
}

private func populate(_ store: PersonalStore) async {
    for _ in 0..<3 {
        await store.learn(word: "shubham", surface: "Shubham", increment: 1)
        await store.learn(word: "airport", context: ["the"], increment: 1)
        for (i, w) in ["see", "you", "at", "the", "airport"].enumerated() {
            await store.learn(word: w, context: Array(["see", "you", "at", "the", "airport"][max(0, i - 2)..<i]), increment: 1,
                              phraseContext: Array(["see", "you", "at", "the", "airport"][max(0, i - 5)..<i]))
        }
    }
    await store.learn(word: "iphone", surface: "iPhone", increment: 1)
    await store.learn(word: "badword", increment: 1)
    await store.forget("badword")
    await store.addNeverCorrect("shubham")
    await store.addNeverCorrect("ok")
}

private let header = #"{"format":"iboarddict","version":1,"created":1700000000}"#

private func file(_ lines: String...) -> Data { Data(([header] + lines).joined(separator: "\n").utf8) }

@Suite struct DictionaryExchangeTests {
    @Test func roundTripPreservesWordsPhrasesCasingListsAndCounts() async throws {
        let clock = ManualPersonalClock()
        let a = makeStore(clock: clock)
        await populate(a)
        let data = await a.exportDictionary()
        let b = makeStore(clock: clock)
        let r = try await b.importDictionary(data)
        #expect(r.decode.rejectedTotal == 0)
        let sa = await a.exportState(), sb = await b.exportState()
        let now = clock.now()
        #expect(Set(sa.unigrams.keys) == Set(sb.unigrams.keys))
        for (k, e) in sa.unigrams {
            #expect(abs(sa.effective(e, at: now) - sb.effective(sb.unigrams[k]!, at: now)) < 1e-3)
            #expect(sb.unigrams[k]!.uses >= min(e.uses, 3))
        }
        #expect(Set(sa.phrases.keys) == Set(sb.phrases.keys))
        #expect(sb.surfaces == sa.surfaces)
        #expect(Set(sb.forgotten.keys) == Set(sa.forgotten.keys))
        #expect(sb.neverCorrect == sa.neverCorrect)
        // Imported phrases that were learned (uses >= 2) are learned in the new model too.
        #expect(await b.repeatedPhrases().count == a.repeatedPhrases().count)
    }

    @Test func exportIsDeterministicAndTextOnlyJSONLines() async throws {
        let a = makeStore()
        await populate(a)
        let d1 = await a.exportDictionary(), d2 = await a.exportDictionary()
        #expect(d1 == d2)
        let text = String(decoding: d1, as: UTF8.self)
        let lines = text.split(separator: "\n")
        #expect(lines.first?.contains("\"format\":\"iboarddict\"") == true)
        #expect(lines.first?.contains("\"version\":1") == true)
        for l in lines { _ = try JSONSerialization.jsonObject(with: Data(l.utf8)) }
        #expect(text.contains("\"t\":\"phrase\""))
        #expect(text.contains("\"t\":\"forget\""))
        #expect(text.contains("\"t\":\"never\""))      // "ok" is not a word, so it gets its own record
        #expect(text.contains("\"f\":[\"neverCorrect\"]"))
        // Forgotten words are not exported as words.
        #expect(!text.contains("\"t\":\"word\",\"w\":\"badword\""))
    }

    @Test func importTwiceIsIdempotent() async throws {
        let a = makeStore()
        await populate(a)
        let data = await a.exportDictionary()
        let b = makeStore()
        try await b.importDictionary(data)
        let once = await b.exportState()
        let second = try await b.importDictionary(data)
        let twice = await b.exportState()
        #expect(second.merge.wordsAdded == 0 && second.merge.wordsUpdated == 0 && second.merge.phrasesUpdated == 0)
        #expect(once.unigrams == twice.unigrams)
        #expect(once.phrases == twice.phrases)
    }

    @Test func mergeKeepsTheLargerCountNeverSums() async throws {
        let s = makeStore()
        for _ in 0..<5 { await s.learn(word: "alpha", increment: 1) }     // local weight 5, uses 5
        let before = await s.effectiveWeight(of: "alpha")
        let d = file(#"{"t":"word","w":"alpha","c":2,"u":2}"#, #"{"t":"word","w":"beta","s":"Beta","c":4,"u":3}"#)
        let r = try await s.importDictionary(d)
        #expect(r.merge.wordsUnchanged == 1 && r.merge.wordsAdded == 1)
        #expect(abs(await s.effectiveWeight(of: "alpha") - before) < 1e-6)
        #expect(abs(await s.effectiveWeight(of: "beta") - 4) < 1e-3)
        #expect(await s.uses(of: "beta") == 3)
        // A bigger imported count raises it to the imported value (not local + imported).
        try await s.importDictionary(file(#"{"t":"word","w":"alpha","c":9,"u":9}"#))
        #expect(abs(await s.effectiveWeight(of: "alpha") - 9) < 1e-3)
    }

    @Test func localForgetBlocksImportAndFileForgetRemovesLocal() async throws {
        let s = makeStore()
        await s.learn(word: "keepme", increment: 1)
        await s.learn(word: "dropme", context: [], increment: 1)
        await s.forget("blocked")
        let d = file(#"{"t":"word","w":"blocked","c":3,"u":3}"#,
                     #"{"t":"phrase","w":["see","blocked","now"],"c":3,"u":3}"#,
                     #"{"t":"forget","w":"dropme","at":1600000000}"#,
                     #"{"t":"word","w":"dropme","c":3,"u":3}"#)
        let r = try await s.importDictionary(d)
        #expect(r.merge.skippedForgotten == 3)
        #expect(r.merge.forgetsApplied == 1)
        #expect(await s.uses(of: "blocked") == 0)
        #expect(await s.uses(of: "dropme") == 0)
        #expect(await s.isForgotten("dropme"))
        #expect(await s.uses(of: "keepme") == 1)
    }

    @Test func neverCorrectIsUnionAndFlagCounts() async throws {
        let s = makeStore()
        await s.addNeverCorrect("local")
        try await s.importDictionary(file(#"{"t":"never","w":"remote"}"#, #"{"t":"word","w":"flagged","c":2,"u":2,"f":["neverCorrect","future-flag"]}"#))
        #expect(Set(await s.neverCorrectWords()) == ["local", "remote", "flagged"])
    }

    @Test func replaceExistingClearsFirst() async throws {
        let s = makeStore()
        await s.learn(word: "old", increment: 1)
        try await s.importDictionary(file(#"{"t":"word","w":"fresh","c":2,"u":2}"#), options: DictionaryImportOptions(replaceExisting: true))
        #expect(await s.uses(of: "old") == 0)
        #expect(await s.uses(of: "fresh") == 2)
    }

    @Test func headerValidation() throws {
        #expect(throws: DictionaryError.empty) { try DictionaryDecoder.decode(Data()) }
        #expect(throws: DictionaryError.missingHeader) { try DictionaryDecoder.decode(Data("hello\n".utf8)) }
        #expect(throws: DictionaryError.missingHeader) { try DictionaryDecoder.decode(Data(#"{"t":"word","w":"abc","c":1}"#.utf8)) }
        #expect(throws: DictionaryError.wrongFormat) { try DictionaryDecoder.decode(Data(#"{"format":"other","version":1}"#.utf8)) }
        #expect(throws: DictionaryError.unsupportedVersion(2)) { try DictionaryDecoder.decode(Data(#"{"format":"iboarddict","version":2}"#.utf8)) }
        #expect(throws: DictionaryError.missingHeader) { try DictionaryDecoder.decode(Data(#"{"format":"iboarddict","version":0}"#.utf8)) }
        #expect(throws: DictionaryError.tooLarge) { try DictionaryDecoder.decode(Data(count: DictionaryFormat.maxBytes + 1)) }
        // BOM and CRLF are tolerated.
        var d = Data([0xEF, 0xBB, 0xBF])
        d.append(Data("\(header)\r\n{\"t\":\"word\",\"w\":\"hello\",\"c\":1,\"u\":1}\r\n".utf8))
        #expect(try DictionaryDecoder.decode(d).words.count == 1)
    }

    @Test func badLinesAreSkippedAndCounted() throws {
        var bytes = Data(header.utf8)
        func add(_ s: String) { bytes.append(0x0A); bytes.append(Data(s.utf8)) }
        add(#"{"t":"word","w":"goodword","c":1,"u":1}"#)
        add("not json")
        add(#"{"t":"word","w":"abc123","c":1}"#)                       // digit
        add(#"{"t":"word","w":"me@example.com","c":1}"#)                // email
        add(#"{"t":"word","w":"https://x.y","c":1}"#)                  // url
        add(#"{"t":"word","w":"fine","c":-1}"#)                         // weight
        add(#"{"t":"word","w":"fine","c":0}"#)
        add(#"{"t":"word","w":"fine","c":1e999}"#)                      // not representable
        add(#"{"t":"word","w":"fine","s":"Other","c":1}"#)              // surface does not match
        add(#"{"t":"word","c":1}"#)                                     // no word
        add(#"{"t":"phrase","w":["only","two"],"c":1}"#)               // too short
        add(#"{"t":"phrase","w":["a1b","two","three"],"c":1}"#)        // bad word inside
        add(#"{"t":"future","w":"x"}"#)                                 // unknown type
        add(#"{"w":"x"}"#)                                              // no type
        add(#"{"t":"word","w":"\#(String(repeating: "a", count: 3000))","c":1}"#)   // too long line
        add(#"{"t":"never","w":"has space"}"#)
        add(#"{"t":"never","w":"bad\u001Fsep"}"#)
        bytes.append(0x0A); bytes.append(contentsOf: [0xFF, 0xFE, 0xFD])   // invalid UTF-8
        let d = try DictionaryDecoder.decode(bytes)
        #expect(d.words.map(\.word) == ["goodword"])
        #expect(d.report.accepted == 1)
        #expect(d.report.rejected[.malformedJSON, default: 0] >= 2)
        #expect(d.report.rejected[.invalidWord, default: 0] >= 6)
        #expect(d.report.rejected[.unknownRecordType] == 1)
        #expect(d.report.rejected[.lineTooLong] == 1)
        #expect(d.report.rejected[.invalidUTF8] == 1)
        #expect(d.report.rejected[.invalidWeight, default: 0] >= 2)
    }

    @Test func hostileValuesAreClamped() throws {
        let d = try DictionaryDecoder.decode(file(#"{"t":"word","w":"huge","c":1e300,"u":99999999999}"#,
                                                    #"{"t":"word","w":"neg","c":5,"u":-5}"#))
        let huge = try #require(d.words.first { $0.word == "huge" })
        #expect(huge.weight == DictionaryFormat.maxWeight && huge.uses == DictionaryFormat.maxUses)
        #expect(try #require(d.words.first { $0.word == "neg" }).uses == 1)
    }

    @Test func deeplyNestedAndHugeInputsDoNotCrash() throws {
        let nested = String(repeating: "[", count: 1500) + String(repeating: "]", count: 1500)
        let d = try DictionaryDecoder.decode(file(nested, #"{"t":"word","w":"ok1","c":1}"#, #"{"t":"word","w":"good","c":1,"u":1}"#))
        #expect(d.words.count == 1)
        // Too many lines.
        var big = Data(header.utf8)
        let line = Data("\n{\"t\":\"never\",\"w\":\"x\"}".utf8)
        for _ in 0...DictionaryFormat.maxRecords { big.append(line) }
        #expect(throws: DictionaryError.tooManyRecords) { try DictionaryDecoder.decode(big) }
    }

    @Test func capsKeepTheHeaviestPhrases() throws {
        var lines: [String] = []
        for i in 0..<(DictionaryFormat.maxPhrases + 50) {
            let w = "word" + String(UnicodeScalar(UInt8(97 + i % 26))) + String(UnicodeScalar(UInt8(97 + (i / 26) % 26))) + String(UnicodeScalar(UInt8(97 + i / 676)))
            lines.append(#"{"t":"phrase","w":["see","you","\#(w)"],"c":\#(i + 1),"u":2}"#)
        }
        let d = try DictionaryDecoder.decode(file(lines.joined(separator: "\n")))
        #expect(d.phrases.count == DictionaryFormat.maxPhrases)
        #expect(d.report.droppedByCap == 50)
        #expect(d.phrases.allSatisfy { $0.weight > 50 })
    }

    @Test func fuzzedFilesNeverCrashAndOnlyYieldValidData() async throws {
        let a = makeStore()
        await populate(a)
        let base = await a.exportDictionary()
        var rng = SplitMix64(seed: 77)
        for _ in 0..<400 {
            var d = base
            for _ in 0..<(1 + Int(rng.next() % 8)) {
                guard !d.isEmpty else { break }
                let i = Int(rng.next() % UInt64(d.count))
                switch rng.next() % 3 {
                case 0: d[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: d.remove(at: i)
                default: d.insert(UInt8(truncatingIfNeeded: rng.next()), at: i)
                }
            }
            if let dec = try? DictionaryDecoder.decode(d) {
                #expect(dec.words.allSatisfy { LearnableWord.rejection($0.word) == nil && $0.weight > 0 && $0.weight <= DictionaryFormat.maxWeight })
                #expect(dec.phrases.allSatisfy { (3...6).contains($0.words.count) })
                // Merging a fuzzed file must not throw or crash either.
                let plan = DictionaryMerger.plan(dec, into: PersonalModelState(), at: 1_700_000_000)
                var st = PersonalModelState(); for op in plan.ops { st.apply(op) }
            }
        }
    }

    @Test func importedForgetTimestampsAreNotInTheFuture() async throws {
        let clock = ManualPersonalClock()
        let s = makeStore(clock: clock)
        try await s.importDictionary(file(#"{"t":"forget","w":"later","at":99999999999}"#))
        #expect((await s.forgetEntry(for: "later"))?.at == clock.now())
    }
}
