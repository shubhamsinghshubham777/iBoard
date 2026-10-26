import Foundation

// App -> keyboard command queue (M3-07, M10-03). The personal store lives in the keyboard; the app cannot edit it
// directly, so it appends idempotent commands that the keyboard applies later and acknowledges by remembering the
// highest applied `seq` in its own container (it cannot write the App Group without Full Access, P-23).
// Pure value types here; see docs/APP_COMMANDS.md. Commands carry words the user typed into the app's own
// dictionary editor (never captured keystrokes); the queue is plain data and is never logged.

public enum CommandWord {
    public static let maxLength = 64

    /// Lowercased, trimmed word or nil when unusable (empty, too long, whitespace/control characters inside).
    public static func normalize(_ raw: String) -> String? {
        let w = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, w.count <= maxLength else { return nil }
        for s in w.unicodeScalars where CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.controlCharacters.contains(s) {
            return nil
        }
        return w
    }

    /// Display casing is kept only when it lowercases to the word.
    public static func normalizeSurface(_ raw: String?, for word: String) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              s.count <= maxLength, s.lowercased() == word else { return nil }
        return s
    }
}

public enum AppCommand: Sendable, Equatable {
    /// Add (or boost) a word in the personal dictionary. `surface` is an optional display casing.
    case addWord(word: String, surface: String?)
    /// Forget a word: removed and blocked from being relearned until un-forgotten.
    case forgetWord(word: String)
    case unforgetWord(word: String)
    /// Pin = never autocorrect this word (the engine's never-correct list).
    case setNeverCorrect(word: String, enabled: Bool)
    /// Merge an import file the app copied into the App Group (`ImportPayloadStore`), by file name.
    case importDictionary(fileName: String, replaceExisting: Bool)
    case resetInsights
    /// Wipe the whole personal model.
    case clearPersonalData

    /// Validated builders; nil when the word is unusable.
    public static func makeAddWord(_ raw: String, surface: String? = nil) -> AppCommand? {
        guard let w = CommandWord.normalize(raw) else { return nil }
        return .addWord(word: w, surface: CommandWord.normalizeSurface(surface, for: w))
    }
    public static func makeForget(_ raw: String) -> AppCommand? {
        CommandWord.normalize(raw).map { .forgetWord(word: $0) }
    }
    public static func makeUnforget(_ raw: String) -> AppCommand? {
        CommandWord.normalize(raw).map { .unforgetWord(word: $0) }
    }
    public static func makeNeverCorrect(_ raw: String, enabled: Bool) -> AppCommand? {
        CommandWord.normalize(raw).map { .setNeverCorrect(word: $0, enabled: enabled) }
    }
}

extension AppCommand: Codable {
    private enum K: String, CodingKey { case type, word, surface, enabled, fileName, replace }
    private enum T: String { case addWord, forgetWord, unforgetWord, neverCorrect, importDictionary, resetInsights, clearPersonalData }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let raw = try c.decode(String.self, forKey: .type)
        guard let t = T(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown command")
        }
        func word() throws -> String {
            guard let w = CommandWord.normalize(try c.decode(String.self, forKey: .word)) else {
                throw DecodingError.dataCorruptedError(forKey: .word, in: c, debugDescription: "invalid word")
            }
            return w
        }
        switch t {
        case .addWord:
            let w = try word()
            self = .addWord(word: w, surface: CommandWord.normalizeSurface(try c.decodeIfPresent(String.self, forKey: .surface), for: w))
        case .forgetWord: self = .forgetWord(word: try word())
        case .unforgetWord: self = .unforgetWord(word: try word())
        case .neverCorrect: self = .setNeverCorrect(word: try word(), enabled: try c.decode(Bool.self, forKey: .enabled))
        case .importDictionary:
            let f = try c.decode(String.self, forKey: .fileName)
            guard ImportPayloadStore.isValidFileName(f) else {
                throw DecodingError.dataCorruptedError(forKey: .fileName, in: c, debugDescription: "invalid file name")
            }
            self = .importDictionary(fileName: f, replaceExisting: try c.decodeIfPresent(Bool.self, forKey: .replace) ?? false)
        case .resetInsights: self = .resetInsights
        case .clearPersonalData: self = .clearPersonalData
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .addWord(w, s):
            try c.encode(T.addWord.rawValue, forKey: .type); try c.encode(w, forKey: .word)
            try c.encodeIfPresent(s, forKey: .surface)
        case let .forgetWord(w): try c.encode(T.forgetWord.rawValue, forKey: .type); try c.encode(w, forKey: .word)
        case let .unforgetWord(w): try c.encode(T.unforgetWord.rawValue, forKey: .type); try c.encode(w, forKey: .word)
        case let .setNeverCorrect(w, e):
            try c.encode(T.neverCorrect.rawValue, forKey: .type); try c.encode(w, forKey: .word); try c.encode(e, forKey: .enabled)
        case let .importDictionary(f, r):
            try c.encode(T.importDictionary.rawValue, forKey: .type); try c.encode(f, forKey: .fileName); try c.encode(r, forKey: .replace)
        case .resetInsights: try c.encode(T.resetInsights.rawValue, forKey: .type)
        case .clearPersonalData: try c.encode(T.clearPersonalData.rawValue, forKey: .type)
        }
    }
}

