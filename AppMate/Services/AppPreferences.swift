import Foundation
import SwiftData

struct CITemplate: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var variable: String
    var value: CIValue
}

enum CIValue: String, Codable, CaseIterable, Sendable {
    case base64, keyID, issuerID, teamID, password
    var title: String {
        switch self {
        case .base64: "元ファイルのbase64"
        case .keyID: "Key ID"
        case .issuerID: "Issuer ID"
        case .teamID: "Team ID"
        case .password: ".p12パスワード"
        }
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var showDockBadge = true
    var templates: [CITemplate] = [
        CITemplate(id: UUID(uuidString: "00000000-0000-0000-0001-000000000001")!, name: "GitHub Actions · 秘密鍵", variable: "ASC_KEY_P8_BASE64", value: .base64),
        CITemplate(id: UUID(uuidString: "00000000-0000-0000-0001-000000000002")!, name: "Key ID", variable: "ASC_KEY_ID", value: .keyID),
        CITemplate(id: UUID(uuidString: "00000000-0000-0000-0001-000000000003")!, name: "Issuer ID", variable: "ASC_ISSUER_ID", value: .issuerID),
        CITemplate(id: UUID(uuidString: "00000000-0000-0000-0001-000000000004")!, name: "Team ID", variable: "APPLE_TEAM_ID", value: .teamID),
        CITemplate(id: UUID(uuidString: "00000000-0000-0000-0001-000000000005")!, name: "証明書パスワード", variable: "P12_PASSWORD", value: .password)
    ]

    func validate() throws {
        guard templates.count <= 100, Set(templates.map(\.id)).count == templates.count,
              templates.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256 && $0.variable.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil }) else { throw BackupError.invalid }
    }
}

@MainActor enum PreferencesStore {
    static func read(in context: ModelContext) throws -> AppPreferences {
        guard let bytes = try context.fetch(FetchDescriptor<BackupCheckpoint>()).first?.preferencesData else { return AppPreferences() }
        let value = try JSONDecoder().decode(AppPreferences.self, from: bytes)
        try value.validate()
        return value
    }

    static func assign(_ value: AppPreferences, in context: ModelContext) throws {
        try value.validate()
        try BackupHistory.prepare(in: context)
        guard let row = try context.fetch(FetchDescriptor<BackupCheckpoint>()).first else { throw BackupError.invalid }
        row.preferencesData = try JSONEncoder().encode(value)
    }

    static func save(_ value: AppPreferences, in context: ModelContext) throws {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        try value.validate()
        guard try read(in: context) != value else { return }
        context.autosaveEnabled = false
        do {
            try assign(value, in: context)
            BackupHistory.record(in: context)
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
