import CryptoKit
import Foundation
import SwiftData

enum RestoreError: LocalizedError {
    case identity, stale, choices, relationships, pendingChanges
    var errorDescription: String? {
        switch self {
        case .identity: "同じ識別子が異なるTeam・App・ファイルを指しています。既存データを保護するため、このバックアップはまとめられません。"
        case .stale: "確認後に現在のデータが変更されました。「差分を更新」で確認し直してください。"
        case .choices: "内容が異なる項目ごとに、どちらを使うか選択してください。"
        case .relationships: "選択した内容では置き換え履歴などの関連が一致しません。関連する項目の選択を確認してください。"
        case .pendingChanges: "別の操作が保存待ちです。その操作を完了してから復元してください。"
        }
    }
}

enum RestoreChoice: String, CaseIterable { case current, backup }

struct RestorePlan: Sendable {
    enum Kind: String, Sendable { case team, app, credential, preferences }
    enum State: Sendable { case added, duplicate, conflict }
    struct Item: Identifiable, Sendable {
        let kind: Kind
        let target: UUID
        let title: String
        let detail: String
        let current: String?
        let incoming: String
        let state: State
        var id: String { kind.rawValue + ":" + target.uuidString }
    }
    static let preferencesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let incoming: BackupSnapshot
    let localRevision: String
    let items: [Item]
    var conflicts: [Item] { items.filter { $0.state == .conflict } }
    var addedCount: Int { items.filter { $0.state == .added }.count }
    var duplicateCount: Int { items.filter { $0.state == .duplicate }.count }

