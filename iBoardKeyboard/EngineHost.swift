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
enum EngineHost {
    struct Loaded: Sendable {
        var engine: EngineBridge?
        /// Swipe decoder sharing the lexicon / model with `engine`; reads the personal model per swipe.
        var swipe: SwipeEngine?
        var learner: PersonalLearner
        var wordCount: Int
        var storageMode: PersonalStorageMode
    }

    /// Blocking: call from a background task only.
    static func load(layout: KeyboardLayout, hasFullAccess: Bool) -> Loaded {
        var bridge: EngineBridge?
        var lexicon: Lexicon?
        var lm: NGramModel?
        var words = 0
        if let lexURL = Bundle.main.url(forResource: "lexicon", withExtension: "iblex"),
           let lex = try? Lexicon(url: lexURL, verifyChecksum: false) {
            // Checksum verification would fault in every page of a large mmapped lexicon (memory budget); the
            // bundle is code-signed, so integrity is already covered.
            let model = Bundle.main.url(forResource: "lm", withExtension: "iblm")
                .flatMap { try? NGramModel(url: $0, lexicon: lex, verifyChecksum: false) }
            lexicon = lex
            lm = model
            bridge = EngineBridge(EngineActor(layout: layout, lexicon: lex, model: model))
            words = lex.wordCount
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let local = support.appendingPathComponent("iBoard/personal", isDirectory: true)
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SettingsStore.appGroup)?
            .appendingPathComponent("personal", isDirectory: true)
        let storage = PersonalStorageFactory.make(hasFullAccess: hasFullAccess, localDirectory: local, appGroupDirectory: group)
        if storage.mode == .appGroup {
            // Full Access was granted after data was collected locally: carry it over once (NOT TESTED).
            let localStorage = FilePersonalStorage(directory: local, mode: .extensionLocal)
            if (try? storage.readSnapshot()) == nil, (try? storage.readJournal())?.isEmpty ?? true {
                _ = try? PersonalStorageFactory.migrate(from: localStorage, to: storage)
            }
        }
        let store = PersonalStore(storage: storage)
        let learner = PersonalLearner(store: store)
        var swipe: SwipeEngine?
        if let lexicon {
            swipe = SwipeEngine(layout: layout, lexicon: lexicon, model: lm, personal: { await store.scorer() })
        }
        return Loaded(engine: bridge, swipe: swipe, learner: learner, wordCount: words, storageMode: storage.mode)
    }
}
