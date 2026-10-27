import CoreGraphics
import Foundation
import Testing
@testable import IBoardEngine
import IBoardLayout

/// Opt-in (IBOARD_TRACE=1, or =v for per-miss lines) failure analysis and train / held-out report over the real
/// owner traces. Split: even trace index = train (tuning allowed), odd = held-out (report only).
/// Params override with IBOARD_P="lmWeight=0.5,corridorRadius=1.2".
@Suite struct SwipeRealTraceAnalysisTests {
    static func params() -> SwipeParameters {
        var p = SwipeParameters()
        guard let s = ProcessInfo.processInfo.environment["IBOARD_P"] else { return p }
        for kv in s.split(separator: ",") {
            let a = kv.split(separator: "=")
            guard a.count == 2, let v = Double(a[1]) else { continue }
            switch a[0] {
            case "lmWeight": p.lmWeight = v
            case "corridorRadius": p.corridorRadius = v
            case "endRadius": p.endRadius = v
            case "shapeSigma": p.shapeSigma = v
            case "locationSigma": p.locationSigma = v
            case "locationTolerance": p.locationTolerance = v
            case "anchorWeight": p.anchorWeight = v
            case "anchorSigma": p.anchorSigma = v
            case "cornerDegrees": p.cornerDegrees = v
            case "dwellSpeed": p.dwellSpeed = v
            case "lmUnigramMix": p.lmUnigramMix = v
            case "endpointWeight": p.endpointWeight = v
            case "endpointTolerance": p.endpointTolerance = v
            case "endpointSigma": p.endpointSigma = v
            case "resampleCount": p.resampleCount = Int(v)
            default: print("unknown param \(a[0])")
            }
        }
        return p
    }

    @Test func analyse() throws {
        guard let mode = ProcessInfo.processInfo.environment["IBOARD_TRACE"],
              let dir = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/traces"),
              let (en, enLM) = realEnglish(), let (hi, hiLM) = realHinglish() else { return }
        let traces = try SwipeTraceFile.loadDirectory(dir)
        let sec = SecondaryLanguage(lexicon: hi, model: hiLM)
        var p = Self.params()
        p.maxCandidates = 50
        let dec = SwipeDecoder(layout: testLayout, lexicon: en, model: enLM, parameters: p, secondary: sec)
        var train = SwipeScore(), held = SwipeScore()
        var offs: [(Double, Double)] = []
        for (i, t) in traces.enumerated() {
            let ctx = CodeSwitch.context(previousWords: t.previousWords, primary: en, secondary: sec, parameters: CodeSwitchParameters())
            let pts = t.swipePoints(scaledTo: testLayout.bounds.size)
            let r = dec.decode(points: pts, context: ctx.primary, contextWords: t.previousWords, secondaryContext: ctx.secondary)
            if i % 2 == 0 { train.add(truth: t.word, result: r) } else { held.add(truth: t.word, result: r) }
            guard let first = testLayout.firstKey(.letter(String(t.word.first!))),
                  let last = testLayout.firstKey(.letter(String(t.word.last!))) else { continue }
            let s0 = pts[0], s1 = pts[pts.count - 1]
            let kw = Double(first.frame.width), kh = Double(first.frame.height)
            let a = ((s0.x - Double(first.frame.midX)) / kw, (s0.y - Double(first.frame.midY)) / kh)
            let b = ((s1.x - Double(last.frame.midX)) / kw, (s1.y - Double(last.frame.midY)) / kh)
            offs.append(a); offs.append(b)
            let words = r.candidates.map(\.word)
            if mode == "v", !words.prefix(3).contains(t.word) {
                let rank = words.firstIndex(of: t.word).map(String.init) ?? "-"
                let inLex = en.lookup(t.word) != nil ? "en" : (hi.lookup(t.word) != nil ? "hi" : "OOV")
                let top = r.candidates.prefix(3).map { String(format: "%@(%.1f/%.1f)", $0.word, $0.spatial, $0.language) }.joined(separator: " ")
                var line = String(format: "MISS #%d %@ [%@] rank=%@ conf=%.2f start(%.2f,%.2f) end(%.2f,%.2f) anchors=%d top=%@",
                                  i, t.word, inLex, rank, r.confidence, a.0, a.1, b.0, b.1, r.anchorCount, top)
                if let c = r.candidates.first(where: { $0.word == t.word }) {
                    line += String(format: " | truth spatial %.1f lang %.1f", c.spatial, c.language)
                }
                print(line)
            }
        }
        let mx = offs.map { $0.0 }.reduce(0, +) / Double(offs.count), my = offs.map { $0.1 }.reduce(0, +) / Double(offs.count)
        print(String(format: "OFFSET end-points mean dx %.3f dy %.3f key", mx, my))
        print(train.line("TRAIN").replacingOccurrences(of: "SYNTHETIC ", with: "REAL "))
        print(held.line("HELD").replacingOccurrences(of: "SYNTHETIC ", with: "REAL "))
        if ProcessInfo.processInfo.environment["IBOARD_SYNTH"] != nil {
            print(SwipeSloppySweepTests.line("synthetic under IBOARD_P",
                  SwipeSloppySweepTests.evaluate(Self.params(), en: en, enLM: enLM, hi: hi, hiLM: hiLM)))
        }
    }
}
