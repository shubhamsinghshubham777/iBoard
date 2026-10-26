import Foundation

/// How readily a proposal is applied. Posterior thresholds on `AutocorrectProposal.confidence`.
public enum AutocorrectAggressiveness: Sendable, Equatable {
    case conservative, balanced, assertive

    public var threshold: Double {
        switch self {
        case .conservative: return 0.97
        case .balanced: return 0.90
        case .assertive: return 0.80
        }
    }
}

public struct AutocorrectSettings: Sendable, Equatable {
    public var aggressiveness = AutocorrectAggressiveness.conservative
    /// Words shorter than this are never auto-corrected.
    public var minLength = 2
    /// Minimum confidence when the typed literal is itself a valid word.
    public var knownWordThreshold = 0.995
    /// Backspace restores the original only within this many seconds of the correction.
    public var restoreWindow: TimeInterval = 30
    /// Restores of the same word before it goes on the never-correct list.
    public var neverCorrectAfter = 2

    public init() {}
}

public struct AutocorrectTraits: Sendable, Equatable {
    /// `.no` means suggestions only: nothing is replaced automatically.
    public var autocorrection: TraitSwitch
    /// `.no` also disables automatic replacement (we only auto-replace misspellings).
    public var spellChecking: TraitSwitch

    public init(autocorrection: TraitSwitch = .default, spellChecking: TraitSwitch = .default) {
        self.autocorrection = autocorrection
        self.spellChecking = spellChecking
    }
}

public enum AutocorrectDecision: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case disabledByTraits, noProposal, tooShort, nonLetters, neverCorrectList, lowConfidence
    }
    /// Leave the typed word as is (the strip still offers the proposal as a suggestion).
    case keepLiteral(Reason)
    case correct(to: String, confidence: Double)
}

/// A correction that was just applied, kept so backspace can undo it.
public struct AppliedCorrection: Sendable, Equatable {
    public var original: String
    public var corrected: String
    /// Separator typed together with the correction (space or punctuation); the restore removes it.
    public var trailing: String
    public var time: TimeInterval
}

/// Mutable part of the policy: pending-restore tracking and the never-correct list. Pure value type; the clock is
/// an argument (`now`), so tests use fake times. Memory only: the never-correct words are typed text, so
/// persisting them is a decision for the personal-model work (opt-in), not made here.
public struct AutocorrectState: Sendable, Equatable {
    public private(set) var lastCorrection: AppliedCorrection?
    public private(set) var neverCorrect: Set<String>
    public private(set) var restoreCounts: [String: Int] = [:]

    public init(neverCorrect: Set<String> = []) { self.neverCorrect = neverCorrect }

    public mutating func recordApplied(original: String, corrected: String, trailing: String, at now: TimeInterval) {
        lastCorrection = AppliedCorrection(original: original, corrected: corrected, trailing: trailing, time: now)
    }

    /// Any input other than backspace after a correction ends the restore opportunity.
    public mutating func noteOtherInput() { lastCorrection = nil }

    /// Backspace: if it directly follows a correction (and within the window), returns the edit that restores the
    /// original (delete the corrected word plus separator, insert the original) and counts the restore.
    /// Lengths are in Characters (grapheme clusters), as `deleteBackward` removes.
    public mutating func backspace(at now: TimeInterval, settings: AutocorrectSettings = AutocorrectSettings()) -> TextEdit? {
        defer { lastCorrection = nil }
        guard let c = lastCorrection, now - c.time <= settings.restoreWindow else { return nil }
        countRestore(c.original, settings)
        return TextEdit(deleteBackward: (c.corrected + c.trailing).count, insert: c.original)
    }

    /// The user tapped the quoted literal slot instead of accepting a correction: same signal as a restore.
    public mutating func userChoseLiteral(_ word: String, settings: AutocorrectSettings = AutocorrectSettings()) {
        countRestore(word, settings)
    }

    private mutating func countRestore(_ word: String, _ settings: AutocorrectSettings) {
        let key = word.lowercased()
        let n = (restoreCounts[key] ?? 0) + 1
        restoreCounts[key] = n
        if n >= settings.neverCorrectAfter { neverCorrect.insert(key) }
    }

    public mutating func allowAgain(_ word: String) {
        neverCorrect.remove(word.lowercased())
        restoreCounts[word.lowercased()] = nil
    }
}

public enum AutocorrectPolicy {
    /// Decide whether to replace `literal` by the engine's proposal when the word is committed.
    /// The strip always offers the literal regardless of the decision (D-12).
    public static func decide(literal: String, proposal: AutocorrectProposal?, traits: AutocorrectTraits,
                              settings: AutocorrectSettings = AutocorrectSettings(),
                              state: AutocorrectState) -> AutocorrectDecision {
        guard traits.autocorrection.isEnabled, traits.spellChecking.isEnabled else { return .keepLiteral(.disabledByTraits) }
        guard let p = proposal else { return .keepLiteral(.noProposal) }
        guard literal.count >= settings.minLength else { return .keepLiteral(.tooShort) }
        guard literal.allSatisfy({ $0.isLetter }) else { return .keepLiteral(.nonLetters) }
        if state.neverCorrect.contains(literal.lowercased()) { return .keepLiteral(.neverCorrectList) }
        let needed = p.literalIsWord ? max(settings.aggressiveness.threshold, settings.knownWordThreshold)
                                     : settings.aggressiveness.threshold
        guard p.confidence >= needed else { return .keepLiteral(.lowConfidence) }
        return .correct(to: p.word, confidence: p.confidence)
    }
}
