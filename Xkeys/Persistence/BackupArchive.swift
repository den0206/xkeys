import CommonCrypto
import CryptoKit
import Foundation
import SwiftData

struct BackupSnapshot: Codable, Sendable, Equatable {
    struct Team: Codable, Sendable, Equatable {
        let id: UUID
        let name: String
        let teamID: String
    }
    struct App: Codable, Sendable, Equatable {
        let id: UUID
        let name: String
        let bundleID: String
        let platform: String
        let team: UUID
        let createdAt: Date
        var deletedAt: Date? = nil
        var note: String? = nil
        var parentAppID: UUID? = nil
        var iconColor: String? = nil
        var iconImage: Data? = nil
        var customSecrets: [AppSecret]? = nil
    }
    struct Credential: Codable, Sendable, Equatable {
        let id: UUID
        let registrationKey: String
        let name: String
        let kind: String
        let originalName: String
        let fileExtension: String
        let digest: String
        let fingerprint: String?
        let sourceTeamID: String?
        let bundleID: String?
        let expiresAt: Date?
        let createdAt: Date
        let isTeamShared: Bool
        let hasSavedPassword: Bool
        let team: UUID
        let app: UUID?
        let keyPurpose: String?
        let keyID: String?
        let issuerID: String?
        let original: Data
        let password: String?
        var note: String? = nil
        var deletedAt: Date? = nil
    }
    var version: Int
    let createdAt: Date
    let appVersion: String
    let teams: [Team]
    let apps: [App]
    let credentials: [Credential]
    var preferences: AppPreferences? = nil

    @MainActor
    static func capture(vault: CredentialVault, key: SymmetricKey) throws -> BackupSnapshot {
        let teams = try vault.context.fetch(FetchDescriptor<DeveloperTeam>()).map {
            Team(id: $0.id, name: $0.name, teamID: $0.teamID)
        }
        var customBytes = 0
        let apps = try vault.context.fetch(FetchDescriptor<ManagedApp>()).map { app in
            guard let team = app.team else { throw VaultError.invalidAssociation }
            let secrets = try VaultManagement(vault: vault).readCustomSecrets(app, key: key)
            customBytes += secrets.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
            guard customBytes <= BackupArchive.maximumPayloadBytes / 4 else { throw BackupError.tooLarge }
            return App(id: app.id, name: app.name, bundleID: app.bundleID, platform: app.platform, team: team.id, createdAt: app.createdAt, deletedAt: app.deletedAt, note: try VaultManagement(vault: vault).readNote(app, key: key), parentAppID: app.parentAppID, iconColor: app.iconColor, iconImage: app.iconImage, customSecrets: secrets.isEmpty ? nil : secrets)
        }
        var credentials: [Credential] = []
        var originalBytes = 0
        for record in try vault.records() {
            guard let team = record.team else { throw VaultError.invalidAssociation }
            let payload = try vault.read(record, key: key)
            originalBytes += payload.original.count
            guard originalBytes <= BackupArchive.maximumPayloadBytes / 2 else { throw BackupError.tooLarge }
            credentials.append(Credential(
                id: record.id, registrationKey: record.registrationKey, name: record.name, kind: record.kind,
                originalName: record.originalName, fileExtension: record.fileExtension, digest: record.digest,
                fingerprint: record.fingerprint, sourceTeamID: record.sourceTeamID, bundleID: record.bundleID,
                expiresAt: record.expiresAt, createdAt: record.createdAt, isTeamShared: record.isTeamShared,
                hasSavedPassword: record.hasSavedPassword, team: team.id, app: record.app?.id,
                keyPurpose: record.keyPurpose, keyID: record.keyID, issuerID: record.issuerID,
                original: payload.original, password: payload.password, note: payload.note, deletedAt: record.deletedAt))
        }
        let snapshot = BackupSnapshot(version: 1, createdAt: .now,
                                      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                                      teams: teams, apps: apps, credentials: credentials, preferences: try PreferencesStore.read(in: vault.context))
        try snapshot.validate()
        return snapshot
    }

    func selecting(appIDs: Set<UUID>) throws -> BackupSnapshot {
        let roots = Set(apps.filter { appIDs.contains($0.id) }.map { $0.parentAppID ?? $0.id })
        let selectedApps = apps.filter { roots.contains($0.parentAppID ?? $0.id) }
        let selectedIDs = Set(selectedApps.map(\.id))
        let teamIDs = Set(selectedApps.map(\.team))
        let selectedRecords = credentials.filter { $0.isTeamShared ? teamIDs.contains($0.team) : $0.app.map(selectedIDs.contains) == true }
        let result = BackupSnapshot(version: version, createdAt: createdAt, appVersion: appVersion, teams: teams.filter { teamIDs.contains($0.id) }, apps: selectedApps, credentials: selectedRecords)
        try result.validate()
        return result
    }