public struct CommandEnvelope: Sendable, Equatable, Codable {
    public var seq: Int
    public var created: Double
    public var command: AppCommand
    public init(seq: Int, created: Double, command: AppCommand) {
        self.seq = seq; self.created = created; self.command = command
    }
}

/// The queue value: a monotonic sequence plus the most recent envelopes. Encoded as one JSON object
/// `{"version":1,"nextSeq":N,"entries":[...]}`; entries that fail to decode (unknown future command types or
/// invalid words) are skipped individually so one bad entry never blocks the rest.
public struct CommandQueue: Sendable, Equatable {
    public static let currentVersion = 1
    public static let maxEntries = 500
    public static let maxBytes = 512 * 1024

    public private(set) var nextSeq: Int
    public private(set) var entries: [CommandEnvelope]
    /// Entries skipped while decoding (not persisted).
    public private(set) var skippedOnDecode = 0

    public init(nextSeq: Int = 1, entries: [CommandEnvelope] = []) {
        self.nextSeq = max(1, nextSeq); self.entries = entries
    }

    /// Appends and returns the assigned sequence number. Oldest entries beyond `maxEntries` are dropped.
    @discardableResult
    public mutating func append(_ command: AppCommand, at now: Double) -> Int {
        let seq = nextSeq
        nextSeq += 1
        entries.append(CommandEnvelope(seq: seq, created: now, command: command))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        return seq
    }

    /// Envelopes the keyboard has not applied yet, in order.
    public func pending(after lastApplied: Int) -> [CommandEnvelope] {
        entries.filter { $0.seq > lastApplied }
    }

    private struct Wire: Codable { var version: Int; var nextSeq: Int; var entries: [Lossy] }
    private struct Lossy: Codable {
        var value: CommandEnvelope?
        init(_ v: CommandEnvelope) { value = v }
        init(from decoder: Decoder) throws { value = try? CommandEnvelope(from: decoder) }
        func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
    }

    public func encoded() -> Data {
        let wire = Wire(version: Self.currentVersion, nextSeq: nextSeq, entries: entries.map(Lossy.init))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(wire)) ?? Data()
    }

    /// nil for corrupt data or a newer version; the keyboard then applies nothing.
    public static func decode(_ data: Data) -> CommandQueue? {
        guard data.count <= maxBytes, let w = try? JSONDecoder().decode(Wire.self, from: data),
              w.version <= currentVersion else { return nil }
        var q = CommandQueue(nextSeq: w.nextSeq, entries: w.entries.compactMap(\.value))
        q.skippedOnDecode = w.entries.count - q.entries.count
        // Keep nextSeq ahead of every entry even if the field was damaged.
        if let top = q.entries.map(\.seq).max(), q.nextSeq <= top { q.nextSeq = top + 1 }
        return q
    }
}

/// App Group UserDefaults backed queue. Defaults are the channel measured readable by the keyboard without Full
/// Access (P-23). Single writer: only the app appends. Read-modify-write is guarded by a process-local lock.
public final class CommandQueueStore: @unchecked Sendable {
    public static let key = "iboard.commands.queue"
    private let defaults: UserDefaults?
    private let lock = NSLock()

    public init(suiteName: String? = SettingsStore.appGroup) {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) }
    }
    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> CommandQueue {
        guard let d = defaults?.data(forKey: Self.key), let q = CommandQueue.decode(d) else { return CommandQueue() }
        return q
    }

    /// Returns the sequence number, or nil when the store is unavailable or the queue would exceed its size cap.
    @discardableResult
    public func enqueue(_ command: AppCommand, at now: Double = Date().timeIntervalSince1970) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let defaults else { return nil }
        var q = load()
        let seq = q.append(command, at: now)
        let data = q.encoded()
        guard data.count <= CommandQueue.maxBytes else { return nil }
        defaults.set(data, forKey: Self.key)
        return seq
    }
}

/// Import files the app copies into a directory of the App Group container for the keyboard to merge. Whether the
/// keyboard can read app-written files without Full Access is NOT measured (only defaults are, P-23).
public struct ImportPayloadStore: Sendable {
    public static let maxBytes = 8 * 1024 * 1024
    public static let directoryName = "imports"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func appGroupDirectory(group: String = SettingsStore.appGroup) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func isValidFileName(_ f: String) -> Bool {
        guard !f.isEmpty, f.count <= 80, f.hasSuffix(".iboarddict"), !f.hasPrefix("."), !f.contains("..") else { return false }
        return f.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    public enum Failure: Error, Equatable { case tooLarge, empty, io }

    /// Writes the payload atomically under a fresh name and returns the file name for `.importDictionary`.
    public func write(_ data: Data, id: UUID = UUID()) throws -> String {
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge }
        let name = "import-\(id.uuidString.lowercased()).iboarddict"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch { throw Failure.io }
        return name
    }

    /// Deletes payload files older than `maxAge` seconds (the app is the only writer, so it also cleans up).
    public func prune(olderThan maxAge: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in urls where Self.isValidFileName(u.lastPathComponent) {
            if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(m) > maxAge { try? fm.removeItem(at: u) }
        }
    }
}
