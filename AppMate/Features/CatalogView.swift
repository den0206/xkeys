import SwiftData
import SwiftUI

enum CredentialScope: Hashable {
    case all, expired, expiring, trash, credential(UUID), app(UUID), shared(P8Purpose)

    var title: String {
        switch self {
        case .trash: "最近削除した項目"
        case .credential: "資格情報"
        case .all: "すべての鍵とファイル"
        case .expired: "期限切れ"
        case .expiring: "30日以内に期限"
        case .app: "App"
        case .shared(let purpose): purpose.title + " の鍵"
        }
    }
}

struct CatalogView: View {
    let container: ModelContainer
    let navigation: AppNavigation
    @Query(sort: \DeveloperTeam.name) private var teams: [DeveloperTeam]
    @Query(sort: \ManagedApp.name) private var apps: [ManagedApp]
    @Query private var credentials: [StoredCredential]
    @Query private var changes: [BackupChange]
    @Query private var checkpoints: [BackupCheckpoint]
    @State private var selection: CredentialScope? = .all
    @State private var selectedTeam: UUID?
    @State private var addingTeam = false
    @State private var addingApp = false
    @State private var addingFile = false
    @State private var creatingBackup = false
    @State private var restoringBackup = false
    @State private var historyError: String?
    @FocusState private var searchFocused: Bool
    @State private var clock = Date.now
    @State private var search = ""
    @State private var editingTeam: DeveloperTeam?
    @State private var editingApp: ManagedApp?
    @State private var onboarding = false
    @AppStorage("AppMate.onboardingCompleted") private var onboardingCompleted = false
    @State private var typeFilter: CredentialTypeFilter = .all

    private var selectedApp: ManagedApp? {
        guard case .app(let id) = selection else { return nil }
        return apps.first { $0.id == id }
    }
    private var active: [StoredCredential] { credentials.filter { $0.replacedByID == nil && $0.deletedAt == nil && $0.app?.deletedAt == nil } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("まとめて見る") {
                    summary("期限切れ", symbol: "exclamationmark.circle", scope: .expired,
                            count: active.filter { $0.displayState(at: clock) == .expired }.count)
                    summary("30日以内に期限", symbol: "clock", scope: .expiring,
                            count: active.filter { $0.displayState(at: clock).needsRenewal }.count)
                    summary("すべて", symbol: "square.grid.2x2", scope: .all, count: active.count)
                    Label("最近削除した項目", systemImage: "trash").tag(CredentialScope.trash)
                }
                Section("アプリ") {
                    ForEach(apps.filter { $0.deletedAt == nil }) { app in
                        HStack(spacing: 9) {
                            Image(systemName: app.platform == "macOS" ? "macwindow" : "app.fill")
                                .foregroundStyle(Color.accentColor).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).lineLimit(1)
                                if teams.count > 1 { Text(app.team?.name ?? "").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 2)
                            if active.contains(where: { $0.isVisible(in: app) && $0.displayState(at: clock) == .expired }) {
                                Text("期限切れ").font(.caption2).foregroundStyle(.red)
                            } else if active.contains(where: { $0.isVisible(in: app) && $0.displayState(at: clock).needsRenewal }) {
                                Text("注意").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .tag(CredentialScope.app(app.id))
                        .contextMenu { Button("Appを編集…") { editingApp = app } }
                    }
                }
                Section("チーム") {
                    ForEach(teams) { team in Button(team.name) { editingTeam = team }.buttonStyle(.plain).help("チームを編集") }
                }
                Section("複数のアプリで使う鍵") {
                    Label("App Store Connect の鍵", systemImage: "lock")
                        .tag(CredentialScope.shared(.appStoreConnect))
                    Label("プッシュ通知の鍵", systemImage: "lock")
                        .tag(CredentialScope.shared(.apns))
                    Label("Sign in with Apple の鍵", systemImage: "lock")
                        .tag(CredentialScope.shared(.signInWithApple))
                }
            }
            .font(.system(size: 13))
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("App Mate")
            .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("アプリを追加…", systemImage: "plus") { addingApp = true }.disabled(teams.isEmpty)
                    Button("チームを追加…", systemImage: "plus") { addingTeam = true }
                    Divider()
                    if let historyError {
                        Text(historyError).foregroundStyle(.red).font(.caption)
                        Button("変更状態を再確認", action: loadHistory)
                    } else if let checkpoint = checkpoints.first {
                        let history = BackupHistorySummary(changes: changes, checkpoint: checkpoint)
                        Label("未バックアップの変更 \(history.pendingCount)件", systemImage: history.pendingCount > 0 ? "externaldrive.badge.exclamationmark" : "checkmark.circle")
                            .font(.caption).foregroundStyle(history.pendingCount > 0 ? Color.orange : .secondary)
                        if let date = history.lastCompletedAt {
                            Text("前回：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        } else { Text("バックアップの記録なし").font(.caption2).foregroundStyle(.secondary) }
                    } else {
                        Text("バックアップ状態を確認中…").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("バックアップを作る…", systemImage: "externaldrive") { creatingBackup = true }
                    Button("バックアップから復元…", systemImage: "arrow.counterclockwise") { restoringBackup = true }
                }
                .buttonStyle(.borderless).font(.system(size: 12)).padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if selection == .trash {
                TrashView(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)))
            } else if teams.isEmpty {
                ContentUnavailableView {
                    Label("チームを登録してください", systemImage: "person.2")
                } description: {
                    Text("Apple Developerのチームを登録して、アプリと鍵を管理しましょう。")
                } actions: {
                    Button("チームを追加") { addingTeam = true }
                }
            } else if apps.filter({ $0.deletedAt == nil }).isEmpty && active.isEmpty {
                ContentUnavailableView {
                    Label("アプリを追加しましょう", systemImage: "app.dashed")
                } description: {
                    Text("名前・Bundle ID・プラットフォームを登録すると、ファイルを追加できます。")
                } actions: {
                    Button("アプリを追加") { addingApp = true }
                }
            } else {
                CredentialAppView(app: CredentialSearch.hasQuery(search) ? nil : selectedApp, scope: selection ?? .all, container: container, importing: $addingFile, search: search, typeFilter: typeFilter)
                    .id(selection)
            }
        }
        .background(Button("横断検索へ移動") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true))
        .tint(Color(red: 10 / 255, green: 100 / 255, blue: 214 / 255))
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("アプリ・鍵・IDを横断検索", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 260).focused($searchFocused)
                    .accessibilityLabel("アプリ・鍵・IDを横断検索")
            }
            ToolbarItem {
                Picker("種類", selection: $typeFilter) {
                    ForEach(CredentialTypeFilter.allCases) { Text($0.title).tag($0) }
                }.frame(width: 160)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("ファイルを追加", systemImage: "plus") { addingFile = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedApp == nil || CredentialSearch.hasQuery(search))
                    .help(selectedApp == nil || CredentialSearch.hasQuery(search) ? "左側で追加先のアプリを選択してください" : "選択中のアプリへファイルを追加")
            }
        }
        .task {
            loadHistory()
            do { try VaultManagement(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))).pruneExpired() }
            catch ManagementError.replacementInUse { /* Re-encrypt surviving history after owner authentication. */ }
            catch { historyError = "削除済みデータの整理を完了できませんでした。再起動して確認してください。" }
            selection = navigation.scope
            onboarding = !onboardingCompleted && ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1"
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in clock = .now }
        .onChange(of: selection) { _, _ in search = "" }
        .onChange(of: navigation.request) { _, _ in
            search = ""
            typeFilter = .all
            selection = navigation.scope
        }
        .sheet(isPresented: $onboarding) {
            VStack(alignment: .leading, spacing: 20) {
                Text("App Mateへようこそ").font(.largeTitle.bold())
                Label("TeamとAppを登録して、証明書・鍵・プロファイルをまとめます", systemImage: "app")
                Label("秘密情報はこのMacで暗号化し、操作のたびにMacで認証します", systemImage: "lock.shield")
                Label("元ファイルは残します。バックアップはご自身で安全に保管してください", systemImage: "externaldrive")
                Text("Apple側の失効状態は照会しません。期限や手動失効を確認して管理してください。通知は「設定 → 通知」から許可できます。")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("始める") { onboardingCompleted = true; onboarding = false }.keyboardShortcut(.defaultAction) }
            }.padding(32).frame(width: 620)
        }
        .sheet(item: $editingTeam) { team in CatalogEditor(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), team: team, app: nil) }
        .sheet(item: $editingApp) { app in CatalogEditor(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), team: nil, app: app) }
        .sheet(isPresented: $restoringBackup) {
            RestoreView(container: container)
        }
        .sheet(isPresented: $creatingBackup) {
            BackupView(container: container)
        }
        .sheet(isPresented: $addingTeam) {
            RegistrationForm(container: container, teams: teams, initialTeam: selectedTeam, isTeam: true) { id in
                selectedTeam = id
                selection = .all
            }
        }
        .sheet(isPresented: $addingApp) {
            RegistrationForm(container: container, teams: teams, initialTeam: selectedApp?.team?.id ?? selectedTeam, isTeam: false) { id in
                selection = .app(id)
            }
        }
    }

    private func loadHistory() {
        do { try BackupHistory.bootstrap(in: container.mainContext); historyError = nil }
        catch { historyError = "バックアップの変更状態を確認できません。再確認してください。" }
    }

    private func summary(_ title: String, symbol: String, scope: CredentialScope, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(count.formatted()).foregroundStyle(.secondary).font(.caption)
        }.tag(scope)
    }
}

