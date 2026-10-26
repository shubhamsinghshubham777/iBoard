import Foundation
import Synchronization

public enum PersonalStorageMode: Sendable, Equatable {
    /// Container only the keyboard extension can see. Always works, with or without Full Access.
    case extensionLocal
    /// App Group container shared with the app. Writable only with Full Access (P-23).
    case appGroup
}

/// Byte-level persistence for the personal store. Every call is a short, self-contained file operation: no handle,
/// lock or transaction is held between calls, so nothing is held across process suspension (P-16, 0xdead10cc).
/// The keyboard extension is the single writer; the app only reads (and sends edit commands to the keyboard).
public protocol PersonalStorage: Sendable {
    var mode: PersonalStorageMode { get }
    func readSnapshot() throws -> Data?
    func writeSnapshot(_ data: Data) throws
    func readJournal() throws -> Data
    func appendJournal(_ data: Data) throws
    func resetJournal() throws
    /// Deletes snapshot and journal ("delete all personal data").
    func destroy() throws
}

/// Files `personal.snapshot` and `personal.journal` in a directory. Snapshot writes are atomic (temp + rename).
/// No timestamps are read (privacy manifest: file timestamp API not used).
public struct FilePersonalStorage: PersonalStorage {
    public let mode: PersonalStorageMode
    public let directory: URL

    public init(directory: URL, mode: PersonalStorageMode) {
        self.directory = directory
        self.mode = mode
    }

    private var snapshotURL: URL { directory.appendingPathComponent("personal.snapshot") }
    private var journalURL: URL { directory.appendingPathComponent("personal.journal") }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func readSnapshot() throws -> Data? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        return try Data(contentsOf: snapshotURL)
    }

    public func writeSnapshot(_ data: Data) throws {
        try ensureDirectory()
        try data.write(to: snapshotURL, options: .atomic)
    }

    public func readJournal() throws -> Data {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return Data() }
        return try Data(contentsOf: journalURL)
    }

    public func appendJournal(_ data: Data) throws {
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            try data.write(to: journalURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func resetJournal() throws {
        try ensureDirectory()
        try Data().write(to: journalURL, options: .atomic)
    }

    public func destroy() throws {
        for url in [snapshotURL, journalURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// In-memory storage for tests, with fault injection hooks.
public final class InMemoryPersonalStorage: PersonalStorage {
    public struct Failure: Error {}
    private struct State { var snapshot: Data?; var journal = Data(); var failWrites = false }
    private let state = Mutex(State())
    public let mode: PersonalStorageMode

    public init(mode: PersonalStorageMode = .extensionLocal) { self.mode = mode }

    public var failWrites: Bool {
        get { state.withLock { $0.failWrites } }
        set { state.withLock { $0.failWrites = newValue } }
    }
    public var snapshotData: Data? {
        get { state.withLock { $0.snapshot } }
        set { state.withLock { $0.snapshot = newValue } }
    }
    public var journalData: Data {
        get { state.withLock { $0.journal } }
        set { state.withLock { $0.journal = newValue } }
    }

    public func readSnapshot() throws -> Data? { state.withLock { $0.snapshot } }
    public func writeSnapshot(_ data: Data) throws {
        try state.withLock { if $0.failWrites { throw Failure() }; $0.snapshot = data }
    }
    public func readJournal() throws -> Data { state.withLock { $0.journal } }
    public func appendJournal(_ data: Data) throws {
        try state.withLock { if $0.failWrites { throw Failure() }; $0.journal.append(data) }
    }
    public func resetJournal() throws {
        try state.withLock { if $0.failWrites { throw Failure() }; $0.journal = Data() }
    }
    public func destroy() throws { state.withLock { $0.snapshot = nil; $0.journal = Data() } }
}

public enum PersonalStorageFactory {
    /// Extension-local storage always works; App Group storage is used only when Full Access is granted and an App
    /// Group directory is available (P-23: without Full Access shared writes fail).
    public static func make(hasFullAccess: Bool, localDirectory: URL, appGroupDirectory: URL?) -> any PersonalStorage {
        if hasFullAccess, let appGroupDirectory {
            return FilePersonalStorage(directory: appGroupDirectory, mode: .appGroup)
        }
        return FilePersonalStorage(directory: localDirectory, mode: .extensionLocal)
    }

    /// Copies the model from `source` into `destination` (as a fresh snapshot) when switching modes, e.g. Full Access
    /// granted or revoked. Returns false when the source holds nothing. Replaces the destination content.
    @discardableResult
    public static func migrate(from source: any PersonalStorage, to destination: any PersonalStorage,
                               config: PersonalStoreConfig = PersonalStoreConfig()) throws -> Bool {
        let loaded = try PersonalStore.load(storage: source, config: config)
        guard loaded.hadData else { return false }
        try destination.writeSnapshot(PersonalSnapshotCodec.encode(loaded.state, lastSeq: loaded.lastSeq))
        try destination.resetJournal()
        return true
    }
}
