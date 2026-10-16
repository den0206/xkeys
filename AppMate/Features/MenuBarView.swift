import AppKit
import SwiftData
import SwiftUI

@MainActor @Observable
final class AppNavigation {
    var request: UUID = UUID()
    var menuVisible = true
    var scope: CredentialScope = .all

    func show(_ scope: CredentialScope) {
        self.scope = scope
        request = UUID()
    }
}

struct AppMateMenu: View {
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow
    @Query private var apps: [ManagedApp]
    @Query private var records: [StoredCredential]
    @Query private var changes: [BackupChange]
    @Query private var checkpoints: [BackupCheckpoint]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let summary = MenuBarSummary(records: records, at: timeline.date)
            VStack(alignment: .leading, spacing: 14) {
                Text("App Mate").font(.headline)
                Button("期限切れ \(summary.expired)件") { show(.expired) }
                Button("30日以内に期限 \(summary.expiring)件") { show(.expiring) }
                Button("すべての鍵とファイル \(summary.total)件") { show(.all) }
                Divider()
                if let checkpoint = checkpoints.first {
                    let history = BackupHistorySummary(changes: changes, checkpoint: checkpoint, hasStoredItems: !apps.isEmpty || !records.isEmpty)
                    Text("未バックアップの変更 \(history.pendingCount)件").font(.caption).foregroundStyle(.secondary)
                }
                Text("アプリの実行中に表示します。終了中の常駐・自動起動は行いません。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("メイン画面を開く") { show(.all) }
                    Spacer()
                    Button("終了") { NSApplication.shared.terminate(nil) }
                }
            }.padding(18).frame(width: 300)
        }
    }

    private func show(_ scope: CredentialScope) {
        navigation.show(scope)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "App Mate" && $0.canBecomeMain }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else { openWindow(id: "main") }
        NSApplication.shared.activate()
    }
}
