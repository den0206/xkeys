import SwiftData
import SwiftUI

@main
struct AppMateApp: App {
    @State private var navigation = AppNavigation()
    private let container: Result<ModelContainer, Error>

    init() {
        container = Result {
            let testing = ProcessInfo.processInfo.environment["APP_MATE_TESTING"] == "1"
            return try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, VerificationRecord.self, BackupChange.self, BackupCheckpoint.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: testing))
        }
    }

    var body: some Scene {
        WindowGroup("App Mate", id: "main") {
            switch container {
            case .success(let container):
                CatalogView(container: container, navigation: navigation)
                    .modelContainer(container)
                    .frame(minWidth: 960, minHeight: 640)
                    .preferredColorScheme(.light)
            case .failure:
                ContentUnavailableView("保存領域を開けません", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("既存データを変更せずに停止しました。保存先とアクセス権を確認して再起動してください。"))
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1232, height: 752)

        Settings {
            if case .success(let container) = container { AppSettingsView(container: container).modelContainer(container).preferredColorScheme(.light) }
        }
    }
}
