import Foundation

// M3-05 UILexicon import (engine side). The keyboard's `UIInputViewController.requestSupplementaryLexicon` returns
// entries for the user's Text Replacements (userInput != documentText) and for contact names (userInput ==
// documentText). The engine never imports UIKit: the keyboard adapts `UILexicon` to `SystemLexiconSource`.
// Nothing here reads or stores typed text; entries come from the system lexicon only.

public struct SystemLexiconEntry: Sendable, Hashable, Codable {
    /// What the user types (the shortcut for a replacement; the name itself for a contact).
    public var userInput: String
    /// What gets inserted.
    public var documentText: String
    public init(userInput: String, documentText: String) {
        self.userInput = userInput
        self.documentText = documentText
    }
}

/// Seam for `UILexicon` (and for tests).
public protocol SystemLexiconSource: Sendable {
    func entries() async -> [SystemLexiconEntry]
}

/// Immutable, classified view of the system lexicon.
public struct SystemLexiconSnapshot: Sendable, Equatable {
    /// Lowercased shortcut -> expansion (first entry wins on a duplicate shortcut).
    public private(set) var replacements: [String: String]
    /// Contact / proper names, display casing preserved, sorted case-insensitively.
    public private(set) var names: [String]
    /// Order-independent, process-stable digest of the input entries (FNV-1a, not `Hasher`).
    public let fingerprint: UInt64

    public static let empty = SystemLexiconSnapshot(entries: [])

    /// Caps keep memory bounded for very large address books.
    public static let maxNames = 5000
    public static let maxReplacements = 2000

    public init(entries: [SystemLexiconEntry]) {
        var reps: [String: String] = [:]
        var nameSet: [String: String] = [:]   // lowercased -> display
        var digest: UInt64 = 0
        for e in entries {
            let input = e.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = e.documentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, !text.isEmpty else { continue }
            digest &+= Self.fnv(input + "\u{1F}" + text)   // sum of per-entry hashes: order independent
            if input.lowercased() == text.lowercased() {
                // Names: a single token (multi-word contact names are split by the system already). Skip digits-only.
                guard !input.contains(where: \.isWhitespace), input.contains(where: \.isLetter) else { continue }
                let key = input.lowercased()
                if nameSet[key] == nil { nameSet[key] = text }
            } else {
                let key = input.lowercased()
                if reps[key] == nil { reps[key] = text }
            }
        }
        replacements = reps.count > Self.maxReplacements
            ? Dictionary(uniqueKeysWithValues: reps.sorted { $0.key < $1.key }.prefix(Self.maxReplacements).map { ($0.key, $0.value) })
            : reps
        names = Array(nameSet.values.sorted { $0.lowercased() < $1.lowercased() }.prefix(Self.maxNames))
        fingerprint = digest
    }

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    /// Expansion for the word just typed (exact match on the lowercased shortcut), nil if none.
    public func expansion(for typed: String) -> String? { replacements[typed.lowercased()] }

    /// Names starting with `prefix` (case-insensitive), alphabetical, at most `limit`.
    public func names(withPrefix prefix: String, limit: Int = 5) -> [String] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        var out: [String] = []
        for n in names where n.lowercased().hasPrefix(p) && n.lowercased() != p {
            out.append(n)
            if out.count == limit { break }
        }
        return out
    }

    public func isKnownName(_ word: String) -> Bool {
        let w = word.lowercased()
        return names.contains { $0.lowercased() == w }
    }
}

public struct SystemLexiconRefresh: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case unchanged, updated }
    public var outcome: Outcome
    public var namesAdded: Int
    public var namesRemoved: Int
    public var replacementsTotal: Int
    public var fingerprint: UInt64
}

/// Holds the current snapshot and refreshes it cheaply: the entries are digested first and nothing else is rebuilt or
/// written when the digest matches the previous one (the common case for every keyboard launch).
/// Persist `fingerprint` (an integer, no content) if you want the check to survive process restarts; the snapshot itself
/// is cheap to rebuild from the system lexicon, so it is not persisted.
public actor SystemLexiconImporter {
    private let source: any SystemLexiconSource
    private let store: PersonalStore?
    private var snapshot: SystemLexiconSnapshot
    private var seededFingerprint: UInt64?
    private var loaded = false

    /// - store: when given, newly seen contact names are seeded once into the personal model (`seedIncrement`) so
    ///   they are offered and not autocorrected away. Replacements are never written to the store.
    public init(source: any SystemLexiconSource, store: PersonalStore? = nil, previousFingerprint: UInt64? = nil) {
        self.source = source
        self.store = store
        self.snapshot = .empty
        self.seededFingerprint = previousFingerprint
    }

    public var current: SystemLexiconSnapshot { snapshot }
    public static let seedIncrement: Float = 2

    @discardableResult
    public func refresh() async -> SystemLexiconRefresh {
        let next = SystemLexiconSnapshot(entries: await source.entries())
        if loaded, next.fingerprint == snapshot.fingerprint {
            return SystemLexiconRefresh(outcome: .unchanged, namesAdded: 0, namesRemoved: 0,
                                        replacementsTotal: snapshot.replacements.count, fingerprint: snapshot.fingerprint)
        }
        let old = Set(snapshot.names.map { $0.lowercased() })
        let new = Set(next.names.map { $0.lowercased() })
        let added = next.names.filter { !old.contains($0.lowercased()) }
        // Seed only when the persisted fingerprint differs: an unchanged address book across launches costs nothing.
        if let store, seededFingerprint != next.fingerprint {
            for n in added { await store.learn(word: n, surface: n, increment: Self.seedIncrement) }
        }
        let removed = old.subtracting(new).count
        snapshot = next
        loaded = true
        seededFingerprint = next.fingerprint
        return SystemLexiconRefresh(outcome: .updated, namesAdded: added.count, namesRemoved: removed,
                                    replacementsTotal: next.replacements.count, fingerprint: next.fingerprint)
    }
}
