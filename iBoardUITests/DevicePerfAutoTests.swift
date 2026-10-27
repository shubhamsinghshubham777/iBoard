import XCTest
import ObjectiveC

/// Fully automated on-device perf drive (scripts/device-perf.sh auto). Drives the real iBoard keyboard inside Apple Notes
/// by screen coordinates (the keyboard extension's own elements are not exposed to the host app's accessibility tree).
/// Types only harmless letters into a scratch note and deletes the note afterwards. Records nothing itself: the keyboard's
/// PerfMetricsHook writes the counts/timings. Env: IBOARD_PHASES (comma list, default all), IBOARD_SOAK_SECONDS.
final class DevicePerfAutoTests: XCTestCase {
    var notes: XCUIApplication!
    // iPhone 12 (390x844 pt) iBoard geometry, measured from device screenshots (docs/perf/evidence).
    let rowY: [CGFloat] = [580, 634, 688]
    let rowX0: [CGFloat] = [21, 40.5, 78.5]
    let pitch: CGFloat = 38.6
    let spaceY: CGFloat = 743
    let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    func p(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        notes.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    func key(_ c: Character) -> CGPoint? {
        for (r, row) in rows.enumerated() {
            if let i = row.firstIndex(of: c) {
                return CGPoint(x: rowX0[r] + pitch * CGFloat(row.distance(from: row.startIndex, to: i)), y: rowY[r])
            }
        }
        return nil
    }
    func shot(_ n: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }
    func tapKey(_ c: Character) {
        if c == " " { p(170, spaceY).tap() } else if let k = key(c) { p(k.x, k.y).tap() }
    }
    func typeText(_ s: String) { for c in s { tapKey(c) } }

    // Multi-point touch via XCTest's private event synthesizer (same machinery XCUICoordinate uses).
    func swipeWord(_ w: String) -> Bool {
        let pts = w.compactMap { key($0) }
        guard pts.count >= 2 else { return false }
        // Collapse duplicates, keep up to 5 points evenly spread.
        var path: [CGPoint] = []
        for q in pts where path.last != q { path.append(q) }
        guard path.count >= 2 else { return false }
        if path.count > 5 {
            let n = path.count
            path = (0..<5).map { path[$0 * (n - 1) / 4] }
        }
        guard let pathCls = NSClassFromString("XCPointerEventPath"),
              let recCls = NSClassFromString("XCSynthesizedEventRecord") else { return false }
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRec = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        func imp<T>(_ c: AnyClass, _ s: String, _ t: T.Type) -> T? {
            guard let m = class_getInstanceMethod(c, NSSelectorFromString(s)) else { return nil }
            return unsafeBitCast(method_getImplementation(m), to: t)
        }
        guard let initPath = imp(pathCls, "initForTouchAtPoint:offset:", InitPath.self),
              let move = imp(pathCls, "moveToPoint:atOffset:", Move.self),
              let lift = imp(pathCls, "liftUpAtOffset:", Lift.self),
              let initRec = imp(recCls, "initWithName:interfaceOrientation:", InitRec.self),
              let add = imp(recCls, "addPointerEventPath:", Add.self) else { return false }
        let first = p(path[0].x, path[0].y).screenPoint
        let ev = (pathCls as! NSObject.Type).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        let pe = initPath(ev, NSSelectorFromString("initForTouchAtPoint:offset:"), first, 0)
        var t = 0.0
        for q in path.dropFirst() {
            t += 0.06
            move(pe, NSSelectorFromString("moveToPoint:atOffset:"), p(q.x, q.y).screenPoint, t)
        }
        lift(pe, NSSelectorFromString("liftUpAtOffset:"), t + 0.02)
        let rec0 = (recCls as! NSObject.Type).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        let rec = initRec(rec0, NSSelectorFromString("initWithName:interfaceOrientation:"), "swipe" as NSString, 1)
        add(rec, NSSelectorFromString("addPointerEventPath:"), pe)
        let dev = XCUIDevice.shared
        guard let synth = dev.value(forKey: "eventSynthesizer") as? NSObject else { return false }
        let done = expectation(description: "synth")
        let blk: @convention(block) (Bool, NSError?) -> Void = { _, _ in done.fulfill() }
        typealias Synth = @convention(c) (AnyObject, Selector, AnyObject, Any) -> Void
        guard let synthImp = imp(type(of: synth), "synthesizeEvent:completion:", Synth.self) else { return false }
        synthImp(synth, NSSelectorFromString("synthesizeEvent:completion:"), rec, blk)
        wait(for: [done], timeout: 5)
        return true
    }

    func openScratchNote() {
        notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.launch()
        sleep(2)
        let new = notes.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'New Note'")).firstMatch
        if new.waitForExistence(timeout: 5) { new.tap() }
        sleep(1)
        let tv = notes.textViews.firstMatch
        if tv.waitForExistence(timeout: 5) { tv.tap() }
        sleep(2)
    }
    func deleteScratchNote() {
        // Done (checkmark) then "..." menu > Delete.
        p(352, 69).tap(); sleep(1)
        let more = notes.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'More'")).firstMatch
        if more.waitForExistence(timeout: 3) { more.tap(); sleep(1)
            let del = notes.buttons["Delete"].firstMatch
            if del.waitForExistence(timeout: 3) { del.tap() }
            let confirm = notes.buttons["Delete"].firstMatch
            if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        }
        sleep(1); shot("after-delete")
    }

    @MainActor
    func testAuto() throws {
        let phases = (ProcessInfo.processInfo.environment["IBOARD_PHASES"] ?? "idle,type,swipe,emoji,reshow").split(separator: ",").map(String.init)
        openScratchNote()
        shot("0-keyboard")
        if phases.contains("idle") { sleep(20) }
        if phases.contains("type") {
            let words = "the quick brown fox jumps over a lazy dog and then we went to see what people think about this idea "
            var s = ""; while s.count < 110 { s += words }
            typeText(String(s.prefix(110)))
            shot("1-typed")
        }
        if phases.contains("swipe") {
            typeText(" ")
            var ok = 0
            for w in ["hello", "world", "thanks", "tomorrow", "morning", "people", "great", "about", "should", "together"] {
                if swipeWord(w) { ok += 1 }; usleep(400_000); tapKey(" ")
            }
            print("IBOARD_SWIPES_OK", ok)
            shot("2-swiped")
        }
        if phases.contains("emoji") {
            p(76, spaceY).press(forDuration: 1.0)
            sleep(2); shot("3-emoji-open")
            for _ in 0..<6 { p(195, 700).press(forDuration: 0.05, thenDragTo: p(195, 560)) }
            sleep(10); shot("4-emoji-scrolled")
            // close: tap the ABC / letters key at bottom-left (see screenshot)
            p(42, 804).tap(); sleep(1); shot("5-emoji-closed")
        }
        if phases.contains("reshow") {
            for _ in 0..<20 {
                p(352, 69).tap(); usleep(900_000)     // Done: keyboard dismisses
                p(195, 300).tap(); usleep(1_200_000)  // tap back into the note
            }
            shot("6-reshown")
        }
        if let s = Double(ProcessInfo.processInfo.environment["IBOARD_SOAK_SECONDS"] ?? ""), s > 0 {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
            let end = Date().addingTimeInterval(s); var n = 0
            let letters = Array("abcdefghijklmnopqrstuvwxyz ")
            while Date() < end {
                if n % 60 == 59 { _ = swipeWord(["hello", "world", "people", "tomorrow"][Int(rnd() * 4) % 4]) }
                else if n % 50 == 49 { p(352, 688).tap() }   // backspace
                else { tapKey(letters[Int(rnd() * 27) % 27]) }
                n += 1
            }
            print("IBOARD_SOAK_TAPS", n)
        }
        if phases.contains("delete") || true { deleteScratchNote() }
    }
}
