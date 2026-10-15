import CryptoKit
import Foundation
import Observation
import SwiftData

enum P8Purpose: String, CaseIterable, Codable {
    case appStoreConnect = "asc", apns, signInWithApple = "sign-in"
    var title: String {
        switch self {
        case .appStoreConnect: "App Store Connect API"
        case .apns: "APNs"
        case .signInWithApple: "Sign in with Apple"
        }
    }
}

struct P8Metadata {
    let purpose: P8Purpose
    let keyID: String
    let issuerID: String?

    func validated() throws -> P8Metadata {
        let keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw VaultError.invalidKeyID }
        var issuer: String?
        if purpose == .appStoreConnect {
            guard let value = issuerID?.trimmingCharacters(in: .whitespacesAndNewlines), let id = UUID(uuidString: value) else {
                throw VaultError.invalidIssuerID
            }
            issuer = id.uuidString.lowercased()
        }
        return P8Metadata(purpose: purpose, keyID: keyID, issuerID: issuer)
    }
}

@Model
final class StoredCredential {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var registrationKey: String
    var name: String
    var kind: String
    var originalName: String
    var fileExtension: String
    var digest: String
    var fingerprint: String?
    var sourceTeamID: String?
    var bundleID: String?
    var expiresAt: Date?
    var createdAt: Date
    var isTeamShared: Bool
    var hasSavedPassword: Bool
    var team: DeveloperTeam?
    var app: ManagedApp?
    var deletedAt: Date?
    var revokedAt: Date?
    var blobID: UUID?
    var metadataVersion: Int = 1
    var keyPurpose: String?
    var keyID: String?
    var issuerID: String?
    var replacesCredentialID: UUID?
    var replacedByID: UUID?

    init(file: CredentialFile, parsed: ParsedCredential, app: ManagedApp, team: DeveloperTeam, savePassword: Bool, p8: P8Metadata? = nil) {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let shared = ext == "cer" || ext == "p12" || ext == "p8"
        let hash = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
        id = UUID()
        name = p8.map { "\($0.purpose.title)（\($0.keyID)）" } ?? parsed.name
        kind = p8?.purpose.title ?? parsed.kind
        originalName = file.name
        fileExtension = ext
        digest = hash
        fingerprint = parsed.fingerprint
        sourceTeamID = parsed.teamID
        bundleID = parsed.bundleID
        expiresAt = parsed.expiresAt
        createdAt = .now
        isTeamShared = shared
        hasSavedPassword = ext == "p12" && savePassword
        self.team = team
        self.app = shared ? nil : app
        registrationKey = "\(team.id)|\(shared ? "team" : app.id.uuidString)|\(hash)"
        metadataVersion = 2
        keyPurpose = p8?.purpose.rawValue
        keyID = p8?.keyID
        issuerID = p8?.issuerID
    }

    init(restoring value: BackupSnapshot.Credential, team: DeveloperTeam, app: ManagedApp?) {
        id = value.id
        registrationKey = value.registrationKey
        name = value.name
        kind = value.kind
        originalName = value.originalName
        fileExtension = value.fileExtension
        digest = value.digest
        fingerprint = value.fingerprint
        sourceTeamID = value.sourceTeamID
        bundleID = value.bundleID
        expiresAt = value.expiresAt
        createdAt = value.createdAt
        isTeamShared = value.isTeamShared
        hasSavedPassword = value.hasSavedPassword
        self.team = team
        self.app = app
        metadataVersion = value.metadataVersion
        keyPurpose = value.keyPurpose
        keyID = value.keyID
        issuerID = value.issuerID
        replacesCredentialID = value.replacesCredentialID
        replacedByID = value.replacedByID
        deletedAt = value.deletedAt
        revokedAt = value.revokedAt
    }

    func apply(_ value: BackupSnapshot.Credential) {
        name = value.name
        kind = value.kind
        originalName = value.originalName
        fingerprint = value.fingerprint
        sourceTeamID = value.sourceTeamID
        bundleID = value.bundleID
        expiresAt = value.expiresAt
        createdAt = value.createdAt
        hasSavedPassword = value.hasSavedPassword
        metadataVersion = value.metadataVersion
        keyPurpose = value.keyPurpose
        keyID = value.keyID
        issuerID = value.issuerID
        replacesCredentialID = value.replacesCredentialID
        replacedByID = value.replacedByID
        deletedAt = value.deletedAt
        revokedAt = value.revokedAt
    }

    func isVisible(in app: ManagedApp) -> Bool {
        guard let teamID = team?.id, app.team?.id == teamID else { return false }
        return isTeamShared || self.app?.id == app.id
    }

    func authenticatedData() throws -> Data {
        guard let team else { throw VaultError.invalidAssociation }
        var fields = [
            "AppMateCredential-v1", id.uuidString, registrationKey, team.id.uuidString,
            app?.id.uuidString ?? "", String(isTeamShared), name, kind, originalName, fileExtension,
            digest, fingerprint ?? "", sourceTeamID ?? "", bundleID ?? "",
            expiresAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "", String(hasSavedPassword)
        ]
        if metadataVersion == 2 {
            fields[0] = "AppMateCredential-v2"
            fields += [keyPurpose ?? "", keyID ?? "", issuerID ?? "", replacesCredentialID?.uuidString ?? ""]
        } else if metadataVersion != 1 { throw ValidationError.invalidFile }
        if let blobID { fields += ["blob-reference-v1", blobID.uuidString] }
        return try JSONEncoder().encode(fields)
    }
}

