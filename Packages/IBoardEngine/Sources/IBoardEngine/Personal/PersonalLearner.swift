import Foundation

/// How a word got into the text.
public enum CommitSource: Sendable, Equatable {
    /// Typed letter by letter and left as typed.
    case typed
    /// A suggestion / completion chip was tapped.
    case suggestionTapped
    /// Autocorrect replaced what the user typed.
    case autocorrected
    /// Swipe typing.
    case swipe
}

/// Turns keyboard events into personal-store writes under the F4 / D-10 / F15 policy.
///
/// Event contract for the keyboard controller (integration NOT TESTED here, only the unit behaviour):
/// - `fieldDidChange(_:)` on every text-input change / appearance, before any word event. Until the first call the
///   learner fails closed and learns nothing.
/// - `wordCommitted(_:source:)` when a word is committed (space, punctuation, suggestion, swipe).
/// - `typingContinued()` when the user inserts the first character after a commit (anything but backspace). A word is
///   "kept" at that point: committed and neither corrected away nor reopened by backspace. This is what makes a word
///   typed once show up on the next prefix.
/// - `lastWordReopened()` when backspace deletes back into the last committed word; `autocorrectReverted(original:)`
///   when backspace restores the pre-autocorrect text.
/// - `sentenceBoundary()` at . ! ? or newline; `flush()` on idle / app background.
///
/// Privacy: words are held only transiently (current sentence, at most `sentenceWindow` words, in memory) and written
/// only to `PersonalStore`. Nothing is logged. While incognito or in an excluded field nothing reaches the store and
/// pending words are discarded, not deferred.
///
/// Reentrancy: all tracker state changes happen synchronously before an `await`; store writes are queued as jobs that
/// were legitimate when created. Switching incognito ON bumps an epoch that cancels jobs still in flight.
public actor PersonalLearner {
    public let store: PersonalStore
    private let clock: any PersonalClock
    private let config: LearningConfig

    public private(set) var incognito = IncognitoState()
    private var traits: FieldTraits?          // nil until the first fieldDidChange: fail closed
    private var epoch = 0

    private enum State { case pending, promoted, barrier }
    private struct Item {
        var word: String
        var surface: String?
        var state: State
        var deliberate: Bool
        var restored: Bool
        var source: CommitSource
    }
    private struct Job {
        var word: String
        var surface: String?
        var context: [String]
        var phraseContext: [String]
        var deliberate: Bool
        var restored: Bool
        var epoch: Int
    }

    private var items: [Item] = []
    private var nextStartsSentence = true

    public init(store: PersonalStore, clock: any PersonalClock = SystemPersonalClock(),
                config: LearningConfig = LearningConfig()) {
        self.store = store
        self.clock = clock
        self.config = config
    }

    /// True when words would currently be learned.
    public var isLearning: Bool { traits != nil && !incognito.isActive }

    // MARK: Incognito and field

    public func setIncognito(_ on: Bool) {
        let wasActive = incognito.isActive
        incognito.setUserToggle(on)
        if on {
            epoch += 1
            discardTracking()
        } else if !wasActive {
            // nothing to do
        }
    }

    public func fieldDidChange(_ newTraits: FieldTraits) async {
        // Words kept in the previous field are legitimate: queue them first.
        let jobs = isLearning ? promoteAll() : []
        discardTracking()
        traits = newTraits
        incognito.fieldChanged(newTraits)
        await apply(jobs)
    }

    // MARK: Word events

    public func wordCommitted(_ raw: String, source: CommitSource) async {
        guard isLearning else { discardTracking(); return }
        let jobs = promoteAll()
        append(raw, source: source, deliberate: source == .typed, restored: false)
        await apply(jobs)
    }

    public func typingContinued() async {
        guard isLearning else { return }
        await apply(promoteAll())
    }

    public func lastWordReopened() {
        guard let last = items.last, last.state != .promoted else { return }
        items.removeLast()
    }

    /// The user backspaced an autocorrection and restored `original`: the corrected word is dropped (never learned),
    /// the original becomes a deliberate pending word with a stronger increment.
    public func autocorrectReverted(original: String) {
        guard isLearning else { discardTracking(); return }
        if let last = items.last, last.source == .autocorrected, last.state != .promoted { items.removeLast() }
        append(original, source: .typed, deliberate: true, restored: true)
    }

    public func sentenceBoundary() async {
        guard isLearning else { discardTracking(); return }
        let jobs = promoteAll()
        items.removeAll()
        nextStartsSentence = true
        await apply(jobs)
    }

    public func flush() async {
        guard isLearning else { discardTracking(); return }
        await apply(promoteAll())
    }

    /// "Forget" from the strip: removes the word from the personal model and drops it from the current sentence.
    public func forgetSuggestion(_ word: String) async {
        let w = PersonalStore.normalize(word)
        for i in items.indices where items[i].word == w { items[i].state = .barrier }
        await store.forget(w)
    }

    // MARK: Internals

    private func discardTracking() {
        items.removeAll()
        nextStartsSentence = true
    }

    private func append(_ raw: String, source: CommitSource, deliberate: Bool, restored: Bool) {
        let w = PersonalStore.normalize(raw)
        let rejected = LearnableWord.rejection(raw) != nil
        var surface: String?
        if !rejected, raw != w {
            let upperBeyondFirst = raw.dropFirst().contains(where: { $0.isUppercase })
            if upperBeyondFirst || !nextStartsSentence { surface = raw }
        }
        items.append(Item(word: w, surface: surface, state: rejected ? .barrier : .pending,
                          deliberate: deliberate, restored: restored, source: source))
        nextStartsSentence = false
        if items.count > config.sentenceWindow { items.removeFirst(items.count - config.sentenceWindow) }
    }

    /// Marks every pending item promoted and returns the store jobs. Synchronous.
    private func promoteAll() -> [Job] {
        var jobs: [Job] = []
        for i in items.indices where items[i].state == .pending {
            var chain: [String] = []
            var j = i - 1
            while j >= 0, items[j].state != .barrier, chain.count < 5 {
                chain.insert(items[j].word, at: 0)
                j -= 1
            }
            let it = items[i]
            jobs.append(Job(word: it.word, surface: it.surface, context: Array(chain.suffix(2)), phraseContext: chain,
                            deliberate: it.deliberate, restored: it.restored, epoch: epoch))
            items[i].state = .promoted
        }
        return jobs
    }

    private func apply(_ jobs: [Job]) async {
        for job in jobs {
            guard job.epoch == epoch else { continue }   // incognito was switched on meanwhile
            let now = clock.now()
            if let f = await store.forgetEntry(for: job.word) {
                let expired = now - f.at >= config.forgetWindowDays * 86_400
                if !expired {
                    guard job.deliberate else { continue }
                    if Int(f.deliberate) + 1 < config.deliberateRetypesToOverrideForget {
                        await store.noteDeliberateRetypeOfForgotten(job.word)
                        continue
                    }
                }
                await store.unforget(job.word)
            }
            guard job.epoch == epoch else { continue }
            let uses = await store.uses(of: job.word)
            var inc = config.increment(forPriorUses: uses)
            if job.restored { inc = max(inc, config.restoredOriginalIncrement) }
            guard job.epoch == epoch else { continue }
            await store.learn(word: job.word, surface: job.surface, context: job.context, increment: inc,
                              phraseContext: job.phraseContext)
        }
    }
}
