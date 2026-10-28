#if DEBUG
import UIKit
import IBoardCore
import IBoardLayout
import IBoardUI

/// DEBUG-only touch recorder (M1-04 hunt). Keeps the last ~400 touch / machine events in memory and flushes them
/// to `Library/Caches/touchlog.json` in the App Group container about once a second and on disappear.
/// Privacy: records key INDEX and KIND only, never a character; compiled out of Release.
@MainActor
final class TouchRecorder {
    private var ring = TouchLogRing(capacity: 400)
    private var dirty = false
    private var timer: Timer?
    private var header = (w: 0.0, h: 0.0, globe: false, delay: 0.45)
    private var lastTS = 0.0

    func configure(container: CGSize, globe: Bool, longPressDelay: TimeInterval) {
        header = (Double(container.width), Double(container.height), globe, longPressDelay)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    func touch(_ phase: KeyTouchPhase, id: Int, point: CGPoint, time: TimeInterval, layout: KeyboardLayout?) {
        let hit = layout?.hit(at: point) ?? layout?.nearestHit(to: point)
        let ki = hit?.keyIndex ?? -1
        var identity: KeyIdentity?
        if let layout, ki >= 0, ki < layout.keys.count { identity = layout.keys[ki].identity }
        let name: String
        switch phase {
        case .began: name = "began"
        case .moved: name = "moved"
        case .ended: name = "ended"
        case .cancelled: name = "cancelled"
        }
        lastTS = time
        append(TouchLogRecord(type: name, id: id, ts: time, x: point.x, y: point.y, ki: ki,
                              kind: TouchLogRecord.kind(of: identity), lagMs: (CACurrentMediaTime() - time) * 1000))
    }

    func event(_ type: String, ki: Int = -1, n: Int = 0, layout: KeyboardLayout? = nil) {
        var kind = "none"
        if let layout, ki >= 0, ki < layout.keys.count { kind = TouchLogRecord.kind(of: layout.keys[ki].identity) }
        append(TouchLogRecord(type: type, ts: lastTS, ki: ki, kind: kind, n: n,
                              lagMs: (CACurrentMediaTime() - lastTS) * 1000))
    }

    private func append(_ r: TouchLogRecord) { ring.append(r); dirty = true }

    func flush() {
        guard dirty, let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SettingsStore.appGroup)
        else { return }
        dirty = false
        let file = TouchLogFile(containerWidth: header.w, containerHeight: header.h, needsGlobe: header.globe,
                                longPressDelay: header.delay, records: ring.ordered)
        let url = dir.appendingPathComponent("Library/Caches/touchlog.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: .atomic) }
    }
}
#endif
