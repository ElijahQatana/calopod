import CryptoKit
import Foundation

/// Backup files are encrypted with AES-GCM using a random key kept in the secret store.
/// The file is a fixed header followed by the sealed SQLite bytes.
enum BackupEncryption {
    static let header = Data("CALOPODBK1\n".utf8)
    private static let reference = SecretReference(account: "local-state-backup-key")

    static func isEncrypted(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: header.count) == header
    }

    static func seal(_ plain: Data, secrets: any SecretStore) throws -> Data {
        let sealed = try AES.GCM.seal(plain, using: try loadOrCreateKey(secrets), authenticating: header)
        guard let combined = sealed.combined else { throw LocalStateBackupError.backupInvalid }
        return header + combined
    }

    /// A missing key is reported separately from a wrong key or a damaged file.
    static func open(_ file: Data, secrets: any SecretStore) throws -> Data {
        guard file.starts(with: header) else { throw LocalStateBackupError.backupInvalid }
        guard let stored = try secrets.value(for: reference) else {
            throw LocalStateBackupError.keyUnavailable
        }
        do {
            let box = try AES.GCM.SealedBox(combined: file.dropFirst(header.count))
            return try AES.GCM.open(box, using: SymmetricKey(data: stored), authenticating: header)
        } catch {
            throw LocalStateBackupError.backupInvalid
        }
    }

    private static func loadOrCreateKey(_ secrets: any SecretStore) throws -> SymmetricKey {
        if let stored = try secrets.value(for: reference) {
            guard stored.count == 32 else { throw SecretStoreError.unexpectedValue }
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        try secrets.save(key.withUnsafeBytes { Data($0) }, for: reference)
        return key
    }
}