    func revision() throws -> String {
        let ordered = BackupSnapshot(version: version, createdAt: Date(timeIntervalSinceReferenceDate: 0), appVersion: "",
                                     teams: teams.sorted { $0.id.uuidString < $1.id.uuidString },
                                     apps: apps.sorted { $0.id.uuidString < $1.id.uuidString },
                                     credentials: credentials.sorted { $0.id.uuidString < $1.id.uuidString }, preferences: preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return BackupArchive.digest(try encoder.encode(ordered))
    }

    func validate() throws {
        guard apps.allSatisfy({ ($0.note?.utf8.count ?? 0) <= 65536 }), credentials.allSatisfy({ ($0.note?.utf8.count ?? 0) <= 65536 }) else { throw BackupError.tooLarge }
        guard version == 1, teams.count <= 1000, apps.count <= 10000, credentials.count <= 10000,
              Set(teams.map(\.id)).count == teams.count, Set(teams.map(\.teamID)).count == teams.count,
              Set(apps.map(\.id)).count == apps.count, Set(credentials.map(\.id)).count == credentials.count,
              Set(credentials.map(\.registrationKey)).count == credentials.count else { throw BackupError.invalid }
        let teamIDs = Set(teams.map(\.id))
        let teamValues = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0) })
        let appValues = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let appTeams = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.team) })
        for team in teams {
            guard !team.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  team.teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw BackupError.invalid }
        }
        var appKeys = Set<String>()
        var iconBytes = 0
        var customBytes = 0
        for app in apps {
            try AppSecret.validate(app.customSecrets ?? [])
            customBytes += (app.customSecrets ?? []).reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
            guard customBytes <= BackupArchive.maximumPayloadBytes / 4 else { throw BackupError.tooLarge }
            let bytes = app.iconImage?.count ?? 0
            iconBytes += bytes
            guard bytes <= 1_048_576, iconBytes <= BackupArchive.maximumPayloadBytes / 4, app.iconColor.map(AppCatalog.iconColors.contains) ?? true else { throw BackupError.tooLarge }
            guard teamIDs.contains(app.team), !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  app.bundleID.range(of: AppCatalog.bundleIDPattern, options: .regularExpression) != nil,
                  AppCatalog.platforms.contains(app.platform),
                  appKeys.insert(app.team.uuidString + ":" + app.bundleID.lowercased()).inserted else { throw BackupError.invalid }
        }
        for app in apps {
            if let parentID = app.parentAppID {
                guard parentID != app.id, let parent = appValues[parentID], parent.team == app.team,
                      parent.parentAppID == nil, parent.deletedAt == nil || app.deletedAt != nil else { throw BackupError.invalid }
            }
        }
        var totalBytes = 0
        for record in credentials {
            totalBytes += record.original.count
            guard totalBytes <= BackupArchive.maximumPayloadBytes / 2 else { throw BackupError.tooLarge }
            guard teamIDs.contains(record.team), !record.original.isEmpty, record.original.count <= CredentialParser.maximumBytes,
                  BackupArchive.digest(record.original) == record.digest,
                  record.isTeamShared ? record.app == nil : record.app.map({ appTeams[$0] == record.team }) == true,
                  record.hasSavedPassword == (record.password != nil),
                  record.password == nil || record.fileExtension == "p12" else { throw BackupError.invalid }
            let shared = ["cer", "p12", "p8"].contains(record.fileExtension)
            let expectedKey = "\(record.team)|\(shared ? "team" : record.app?.uuidString ?? "")|\(record.digest)"
            guard ["cer", "p12", "p8", "mobileprovision", "provisionprofile"].contains(record.fileExtension),
                  record.isTeamShared == shared, record.registrationKey == expectedKey,
                  !record.name.isEmpty, !record.originalName.isEmpty,
                  (record.originalName as NSString).lastPathComponent == record.originalName,
                  (record.originalName as NSString).pathExtension.lowercased() == record.fileExtension,
                  record.password.map({ $0.utf8.count <= 4096 }) ?? true,
                  record.sourceTeamID == nil || teamValues[record.team]?.teamID == record.sourceTeamID else { throw BackupError.invalid }
            if !shared {
                guard let appID = record.app, let app = appValues[appID], let bundle = record.bundleID,
                      CredentialVault.profileMatches(bundle, bundleID: app.bundleID) else { throw BackupError.invalid }
            }
            if record.fileExtension == "p8" {
                guard let raw = record.keyPurpose, let purposes = P8Purpose.purposes(stored: raw), let keyID = record.keyID else { throw BackupError.invalid }
                let metadata = try P8Metadata(purposes: purposes, keyID: keyID, issuerID: record.issuerID).validated()
                guard metadata.issuerID == record.issuerID, metadata.storedPurpose == raw else { throw BackupError.invalid }
            } else if record.keyPurpose != nil || record.keyID != nil || record.issuerID != nil { throw BackupError.invalid }
        }
    }
}

