import Foundation

// Personal-info chips data (M6-06, F7). The companion app saves it into the App Group; the keyboard only READS it
// (works without Full Access, P-23) and never writes or logs it. Pure and UIKit-free.

public struct PersonalAddress: Codable, Sendable, Equatable {
    public var street: String
    public var city: String
    public var region: String
    public var postalCode: String
    public init(street: String = "", city: String = "", region: String = "", postalCode: String = "") {
        self.street = street; self.city = city; self.region = region; self.postalCode = postalCode
    }
}

public struct PersonalInfo: Codable, Sendable, Equatable {
    public static let empty = PersonalInfo()
    /// Caps so a corrupt or hostile blob cannot bloat the keyboard.
    public static let maxEntries = 5

    public var fullName: String
    public var givenName: String
    public var familyName: String
    public var emails: [String]
    public var phones: [String]
    public var addresses: [PersonalAddress]

    public init(fullName: String = "", givenName: String = "", familyName: String = "", emails: [String] = [],
                phones: [String] = [], addresses: [PersonalAddress] = []) {
        self.fullName = fullName; self.givenName = givenName; self.familyName = familyName
        self.emails = emails; self.phones = phones; self.addresses = addresses
    }

    private enum CodingKeys: String, CodingKey { case fullName, givenName, familyName, emails, phones, addresses }

    /// Tolerant decoding: any missing field is empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        givenName = try c.decodeIfPresent(String.self, forKey: .givenName) ?? ""
        familyName = try c.decodeIfPresent(String.self, forKey: .familyName) ?? ""
        emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        phones = try c.decodeIfPresent([String].self, forKey: .phones) ?? []
        addresses = try c.decodeIfPresent([PersonalAddress].self, forKey: .addresses) ?? []
    }

    public var isEmpty: Bool { self == PersonalInfo.empty }

    private func nameParts() -> [Substring] { fullName.split(separator: " ") }

    /// The value strings offered for a field of the given `UITextContentType` raw value (case-insensitive).
    /// Empty for every type that is not one of the personal-info types: this is the "never in untyped fields" rule.
    public func values(forContentType raw: String?) -> [String] {
        guard let key = raw?.lowercased(), !key.isEmpty else { return [] }
        func clean(_ xs: [String]) -> [String] {
            Array(xs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(Self.maxEntries))
        }
        func joined(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: ", ") }
        switch key {
        case "name":
            return clean([fullName.isEmpty ? [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") : fullName])
        case "givenname":
            return clean([givenName.isEmpty ? String(nameParts().first ?? "") : givenName])
        case "familyname":
            return clean([familyName.isEmpty ? (nameParts().count > 1 ? String(nameParts().last ?? "") : "") : familyName])
        case "emailaddress": return clean(emails)
        case "telephonenumber": return clean(phones)
        case "fullstreetaddress": return clean(addresses.map { joined([$0.street, $0.city, $0.region, $0.postalCode]) })
        case "streetaddressline1": return clean(addresses.map(\.street))
        case "addresscity": return clean(addresses.map(\.city))
        case "addresscityandstate": return clean(addresses.map { joined([$0.city, $0.region]) })
        case "addressstate": return clean(addresses.map(\.region))
        case "postalcode": return clean(addresses.map(\.postalCode))
        default: return []
        }
    }
}

/// Storage seam (tests need no App Group).
public protocol PersonalInfoStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public struct UserDefaultsPersonalInfoStorage: PersonalInfoStorage, @unchecked Sendable {
    private let defaults: UserDefaults?
    public init(suiteName: String = PersonalInfoStore.appGroup) { defaults = UserDefaults(suiteName: suiteName) }
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults?.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults?.set(data, forKey: key) } else { defaults?.removeObject(forKey: key) }
    }
}

public final class InMemoryPersonalInfoStorage: PersonalInfoStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    public func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

public enum PersonalInfoStore {
    public static let appGroup = "group.app.iBoard"
    public static let key = "iBoard.personalInfo"
}

/// Read side, used by the keyboard. Never writes.
public struct PersonalInfoReader: Sendable {
    let storage: any PersonalInfoStorage
    public init(storage: any PersonalInfoStorage = UserDefaultsPersonalInfoStorage()) { self.storage = storage }
    public func load() -> PersonalInfo {
        storage.data(forKey: PersonalInfoStore.key).flatMap { try? JSONDecoder().decode(PersonalInfo.self, from: $0) } ?? .empty
    }
}

/// Write side, for the companion app only (the keyboard never calls it).
public struct PersonalInfoWriter: Sendable {
    let storage: any PersonalInfoStorage
    public init(storage: any PersonalInfoStorage = UserDefaultsPersonalInfoStorage()) { self.storage = storage }
    public func save(_ info: PersonalInfo) {
        storage.set(info.isEmpty ? nil : try? JSONEncoder().encode(info), forKey: PersonalInfoStore.key)
    }
}
