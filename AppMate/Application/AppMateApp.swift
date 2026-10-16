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
            case .failure:
                ContentUnavailableView("保存領域を開けません", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("既存データを変更せずに停止しました。保存先とアクセス権を確認して再起動してください。"))
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1232, height: 752)
        .commands { VerificationCommands() }

        Settings {
            if case .success(let container) = container { AppSettingsView(container: container).modelContainer(container) }
        }

        Window("技術検証", id: "verification") {
            if case .success(let container) = container {
                VerificationView(container: container)
            }
        }
        .defaultSize(width: 1000, height: 700)
    }
}

private struct VerificationCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("技術検証を開く") { openWindow(id: "verification") }
        }
    }
}