    static func make(incoming source: BackupSnapshot, current: BackupSnapshot) throws -> RestorePlan {
        try source.validate()
        try current.validate()
        let localTeams = Dictionary(uniqueKeysWithValues: current.teams.map { ($0.id, $0) })
        let localTeamIDs = Dictionary(uniqueKeysWithValues: current.teams.map { ($0.teamID, $0) })
        let localApps = Dictionary(uniqueKeysWithValues: current.apps.map { ($0.id, $0) })
        let localAppKeys = Dictionary(uniqueKeysWithValues: current.apps.map { ($0.team.uuidString + ":" + $0.bundleID.lowercased(), $0) })
        let localCredentials = Dictionary(uniqueKeysWithValues: current.credentials.map { ($0.id, $0) })
        let localCredentialKeys = Dictionary(uniqueKeysWithValues: current.credentials.map { ($0.registrationKey, $0) })
        var teamIDs: [UUID: UUID] = [:]
        var appIDs: [UUID: UUID] = [:]
        var credentialIDs: [UUID: UUID] = [:]
        for team in source.teams {
            if let local = localTeams[team.id], local.teamID != team.teamID { throw RestoreError.identity }
            teamIDs[team.id] = (localTeams[team.id] ?? localTeamIDs[team.teamID])?.id ?? team.id
        }
        for app in source.apps {
            guard let team = teamIDs[app.team] else { throw BackupError.invalid }
            if let local = localApps[app.id], local.team != team || local.bundleID.lowercased() != app.bundleID.lowercased() {
                throw RestoreError.identity
            }
            appIDs[app.id] = (localApps[app.id] ?? localAppKeys[team.uuidString + ":" + app.bundleID.lowercased()])?.id ?? app.id
        }
        func key(for record: BackupSnapshot.Credential) throws -> String {
            guard let team = teamIDs[record.team] else { throw BackupError.invalid }
            let scope: String
            if record.isTeamShared { scope = "team" }
            else if let app = record.app.flatMap({ appIDs[$0] }) { scope = app.uuidString }
            else { throw BackupError.invalid }
            return "\(team)|\(scope)|\(record.digest)"
        }
        for record in source.credentials {
            let registrationKey = try key(for: record)
            let local = localCredentials[record.id] ?? localCredentialKeys[registrationKey]
            if let local, local.registrationKey != registrationKey || local.fileExtension != record.fileExtension || local.isTeamShared != record.isTeamShared {
                throw RestoreError.identity
            }
            credentialIDs[record.id] = local?.id ?? record.id
        }
        let teams = try source.teams.map { value -> BackupSnapshot.Team in
            guard let id = teamIDs[value.id] else { throw BackupError.invalid }
            return .init(id: id, name: value.name, teamID: value.teamID)
        }
        let apps = try source.apps.map { value -> BackupSnapshot.App in
            guard let id = appIDs[value.id], let team = teamIDs[value.team] else { throw BackupError.invalid }
            return .init(id: id, name: value.name, bundleID: value.bundleID, platform: value.platform, team: team, createdAt: value.createdAt, deletedAt: value.deletedAt, note: value.note, iconColor: value.iconColor, iconImage: value.iconImage)
        }
        let credentials = try source.credentials.map { value -> BackupSnapshot.Credential in
            guard let id = credentialIDs[value.id], let team = teamIDs[value.team] else { throw BackupError.invalid }
            return .init(id: id, registrationKey: try key(for: value), name: value.name, kind: value.kind,
                         originalName: value.originalName, fileExtension: value.fileExtension, digest: value.digest,
                         fingerprint: value.fingerprint, sourceTeamID: value.sourceTeamID, bundleID: value.bundleID,
                         expiresAt: value.expiresAt, createdAt: value.createdAt, isTeamShared: value.isTeamShared,
                         hasSavedPassword: value.hasSavedPassword, team: team, app: value.app.flatMap { appIDs[$0] },
                         metadataVersion: value.metadataVersion, keyPurpose: value.keyPurpose, keyID: value.keyID,
                         issuerID: value.issuerID, replacesCredentialID: value.replacesCredentialID.flatMap { credentialIDs[$0] },
                         replacedByID: value.replacedByID.flatMap { credentialIDs[$0] }, original: value.original, password: value.password, note: value.note, deletedAt: value.deletedAt, revokedAt: value.revokedAt)
        }
        let normalized = BackupSnapshot(version: source.version, createdAt: source.createdAt, appVersion: source.appVersion,
                                        teams: teams, apps: apps, credentials: credentials, preferences: source.preferences)
        try normalized.validate()
        var items: [Item] = []
        for team in teams {
            let local = localTeams[team.id]
            items.append(Item(kind: .team, target: team.id, title: "Team · \(team.teamID)", detail: "表示名",
                              current: local?.name, incoming: team.name,
                              state: local == nil ? .added : local == team ? .duplicate : .conflict))
        }
        for app in apps {
            let local = localApps[app.id]
            func summary(_ value: BackupSnapshot.App) -> String { "\(value.name) · \(value.bundleID) · \(value.platform) · 登録 \(value.createdAt.formatted())" }
            items.append(Item(kind: .app, target: app.id, title: "App · \(app.bundleID)", detail: "表示名・プラットフォーム・アイコン・登録日時・メモ（非表示）・削除状態",
                              current: local.map(summary), incoming: summary(app),
                              state: local == nil ? .added : local == app ? .duplicate : .conflict))
        }
        for record in credentials {
            let local = localCredentials[record.id]
            var differences: [String] = []
            if let local, local != record {
                if local.name != record.name || local.originalName != record.originalName { differences.append("名前") }
                if local.note != record.note { differences.append("暗号化メモ（値は非表示）") }
                if local.deletedAt != record.deletedAt || local.revokedAt != record.revokedAt { differences.append("削除・手動失効状態") }
                if local.password != record.password { differences.append("保存済みパスワード（値は非表示）") }
                if local.replacesCredentialID != record.replacesCredentialID || local.replacedByID != record.replacedByID { differences.append("置き換え履歴") }
                if local.keyID != record.keyID || local.issuerID != record.issuerID || local.keyPurpose != record.keyPurpose { differences.append("鍵の識別情報") }
                if differences.isEmpty { differences.append("期限・登録日時などのメタデータ") }
            }
            func summary(_ value: BackupSnapshot.Credential) -> String {
                "\(value.name) · \(value.originalName) · \(value.replacedByID == nil ? "通常一覧" : "置き換え済み")"
            }
            items.append(Item(kind: .credential, target: record.id, title: "資格情報 · \(record.originalName)",
                              detail: differences.joined(separator: "・"), current: local.map(summary), incoming: summary(record),
                              state: local == nil ? .added : local == record ? .duplicate : .conflict))
        }
        if let prefs = source.preferences {
            items.append(Item(kind: .preferences, target: preferencesID, title: "アプリ設定", detail: "通知・表示・CIテンプレート", current: "このMacの設定（秘密値なし）", incoming: "バックアップの設定（秘密値なし）", state: prefs == (current.preferences ?? AppPreferences()) ? .duplicate : .conflict))
        }
        return RestorePlan(incoming: normalized, localRevision: try current.revision(), items: items)
    }

