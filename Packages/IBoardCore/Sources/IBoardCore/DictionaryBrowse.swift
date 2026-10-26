import Foundation

// Pure model behind the app's dictionary manager (M10-03): search/sort over a snapshot, and an overlay that shows
// queued (not yet applied) commands so edits feel immediate even though the keyboard applies them later.

public struct DictionaryEntry: Sendable, Equatable, Identifiable {
    public var id: String { word }
    public var word: String
    public var surface: String?
    public var weight: Double
    public var uses: Int
    /// Pinned = never autocorrect.
    public var neverCorrect: Bool
    /// True while the entry only exists because of a queued command.
    public var pendingAdd = false

    public init(word: String, surface: String? = nil, weight: Double = 0, uses: Int = 0, neverCorrect: Bool = false) {
        self.word = word; self.surface = surface; self.weight = weight; self.uses = uses; self.neverCorrect = neverCorrect
    }

    public var display: String { surface ?? word }
}

public enum DictionarySort: String, CaseIterable, Sendable {
    case weight, alphabetical, uses
}

public enum DictionaryBrowse {
    /// Case- and diacritic-insensitive substring match on the word and its display form; stable ordering.
    public static func filter(_ entries: [DictionaryEntry], query: String, sort: DictionarySort) -> [DictionaryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hits = q.isEmpty ? entries : entries.filter {
            $0.word.range(of: q, options: opts) != nil || ($0.surface?.range(of: q, options: opts) != nil)
        }
        switch sort {
        case .weight: return hits.sorted { ($0.weight, $1.word) > ($1.weight, $0.word) }
        case .uses: return hits.sorted { ($0.uses, $1.word) > ($1.uses, $0.word) }
        case .alphabetical: return hits.sorted { $0.word < $1.word }
        }
    }

    /// Entries as they will look once `pending` commands are applied, in order. Import and whole-model commands
    /// cannot be previewed (their content is not in the queue) and are reported through `unpreviewable`.
    public static func applying(_ pending: [AppCommand], to entries: [DictionaryEntry])
        -> (entries: [DictionaryEntry], unpreviewable: Int) {
        var map = Dictionary(uniqueKeysWithValues: entries.map { ($0.word, $0) })
        var unpreviewable = 0
        for c in pending {
            switch c {
            case let .addWord(w, s):
                if var e = map[w] { if let s { e.surface = s }; map[w] = e }
                else { var e = DictionaryEntry(word: w, surface: s); e.pendingAdd = true; map[w] = e }
            case let .forgetWord(w): map[w] = nil
            case .unforgetWord: break
            case let .setNeverCorrect(w, on):
                if var e = map[w] { e.neverCorrect = on; map[w] = e }
                else if on { var e = DictionaryEntry(word: w, neverCorrect: true); e.pendingAdd = true; map[w] = e }
            case .importDictionary: unpreviewable += 1
            case .clearPersonalData: map = [:]; unpreviewable += 1
            case .resetInsights: break
            }
        }
        return (Array(map.values), unpreviewable)
    }
}
