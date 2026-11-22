import SwiftData

/// Every SwiftData model of the app. The container, `discardChanges()` and the tests read this one list.
enum XkeysSchema {
    static let models: [any PersistentModel.Type] = [
        DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
    ]

    static func container(inMemory: Bool) throws -> ModelContainer {
        try ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }
}