    func merged(with current: BackupSnapshot, choices: [String: RestoreChoice]) throws -> BackupSnapshot {
        guard try current.revision() == localRevision else { throw RestoreError.stale }
        guard conflicts.allSatisfy({ choices[$0.id] != nil }) else { throw RestoreError.choices }
        let selected = Set(items.filter { $0.state == .added || ($0.state == .conflict && choices[$0.id] == .backup) }.map(\.id))
        var teams = Dictionary(uniqueKeysWithValues: current.teams.map { ($0.id, $0) })
        var apps = Dictionary(uniqueKeysWithValues: current.apps.map { ($0.id, $0) })
        var credentials = Dictionary(uniqueKeysWithValues: current.credentials.map { ($0.id, $0) })
        for value in incoming.teams where selected.contains("team:" + value.id.uuidString) { teams[value.id] = value }
        for value in incoming.apps where selected.contains("app:" + value.id.uuidString) { apps[value.id] = value }
        for value in incoming.credentials where selected.contains("credential:" + value.id.uuidString) { credentials[value.id] = value }
        let result = BackupSnapshot(version: 2, createdAt: .now, appVersion: current.appVersion,
                                    teams: Array(teams.values), apps: Array(apps.values), credentials: Array(credentials.values), preferences: selected.contains("preferences:" + Self.preferencesID.uuidString) ? incoming.preferences : current.preferences)
        do { try result.validate() }
        catch BackupError.tooLarge { throw BackupError.tooLarge }
        catch { throw RestoreError.relationships }
        return result
    }
}

@MainActor
struct BackupRestore {
    let vault: CredentialVault

    struct Result {
        let added: Int
        let updated: Int
        let skipped: Int
    }

    func prepare(_ snapshot: BackupSnapshot, key: SymmetricKey) throws -> RestorePlan {
        try RestorePlan.make(incoming: snapshot, current: BackupSnapshot.capture(vault: vault, key: key))
    }

