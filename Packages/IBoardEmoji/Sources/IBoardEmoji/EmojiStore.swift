import Foundation

/// Owns the emoji data for the panel's lifetime. Nothing is loaded until the panel opens
/// (`catalog()`); `dropCaches()` releases everything (panel close, memory warning), per F8 / P-21.
public final class EmojiStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: EmojiCatalog?
    private var index: EmojiSearchIndex?
    private let loader: @Sendable () throws -> EmojiCatalog

    public init(loader: @escaping @Sendable () throws -> EmojiCatalog = { try EmojiCatalog.loadBundled() }) {
        self.loader = loader
    }

    public var isLoaded: Bool { lock.withLock { cached != nil } }

    /// Loads on first use; nil only if the bundled resource is unreadable.
    public func catalog() -> EmojiCatalog? {
        lock.withLock {
            if cached == nil { cached = try? loader() }
            return cached
        }
    }

    /// Search/prediction index, built on first use from the catalog (about a millisecond-scale one-off).
    public func searchIndex() -> EmojiSearchIndex? {
        lock.withLock {
            if cached == nil { cached = try? loader() }
            guard let c = cached else { return nil }
            if index == nil { index = EmojiSearchIndex(catalog: c) }
            return index
        }
    }

    public func dropCaches() {
        lock.withLock { cached = nil; index = nil }
    }
}