private struct RegistrationForm: View {
    let container: ModelContainer
    let teams: [DeveloperTeam]
    let initialTeam: UUID?
    let isTeam: Bool
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var identifier = ""
    @State private var platform = "iOS"
    @State private var teamID: UUID?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isTeam ? "Teamを追加" : "Appを追加").font(.title2.bold())
            Form {
                TextField("表示名", text: $name).focused($nameFocused)
                TextField(isTeam ? "Team ID" : "Bundle ID", text: $identifier)
                    .font(.body.monospaced())
                if isTeam {
                    Text("Team IDは英大文字と数字の10文字です。Apple Developerの登録内容を確認してください。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Team", selection: $teamID) {
                        Text("選択してください").tag(nil as UUID?)
                        ForEach(teams) { team in
                            Text("\(team.name)（\(team.teamID)）").tag(Optional(team.id))
                        }
                    }
                    Picker("プラットフォーム", selection: $platform) {
                        ForEach(AppCatalog.platforms, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Bundle IDの例：com.example.app。同じTeam内では重複して登録できません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("登録", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || identifier.isEmpty || (!isTeam && teamID == nil))
            }
        }
        .padding(24).frame(width: 480)
        .onAppear {
            teamID = initialTeam ?? (teams.count == 1 ? teams.first?.id : nil)
            nameFocused = true
        }
    }

    private func save() {
        do {
            let catalog = AppCatalog(context: container.mainContext)
            let id: UUID
            if isTeam {
                id = try catalog.addTeam(name: name, teamID: identifier)
            } else {
                guard let teamID else { throw RegistrationError.teamMissing }
                id = try catalog.addApp(name: name, bundleID: identifier, platform: platform, teamID: teamID)
            }
            onSaved(id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
