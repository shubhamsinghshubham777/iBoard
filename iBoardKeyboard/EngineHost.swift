import Foundation
import IBoardCore
import IBoardEngine
import IBoardLayout
import IBoardUI

/// Builds the engine and the personal learner OFF the main thread (M2-04 wiring). Nothing here touches typed text.
///
/// - The lexicon / LM are the bundled files `lexicon.iblex` and `lm.iblm` (a 219-word synthetic CC0 fixture until the
///   real data lands). If they are missing or fail to open the keyboard runs without an engine: no suggestions,
///   but contractions, smart punctuation and personal learning still work. Never crashes, never blocks.
/// - The personal store is extension-local unless Full Access is granted (P-23: shared writes fail without it).
/// - The engine takes its personal snapshot from the same store the learner writes to (`refreshPersonal`), and the
///   learned touch model (F14) from an extension-local file. Both stay in the extension container.
enum EngineHost {
    struct Loaded: Sendable {
        var engine: EngineBridge?
        /// Swipe decoder sharing the lexicon / model with `engine`; reads the personal model per swipe.
        var swipe: SwipeEngine?
        var learner: PersonalLearner
        var store: PersonalStore
        var wordCount: Int
        /// Words in the mmap'd Hinglish secondary lexicon (0 when it is not bundled / failed to open).
        var hinglishWordCount: Int
        var storageMode: PersonalStorageMode
        var touchModel: AdaptiveTouchModel
        var touchStore: AdaptiveTouchFileStore
        var commands: AppCommandApplier
    }

    /// Extension-local state (always writable) and the App Group directory (writable only with Full Access).
    static func localDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("iBoard", isDirectory: true)
    }

    static func appGroupRoot() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SettingsStore.appGroup)
    }

    /// Runs on a background task only (blocking file work).
    static func load(layout: KeyboardLayout, hasFullAccess: Bool) async -> Loaded {
        var actor: EngineActor?
        var lexicon: Lexicon?
        var lm: NGramModel?
        var words = 0
        var secondary: SecondaryLanguage?
        if let lexURL = Bundle.main.url(forResource: "lexicon", withExtension: "iblex"),
           let lex = try? Lexicon(url: lexURL, verifyChecksum: false) {
            secondary = loadHinglish()
            // Checksum verification would fault in every page of a large mmapped lexicon (memory budget); the
            // bundle is code-signed, so integrity is already covered.
            let model = Bundle.main.url(forResource: "lm", withExtension: "iblm")
                .flatMap { try? NGramModel(url: $0, lexicon: lex, verifyChecksum: false) }
            lexicon = lex
            lm = model
            actor = EngineActor(layout: layout, lexicon: lex, model: model, secondary: secondary)
            words = lex.wordCount
        }
        let local = localDirectory()
        let root = appGroupRoot()
        let storage = PersonalStorageFactory.make(
            hasFullAccess: hasFullAccess, localDirectory: local.appendingPathComponent("personal", isDirectory: true),
            appGroupDirectory: root?.appendingPathComponent("personal", isDirectory: true))
        if storage.mode == .appGroup {
            // Full Access was granted after data was collected locally: carry it over once (NOT TESTED).
            let localStorage = FilePersonalStorage(directory: local.appendingPathComponent("personal", isDirectory: true),
                                                   mode: .extensionLocal)
            if (try? storage.readSnapshot()) == nil, (try? storage.readJournal())?.isEmpty ?? true {
                _ = try? PersonalStorageFactory.migrate(from: localStorage, to: storage)
            }
        }
        let store = PersonalStore(storage: storage)
        let learner = PersonalLearner(store: store)
        var swipe: SwipeEngine?
        if let lexicon {
            swipe = SwipeEngine(layout: layout, lexicon: lexicon, model: lm, personal: { await store.scorer() },
                                secondary: secondary)
        }
        // The engine reads the personal model from the store (learned words, phrase chip, never-correct list).
        if let actor { await actor.refreshPersonal(from: store) }
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let touchStore = AdaptiveTouchFileStore(url: local.appendingPathComponent("touch-model.json"))
        let commands = AppCommandApplier(
            store: store, loadQueue: { CommandQueueStore().load() }, applied: DefaultsAppliedSequence(),
            importDirectory: root?.appendingPathComponent(ImportPayloadStore.directoryName, isDirectory: true))
        return Loaded(engine: actor.map { EngineBridge($0, store: store) }, swipe: swipe, learner: learner, store: store,
                      wordCount: words, hinglishWordCount: secondary?.lexicon.wordCount ?? 0, storageMode: storage.mode, touchModel: touchStore.load(), touchStore: touchStore,
                      commands: commands)
    }

    /// Hinglish (romanised Hindi) as the code-switched secondary language: `hinglish/lexicon.iblex` + `lm.iblm`
    /// (docs/HINGLISH.md, ~7 MB). Both are mmap'd (pages fault in on use, checksums skipped like the English files);
    /// opened here, so on the background load task only. Missing or unreadable: English only, no crash.
    static func loadHinglish() -> SecondaryLanguage? {
        guard let lexURL = Bundle.main.url(forResource: "lexicon", withExtension: "iblex", subdirectory: "hinglish"),
              let lex = try? Lexicon(url: lexURL, verifyChecksum: false) else { return nil }
        let model = Bundle.main.url(forResource: "lm", withExtension: "iblm", subdirectory: "hinglish")
            .flatMap { try? NGramModel(url: $0, lexicon: lex, verifyChecksum: false) }
        return SecondaryLanguage(lexicon: lex, model: model)
    }

    /// Insight counters: the keyboard's own copy always, the shared copy for the app only with Full Access (P-23).
    enum Insights {
        static func loadLocal() -> InsightCounters { InsightsStore(defaults: .standard).load() ?? InsightCounters() }
        static func save(_ c: InsightCounters, hasFullAccess: Bool) {
            InsightsStore(defaults: .standard).save(c)
            if hasFullAccess { InsightsStore().save(c) }
        }
    }

    /// With Full Access: writes `shared/dictionary.iboarddict` for the companion app (docs/APP_COMMANDS.md).
    static func writeSharedSnapshot(store: PersonalStore) async {
        guard let dir = appGroupRoot()?.appendingPathComponent("shared", isDirectory: true) else { return }
        await store.compact()
        let data = await store.exportDictionary()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("dictionary.iboarddict"), options: .atomic)
    }
}
