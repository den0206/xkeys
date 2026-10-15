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
}

enum RegistrationError: LocalizedError {
    case nameRequired, invalidTeamID, duplicateTeam, invalidBundleID, duplicateApp, invalidPlatform, teamMissing

    var errorDescription: String? {
        switch self {
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

    func addApp(name: String, bundleID: String, platform: String, teamID: UUID, iconColor: String? = nil, iconImage: Data? = nil) throws -> UUID {
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
        do {
            try BackupHistory.prepare(in: context)
            let app = ManagedApp(name: name, bundleID: bundleID, platform: platform, team: team)
            app.iconColor = iconColor
            app.iconImage = iconImage
            context.insert(app)
            BackupHistory.record(in: context)
            try context.save()
            return app.id
        } catch { context.rollback(); throw error }
    }
}
