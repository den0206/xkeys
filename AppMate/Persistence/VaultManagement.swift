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

    func setRevoked(_ record: StoredCredential, key: SymmetricKey) throws {
        guard record.modelContext === context else { throw VaultError.invalidAssociation }
        _ = try vault.read(record, key: key)
        try change { record.revokedAt = record.revokedAt == nil ? .now : nil }
    }

    func trash(_ record: StoredCredential, key: SymmetricKey, at now: Date = .now) throws {
        guard record.modelContext === context else { throw VaultError.invalidAssociation }
        _ = try vault.read(record, key: key)
        try change { record.deletedAt = now }
    }

    func trash(_ app: ManagedApp, key: SymmetricKey, at now: Date = .now) throws {
        guard app.modelContext === context else { throw VaultError.invalidAssociation }
        let owned = try vault.records().filter { $0.app?.id == app.id && $0.deletedAt == nil }
        for record in owned { _ = try vault.read(record, key: key) }
        try change {
            app.deletedAt = now
            for record in owned { record.deletedAt = now }
        }
    }

    func restore(_ app: ManagedApp) throws {
        guard app.modelContext === context else { throw VaultError.invalidAssociation }
        let deletedAt = app.deletedAt
        let owned = try vault.records().filter { $0.app?.id == app.id && $0.deletedAt == deletedAt }
        try change {
            app.deletedAt = nil
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
        let selectedApps = apps.filter { app in
            guard app.deletedAt.map({ !expiredOnly || $0 <= cutoff }) == true else { return false }
            return !expiredOnly || all.filter { $0.app?.id == app.id }.allSatisfy { $0.deletedAt.map { $0 <= cutoff } == true }
        }
        let appIDs = Set(selectedApps.map(\.id))
        let selected = all.filter { record in
            appIDs.contains(record.app?.id ?? UUID()) || records.contains(where: { $0.id == record.id && ($0.deletedAt.map { !expiredOnly || $0 <= cutoff } ?? false) })
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
    case parentDeleted, teamNotEmpty, replacementInUse
    var errorDescription: String? {
        switch self {
        case .parentDeleted: "先に、この資格情報が属するAppを復元してください。"
        case .teamNotEmpty: "Appまたは共有資格情報が残っているTeamは削除できません。最近削除した項目も確認してください。"
        case .replacementInUse: "置き換え履歴で参照されています。新旧の関連項目を一緒に完全削除してください。"
        }
    }
}
