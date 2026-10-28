import CoreGraphics
import Foundation
import Testing
import IBoardLayout
@testable import IBoardUI

/// Deterministic replay of a DEBUG touch log pulled with `scripts/touchlog.sh` (see TouchRecorder.swift).
/// Feeds the touch records to a `KeyboardInputMachine` (ticks at 30 Hz between records, like the display link) and
/// returns the machine's event names, so the inserts can be compared with the "insert" events the device logged.
/// Limits: swipe / spacebar-drag arbitration and strip touches are not replayed (the machine sees plain presses).
struct TouchReplayResult {
    var insertCounts: [Int] = []
    var events: [String] = []
}

func replay(_ log: TouchLogFile, tickHz: Double = 30) -> TouchReplayResult {
    let layout = LayoutEngine.layout(containerSize: CGSize(width: log.containerWidth, height: log.containerHeight),
                                     traits: LayoutTraits(needsInputModeSwitchKey: log.needsGlobe), kind: .letters)
    var m = KeyboardInputMachine(layout: layout)
    m.longPressDelay = log.longPressDelay
    var out = TouchReplayResult()
    func emit(_ e: KeyEvent) {
        switch e {
        case .insert(let s): out.insertCounts.append(s.count); out.events.append("insert")
        case .alternatesBegan: out.events.append("altBegan")
        case .alternatesEnded: out.events.append("altEnded")
        case .alternatesCancelled: out.events.append("altCancelled")
        case .openEmoji: out.events.append("openEmoji")
        default: break
        }
    }
    let touchTypes: Set<String> = ["began", "moved", "ended", "cancelled"]
    var clock = log.records.first(where: { touchTypes.contains($0.type) })?.ts ?? 0
    for r in log.records where touchTypes.contains(r.type) {
        let p = CGPoint(x: r.x, y: r.y)
        while clock + 1 / tickHz < r.ts { clock += 1 / tickHz; m.tick(now: clock, emit: emit) }
        clock = max(clock, r.ts)
        switch r.type {
        case "began": m.touchDown(id: r.id, at: p, time: r.ts, emit: emit)
        case "moved": m.touchMoved(id: r.id, to: p, emit: emit)
        case "ended": m.touchUp(id: r.id, at: p, time: r.ts, emit: emit)
        default: m.touchCancelled(id: r.id, emit: emit)
        }
    }
    return out
}

private func loadFixture(_ name: String) throws -> TouchLogFile {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    return try JSONDecoder().decode(TouchLogFile.self, from: Data(contentsOf: url))
}

@Test func ringKeepsNewestRecordsInOrder() {
    var ring = TouchLogRing(capacity: 3)
    for i in 0..<5 { ring.append(TouchLogRecord(type: "began", id: i, ts: Double(i))) }
    #expect(ring.ordered.map(\.id) == [2, 3, 4])
}

@Test func replayOfFastTapsReproducesLoggedInsertCounts() throws {
    let log = try loadFixture("fast-taps")
    let logged = log.records.filter { $0.type == "insert" }.map(\.n)
    let result = replay(log)
    #expect(result.insertCounts == logged)
    #expect(!result.events.contains("altBegan"))
}

/// Run once to (re)generate Fixtures/fast-taps.json: IBOARD_GEN_FIXTURE=1 swift test --filter generateFixture
@Test func generateFixture() throws {
    guard ProcessInfo.processInfo.environment["IBOARD_GEN_FIXTURE"] != nil else { return }
    let size = CGSize(width: 390, height: 260)
    let layout = LayoutEngine.layout(containerSize: size, traits: LayoutTraits(needsInputModeSwitchKey: false), kind: .letters)
    var recs: [TouchLogRecord] = []
    var t = 100.0
    // "Typing fast", 70 ms apart, 45 ms hold, two overlapping (rollover) pairs.
    let word: [KeyIdentity] = [.letter("t"), .letter("y"), .letter("p"), .letter("i"), .letter("n"), .letter("g"),
                               .space, .letter("f"), .letter("a"), .letter("s"), .letter("t")]
    for (n, id) in word.enumerated() {
        let f = layout.firstKey(id)!.frame
        let ki = layout.firstKey(id)!.id
        let kind = TouchLogRecord.kind(of: id)
        recs.append(TouchLogRecord(type: "began", id: n, ts: t, x: f.midX, y: f.midY, ki: ki, kind: kind))
        let hold = n % 4 == 3 ? 0.11 : 0.045
        recs.append(TouchLogRecord(type: "ended", id: n, ts: t + hold, x: f.midX, y: f.midY, ki: ki, kind: kind))
        recs.append(TouchLogRecord(type: "insert", ts: t + hold, n: 1))
        t += 0.07 + (n % 4 == 3 ? 0.04 : 0)
    }
    let file = TouchLogFile(containerWidth: 390, containerHeight: 260, needsGlobe: false, longPressDelay: 0.45, records: recs)
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fast-taps.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(file).write(to: url)
}
