import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

@Suite struct SwipeTraceTests {
    private func sample(_ word: String = "hello") throws -> SwipeTrace {
        var rng = SplitMix64(seed: 5)
        let pts = try #require(SwipeSynth.trace(word, layout: testLayout, profile: .normal, rng: &rng))
        return SwipeTrace(word: word, previousWords: ["say"], containerWidth: Double(testLayout.bounds.size.width),
                          containerHeight: Double(testLayout.bounds.size.height), samples: pts, source: "synthetic")
    }

    @Test func roundTrip() throws {
        let a = try sample("hello"), b = try sample("world")
        let data = try SwipeTraceFile.encode([a, b])
        let (back, skipped) = try SwipeTraceFile.decode(data)
        #expect(back == [a, b])
        #expect(skipped.isEmpty)
        #expect(String(decoding: data, as: UTF8.self).split(separator: "\n").count == 3)   // header + 2 traces
        // Times are relative to the first sample.
        #expect(a.points.first?[2] == 0)
    }

    @Test func replayMatchesDirectDecode() throws {
        let t = try sample("hello")
        let lex = try Fixture.small.lexicon()
        let lm = try Fixture.small.model(lexicon: lex)
        let dec = SwipeDecoder(layout: testLayout, lexicon: lex, model: lm)
        let direct = dec.decode(points: t.swipePoints())
        let viaScaled = dec.decode(points: t.swipePoints(scaledTo: testLayout.bounds.size))
        #expect(direct == viaScaled)
        #expect(direct.candidates.first?.word == "hello")
    }

    @Test func validationRejectsBadTraces() throws {
        var t = try sample()
        t.word = "Hello"
        #expect(throws: SwipeTrace.ValidationError.self) { try t.validate() }
        t = try sample(); t.points = [[1, 2, 0]]
        #expect(throws: SwipeTrace.ValidationError.self) { try t.validate() }
        t = try sample(); t.points[3] = [1, 2]
        #expect(throws: SwipeTrace.ValidationError.self) { try t.validate() }
        t = try sample(); t.points[4][2] = -5
        #expect(throws: SwipeTrace.ValidationError.self) { try t.validate() }
        t = try sample(); t.containerWidth = 0
        #expect(throws: SwipeTrace.ValidationError.self) { try t.validate() }
        t = try sample(); t.version = 9
        #expect(throws: SwipeTrace.ValidationError.self) { try t.validate() }
    }

    @Test func lenientDecodeSkipsBadLines() throws {
        let good = String(decoding: try SwipeTraceFile.encode([try sample()]), as: UTF8.self)
        let text = good + "not json\n\n# comment\n{\"version\":1}\n"
        #expect(throws: SwipeTraceFile.LineError.self) { try SwipeTraceFile.decode(Data(text.utf8)) }
        let r = try SwipeTraceFile.decode(Data(text.utf8), strict: false)
        #expect(r.traces.count == 1)
        #expect(r.skipped.map(\.line) == [3, 6])
    }

    /// Replays every trace dropped into Fixtures/traces against the real lexicons (prints; passes with none).
    @Test func realTracesReplay() throws {
        guard let dir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/traces") else { return }
        let traces = try SwipeTraceFile.loadDirectory(dir)
        guard !traces.isEmpty, let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else {
            print("REAL TRACES> none present")
            return
        }
        let sec = SecondaryLanguage(lexicon: hi, model: hiLM)
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, secondary: sec)
        var s = SwipeScore()
        for t in traces {
            let ctx = CodeSwitch.context(previousWords: t.previousWords, primary: en, secondary: sec, parameters: CodeSwitchParameters())
            let r = dec.decode(points: t.swipePoints(scaledTo: testLayout.bounds.size), context: ctx.primary,
                               contextWords: t.previousWords, secondaryContext: ctx.secondary)
            s.add(truth: t.word, result: r)
        }
        print(s.line("REAL TRACES> \(traces.count) owner traces").replacingOccurrences(of: "SYNTHETIC ", with: ""))
    }
}
