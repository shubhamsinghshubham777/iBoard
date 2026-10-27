#if DEBUG || IBOARD_PERF
import UIKit
import IBoardCore

/// Privacy-safe device metrics hook (M1-09 / M13-02). Compiled only for DEBUG or `-DIBOARD_PERF` builds.
/// Samples `phys_footprint` and the Perf p50/p95 summaries and writes counts/numbers only (never text) to
/// `Library/Caches/perf/perf-<processStart>.json` (one file per keyboard process) in the extension's data container, which `devicectl` can copy off.
/// Read with: `devicectl device copy from --domain-type appDataContainer --domain-identifier app.iBoard.keyboard
///   --source Library/Caches/perf` (or `scripts/device-perf.sh pull`).
@MainActor
enum PerfMetricsHook {
    private static var timer: Timer?
    private static var samples: [[Double]] = []   // [unixSeconds, footprintMB]
    private static var peakMB = 0.0
    private static var appearCount = 0
    private static var warnings = 0
    private static var firstSample = Date()

    /// Call once from `viewDidLoad`.
    static func start() {
        guard timer == nil else { return }
        firstSample = Date()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { sample(); if samples.count % 4 == 0 { write() } }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { warnings += 1; sample(); write() }
        }
    }

    static func noteAppear() { appearCount += 1; sample(); write() }

    private static func sample() {
        let mb = Perf.memoryFootprintMB()
        peakMB = max(peakMB, mb)
        samples.append([Date().timeIntervalSince1970, (mb * 100).rounded() / 100])
        if samples.count > 1200 { samples.removeFirst(samples.count - 1200) }
    }

    private static func write() {
        var metrics: [String: [String: Double]] = [:]
        for s in Perf.summaries() where s.count > 0 {
            metrics[s.metric.label] = ["count": Double(s.count), "p50ms": s.p50Milliseconds ?? 0, "p95ms": s.p95Milliseconds ?? 0]
        }
        let obj: [String: Any] = [
            "processStart": firstSample.timeIntervalSince1970, "peakMB": peakMB, "currentMB": Perf.memoryFootprintMB(),
            "appearCount": appearCount, "memoryWarnings": warnings, "metrics": metrics, "samples": samples,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        // One file per keyboard process (iOS restarts the extension often), newest 12 kept, so a long run is not overwritten.
        let dir = caches.appendingPathComponent("perf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("perf-\(Int(firstSample.timeIntervalSince1970)).json"), options: .atomic)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("perf-") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
           files.count > 12 {
            for f in files.dropLast(12) { try? FileManager.default.removeItem(at: f) }
        }
    }
}
#endif
