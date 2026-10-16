import CryptoKit
import Foundation
import SwiftData

@MainActor
struct VaultManagement {
    let vault: CredentialVault
    private var context: ModelContext { vault.context }

    static func noteAAD(_ app: ManagedApp) -> Data {
        Data("AppMate-AppNote-v1|\(app.id)|\(app.team?.id.uuidString ?? "")".utf8)
    }

    func readNote(_ app: ManagedApp, key: SymmetricKey) throws -> String? {
        guard app.modelContext === context else { throw VaultError.invalidAssociation }
        guard let id = app.noteBlobID else { return nil }
        let bytes = try vault.blobs.read(id, key: key, authenticating: Self.noteAAD(app))
        guard bytes.count <= 65536, let value = String(data: bytes, encoding: .utf8) else { throw ValidationError.invalidFile }
        return value
    }

    func saveNote(_ note: String, app: ManagedApp, key: SymmetricKey, beforeCommit: () throws -> Void = {}) throws {
        guard note.utf8.count <= 65536, app.modelContext === context else { throw ValidationError.tooLarge }
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        let id = UUID()
        var staged = false
        do {
            try BackupHistory.prepare(in: context)
            try vault.blobs.write(Data(note.utf8), id: id, key: key, authenticating: Self.noteAAD(app))
            staged = true
            app.noteBlobID = id
            BackupHistory.record(in: context)
            try beforeCommit()
            try context.save()
        } catch {
            context.rollback()
            if staged { try? FileManager.default.removeItem(at: vault.blobs.file(id)) }
            throw error
        }
    }

    func saveNote(_ note: String, record: StoredCredential, key: SymmetricKey, beforeCommit: () throws -> Void = {}) throws {
        guard record.modelContext === context else { throw VaultError.invalidAssociation }
        guard note.utf8.count <= 65536 else { throw ValidationError.tooLarge }
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        var payload = try vault.read(record, key: key)
        payload.note = note
        let id = UUID()
        var staged = false
        do {
            try BackupHistory.prepare(in: context)
            record.blobID = id
            try vault.blobs.write(JSONEncoder().encode(payload), id: id, key: key, authenticating: record.authenticatedData())
            staged = true
            _ = try vault.read(record, key: key)
            BackupHistory.record(in: context)
            try beforeCommit()
            try context.save()
        } catch {
            context.rollback()
            if staged { try? FileManager.default.removeItem(at: vault.blobs.file(id)) }
            throw error
        }
    }

    // Purposes are authenticated data, so the payload is re-encrypted under a new blob before the reference switches.
    func updatePurposes(_ record: StoredCredential, metadata: P8Metadata, key: SymmetricKey, beforeCommit: () throws -> Void = {}) throws {
        guard record.modelContext === context, record.fileExtension == "p8", record.deletedAt == nil, let keyID = record.keyID else {
            throw VaultError.invalidAssociation
        }
        // Backups require a replacement pair to share purposes; keep that rule instead of loosening the format.
        guard record.replacesCredentialID == nil, record.replacedByID == nil else { throw ManagementError.purposeLocked }
        let value = try P8Metadata(purposes: metadata.purposes, keyID: keyID, issuerID: metadata.issuerID).validated()
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        let payload = try vault.read(record, key: key)
        guard value.storedPurpose != record.keyPurpose || value.issuerID != record.issuerID else { return }
        context.autosaveEnabled = false
        let id = UUID()
        var staged = false
        do {
            try BackupHistory.prepare(in: context)
            record.metadataVersion = 2
            record.keyPurpose = value.storedPurpose
            record.issuerID = value.issuerID
            record.name = "\(value.title)（\(keyID)）"
            record.kind = value.title
            record.blobID = id
            try vault.blobs.write(JSONEncoder().encode(payload), id: id, key: key, authenticating: record.authenticatedData())
            staged = true
            _ = try vault.read(record, key: key)
            BackupHistory.record(in: context)
            try beforeCommit()
            try context.save()
        } catch {
            context.rollback()
            if staged { try? FileManager.default.removeItem(at: vault.blobs.file(id)) }
            throw error
        }
    }

