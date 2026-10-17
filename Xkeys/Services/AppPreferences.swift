import Foundation
import SwiftData

enum CIValue: CaseIterable {
    case base64, keyID, issuerID, password
    var title: String {
        switch self {
        case .base64: String(localized: "元ファイルのbase64")
        case .keyID: "Key ID"
        case .issuerID: "Issuer ID"
        case .password: String(localized: ".p12パスワード")
        }
    }
}

// Older versions also stored CI templates here; decoding ignores that key.
struct AppPreferences: Codable, Equatable, Sendable {
    var showDockBadge = true
}

@MainActor enum PreferencesStore {
    static func read(in context: ModelContext) throws -> AppPreferences {
        guard let bytes = try context.fetch(FetchDescriptor<BackupCheckpoint>()).first?.preferencesData else { return AppPreferences() }
        return try JSONDecoder().decode(AppPreferences.self, from: bytes)
    }

    static func assign(_ value: AppPreferences, in context: ModelContext) throws {
        try BackupHistory.prepare(in: context)
        guard let row = try context.fetch(FetchDescriptor<BackupCheckpoint>()).first else { throw BackupError.invalid }
        row.preferencesData = try JSONEncoder().encode(value)
    }

    static func save(_ value: AppPreferences, in context: ModelContext) throws {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        guard try read(in: context) != value else { return }
        context.autosaveEnabled = false
        do {
            try assign(value, in: context)
            BackupHistory.record(in: context)
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
