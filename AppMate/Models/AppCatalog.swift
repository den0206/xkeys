import Foundation
import SwiftData

@Model
final class DeveloperTeam {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var teamID: String
    var name: String
    @Relationship(deleteRule: .deny, inverse: \ManagedApp.team) var apps: [ManagedApp] = []

    init(name: String, teamID: String) {
        id = UUID()
        self.name = name
        self.teamID = teamID
    }
}

@Model
final class ManagedApp {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var registrationKey: String
    var name: String
    var bundleID: String
    var platform: String
    var team: DeveloperTeam?
    var createdAt: Date
    var deletedAt: Date?
    var noteBlobID: UUID?
    var parentAppID: UUID?
    var iconColor: String?
    var iconImage: Data?

    init(name: String, bundleID: String, platform: String, team: DeveloperTeam) {
        id = UUID()
        registrationKey = team.id.uuidString + ":" + bundleID.lowercased()
        self.name = name
        self.bundleID = bundleID
        self.platform = platform
        self.team = team
        createdAt = .now
    }

    var product: ManagedApp {
        guard let parentAppID else { return self }
        return team?.apps.first { $0.id == parentAppID } ?? self
    }
    var targets: [ManagedApp] {
        let root = product
        return [root] + (root.team?.apps.filter { $0.parentAppID == root.id && $0.deletedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? [])
    }

    func target(forProfileBundleID bundleID: String) -> ManagedApp? {
        let candidates = product.targets
        if let exact = candidates.first(where: { $0.bundleID == bundleID }) { return exact }
        let matches = candidates.filter { CredentialVault.profileMatches(bundleID, bundleID: $0.bundleID) }
        return matches.count == 1 ? matches[0] : nil
    }

}

enum RegistrationError: LocalizedError {
    case nameRequired, invalidTeamID, duplicateTeam, invalidBundleID, duplicateApp, invalidPlatform, teamMissing, invalidParent

    var errorDescription: String? {
        switch self {
        case .invalidParent: "同じTeam内の、削除されていないアプリを選んでください。ターゲットを持つアプリは別のアプリの配下へ移動できません。"
        case .nameRequired: "表示名を入力してください。"
        case .invalidTeamID: "Team IDは英大文字と数字の10文字で入力してください。"
        case .duplicateTeam: "このTeam IDは登録済みです。既存のTeamを選択してください。"
        case .invalidBundleID: "Bundle IDは英数字・ハイフン・ピリオドで入力してください（例：com.example.app）。ワイルドカードは使えません。"
        case .duplicateApp: "このTeamには同じBundle IDのAppが登録されています。"
        case .invalidPlatform: "プラットフォームを選択してください。"
        case .teamMissing: "登録先のTeamを選択してください。"
        }
    }
}

@MainActor
struct AppCatalog {
    nonisolated static let iconColors = ["purple", "orange", "green", "blue"]
    static let platforms = ["iOS", "macOS", "iPadOS", "watchOS", "tvOS", "visionOS"]
    let context: ModelContext

    func registerRemoteTeam(_ remote: RemoteDeveloperTeam) throws -> UUID {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        if let existing = try context.fetch(FetchDescriptor<DeveloperTeam>()).first(where: { $0.teamID == remote.teamID }) {
            return existing.id
        }
        return try addTeam(name: remote.name, teamID: remote.teamID)
    }

    func addTeam(name: String, teamID: String) throws -> UUID {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let teamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RegistrationError.nameRequired }
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw RegistrationError.invalidTeamID
        }
        context.autosaveEnabled = false
        // shortcut: scan the local catalog; add indexed lookups when lists become paginated.
        let existing = try context.fetch(FetchDescriptor<DeveloperTeam>())
        guard !existing.contains(where: { $0.teamID == teamID }) else { throw RegistrationError.duplicateTeam }
        do {
            try BackupHistory.prepare(in: context)
            let team = DeveloperTeam(name: name, teamID: teamID)
            context.insert(team)
            BackupHistory.record(in: context)
            try context.save()
            return team.id
        } catch { context.rollback(); throw error }
    }

    func addApp(name: String, bundleID: String, platform: String, teamID: UUID, iconColor: String? = nil, iconImage: Data? = nil, parentAppID: UUID? = nil) throws -> UUID {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RegistrationError.nameRequired }
        guard bundleID.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*$", options: .regularExpression) != nil else {
            throw RegistrationError.invalidBundleID
        }
        guard Self.platforms.contains(platform) else { throw RegistrationError.invalidPlatform }
        guard (iconImage?.count ?? 0) <= 1_048_576, iconColor.map(Self.iconColors.contains) ?? true else { throw ValidationError.invalidFile }
        context.autosaveEnabled = false
        guard let team = try context.fetch(FetchDescriptor<DeveloperTeam>()).first(where: { $0.id == teamID }) else {
            throw RegistrationError.teamMissing
        }
        let key = teamID.uuidString + ":" + bundleID.lowercased()
        let existing = try context.fetch(FetchDescriptor<ManagedApp>())
        guard !existing.contains(where: { $0.registrationKey == key }) else { throw RegistrationError.duplicateApp }
        if let parentAppID {
            guard existing.contains(where: { $0.id == parentAppID && $0.team?.id == teamID && $0.parentAppID == nil && $0.deletedAt == nil }) else { throw RegistrationError.invalidParent }
        }
        do {
            try BackupHistory.prepare(in: context)
            let app = ManagedApp(name: name, bundleID: bundleID, platform: platform, team: team)
            app.parentAppID = parentAppID
            app.iconColor = iconColor
            app.iconImage = iconImage
            context.insert(app)
            BackupHistory.record(in: context)
            try context.save()
            return app.id
        } catch { context.rollback(); throw error }
    }

    func setParent(_ parentAppID: UUID?, for app: ManagedApp, name: String, platform: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RegistrationError.nameRequired }
        guard Self.platforms.contains(platform), app.modelContext === context, app.deletedAt == nil else { throw RegistrationError.invalidParent }
        let apps = try context.fetch(FetchDescriptor<ManagedApp>())
        if let parentAppID {
            guard parentAppID != app.id,
                  !apps.contains(where: { $0.parentAppID == app.id }),
                  apps.contains(where: { $0.id == parentAppID && $0.team?.id == app.team?.id && $0.parentAppID == nil && $0.deletedAt == nil }) else { throw RegistrationError.invalidParent }
        }
        try VaultManagement(vault: CredentialVault(context: context, blobs: EncryptedBlobStore(directory: CredentialVault.directory))).change {
            app.name = value
            app.platform = platform
            app.parentAppID = parentAppID
        }
    }

}