    func change(_ operation: () throws -> Void) throws {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        context.autosaveEnabled = false
        do {
            try BackupHistory.prepare(in: context)
            try operation()
            BackupHistory.record(in: context)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func trash(_ record: StoredCredential, key: SymmetricKey, at now: Date = .now) throws {
        try trash([record], key: key, at: now)
    }

    func trash(_ records: [StoredCredential], key: SymmetricKey, at now: Date = .now) throws {
        guard !records.isEmpty else { return }
        for record in records {
            guard record.modelContext === context else { throw VaultError.invalidAssociation }
            _ = try vault.read(record, key: key)
        }
        try change {
            for record in records { record.deletedAt = now }
        }
    }

    func trash(_ app: ManagedApp, key: SymmetricKey, at now: Date = .now) throws {
        guard app.modelContext === context else { throw VaultError.invalidAssociation }
        let targets = app.parentAppID == nil ? app.targets : [app]
        let ids = Set(targets.map(\.id))
        let owned = try vault.records().filter { $0.app.map { ids.contains($0.id) } == true && $0.deletedAt == nil }
        for record in owned { _ = try vault.read(record, key: key) }
        try change {
            for target in targets { target.deletedAt = now }
            for record in owned { record.deletedAt = now }
        }
    }

    func restore(_ app: ManagedApp) throws {
        guard app.modelContext === context else { throw VaultError.invalidAssociation }
        if let parentAppID = app.parentAppID,
           app.team?.apps.first(where: { $0.id == parentAppID })?.deletedAt != nil { throw ManagementError.parentDeleted }
        let deletedAt = app.deletedAt
        let targets = [app] + (app.parentAppID == nil ? app.team?.apps.filter { $0.parentAppID == app.id && $0.deletedAt == deletedAt } ?? [] : [])
        let ids = Set(targets.map(\.id))
        let owned = try vault.records().filter { $0.app.map { ids.contains($0.id) } == true && $0.deletedAt == deletedAt }
        try change {
            for target in targets { target.deletedAt = nil }
            for record in owned { record.deletedAt = nil }
        }
    }

    func restore(_ record: StoredCredential) throws {
        guard record.modelContext === context else { throw VaultError.invalidAssociation }
        guard record.app?.deletedAt == nil else { throw ManagementError.parentDeleted }
        try change { record.deletedAt = nil }
    }

    func removeTeam(_ team: DeveloperTeam) throws {
        guard team.apps.isEmpty, try !vault.records().contains(where: { $0.team?.id == team.id }) else { throw ManagementError.teamNotEmpty }
        try change { context.delete(team) }
    }

    // The database commits first; unreferenced encrypted bytes are collected by recover().
    func purge(records: [StoredCredential], apps: [ManagedApp], at now: Date = .now, expiredOnly: Bool = false, key: SymmetricKey? = nil) throws {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let all = try vault.records()
        let children = Dictionary(grouping: all, by: { $0.app?.id })
        let selectedIDs = Set(records.filter { $0.deletedAt.map { !expiredOnly || $0 <= cutoff } ?? false }.map(\.id))
        let selectedApps = apps.filter { app in
            guard app.deletedAt.map({ !expiredOnly || $0 <= cutoff }) == true else { return false }
            return !expiredOnly || (children[app.id] ?? []).allSatisfy { $0.deletedAt.map { $0 <= cutoff } == true }
        }
        let appIDs = Set(selectedApps.map(\.id))
        let selected = all.filter { record in
            record.app.map { appIDs.contains($0.id) } == true || selectedIDs.contains(record.id)
        }
        guard !selected.isEmpty || !selectedApps.isEmpty else { return }
        let deletedIDs = Set(selected.map(\.id))
        let survivors = all.filter { !deletedIDs.contains($0.id) && $0.replacesCredentialID.map(deletedIDs.contains) == true }
        if !survivors.isEmpty && key == nil { throw ManagementError.replacementInUse }
        let payloads = try survivors.map { record -> (StoredCredential, CredentialPayload) in
            guard let key else { throw ManagementError.replacementInUse }
            return (record, try vault.read(record, key: key))
        }
        var staged: [UUID] = []
        do {
            try change {
                for (record, payload) in payloads {
                    guard let key else { throw ManagementError.replacementInUse }
                    record.replacesCredentialID = nil
                    let id = UUID()
                    record.blobID = id
                    try vault.blobs.write(JSONEncoder().encode(payload), id: id, key: key, authenticating: record.authenticatedData())
                    staged.append(id)
                    _ = try vault.read(record, key: key)
                }
                for record in all where record.replacedByID.map(deletedIDs.contains) == true { record.replacedByID = nil }
                for record in selected { context.delete(record) }
                for app in try context.fetch(FetchDescriptor<ManagedApp>()) where app.parentAppID.map(appIDs.contains) == true && !appIDs.contains(app.id) {
                    app.parentAppID = nil
                }
                for app in selectedApps { app.team = nil; context.delete(app) }
            }
        } catch {
            for id in staged { try? FileManager.default.removeItem(at: vault.blobs.file(id)) }
            throw error
        }
        try vault.recover()
    }
    func pruneExpired(key: SymmetricKey? = nil) throws {
        try purge(records: vault.records(), apps: context.fetch(FetchDescriptor<ManagedApp>()), expiredOnly: true, key: key)
    }
}

enum ManagementError: LocalizedError {
    case parentDeleted, teamNotEmpty, replacementInUse, purposeLocked
    var errorDescription: String? {
        switch self {
        case .parentDeleted: "先に、所属するアプリを復元してください。"
        case .teamNotEmpty: "Appまたは共有資格情報が残っているTeamは削除できません。最近削除した項目も確認してください。"
        case .replacementInUse: "置き換え履歴で参照されています。新旧の関連項目を一緒に完全削除してください。"
        case .purposeLocked: "置き換え履歴のある鍵は、バックアップとの整合性を保つため用途を変更できません。"
        }
    }
}