enum BackupError: LocalizedError {
    case invalid, tooLarge, password, passwordRequired, derivation
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "バックアップの形式または整合性を確認できません。既存データは変更していません。")
        case .tooLarge: String(localized: "このバックアップのサイズ上限を超えています。現在の上限は元ファイル合計32MiB・payload 64MiBです。")
        case .password: String(localized: "パスワードが違うか、バックアップが破損しています。")
        case .passwordRequired: String(localized: "バックアップ用パスワードを6文字以上、UTF-8で1,024バイト以内で入力してください。")
        case .derivation: String(localized: "バックアップの暗号鍵を作成できませんでした。")
        }
    }
}

// v1: 8-byte magic, 4-byte big-endian header size, JSON header, payload.
// The exact header bytes (including prefix) are authenticated; never re-encode them on read.
enum BackupArchive {
    static let maximumPayloadBytes = 64 * 1024 * 1024
    static let maximumFileBytes = maximumPayloadBytes + 8192
    static let iterations: UInt32 = 600_000
    private static let magic = Data("XKEYS\0\0\0".utf8)
    struct Header: Codable {
        let version: Int
        let protection: String
        let payloadLength: Int
        let kdf: String?
        let salt: Data?
        let iterations: UInt32?
        let sha256: String?
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ snapshot: BackupSnapshot, password: String?) throws -> Data {
        try snapshot.validate()
        let payload = try JSONEncoder().encode(snapshot)
        guard payload.count <= maximumPayloadBytes else { throw BackupError.tooLarge }
        let salt = password == nil ? nil : SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let header = Header(version: 1, protection: password == nil ? "none" : "password",
                            payloadLength: payload.count + (password == nil ? 0 : 28),
                            kdf: password == nil ? nil : "PBKDF2-HMAC-SHA256", salt: salt,
                            iterations: password == nil ? nil : iterations,
                            sha256: password == nil ? digest(payload) : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(header)
        let size = UInt32(bytes.count)
        let prefix = magic + Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + bytes
        if let password, let salt {
            let key = try derive(password: password, salt: salt)
            let sealed = try AES.GCM.seal(payload, using: key, authenticating: prefix)
            guard let combined = sealed.combined else { throw BackupError.invalid }
            return prefix + combined
        }
        return prefix + payload
    }

    private static func header(in data: Data) throws -> (Header, Int) {
        guard data.count <= maximumFileBytes else { throw BackupError.tooLarge }
        guard data.count >= 12, data.prefix(8) == magic else { throw BackupError.invalid }
        let size = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= 4096, 12 + size <= data.count else { throw BackupError.invalid }
        let offset = 12 + size
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data[12..<offset]) }
        catch { throw BackupError.invalid }
        guard header.version == 1, header.payloadLength >= 0, header.payloadLength <= maximumPayloadBytes + 28,
              header.payloadLength == data.count - offset else { throw BackupError.invalid }
        switch header.protection {
        case "password":
            guard header.kdf == "PBKDF2-HMAC-SHA256", header.salt?.count == 16,
                  header.iterations == iterations, header.sha256 == nil, header.payloadLength >= 28 else { throw BackupError.invalid }
        case "none":
            guard header.kdf == nil, header.salt == nil, header.iterations == nil,
                  header.sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw BackupError.invalid }
        default: throw BackupError.invalid
        }
        return (header, offset)
    }

    static func requiresPassword(_ data: Data) throws -> Bool { try header(in: data).0.protection == "password" }

    static func decode(_ data: Data, password: String?) throws -> BackupSnapshot {
        let (header, offset) = try header(in: data)
        let bytes = Data(data[offset...])
        let payload: Data
        switch header.protection {
        case "password":
            guard let salt = header.salt else { throw BackupError.invalid }
            guard let password else { throw BackupError.password }
            let key = try derive(password: password, salt: salt)
            do { payload = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: data.prefix(offset)) }
            catch { throw BackupError.password }
        case "none":
            guard header.sha256 == digest(bytes) else { throw BackupError.invalid }
            payload = bytes
        default: throw BackupError.invalid
        }
        guard payload.count <= maximumPayloadBytes else { throw BackupError.tooLarge }
        let snapshot: BackupSnapshot
        do { snapshot = try JSONDecoder().decode(BackupSnapshot.self, from: payload) }
        catch { throw BackupError.invalid }
        try snapshot.validate()
        return snapshot
    }

    private static func derive(password: String, salt: Data) throws -> SymmetricKey {
        var input = Array(password.utf8)
        guard password.count >= 6, input.count <= 1024 else { throw BackupError.passwordRequired }
        var output = [UInt8](repeating: 0, count: 32)
        defer {
            _ = input.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let result = input.withUnsafeBytes { secret in
            salt.withUnsafeBytes { salt in
                output.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress!.assumingMemoryBound(to: Int8.self), secret.count,
                                        salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                        iterations, output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard result == kCCSuccess else { throw BackupError.derivation }
        return SymmetricKey(data: output)
    }
}
