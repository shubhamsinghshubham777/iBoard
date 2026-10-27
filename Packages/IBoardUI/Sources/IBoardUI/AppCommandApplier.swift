import Foundation
import IBoardCore
import IBoardEngine

// Applies the app's queued commands (docs/APP_COMMANDS.md) to the personal model, in the keyboard extension.
// The app is the single writer of the queue; the keyboard remembers the last applied sequence number in its OWN
// container (it cannot write the App Group without Full Access, P-23). Commands are idempotent, so a crash between
// applying and remembering is harmless. Words in commands are the user's own dictionary entries; they are never
// logged, only counted.

/// Where the keyboard remembers `lastAppliedSeq`.
public protocol AppliedSequenceStore: Sendable {
    func load() -> Int
    func save(_ seq: Int)
}

public struct DefaultsAppliedSequence: AppliedSequenceStore, @unchecked Sendable {
    public static let key = "iboard.local.commands.lastApplied"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> Int { defaults.integer(forKey: Self.key) }
    public func save(_ seq: Int) { defaults.set(seq, forKey: Self.key) }
}

public struct AppCommandReport: Sendable, Equatable {
    public var applied = 0
    /// Commands that could not run (unreadable import file, invalid dictionary).
    public var failed = 0
    public var resetInsights = false
    public var clearedPersonalData = false
    public var importedFiles = 0
    public var isEmpty: Bool { applied == 0 && failed == 0 }
}

public struct AppCommandApplier: Sendable {
    public let store: PersonalStore
    private let loadQueue: @Sendable () -> CommandQueue
    private let applied: any AppliedSequenceStore
    private let importDirectory: URL?
    /// Boost of a word the user added by hand: a deliberate entry, like a retyped autocorrection.
    public static let addWordIncrement: Float = 3

    public init(store: PersonalStore, loadQueue: @escaping @Sendable () -> CommandQueue,
                applied: any AppliedSequenceStore, importDirectory: URL?) {
        self.store = store
        self.loadQueue = loadQueue
        self.applied = applied
        self.importDirectory = importDirectory
    }

    /// Applies every command newer than the stored sequence, oldest first, then stores the new sequence.
    public func applyPending() async -> AppCommandReport {
        var report = AppCommandReport()
        let queue = loadQueue()
        var last = applied.load()
        // The queue was recreated (app reinstalled): its numbering restarted below what we have applied.
        if queue.nextSeq <= last { last = 0 }
        let pending = queue.pending(after: last)
        guard !pending.isEmpty else {
            if last != applied.load() { applied.save(last) }
            return report
        }
        for env in pending {
            switch env.command {
            case let .addWord(word, surface):
                if await store.isForgotten(word) { await store.unforget(word) }
                await store.learn(word: word, surface: surface, increment: Self.addWordIncrement)
            case let .forgetWord(word): await store.forget(word)
            case let .unforgetWord(word): await store.unforget(word)
            case let .setNeverCorrect(word, enabled):
                if enabled { await store.addNeverCorrect(word) } else { await store.removeNeverCorrect(word) }
            case let .importDictionary(fileName, replace):
                if await importFile(named: fileName, replace: replace) { report.importedFiles += 1 } else { report.failed += 1 }
            case .resetInsights: report.resetInsights = true
            case .clearPersonalData:
                await store.reset()
                report.clearedPersonalData = true
            }
            report.applied += 1
            last = max(last, env.seq)
        }
        applied.save(last)
        return report
    }

    private func importFile(named name: String, replace: Bool) async -> Bool {
        guard ImportPayloadStore.isValidFileName(name), let dir = importDirectory,
              let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return false }
        return (try? await store.importDictionary(data, options: DictionaryImportOptions(replaceExisting: replace))) != nil
    }
}
