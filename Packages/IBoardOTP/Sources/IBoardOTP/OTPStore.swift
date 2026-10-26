import Foundation

/// A captured code. Deliberately holds nothing but the code, a sender label and a timestamp:
/// the message body is never stored (ROADMAP F6).
public struct StoredCode: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let code: String
    public let sender: String
    public let timestamp: Date
    public var id: String { "\(Int(timestamp.timeIntervalSince1970 * 1000))|\(code)" }

    public init(code: String, sender: String, timestamp: Date) {
        self.code = code
        self.sender = sender
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey { case code, sender, timestamp }
}

/// Minimal key-value storage so tests need no real App Group.
public protocol OTPStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// `UserDefaults` is documented thread-safe; the wrapper is safe to share.
public struct UserDefaultsOTPStorage: OTPStorage, @unchecked Sendable {
    private let defaults: UserDefaults?
    public init(suiteName: String = OTPStoreConfig.appGroup) {
        self.defaults = UserDefaults(suiteName: suiteName)
    }
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults?.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults?.set(data, forKey: key) } else { defaults?.removeObject(forKey: key) }
    }
}

/// In-memory storage for tests.
public final class InMemoryOTPStorage: OTPStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }
}

public enum OTPStoreConfig {
    public static let appGroup = "group.app.iBoard"
    public static let keyPrefix = "iBoard.otp."
    public static let codesKey = keyPrefix + "codes"
    public static let ttlKey = keyPrefix + "ttlSeconds"
    public static let clearAfterInsertKey = keyPrefix + "clearAfterInsert"
    public static let defaultTTL: TimeInterval = 10 * 60
    public static let maxCodes = 3
}

private func decodeCodes(_ storage: any OTPStorage) -> [StoredCode] {
    storage.data(forKey: OTPStoreConfig.codesKey)
        .flatMap { try? JSONDecoder().decode([StoredCode].self, from: $0) } ?? []
}

/// Read side, used by the keyboard. Never writes, so it works without Full Access (P-23).
/// "Cleared after insert" is honoured by the caller passing the ids it already inserted
/// (kept in keyboard memory); the keyboard cannot delete from the shared store.
public struct OTPReader: Sendable {
    let storage: any OTPStorage
    let clock: @Sendable () -> Date

    public init(storage: any OTPStorage = UserDefaultsOTPStorage(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.clock = clock
    }

    public var ttl: TimeInterval {
        guard let d = storage.data(forKey: OTPStoreConfig.ttlKey),
              let v = try? JSONDecoder().decode(Double.self, from: d), v > 0 else { return OTPStoreConfig.defaultTTL }
        return v
    }

    public var clearAfterInsert: Bool {
        guard let d = storage.data(forKey: OTPStoreConfig.clearAfterInsertKey),
              let v = try? JSONDecoder().decode(Bool.self, from: d) else { return true }
        return v
    }

    /// Fresh codes, newest first, at most 3. `excluding` lists ids already inserted.
    public func freshCodes(excluding consumed: Set<String> = []) -> [StoredCode] {
        let now = clock()
        let limit = ttl
        let skip = clearAfterInsert
        let fresh = decodeCodes(storage).filter {
            let age = now.timeIntervalSince($0.timestamp)
            return age <= limit && age >= -60 && !(skip && consumed.contains($0.id))
        }
        return Array(fresh.sorted { $0.timestamp > $1.timestamp }.prefix(OTPStoreConfig.maxCodes))
    }
}

/// Write side, used by the app and the App Intent only.
public struct OTPWriter: Sendable {
    let storage: any OTPStorage
    let clock: @Sendable () -> Date

    public init(storage: any OTPStorage = UserDefaultsOTPStorage(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.clock = clock
    }

    public func setTTL(_ seconds: TimeInterval) {
        storage.set(try? JSONEncoder().encode(max(1, seconds)), forKey: OTPStoreConfig.ttlKey)
    }

    public func setClearAfterInsert(_ value: Bool) {
        storage.set(try? JSONEncoder().encode(value), forKey: OTPStoreConfig.clearAfterInsertKey)
    }

    /// Stores a code (sender label trimmed and capped). Expired entries are pruned; only the newest 3 remain.
    @discardableResult
    public func record(code: String, sender: String?) -> StoredCode {
        let label = String((sender ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let now = clock()
        let entry = StoredCode(code: code, sender: label, timestamp: now)
        let ttl = OTPReader(storage: storage, clock: clock).ttl
        var all = decodeCodes(storage)
        all.removeAll { $0.code == code && $0.sender == label }
        all.append(entry)
        all = all.filter { now.timeIntervalSince($0.timestamp) <= ttl }
            .sorted { $0.timestamp > $1.timestamp }
        storage.set(try? JSONEncoder().encode(Array(all.prefix(OTPStoreConfig.maxCodes))), forKey: OTPStoreConfig.codesKey)
        return entry
    }

    /// Parses `text` and stores the code if one is found. The text itself is never retained.
    @discardableResult
    public func capture(text: String, sender: String?) -> StoredCode? {
        guard let extracted = OTPParser.extract(from: text) else { return nil }
        return record(code: extracted.code, sender: sender)
    }

    public func clearAll() { storage.set(nil, forKey: OTPStoreConfig.codesKey) }
}
