import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import IBoardCore
#if canImport(IBoardEngine)
import IBoardEngine
#endif

/// The `.iboarddict` file type. Not declared in Info.plist, so this is a dynamic type tied to the extension.
enum DictionaryFileType {
    static let type = UTType(filenameExtension: "iboarddict", conformingTo: .plainText) ?? .plainText
    static let importTypes: [UTType] = [type, .plainText, .json]
}

/// Read-only document wrapper so `fileExporter` can hand a snapshot to the Files UI.
struct DictionaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { DictionaryFileType.importTypes }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Where the keyboard shares its dictionary snapshot (written by the keyboard only with Full Access, P-23).
enum SharedFiles {
    static let snapshotName = "dictionary.iboarddict"
    static var sharedDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SettingsStore.appGroup)?
            .appendingPathComponent("shared", isDirectory: true)
    }
    static var snapshotURL: URL? { sharedDirectory?.appendingPathComponent(snapshotName) }
}

/// A decoded dictionary file summarised for the UI.
struct DictionaryFileSummary: Equatable {
    var entries: [DictionaryEntry]
    var phraseCount: Int
    var forgottenCount: Int
    var rejectedLines: Int
}

enum DictionaryLoadError: Error, Equatable {
    case engineNotLinked, unreadable, invalid(String)
    var message: String {
        switch self {
        case .engineNotLinked: "This build of the app cannot read dictionary files yet."
        case .unreadable: "The file could not be read."
        case let .invalid(why): "Not a valid iBoard dictionary: \(why)"
        }
    }
}

enum DictionaryFileReader {
    /// Decodes bytes with the engine's validated decoder. Typed words never leave memory except as the file the
    /// user chose; nothing is logged.
    static func summarize(_ data: Data) -> Result<DictionaryFileSummary, DictionaryLoadError> {
        #if canImport(IBoardEngine)
        do {
            let d = try DictionaryDecoder.decode(data)
            let never = Set(d.neverCorrect)
            let entries = d.words.map {
                DictionaryEntry(word: $0.word, surface: $0.surface, weight: $0.weight, uses: $0.uses,
                                neverCorrect: $0.neverCorrect || never.contains($0.word))
            }
            return .success(DictionaryFileSummary(entries: entries, phraseCount: d.phrases.count,
                                                  forgottenCount: d.forgotten.count, rejectedLines: d.report.rejectedTotal))
        } catch let e as DictionaryError {
            return .failure(.invalid(String(describing: e)))
        } catch { return .failure(.unreadable) }
        #else
        return .failure(.engineNotLinked)
        #endif
    }
}

/// App-side state for the dictionary manager and import/export screens.
@MainActor @Observable
final class DictionaryStore {
    enum Snapshot: Equatable {
        case loading
        /// No shared snapshot: Full Access is off, the keyboard has not run with it yet, or the group is missing.
        case unavailable
        case failed(DictionaryLoadError)
        case ready(DictionaryFileSummary, modified: Date?)
    }

    private(set) var snapshot: Snapshot = .loading
    private(set) var pending: [AppCommand] = []
    private let queue: CommandQueueStore

    init(queue: CommandQueueStore = CommandQueueStore()) { self.queue = queue }

    func reload() async {
        guard let url = SharedFiles.snapshotURL, FileManager.default.fileExists(atPath: url.path) else {
            snapshot = .unavailable; refreshPending(); return
        }
        let result: Result<DictionaryFileSummary, DictionaryLoadError> = await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
            return DictionaryFileReader.summarize(data)
        }.value
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        switch result {
        case let .success(s): snapshot = .ready(s, modified: modified)
        case let .failure(e): snapshot = .failed(e)
        }
        refreshPending()
    }

    /// Commands queued since this app last saw an acknowledgement. The keyboard's acknowledgement is not visible to
    /// the app without Full Access, so this is "queued", never "applied".
    private func refreshPending() { pending = queue.load().entries.map(\.command) }

    var queuedCount: Int { pending.count }

    /// Snapshot entries with queued commands overlaid.
    var visibleEntries: [DictionaryEntry] {
        guard case let .ready(s, _) = snapshot else { return DictionaryBrowse.applying(pending, to: []).entries }
        return DictionaryBrowse.applying(pending, to: s.entries).entries
    }

    @discardableResult
    func send(_ command: AppCommand?) -> Bool {
        guard let command, queue.enqueue(command) != nil else { return false }
        refreshPending()
        return true
    }

    /// Copies a user-chosen file to the App Group and queues the merge. Returns a user-facing result.
    func queueImport(_ data: Data, replaceExisting: Bool) -> Result<Void, ImportPayloadStore.Failure> {
        guard let dir = ImportPayloadStore.appGroupDirectory() else { return .failure(.io) }
        let store = ImportPayloadStore(directory: dir)
        store.prune(olderThan: 14 * 24 * 3600)
        do {
            let name = try store.write(data)
            guard send(.importDictionary(fileName: name, replaceExisting: replaceExisting)) else { return .failure(.io) }
            return .success(())
        } catch let e as ImportPayloadStore.Failure { return .failure(e) } catch { return .failure(.io) }
    }
}
