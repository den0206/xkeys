import AppKit
import SwiftData
import SwiftUI
import UserNotifications

struct AppSettingsView: View {
    let container: ModelContainer
    @State private var preferences = AppPreferences()
    @State private var error: String?
    @State private var loaded = false
    @State private var selectedTemplate: UUID?
    var body: some View {
        TabView {
            Form {
                Toggle("メニューバーに表示", isOn: $preferences.showMenuBar)
                Toggle("Dockにまもなく期限の件数を表示", isOn: $preferences.showDockBadge)
                Text("秘密情報の操作はTouch IDまたはMacのパスワードで毎回認証します。5分間の無操作・スリープ・画面ロックで秘密表示を閉じます。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("外部通信・同期・自動起動は行いません。元ファイルは変更しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }.tabItem { Label("一般・安全", systemImage: "gearshape") }
            Form {
                Toggle("ローカル通知を有効にする", isOn: $preferences.notificationsEnabled)
                ForEach([30, 7, 1, 0], id: \.self) { day in
                    Toggle(day == 0 ? "期限当日" : "\(day)日前", isOn: Binding(get: { preferences.expirationDays.contains(day) }, set: { on in
                        preferences.expirationDays.removeAll { $0 == day }; if on { preferences.expirationDays.append(day) }
                    }))
                }
                Toggle("未バックアップ変更を通知", isOn: Binding(get: { preferences.backupReminderDays != nil }, set: { preferences.backupReminderDays = $0 ? 7 : nil }))
                if preferences.backupReminderDays != nil {
                    Stepper("変更から\(preferences.backupReminderDays ?? 7)日後", value: Binding(get: { preferences.backupReminderDays ?? 7 }, set: { preferences.backupReminderDays = $0 }), in: 1...365)
                }
                Text(NotificationService.shared.message).font(.caption)
                Button("Macで通知を許可する") {
                    Task { @MainActor in
                        do {
                            guard ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1" else { return }
                            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                            await NotificationService.shared.refresh(context: container.mainContext, records: try container.mainContext.fetch(FetchDescriptor<StoredCredential>()), changes: try container.mainContext.fetch(FetchDescriptor<BackupChange>()))
                        } catch { self.error = error.localizedDescription }
                    }
                }
                Button("システム設定を開く") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                Text("通知 → App Mateで許可を確認してください。終了中の通知補充・配送は保証されません。")
                    .font(.caption).foregroundStyle(.secondary)
            }.tabItem { Label("通知", systemImage: "bell") }
            VStack(alignment: .leading) {
                Text("CIコピーの変数名と値の種類を設定します。秘密値は保存しません。")
                List(selection: $selectedTemplate) {
                    ForEach($preferences.templates) { $template in
                        HStack {
                            TextField("名前", text: $template.name)
                            TextField("変数名", text: $template.variable).font(.body.monospaced())
                            Picker("値", selection: $template.value) { ForEach(CIValue.allCases, id: \.self) { Text($0.title).tag($0) } }
                        }.tag(template.id)
                    }
                }
                HStack {
                    Button("追加") { preferences.templates.append(CITemplate(name: "新しいテンプレート", variable: "NEW_SECRET", value: .base64)) }.disabled(preferences.templates.count >= 100)
                    Button("削除") { preferences.templates.removeAll { $0.id == selectedTemplate } }.disabled(selectedTemplate == nil)
                }
            }.tabItem { Label("CIテンプレート", systemImage: "terminal") }
        }
        .padding(20).frame(width: 690, height: 450)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("設定を保存") {
                    do { try PreferencesStore.save(preferences, in: container.mainContext); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(!loaded)
            }.padding()
        }
        .task {
            do { preferences = try PreferencesStore.read(in: container.mainContext); loaded = true }
            catch { self.error = error.localizedDescription }
        }
    }
}
