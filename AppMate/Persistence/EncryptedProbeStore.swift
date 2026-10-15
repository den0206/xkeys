import CryptoKit
import Foundation
import SwiftData

struct EncryptedBlobStore {
    let directory: URL

    func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".blob") }

    func write(_ data: Data, id: UUID, key: SymmetricKey, authenticating aad: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: file(id).path) else { throw ValidationError.invalidFile }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: aad)
        guard let bytes = sealed.combined else { throw ValidationError.invalidFile }
        do {
            try bytes.write(to: file(id), options: .atomic)
            let handle = try FileHandle(forWritingTo: file(id))
            do { try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard try read(id, key: key, authenticating: aad) == data else { throw ValidationError.invalidFile }
        } catch {
            try? FileManager.default.removeItem(at: file(id))
            throw error
        }
    }

    func read(_ id: UUID, key: SymmetricKey, authenticating aad: Data) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file(id))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: CredentialParser.maximumBytes * 2 + 1) ?? Data()
        guard bytes.count <= CredentialParser.maximumBytes * 2 else { throw ValidationError.tooLarge }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad)
    }

    func removeOrphans(keeping ids: Set<UUID>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "blob", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !ids.contains(id) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

@Model
final class VerificationRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var digest: String

    init(id: UUID, digest: String) {
        self.id = id
        self.createdAt = .now
        self.digest = digest
    }
}

struct EncryptedProbeStore {
    let directory: URL

    func save(_ data: Data, key: SymmetricKey, commit: (VerificationRecord) throws -> Void) throws {
        let id = UUID()
        let url = file(id)
        try EncryptedBlobStore(directory: directory).write(data, id: id, key: key, authenticating: Data(id.uuidString.utf8))
        do {
            guard try read(id, key: key) == data else { throw ValidationError.invalidFile }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try commit(VerificationRecord(id: id, digest: digest))
        } catch {
            // The metadata commit failed, so this newly created blob has no owner.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func read(_ id: UUID, key: SymmetricKey) throws -> Data {
        try EncryptedBlobStore(directory: directory).read(id, key: key, authenticating: Data(id.uuidString.utf8))
    }

    func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".blob") }

    func removeOrphans(keeping ids: Set<UUID>) throws {
        try EncryptedBlobStore(directory: directory).removeOrphans(keeping: ids)
    }
}
