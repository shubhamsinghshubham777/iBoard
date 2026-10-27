import Foundation
import IBoardSync

// Connects the personal model to iCloud sync (M12-03). Pure functions over `PersonalModelState` and `SyncState`, plus
// one async driver for the app. Nothing here is linked from keyboard code paths.
//
// Privacy: counter keys are the typed words (needed to apply other devices' counts). They never leave the device in
// readable form: `SyncEngine` AES-GCM encrypts every shard with a key held in iCloud Keychain before upload, and the
// record names contain only a device id and index.
//
// Counting model. A sync counter is "observations made on one device". The model's `uses` mixes local observations
// with counts folded in from other devices, so the ledger separates them:
//  - `lastSeen[key]`   uses value at the previous export; growth since then is new local observation.
//  - `own[key]`        this device's total contribution (what its sync slot holds).
//  - `appliedRemote[key]` other devices' total already folded into the model (never applied twice).

public struct PersonalSyncLedger: Codable, Sendable, Equatable {
    public var own: [String: UInt64] = [:]
    public var lastSeen: [String: UInt32] = [:]
    public var appliedRemote: [String: UInt64] = [:]
    /// Words whose forget has been exported or applied (so a later local un-forget is not undone by the old floor).
    public var forgetHandled: Set<String> = []
    /// Words this device has put on the sync never-correct list (or adopted from it).
    public var neverSent: Set<String> = []
    public init() {}
}

/// What the app persists between syncs: the device's last `SyncState` plus the ledger.
public struct PersonalSyncMemory: Codable, Sendable, Equatable {
    public var state = SyncState()
    public var ledger = PersonalSyncLedger()
    public init() {}

