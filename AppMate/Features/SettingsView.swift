import SwiftData
import SwiftUI

struct AppSettingsView: View {
    let container: ModelContainer
    @State private var preferences = AppPreferences()
    @State private var error: String?
    @State private var loaded = false
    @State private var selectedTemplate: UUID?
    @State private var apple = AppleDeveloperSession.shared
    @State private var section = "一般"
    @State private var creatingBackup = false
    @State private var restoringBackup = false
    private let sections = ["一般", "セキュリティ", "CIテンプレート", "バックアップ"]

    init(container: ModelContainer, appleSession: AppleDeveloperSession = .shared, initialSection: String = "一般") {
        self.container = container
        _apple = State(initialValue: appleSession)
        _section = State(initialValue: initialSection)
    }

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
                        case "一般":
                            settingsGroup("表示") {
                                settingsToggle("Dockアイコンに件数を表示", isOn: $preferences.showDockBadge)
                            }
                            Text("Apple Developerへの接続は利用者の操作時に行います。同期・自動起動は行いません。元ファイルは変更しません。")
                                .foregroundStyle(AppMateStyle.secondary)
                        case "セキュリティ":
                            settingsGroup("Apple Developer") {
                                AppleDeveloperAccountView(session: apple).padding(14)
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
                        catch BackupError.invalid { self.error = "テンプレートの名前と変数名（英字か_で始まる英数字・_、128文字以内）を確認してください。" }
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
    private var templates: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CIコピーの変数名と値の種類を設定します。秘密値は保存しません。")
            ForEach($preferences.templates) { $template in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("名前", text: $template.name)
                    TextField("変数名", text: $template.variable).font(.body.monospaced())
                    HStack {
                        // Team ID is never copied; keep it selectable only for templates saved by older versions.
                        Picker("値", selection: $template.value) { ForEach(CIValue.allCases.filter { $0 != .teamID || template.value == .teamID }, id: \.self) { Text($0.title).tag($0) } }
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

}

struct AppleDeveloperAccountView: View {
    let session: AppleDeveloperSession
    var compact = false
    @State private var showingLogin = false
    @State private var error: String?

    var body: some View {
        Group {
            if compact {
                Menu {
                    Text(session.connected ? "ログイン中" : session.hasSavedSession ? "前回のログイン" : "未ログイン")
                    if let account = session.currentAccount ?? session.savedAccount { Text(account.label) }
                    accountActions
                    if let error { Text(error) }
                } label: {
                    Label((session.currentAccount ?? session.savedAccount)?.label ?? "Apple Developerにログイン", systemImage: "person.crop.circle")
                        .font(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 180, alignment: .leading)
                }.menuStyle(.borderlessButton)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(session.connected ? "ログイン中のApple Account" : session.hasSavedSession ? "前回ログインしたApple Account" : "ログインしていません",
                          systemImage: session.connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.headline)
                    if let account = session.currentAccount ?? session.savedAccount {
                        Text(account.label).font(.system(size: 17, weight: .semibold))
                            .textSelection(.enabled)
                        if let email = account.email, let name = account.name, email != name {
                            Text(name).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if !session.connected {
                        Text(session.hasSavedSession
                             ? "保存したログイン情報を次回のオンライン操作で使用します。期限が切れている場合は再ログインが必要です。"
                             : "Apple Developerにログインして所属チームを確認できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack { accountActions }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .task {
            do { try session.loadSavedAccount() }
            catch { self.error = AppleDeveloperError.message(for: error) }
        }
        .sheet(isPresented: $showingLogin) {
            AppleDeveloperLoginView(onVerified: {}, session: session,
                                    verificationTitle: "所属チーム", restoreSavedSession: false)
                .onChange(of: session.connected) { _, connected in
                    if connected { showingLogin = false }
                }
        }
    }
    @ViewBuilder
    private var accountActions: some View {
        Button(session.hasSavedSession || session.connected ? "再ログイン…" : "ログイン…") {
            session.useAnotherAccount()
            showingLogin = true
        }.disabled(session.busy)
        if session.hasSavedSession && !session.connected {
            Button("ログイン状態を確認") {
                Task {
                    do { try await session.resume(); error = nil }
                    catch { self.error = AppleDeveloperError.message(for: error) }
                }
            }.disabled(session.busy)
        }
        if session.hasSavedSession || session.connected {
            Button("ログアウト", role: .destructive) {
                do { try session.disconnect(); error = nil }
                catch { self.error = AppleDeveloperError.message(for: error) }
            }
        }
        if session.busy { ProgressView().controlSize(.small) }
    }

}
