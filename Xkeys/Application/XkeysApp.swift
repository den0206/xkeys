import SwiftData
import SwiftUI

@main
struct XkeysApp: App {
    @State private var navigation = AppNavigation()
    private let container: Result<ModelContainer, Error>

    init() {
        container = Result {
            let testing = ProcessInfo.processInfo.environment["XKEYS_TESTING"] == "1"
            return try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: testing))
        }
    }

    var body: some Scene {
        WindowGroup("Xkeys", id: "main") {
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
        // Opened .xkeysbackup files go to the restore window, never to a second main window.
        .handlesExternalEvents(matching: [])

        Window("バックアップから戻す", id: "restore") {
            if case .success(let container) = container {
                BackupView(container: container, restoring: true).modelContainer(container).preferredColorScheme(.light)
            }
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["xkeysbackup"])

        Settings {
            if case .success(let container) = container { AppSettingsView(container: container).modelContainer(container).preferredColorScheme(.light) }
        }
    }
}