    public static func load(from url: URL) -> PersonalSyncMemory {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PersonalSyncMemory.self, from: $0) }
            ?? PersonalSyncMemory()
    }

    public func save(to url: URL) {
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

public enum PersonalSyncAdapter {
    static let tables: [(PersonalNGramKind, String)] = [(.unigram, "u:"), (.bigram, "b:"), (.trigram, "t:"), (.phrase, "p:")]
    /// Largest weight a single sync application adds for one key (keeps a long remote history from dominating).
    static let maxApplyIncrement: UInt64 = 20

    static func syncKey(_ prefix: String, _ key: String) -> String? {
        let k = prefix + key
        return k.utf8.count <= SyncState.maxKeyBytes ? k : nil
    }

    static func parse(_ syncKey: String) -> (PersonalNGramKind, String)? {
        for (kind, prefix) in tables where syncKey.hasPrefix(prefix) { return (kind, String(syncKey.dropFirst(prefix.count))) }
        return nil
    }

    static func words(of key: String) -> [String] {
        key.split(separator: PersonalModelState.separator, omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Export (model -> SyncState)

    /// Folds local changes since the last export into `sync`: new observations, forgets, never-correct changes.
    public static func export(state: PersonalModelState, into sync: inout SyncState, ledger: inout PersonalSyncLedger,
                              device: String, nowMs: UInt64) {
        // Forgets first: they also retire this device's n-gram counters that contain the word.
        for w in state.forgotten.keys.sorted() where !ledger.forgetHandled.contains(w) {
            ledger.forgetHandled.insert(w)
            if let k = syncKey("u:", w) { sync.forget(k, device: device, now: nowMs) }
            for k in Array(ledger.own.keys) where k != "u:" + w {
                guard let (_, raw) = parse(k), words(of: raw).contains(w) else { continue }
                sync.forget(k, device: device, now: nowMs)
                ledger.own[k] = nil; ledger.lastSeen[k] = nil; ledger.appliedRemote[k] = nil
            }
            ledger.own["u:" + w] = nil; ledger.lastSeen["u:" + w] = nil; ledger.appliedRemote["u:" + w] = nil
        }

        var present = Set<String>()
        for (kind, prefix) in tables {
            let table: [String: PersonalEntry]
            switch kind {
            case .unigram: table = state.unigrams
            case .bigram: table = state.bigrams
            case .trigram: table = state.trigrams
            case .phrase: table = state.phrases
            }
            for (key, entry) in table {
                guard let k = syncKey(prefix, key) else { continue }
                present.insert(k)
                let uses = UInt32(entry.uses)
                let delta = Int64(uses) - Int64(ledger.lastSeen[k] ?? 0)
                ledger.lastSeen[k] = uses
                if delta > 0 {
                    sync.increment(k, by: UInt64(delta), device: device, now: nowMs)
                    ledger.own[k, default: 0] += UInt64(delta)
                }
            }
        }
        // Keys pruned from the model restart from zero if they come back; own/appliedRemote stay (monotonic).
        for k in Array(ledger.lastSeen.keys) where !present.contains(k) { ledger.lastSeen[k] = nil }

        for w in state.neverCorrect.sorted() where !ledger.neverSent.contains(w) {
            sync.setNeverCorrect(w, present: true, device: device, now: nowMs)
            ledger.neverSent.insert(w)
        }
        for w in ledger.neverSent.sorted() where !state.neverCorrect.contains(w) {
            sync.setNeverCorrect(w, present: false, device: device, now: nowMs)
            ledger.neverSent.remove(w)
        }
    }

    // MARK: Apply (merged SyncState -> model ops)

    /// Plans the model mutations that bring `state` up to `merged`. Updates `ledger` for what the ops will apply.
    /// `appliedKeys` receives the sync keys touched so the caller can refresh `lastSeen` after applying.
    public static func plan(merged: SyncState, state: PersonalModelState, ledger: inout PersonalSyncLedger,
                            nowSeconds: Double, appliedKeys: inout Set<String>) -> [PersonalOp] {
        var ops: [PersonalOp] = []

        // Forgets made on other devices.
        for (k, _) in merged.forgetFloors.sorted(by: { $0.key < $1.key }) where k.hasPrefix("u:") {
            let w = String(k.dropFirst(2))
            guard merged.count(k) == 0, !ledger.forgetHandled.contains(w) else { continue }
            ledger.forgetHandled.insert(w)
            if state.forgotten[w] == nil { ops.append(.forget(word: w, at: nowSeconds)) }
        }
        var forgottenNow = Set(state.forgotten.keys)
        for case let .forget(word, _) in ops { forgottenNow.insert(word) }

        for k in merged.liveKeys {
            guard let (kind, raw) = parse(k) else { continue }
            let ws = words(of: raw)
            // Never resurrect something forgotten (locally or by another device) via an n-gram.
            if ws.contains(where: { forgottenNow.contains($0) && merged.count("u:" + $0) == 0 }) { continue }
            let own = ledger.own[k] ?? 0
            let total = merged.count(k)
            let remote = total > own ? total - own : 0
            let applied = ledger.appliedRemote[k] ?? 0
            if remote > applied {
                let inc = Float(min(remote - applied, maxApplyIncrement))
                ops.append(.add(kind: kind, key: raw, increment: inc, surface: nil, at: nowSeconds))
                appliedKeys.insert(k)
            }
            if remote != applied { ledger.appliedRemote[k] = remote }
        }

        // Never-correct list: adopt remote additions, honour remote removals of words this device had shared.
        for (w, flag) in merged.neverCorrect.sorted(by: { $0.key < $1.key }) {
            if flag.present, !state.neverCorrect.contains(w) {
                ops.append(.addNeverCorrect(word: w)); ledger.neverSent.insert(w)
            } else if !flag.present, state.neverCorrect.contains(w), ledger.neverSent.contains(w) {
                ops.append(.removeNeverCorrect(word: w)); ledger.neverSent.remove(w)
            }
        }
        return ops
    }

    // MARK: Driver

    public struct Result: Sendable {
        public var outcome: SyncOutcome
        public var memory: PersonalSyncMemory
        public var appliedOps: Int
    }

    /// One full cycle: export local changes, run the engine (download, merge, upload), apply the merged result to the
    /// store. `memory` is persisted by the caller (only when `outcome.uploaded`, i.e. the cycle completed).
    public static func run(store: PersonalStore, engine: SyncEngine, memory: PersonalSyncMemory,
                           nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) async -> Result {
        var mem = memory
        let device = engine.deviceID
        let snapshot = await store.exportState()
        export(state: snapshot, into: &mem.state, ledger: &mem.ledger, device: device, nowMs: nowMs)
        let outcome = await engine.sync(local: mem.state)
        guard outcome.uploaded else { return Result(outcome: outcome, memory: memory, appliedOps: 0) }

        var ledger = mem.ledger
        var touched = Set<String>()
        let current = await store.exportState()
        let ops = plan(merged: outcome.merged, state: current, ledger: &ledger, nowSeconds: Double(nowMs) / 1000,
                       appliedKeys: &touched)
        if !ops.isEmpty { await store.apply(ops: ops) }
        // Observations folded in from other devices must not look like local learning at the next export.
        let after = await store.exportState()
        for k in touched {
            guard let (kind, raw) = parse(k) else { continue }
            let uses = after.entry(kind, raw)?.uses ?? 0
            ledger.lastSeen[k] = UInt32(uses)
        }
        return Result(outcome: outcome, memory: PersonalSyncMemory(state: outcome.merged, ledger: ledger),
                      appliedOps: ops.count)
    }
}

extension PersonalSyncMemory {
    init(state: SyncState, ledger: PersonalSyncLedger) { self.init(); self.state = state; self.ledger = ledger }
}