    func merge(_ plan: RestorePlan, choices: [String: RestoreChoice], key: SymmetricKey,
               beforeCommit: () throws -> Void = {}, safetyBackup: SafetyBackup? = nil) throws -> Result {
        let context = vault.context
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        let current = try BackupSnapshot.capture(vault: vault, key: key)
        let final: BackupSnapshot
        if let safetyBackup {
            guard try current.revision() == plan.localRevision, safetyBackup.revision == plan.localRevision else { throw RestoreError.stale }
            var replacement = plan.incoming
            replacement.version = 2
            if replacement.preferences == nil { replacement.preferences = current.preferences }
            final = replacement
            try final.validate()
        } else { final = try plan.merged(with: current, choices: choices) }
        guard try JSONEncoder().encode(final).count <= BackupArchive.maximumPayloadBytes else { throw BackupError.tooLarge }
        var teams = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DeveloperTeam>()).map { ($0.id, $0) })
        var apps = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ManagedApp>()).map { ($0.id, $0) })
        var records = Dictionary(uniqueKeysWithValues: try vault.records().map { ($0.id, $0) })
        let oldCredentials = Dictionary(uniqueKeysWithValues: current.credentials.map { ($0.id, $0) })
        var staged: [UUID] = []
        context.autosaveEnabled = false
        do {
            try BackupHistory.prepare(in: context)
            for value in final.teams {
                if let team = teams[value.id] { team.name = value.name }
                else {
                    let team = DeveloperTeam(name: value.name, teamID: value.teamID)
                    team.id = value.id
                    context.insert(team)
                    teams[value.id] = team
                }
            }
            for value in final.apps {
                guard let team = teams[value.team] else { throw BackupError.invalid }
                if let app = apps[value.id] {
                    app.name = value.name
                    app.bundleID = value.bundleID
                    app.platform = value.platform
                    app.iconColor = value.iconColor
                    app.iconImage = value.iconImage
                    app.createdAt = value.createdAt
                    app.deletedAt = value.deletedAt
                } else {
                    let app = ManagedApp(name: value.name, bundleID: value.bundleID, platform: value.platform, team: team)
                    app.id = value.id
                    app.iconColor = value.iconColor
                    app.iconImage = value.iconImage
                    app.createdAt = value.createdAt
                    app.deletedAt = value.deletedAt
                    context.insert(app)
                    apps[value.id] = app
                }
            }
            let oldApps = Dictionary(uniqueKeysWithValues: current.apps.map { ($0.id, $0) })
            for value in final.apps where value.note != oldApps[value.id]?.note {
                guard let app = apps[value.id] else { throw BackupError.invalid }
                if let note = value.note, !note.isEmpty {
                    let id = UUID()
                    try vault.blobs.write(Data(note.utf8), id: id, key: key, authenticating: VaultManagement.noteAAD(app))
                    staged.append(id)
                    app.noteBlobID = id
                } else { app.noteBlobID = nil }
            }
            if final.preferences != current.preferences, let prefs = final.preferences {
                try PreferencesStore.assign(prefs, in: context)
            }
            // No suspension between staging and the single database commit: recovery cannot remove pending blobs.
            for value in final.credentials where oldCredentials[value.id] != value {
                guard let team = teams[value.team] else { throw BackupError.invalid }
                let record: StoredCredential
                if let existing = records[value.id] {
                    existing.apply(value)
                    record = existing
                } else {
                    record = StoredCredential(restoring: value, team: team, app: value.app.flatMap { apps[$0] })
                    context.insert(record)
                    records[value.id] = record
                }
                let blobID = UUID()
                record.blobID = blobID
                let payload = CredentialPayload(original: value.original, password: value.password, note: value.note)
                try vault.blobs.write(JSONEncoder().encode(payload), id: blobID, key: key, authenticating: record.authenticatedData())
                staged.append(blobID)
                _ = try vault.read(record, key: key)
            }
            if safetyBackup != nil {
                let keepRecords = Set(final.credentials.map(\.id))
                let keepApps = Set(final.apps.map(\.id))
                let keepTeams = Set(final.teams.map(\.id))
                for record in records.values where !keepRecords.contains(record.id) { context.delete(record) }
                for app in apps.values where !keepApps.contains(app.id) { app.team = nil; context.delete(app) }
                for team in teams.values where !keepTeams.contains(team.id) { context.delete(team) }
            }
            if safetyBackup != nil || plan.addedCount > 0 || plan.conflicts.contains(where: { choices[$0.id] == .backup }) {
                BackupHistory.record(in: context)
            }
            try beforeCommit()
            try context.save()
        } catch {
            context.rollback()
            for id in staged { try? FileManager.default.removeItem(at: vault.blobs.file(id)) }
            throw error
        }
        // Old blob versions are retained until commit; ordinary launch recovery collects them.
        let updated = plan.conflicts.filter { choices[$0.id] == .backup }.count
        return Result(added: plan.addedCount, updated: updated, skipped: plan.duplicateCount + plan.conflicts.count - updated)
    }
}