struct CredentialPayload: Codable {
    var version = 1
    let original: Data
    let password: String?
    var note: String? = nil
}

enum VaultError: LocalizedError {
    case invalidAssociation, teamMismatch, bundleMismatch, confirmTeam, duplicate, unsupported, cancelled
    case invalidKeyID, invalidIssuerID, missingPurpose, invalidReplacement, replacementConfirmation

    var errorDescription: String? {
        switch self {
        case .invalidAssociation: "登録先のAppとTeamを確認できません。保存していません。"
        case .teamMismatch: "ファイルのTeam IDと登録先のTeamが一致しません。"
        case .bundleMismatch: "プロファイルのBundle IDがこのAppに一致しません。"
        case .confirmTeam: "Team IDを取得できませんでした。選択中のTeamに割り当てることを確認してください。"
        case .duplicate: "同じファイルはすでに登録されています。既存の資格情報を確認してください。"
        case .unsupported: "現在は.cer・.p12・.p8・プロビジョニングプロファイルを取り込めます。"
        case .cancelled: "ロックまたはキャンセルにより操作を中止しました。"
        case .invalidKeyID: "Key IDは英大文字と数字の10文字で入力してください。"
        case .invalidIssuerID: "App Store Connect APIのIssuer IDをUUID形式で入力してください。"
        case .missingPurpose: ".p8の用途とKey IDを確認してください。"
        case .invalidReplacement: "同じTeam・共有範囲・形式・用途の、置き換えられていない資格情報を選んでください。"
        case .replacementConfirmation: "旧→新と共有先を確認して、置き換えの確認をオンにしてください。"
        }
    }
}

@MainActor
struct CredentialVault {
    let context: ModelContext
    let blobs: EncryptedBlobStore

