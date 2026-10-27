import Foundation
import CryptoKit

/// Authenticated encryption of shard payloads (AES-256-GCM). Typed words never leave the device unencrypted; the key
/// lives in the (iCloud-synced) Keychain, never in CloudKit. The record name is bound as associated data so a
/// payload cannot be replayed under another record name.
public enum SyncCryptoError: Error, Equatable, Sendable { case malformed, authenticationFailed }

public struct SyncCrypto: Sendable {
    private let key: SymmetricKey
    public init(keyData: Data) { key = SymmetricKey(data: keyData) }
    public static func generateKeyData() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    public func seal(_ plaintext: Data, bindingTo recordName: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(recordName.utf8))
        guard let c = box.combined else { throw SyncCryptoError.malformed }
        return c
    }

    public func open(_ combined: Data, bindingTo recordName: String) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: combined) else { throw SyncCryptoError.malformed }
        do { return try AES.GCM.open(box, using: key, authenticating: Data(recordName.utf8)) }
        catch { throw SyncCryptoError.authenticationFailed }
    }
}
