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
    @State private var apple = AppleDeveloperSession.shared
    @State private var section = "通知"
    @State private var creatingBackup = false
    @State private var restoringBackup = false
    private let sections = ["一般", "通知", "セキュリティ", "CIテンプレート", "バックアップ"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.self) { title in
                    Button { section = title } label: {
                        Text(title).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(section == title ? AppMateStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 10).padding(.top, 14).frame(width: 200).background(AppMateStyle.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                Text(section).font(.system(size: 20, weight: .bold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch section {
                        case "通知": notifications
                        case "一般":
                            settingsGroup("表示") {
                                settingsToggle("Dockアイコンに件数を表示", isOn: $preferences.showDockBadge)
                                Divider()
                                settingsToggle("メニューバーに表示", isOn: $preferences.showMenuBar)
                            }
                            Text("Apple Developerへの接続は利用者の操作時に行います。同期・自動起動は行いません。元ファイルは変更しません。")
                                .foregroundStyle(AppMateStyle.secondary)
                        case "セキュリティ":
                            settingsGroup("Apple Developer") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(apple.connected ? "接続中" : "未接続（オンライン操作時に保存済みの接続を確認します）")
                                    Text("接続情報はこのMacのKeychainに保存します。再起動・画面ロック・スリープでは削除しません。")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("接続を解除") {
                                        do { try apple.disconnect(); error = nil }
                                        catch { self.error = AppleDeveloperError.message(for: error) }
                                    }
                                }.padding(14)
                            }

                            settingsGroup("このMacの認証") {
                                Label("Touch ID またはMacのパスワードで確認します", systemImage: "lock.shield").padding(14)
                                Divider()
                                LabeledContent("自動ロック", value: "5分後").padding(14)
                            }
                            Text("秘密情報の操作は毎回認証します。5分間の無操作・スリープ・画面ロックで秘密表示を閉じます。")
                                .foregroundStyle(AppMateStyle.secondary)
                        case "CIテンプレート": templates
                        default:
                            Text("すべてのデータを1つのファイルにまとめます。別のMacへの移行にも使えます。")
                                .foregroundStyle(AppMateStyle.secondary)
                            Button("バックアップを作る…") { creatingBackup = true }.buttonStyle(AppMateButtonStyle(primary: true))
                            Button("復元・移行…") { restoringBackup = true }.buttonStyle(AppMateButtonStyle())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Button("設定を保存") {
                        do { try PreferencesStore.save(preferences, in: container.mainContext); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(AppMateButtonStyle(primary: true)).disabled(!loaded)
                }
            }.padding(.horizontal, 30).padding(.vertical, 26).frame(maxWidth: .infinity)
        }
        .font(.system(size: 13)).foregroundStyle(AppMateStyle.text).background(AppMateStyle.canvas)
        .tint(AppMateStyle.accent).frame(width: 852, height: 592)
        .sheet(isPresented: $creatingBackup) { BackupView(container: container) }
        .sheet(isPresented: $restoringBackup) { BackupView(container: container, restoring: true) }
        .task {
            do { preferences = try PreferencesStore.read(in: container.mainContext); loaded = true }
            catch { self.error = error.localizedDescription }
        }
    }
    private var notifications: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsGroup("期限のお知らせ") {
                ForEach([30, 7, 1, 0], id: \.self) { day in
                    settingsToggle(day == 0 ? "当日" : day == 1 ? "前日" : "\(day)日前", isOn: Binding(get: { preferences.expirationDays.contains(day) }, set: { on in
                        preferences.expirationDays.removeAll { $0 == day }
                        if on { preferences.expirationDays.append(day) }
                    }))
                    if day != 0 { Divider() }
                }
            }
            Text("通知はこのMac内で予約します。Macの通知許可が必要です。")
                .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).padding(.top, -12)
            settingsGroup("バックアップのお知らせ") {
                settingsToggle("バックアップしていない変更があるとき知らせる", isOn: Binding(get: { preferences.backupReminderDays != nil }, set: { preferences.backupReminderDays = $0 ? 7 : nil }))
                if preferences.backupReminderDays != nil {
                    Divider()
                    Stepper("変更してから \(preferences.backupReminderDays ?? 7)日後", value: Binding(get: { preferences.backupReminderDays ?? 7 }, set: { preferences.backupReminderDays = $0 }), in: 1...365).padding(.horizontal, 14).padding(.vertical, 9)
                }
            }
            settingsGroup("表示") {
                settingsToggle("Dockアイコンに件数を表示", isOn: $preferences.showDockBadge)
                Divider()
                settingsToggle("メニューバーに表示", isOn: $preferences.showMenuBar)
            }
            settingsGroup("通知の許可") {
                settingsToggle("ローカル通知を有効にする", isOn: $preferences.notificationsEnabled)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(NotificationService.shared.message).font(.caption)
                    HStack {
                        Button("Macで通知を許可する", action: requestNotifications)
                        Button("システム設定を開く") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                    }.buttonStyle(AppMateButtonStyle())
                    Text("通知 → App Mateで許可を確認してください。終了中の通知補充・配送は保証されません。")
                        .font(.caption).foregroundStyle(AppMateStyle.secondary)
                }.padding(14)
            }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CIコピーの変数名と値の種類を設定します。秘密値は保存しません。")
            ForEach($preferences.templates) { $template in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名前", text: $template.name)
                    TextField("変数名", text: $template.variable).font(.body.monospaced())
                    HStack {
                        Picker("値", selection: $template.value) { ForEach(CIValue.allCases, id: \.self) { Text($0.title).tag($0) } }
                        Button("削除", role: .destructive) { preferences.templates.removeAll { $0.id == template.id } }
                    }
                }.textFieldStyle(.roundedBorder).padding(14)
                    .background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
            }
            Button("追加") { preferences.templates.append(CITemplate(name: "新しいテンプレート", variable: "NEW_SECRET", value: .base64)) }
                .disabled(preferences.templates.count >= 100)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .bold))
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppMateStyle.border, lineWidth: 1))
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 10)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.checkbox)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func requestNotifications() {
        Task { @MainActor in
            do {
                guard ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1" else { return }
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await NotificationService.shared.refresh(context: container.mainContext, records: try container.mainContext.fetch(FetchDescriptor<StoredCredential>()), changes: try container.mainContext.fetch(FetchDescriptor<BackupChange>()))
            } catch { self.error = error.localizedDescription }
        }
    }

}