    static var directory: URL {
        if ProcessInfo.processInfo.environment["APP_MATE_TESTING"] == "1" {
            return FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/VaultBlobs", isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("AppMateVault/blobs", isDirectory: true)
    }

    nonisolated static func profileMatches(_ profile: String, bundleID: String) -> Bool {
        let profile = profile.lowercased()
        let bundle = bundleID.lowercased()
        if profile == "*" { return !bundle.isEmpty }
        if profile.hasSuffix(".*"), !profile.dropLast().contains("*") {
            let prefix = String(profile.dropLast())
            return bundle.hasPrefix(prefix) && bundle.count > prefix.count
        }
        return !profile.contains("*") && profile == bundle
    }

    func records() throws -> [StoredCredential] { try context.fetch(FetchDescriptor<StoredCredential>()) }

    func canCreateKey() throws -> Bool {
        guard try records().isEmpty, (try context.fetch(FetchDescriptor<ManagedApp>())).allSatisfy({ $0.noteBlobID == nil }) else { return false }
        guard FileManager.default.fileExists(atPath: blobs.directory.path) else { return true }
        return try FileManager.default.contentsOfDirectory(atPath: blobs.directory.path).isEmpty
    }

    func recover() throws {
        let records = try records()
        try blobs.removeOrphans(keeping: Set(records.map { $0.blobID ?? $0.id } + (try context.fetch(FetchDescriptor<ManagedApp>())).compactMap(\.noteBlobID)))
    }

    func validate(file: CredentialFile, parsed: ParsedCredential, app: ManagedApp, confirmUnknownTeam: Bool,
                  p8: P8Metadata? = nil, replacingID: UUID? = nil, confirmReplacement: Bool = false) throws {
        guard let team = app.team, app.modelContext === context, app.deletedAt == nil else { throw VaultError.invalidAssociation }
        let ext = (file.name as NSString).pathExtension.lowercased()
        guard ["cer", "p12", "p8", "mobileprovision", "provisionprofile"].contains(ext) else { throw VaultError.unsupported }
        if ext == "p8" {
            guard let p8 else { throw VaultError.missingPurpose }
            _ = try p8.validated()
        } else if p8 != nil { throw VaultError.missingPurpose }
        if let sourceTeam = parsed.teamID {
            guard sourceTeam == team.teamID else { throw VaultError.teamMismatch }
        } else if !confirmUnknownTeam { throw VaultError.confirmTeam }
        if ext == "mobileprovision" || ext == "provisionprofile" {
            guard let bundle = parsed.bundleID, Self.profileMatches(bundle, bundleID: app.bundleID) else { throw VaultError.bundleMismatch }
        }
        let candidate = StoredCredential(file: file, parsed: parsed, app: app, team: team, savePassword: false)
        guard try !records().contains(where: { $0.registrationKey == candidate.registrationKey }) else { throw VaultError.duplicate }
        if let replacingID {
            guard confirmReplacement else { throw VaultError.replacementConfirmation }
            _ = try replacementTarget(replacingID, fileExtension: ext, purpose: p8?.purpose.rawValue, app: app)
        }
    }

    private func replacementTarget(_ id: UUID, fileExtension ext: String, purpose: String?, app: ManagedApp) throws -> StoredCredential {
        guard let old = try records().first(where: { $0.id == id }), old.isVisible(in: app), old.replacedByID == nil,
              old.fileExtension == ext, old.keyPurpose == purpose else { throw VaultError.invalidReplacement }
        return old
    }

    @discardableResult
    func importFile(_ file: CredentialFile, parsed: ParsedCredential, app: ManagedApp, password: String?,
                    confirmUnknownTeam: Bool, key: SymmetricKey, p8: P8Metadata? = nil,
                    replacingID: UUID? = nil, confirmReplacement: Bool = false, beforeCommit: () throws -> Void = {}) throws -> UUID {
        try validate(file: file, parsed: parsed, app: app, confirmUnknownTeam: confirmUnknownTeam,
                     p8: p8, replacingID: replacingID, confirmReplacement: confirmReplacement)
        guard let team = app.team else { throw VaultError.invalidAssociation }
        guard (password?.utf8.count ?? 0) <= 4096 else { throw ValidationError.tooLarge }
        context.autosaveEnabled = false
        let metadata = try p8?.validated()
        let old = try replacingID.map { try replacementTarget($0, fileExtension: (file.name as NSString).pathExtension.lowercased(), purpose: metadata?.purpose.rawValue, app: app) }
        if let old { _ = try read(old, key: key) }
        var writtenID: UUID?
        do {
            try BackupHistory.prepare(in: context)
            let record = StoredCredential(file: file, parsed: parsed, app: app, team: team, savePassword: password != nil, p8: metadata)
            record.replacesCredentialID = old?.id
            let payload = CredentialPayload(original: file.data, password: record.hasSavedPassword ? password : nil)
            let bytes = try JSONEncoder().encode(payload)
            try blobs.write(bytes, id: record.id, key: key, authenticating: record.authenticatedData())
            writtenID = record.id
            context.insert(record)
            old?.replacedByID = record.id
            BackupHistory.record(in: context)
            try beforeCommit()
            try context.save()
            return record.id
        } catch {
            context.rollback()
            if let writtenID { try? FileManager.default.removeItem(at: blobs.file(writtenID)) }
            throw error
        }
    }

    func restoreToList(_ record: StoredCredential, key: SymmetricKey) throws {
        guard record.modelContext === context, let replacement = record.replacedByID,
              let next = try records().first(where: { $0.id == replacement }), next.replacesCredentialID == record.id else {
            throw VaultError.invalidReplacement
        }
        _ = try read(record, key: key)
        _ = try read(next, key: key)
        context.autosaveEnabled = false
        do {
            try BackupHistory.prepare(in: context)
            record.replacedByID = nil
            BackupHistory.record(in: context)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func read(_ record: StoredCredential, key: SymmetricKey) throws -> CredentialPayload {
        let bytes = try blobs.read(record.blobID ?? record.id, key: key, authenticating: record.authenticatedData())
        let payload = try JSONDecoder().decode(CredentialPayload.self, from: bytes)
        guard payload.version == 1, !payload.original.isEmpty, payload.original.count <= CredentialParser.maximumBytes,
              SHA256.hash(data: payload.original).map({ String(format: "%02x", $0) }).joined() == record.digest else {
            throw ValidationError.invalidFile
        }
        return payload
    }

    func export(_ record: StoredCredential, to url: URL, key: SymmetricKey) throws {
        let payload = try read(record, key: key)
        try CredentialFile(data: payload.original, name: record.originalName).export(to: url)
    }
}

@MainActor @Observable
final class VaultAccess {
    private(set) var busy = false
    private(set) var generation = UUID()
    var presentingPanel = false
    @ObservationIgnored private let authentication = OwnerAuthentication()
    @ObservationIgnored private let keyProvider: ((String, Bool) async throws -> SymmetricKey)?

    init(keyProvider: ((String, Bool) async throws -> SymmetricKey)? = nil) { self.keyProvider = keyProvider }

    func lock() {
        generation = UUID()
        authentication.cancel()
    }

    func withKey<T>(reason: String, allowCreation: Bool, vault: CredentialVault? = nil, operation: (SymmetricKey) throws -> T) async throws -> T {
        guard !busy else { throw VaultError.cancelled }
        busy = true
        let generation = self.generation
        defer { busy = false; authentication.cancel() }
        let key: SymmetricKey
        if let keyProvider {
            key = try await keyProvider(reason, allowCreation)
        } else {
            try EncryptionKeychain.requireSigning()
            let context = try await authentication.authenticate(reason: reason)
            key = try EncryptionKeychain.vault.key(context: context, allowCreation: allowCreation)
        }
        guard self.generation == generation, !Task.isCancelled else { throw VaultError.cancelled }
        if let vault { try VaultManagement(vault: vault).pruneExpired(key: key) }
        return try operation(key)
    }
}
