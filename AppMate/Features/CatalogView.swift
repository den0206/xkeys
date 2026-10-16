import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum CredentialScope: Hashable {
    case all, expired, expiring, trash, credential(UUID), app(UUID), team(UUID)

    var title: String {
        switch self {
        case .trash: "最近削除した項目"
        case .credential: "資格情報"
        case .all: "すべての鍵とファイル"
        case .expired: "期限切れ"
        case .expiring: "30日以内に期限"
        case .app: "App"
        case .team: "チームの鍵・証明書"
        }
    }
}

@MainActor @Observable
final class AppNavigation {
    var scope: CredentialScope = .all
}

struct CatalogView: View {
    let container: ModelContainer
    let navigation: AppNavigation
    var appleSession: AppleDeveloperSession = .shared
    @Query(sort: \DeveloperTeam.name) private var teams: [DeveloperTeam]
    @Query(sort: \ManagedApp.name) private var apps: [ManagedApp]
    @Query private var credentials: [StoredCredential]
    @Query private var changes: [BackupChange]
    @Query private var checkpoints: [BackupCheckpoint]
    @State private var selection: CredentialScope? = .all
    @State private var selectedTeam: UUID?
    @State private var addingTeam = false
    @State private var addingApp = false
    @State private var collapsedApps: Set<UUID> = []
    @State private var addingTarget: ManagedApp?
    @State private var addingFile = false
    @State private var onlineImportTeam: DeveloperTeam?
    @State private var creatingBackup = false
    @State private var restoringBackup = false
    @State private var historyError: String?
    @FocusState private var searchFocused: Bool
    @State private var clock = Date.now
    @State private var search = ""
    @State private var managingTeams = false
    @State private var deletingTeam: DeveloperTeam?
    @State private var editingTeam: DeveloperTeam?
    @State private var editingApp: ManagedApp?
    @State private var onboarding = false
    @State private var onboardingSources: [URL] = []
    @AppStorage("AppMate.onboardingCompleted") private var onboardingCompleted = false
    @State private var typeFilter: CredentialTypeFilter = .all

    private var selectedApp: ManagedApp? {
        guard case .app(let id) = selection else { return nil }
        return apps.first { $0.id == id }
    }
    private var credentialTeam: DeveloperTeam? {
        guard case .team(let id) = selection else { return selectedApp?.team }
        return teams.first { $0.id == id }
    }
    private var rootApps: [ManagedApp] { apps.filter { $0.deletedAt == nil && $0.parentAppID == nil } }
    private var sidebarApps: [ManagedApp] {
        rootApps.flatMap { collapsedApps.contains($0.id) ? [$0] : $0.targets }
    }
    private var pendingBackupCount: Int {
        guard historyError == nil, let checkpoint = checkpoints.first else { return 0 }
        return BackupHistorySummary(changes: changes, checkpoint: checkpoint,
                                    hasStoredItems: !apps.isEmpty || !credentials.isEmpty).pendingCount
    }
    private var active: [StoredCredential] { credentials.filter { $0.replacedByID == nil && $0.deletedAt == nil && $0.app?.deletedAt == nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 276)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppMateStyle.canvas)
        .foregroundStyle(AppMateStyle.text)
        .background(Button("横断検索へ移動") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true))
        .tint(AppMateStyle.accent)
        .task {
            loadHistory()
            do { try VaultManagement(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))).pruneExpired() }
            catch ManagementError.replacementInUse { /* Re-encrypt surviving history after owner authentication. */ }
            catch { historyError = "削除済みデータの整理を完了できませんでした。再起動して確認してください。" }
            selection = navigation.scope
            onboarding = !onboardingCompleted && ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1"
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in clock = .now }
        .onChange(of: dockBadgeLabel, initial: true) { _, label in
            guard ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1" else { return }
            NSApp.dockTile.badgeLabel = label
        }
        .onChange(of: selection) { _, _ in search = ""; typeFilter = .all }
        .onChange(of: trashCount) { _, count in
            if count == 0 && selection == .trash { selection = .all }
        }
        .onChange(of: selectedApp?.deletedAt) { _, deletedAt in
            if deletedAt != nil { selection = .all }
        }
        .sheet(isPresented: $onboarding, onDismiss: {
            guard !onboardingSources.isEmpty else { return }
            if let team = teams.first { selection = .team(team.id); addingFile = true }
            else { addingTeam = true }
        }) {
            OnboardingView { sources in
                onboardingSources = sources
                onboardingCompleted = true
                onboarding = false
            }
        }
        .onChange(of: addingFile) { _, shown in if !shown { onboardingSources = [] } }
        .sheet(isPresented: $managingTeams) {
            TeamManagementView(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), appleSession: appleSession) { id in
                if selection == .team(id) { selection = .all }
                if selectedTeam == id { selectedTeam = nil }
            }.modelContainer(container)
        }
        .sheet(item: $deletingTeam) { team in
            let id = team.id
            TeamDeletionView(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), team: team) {
                if selection == .team(id) { selection = .all }
                if selectedTeam == id { selectedTeam = nil }
            }
        }
        .sheet(item: $editingTeam) { team in CatalogEditor(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), team: team, app: nil) }
        .sheet(item: $editingApp) { app in CatalogEditor(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), team: nil, app: app) }
        .sheet(isPresented: $restoringBackup) {
            BackupView(container: container, restoring: true)
        }
        .sheet(isPresented: $creatingBackup) {
            BackupView(container: container)
        }
        .sheet(item: $onlineImportTeam) { team in
            AppleDeveloperImportView(team: team,
                                     vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)),
                                     session: appleSession) { _ in
                search = ""
                selection = .team(team.id)
            }.modelContainer(container)
        }
        .sheet(item: $addingTarget) { parent in
            RegistrationForm(container: container, teams: teams, initialTeam: parent.team?.id, isTeam: false, parentApp: parent) { id in
                selection = .app(id)
            }
        }
        .sheet(isPresented: $addingTeam, onDismiss: {
            if !onboardingSources.isEmpty, let selectedTeam { selection = .team(selectedTeam); addingFile = true } else { onboardingSources = [] }
        }) {
            RegistrationForm(container: container, teams: teams, initialTeam: selectedTeam, isTeam: true) { id in
                selectedTeam = id
                selection = .team(id)
            }
        }
        .sheet(isPresented: $addingApp, onDismiss: {
            if !onboardingSources.isEmpty && selectedApp != nil { addingFile = true } else { onboardingSources = [] }
        }) {
            RegistrationForm(container: container, teams: teams, initialTeam: credentialTeam?.id ?? selectedTeam, isTeam: false) { id in
                selection = .app(id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("App Mate").font(.system(size: 14, weight: .bold)).fixedSize()
                .padding(.leading, 78)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppMateStyle.secondary)
                TextField("アプリ・鍵・IDを横断検索", text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
            }
            .font(.system(size: 13)).padding(.horizontal, 10).frame(minWidth: 160, idealWidth: 320, maxWidth: 320).frame(height: 30)
            .background(AppMateStyle.search, in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 12)
            AppleDeveloperAccountView(session: appleSession, compact: true)
            Menu {
                if let historyError {
                    Text(historyError)
                    Button("変更状態を再確認", action: loadHistory)
                } else if let checkpoint = checkpoints.first {
                    let history = BackupHistorySummary(changes: changes, checkpoint: checkpoint, hasStoredItems: !apps.isEmpty || !credentials.isEmpty)
                    Text(history.pendingCount > 0 ? "未バックアップの変更：\(history.pendingCount)件" : "未バックアップの変更はありません")
                    if let date = history.lastCompletedAt {
                        Text("前回：" + date.formatted(date: .abbreviated, time: .shortened))
                    }
                } else { Text("バックアップ状態を確認中…") }
                Divider()
                Button("今すぐバックアップ…") { creatingBackup = true }
                Button("バックアップから復元…") { restoringBackup = true }
            } label: {
                Label("バックアップ", systemImage: "externaldrive")
            }.menuStyle(.borderlessButton).fixedSize()
                .overlay(alignment: .topTrailing) {
                    if pendingBackupCount > 0 {
                        Text(pendingBackupCount.formatted())
                            .font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white).padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                            .background(AppMateStyle.danger, in: Capsule())
                            .offset(x: 8, y: -10).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .padding(.trailing, pendingBackupCount > 0 ? 8 : 0)
                .accessibilityLabel(pendingBackupCount > 0 ? "バックアップ、未バックアップの変更が\(pendingBackupCount)件" : "バックアップ")
            Menu {
                Button("Macからファイルを追加…", systemImage: "folder") { addingFile = true }
                    .disabled(credentialTeam == nil || CredentialSearch.hasQuery(search))
                Menu("Apple Developerから取り込む…", systemImage: "icloud.and.arrow.down") {
                    ForEach(teams) { team in
                        Button(team.name + "（" + team.teamID + "）") { onlineImportTeam = team }
                    }
                }.disabled(teams.isEmpty)
            } label: {
                Label("ファイルを追加", systemImage: "plus")
            }.menuStyle(.borderlessButton).fixedSize()
                .help("Mac上のファイル、またはApple Developerから取り込みます")
        }.padding(.horizontal, 16).frame(height: 52).background(AppMateStyle.sidebar)
    }

    private var trashCount: Int { credentials.filter { $0.deletedAt != nil }.count + apps.filter { $0.deletedAt != nil }.count }
    private var expiredCount: Int { active.filter { $0.displayState(at: clock) == .expired }.count }
    private var expiringCount: Int { active.filter { $0.displayState(at: clock).needsRenewal }.count }
    private var dockBadgeLabel: String? {
        let show = checkpoints.first?.preferencesData.flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0).showDockBadge } ?? true
        return show && expiringCount > 0 ? String(expiringCount) : nil
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarHeading("まとめて見る")
                    if expiredCount > 0 {
                        sidebarItem("期限切れ", symbol: "square.fill", scope: .expired,
                                    count: expiredCount, color: AppMateStyle.danger)
                    }
                    if expiringCount > 0 {
                        sidebarItem("30日以内に期限", symbol: "circle.fill", scope: .expiring,
                                    count: expiringCount, color: Color(red: 224/255, green: 160/255, blue: 48/255))
                    }
                    sidebarItem("すべて", symbol: "circle", scope: .all, count: active.count)
                    if trashCount > 0 {
                        sidebarItem("最近削除した項目", symbol: "trash", scope: .trash, count: trashCount)
                    }
                    ForEach(teams) { team in
                        HStack(spacing: 4) {
                            sidebarHeading(team.name).lineLimit(1)
                                .help("\(team.name)（\(team.teamID)）")
                            Spacer(minLength: 0)
                            Menu {
                                Button("チームを編集…") { editingTeam = team }
                                Button("チームを削除…", role: .destructive) { deletingTeam = team }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.system(size: 14))
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel(team.name + "の編集・削除")
                                .help("チームの編集・削除")
                        }.padding(.top, 10).padding(.trailing, 8)
                        .contextMenu {
                            Button("チームを編集…") { editingTeam = team }
                            Button("チームを削除…", role: .destructive) { deletingTeam = team }
                        }
                        sidebarItem("チームの鍵・証明書", symbol: "key", scope: .team(team.id),
                                    count: active.filter { $0.isTeamShared && $0.team?.id == team.id }.count)
                        sidebarHeading("アプリ").padding(.top, 8)
                        ForEach(rootApps.filter { $0.team?.id == team.id }) { root in
                            VStack(alignment: .leading, spacing: 2) {
                                sidebarApp(root)
                                if !collapsedApps.contains(root.id) {
                                    ForEach(root.targets.dropFirst()) { target in sidebarApp(target).padding(.leading, 40) }
                                }
                            }.padding(.bottom, 6)
                        }
                    }

                }.font(.system(size: 13)).buttonStyle(.borderless).padding(.horizontal, 10).padding(.top, 14)
            }
            .focusable().focusEffectDisabled()
            .onMoveCommand { direction in
                let scopes: [CredentialScope] = (expiredCount > 0 ? [.expired] : []) + (expiringCount > 0 ? [.expiring] : []) + [.all] + (trashCount > 0 ? [.trash] : []) + teams.flatMap { team in
                    [.team(team.id)] + sidebarApps.filter { $0.team?.id == team.id }.map { .app($0.id) }
                }
                guard direction == .up || direction == .down else { return }
                let index = scopes.firstIndex { $0 == selection } ?? (direction == .down ? -1 : scopes.count)
                selection = scopes[min(max(index + (direction == .down ? 1 : -1), 0), scopes.count - 1)]
            }
            VStack(spacing: 8) {
                Divider().padding(.bottom, 4)
                Button { addingApp = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.app").frame(width: 16).foregroundStyle(AppMateStyle.accent)
                        Text("アプリを追加…")
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(AppMateButtonStyle()).disabled(teams.isEmpty)
                Button { addingTeam = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2.badge.plus").frame(width: 16).foregroundStyle(AppMateStyle.secondary)
                        Text("チームを追加…")
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(AppMateButtonStyle())
                Button("登録済みチームを管理…", systemImage: "person.2") { managingTeams = true }
                    .buttonStyle(AppMateButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 14).padding(.bottom, 14)
        }.background(AppMateStyle.sidebar)
    }

    private func sidebarApp(_ app: ManagedApp) -> some View {
        let isRoot = app.parentAppID == nil
        let grouped = isRoot && app.targets.count > 1
        let relevant = active.filter { record in
            !record.isTeamShared && (isRoot ? app.targets.contains { record.isVisible(in: $0) } : record.isVisible(in: app))
        }
        let expired = relevant.contains { $0.displayState(at: clock) == .expired }
        let attention = relevant.contains { $0.displayState(at: clock).needsRenewal }
        return HStack(alignment: .top, spacing: 0) {
            if grouped {
                Button {
                    if collapsedApps.contains(app.id) { collapsedApps.remove(app.id) }
                    else {
                        if let selectedApp, selectedApp.parentAppID == app.id { selection = .app(app.id) }
                        collapsedApps.insert(app.id)
                    }
                } label: {
                    Image(systemName: collapsedApps.contains(app.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 38)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(app.name + (collapsedApps.contains(app.id) ? "のターゲットを展開" : "のターゲットを折りたたむ"))
            } else if isRoot {
                Color.clear.frame(width: 22, height: 1).accessibilityHidden(true)
            }
            Button { selection = .app(app.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    if isRoot { AppIcon(app: app, size: 20).padding(.top, 2) }
                    else {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(AppMateStyle.secondary).frame(width: 18, height: 20)
                            .padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).fontWeight(isRoot ? .semibold : .regular)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(grouped ? "全\(app.targets.count)ターゲットを表示" : isRoot ? app.platform + " · 本体" : app.platform + " · ターゲット")
                            .font(.system(size: 10)).foregroundStyle(AppMateStyle.secondary)
                        if !isRoot || teams.count > 1 {
                            Text(isRoot ? app.team?.name ?? "" : app.bundleID)
                                .font(.system(size: 10)).foregroundStyle(AppMateStyle.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if expired || attention {
                        Image(systemName: expired ? "exclamationmark.circle.fill" : "clock")
                            .foregroundStyle(expired ? AppMateStyle.dangerText : AppMateStyle.warningText)
                            .help(expired ? "期限切れの資格情報があります" : "期限が近い資格情報があります")
                            .accessibilityLabel(expired ? "期限切れあり" : "期限間近")
                    }
                }.padding(.vertical, 8).padding(.trailing, 8)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(grouped ? app.name + "：本体と配下の全ターゲットを表示" : app.name + "\n" + app.bundleID)
                .accessibilityAddTraits(selection == .app(app.id) ? .isSelected : [])
                .contextMenu {
                    Button("ターゲットを追加…") { addingTarget = app.product }
                    Button("App・ターゲットを編集…") { editingApp = app }
                }
        }
        .padding(.leading, isRoot ? 0 : 8)
        .background(selection == .app(app.id) ? AppMateStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(AppMateStyle.secondary)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }

    private func sidebarItem(_ title: String, symbol: String, scope: CredentialScope, count: Int? = nil, color: Color = AppMateStyle.secondary) -> some View {
        Button { selection = scope } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(color).frame(width: 14)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if let count { Text(count.formatted()).font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(selection == scope ? AppMateStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == scope ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        if selection == .trash {
            TrashView(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)))
        } else if teams.isEmpty {
            ContentUnavailableView {
                Label("チームを登録してください", systemImage: "person.2")
            } description: {
                Text("Apple Developerのチームを登録して、アプリと鍵を管理しましょう。")
            } actions: { Button("チームを追加") { addingTeam = true } }
        } else {
            CredentialAppView(app: CredentialSearch.hasQuery(search) ? nil : selectedApp, team: CredentialSearch.hasQuery(search) ? nil : credentialTeam, openTeam: { id in selection = .team(id) }, scope: selection ?? .all, container: container, importing: $addingFile, search: search, typeFilter: $typeFilter, initialSources: onboardingSources)
                .id(selection)
        }
    }

    private func loadHistory() {
        do { try BackupHistory.bootstrap(in: container.mainContext); historyError = nil }
        catch { historyError = "バックアップの変更状態を確認できません。再確認してください。" }
    }


}

struct RegistrationForm: View {
    let container: ModelContainer
    let teams: [DeveloperTeam]
    let initialTeam: UUID?
    let isTeam: Bool
    var parentApp: ManagedApp? = nil
    var initialBundleID = ""
    var initialName = ""
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var identifier = ""
    @State private var platform = "iOS"
    @State private var iconColor: String? = "purple"
    @State private var iconImage: Data?
    @State private var showingAddTeam = false
    @Query(sort: \DeveloperTeam.name) private var registeredTeams: [DeveloperTeam]
    @State private var teamID: UUID?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        if isTeam {
            AppleDeveloperLoginView(onTeam: { team in
                let id = try AppleDeveloperSession.shared.register(team, catalog: AppCatalog(context: container.mainContext))
                onSaved(id)
            }).modelContainer(container)
        } else {
            registrationBody
        }
    }

    private var registrationBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(parentApp == nil ? "アプリを追加" : "ターゲットを追加").font(.system(size: 18, weight: .bold))
                Text(parentApp.map { "\($0.name) の配下にBundle IDを登録します。" } ?? "最初のターゲット（本体）のBundle IDを登録します。")
                    .foregroundStyle(AppMateStyle.secondary)
            }
            Label("プロファイルをここにドロップすると、下の項目を自動で入力します", systemImage: "arrow.down.to.line")
                .font(.system(size: 13)).foregroundStyle(AppMateStyle.accent)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(AppMateStyle.selectedRow, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppMateStyle.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    readProfile(url)
                    return true
                }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Text("表示名").frame(width: 120, alignment: .leading)
                    TextField("表示名", text: $name).focused($nameFocused).labelsHidden()
                }
                GridRow {
                    Text("Bundle ID")
                    TextField("com.example.app", text: $identifier)
                        .font(.system(size: 13, design: .monospaced)).labelsHidden()
                }
                GridRow {
                    Text("プラットフォーム")
                    Picker("プラットフォーム", selection: $platform) {
                        ForEach(AppCatalog.platforms, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("チーム")
                    Picker("チーム", selection: $teamID) {
                        Text("選択してください").tag(nil as UUID?)
                        ForEach(registeredTeams) { team in Text("\(team.name)（\(team.teamID)）").tag(Optional(team.id)) }
                    }.labelsHidden().disabled(parentApp != nil)
                }
                GridRow {
                    Color.clear.frame(width: 120, height: 1)
                    Button("チームを追加…") { showingAddTeam = true }.buttonStyle(.borderless).foregroundStyle(AppMateStyle.accent).disabled(parentApp != nil)
                }
                GridRow {
                    Text("アイコン")
                    AppIconPicker(name: name, iconColor: $iconColor, iconImage: $iconImage)
                }

            }.textFieldStyle(.roundedBorder).controlSize(.large).padding(.vertical, 4)
            Text("このアプリのプロファイルはアプリの一覧に、鍵と証明書はチームの一覧に保管します。")
                .font(.system(size: 12)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppMateStyle.selectedRow, in: RoundedRectangle(cornerRadius: 9))
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(AppMateButtonStyle())
                Button("追加", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(AppMateButtonStyle(primary: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || identifier.isEmpty || teamID == nil)
            }
        }
        .font(.system(size: 13)).padding(.horizontal, 26).padding(.vertical, 24).frame(width: isTeam ? 600 : 560)
        .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text).tint(AppMateStyle.accent)
        .sheet(isPresented: $showingAddTeam) {
            RegistrationForm(container: container, teams: registeredTeams, initialTeam: nil, isTeam: true) { teamID = $0 }
        }
        .onAppear {
            teamID = parentApp?.team?.id ?? initialTeam ?? (teams.count == 1 ? teams.first?.id : nil)
            identifier = initialBundleID
            name = initialName
            platform = parentApp?.platform ?? "iOS"
            nameFocused = true
        }
    }


    private func readProfile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.lowercased()
            guard ["mobileprovision", "provisionprofile"].contains(ext) else { throw ValidationError.invalidFile }
            let file = try CredentialFile(url: url)
            let profile = try CredentialParser.parse(file.data, extension: ext)
            guard let bundle = profile.bundleID, !bundle.contains("*") else { throw RegistrationError.invalidBundleID }
            if let parentApp, let sourceTeam = profile.teamID, sourceTeam != parentApp.team?.teamID { throw VaultError.teamMismatch }
            name = profile.name
            identifier = bundle
            if parentApp == nil, let sourceTeam = profile.teamID { teamID = registeredTeams.first { $0.teamID == sourceTeam }?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            let catalog = AppCatalog(context: container.mainContext)
            guard let teamID else { throw RegistrationError.teamMissing }
            let id = try catalog.addApp(name: name, bundleID: identifier, platform: platform, teamID: teamID, iconColor: iconColor, iconImage: iconImage, parentAppID: parentApp?.id)
            onSaved(id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}


enum AppMateStyle {
    static let accent = Color(red: 10/255, green: 100/255, blue: 214/255)
    static let canvas = adaptive(0xFFFFFF, 0x1D1D1F)
    static let sidebar = adaptive(0xF3F3F5, 0x242426)
    static let inspector = adaptive(0xFBFBFC, 0x222224)
    static let search = adaptive(0xE6E6EA, 0x343438)
    static let text = adaptive(0x1D1D1F, 0xF5F5F7)
    static let secondary = adaptive(0x5F5F66, 0xAEAEB5)
    static let border = adaptive(0xDEDEE2, 0x414145)
    static let rowBorder = adaptive(0xF0F0F3, 0x333337)
    static let selection = adaptive(0xD9E6FB, 0x243D60)
    static let selectedRow = adaptive(0xEEF3FD, 0x25354D)
    static let warningBackground = adaptive(0xFFF1D6, 0x49371B)
    static let warningText = adaptive(0x7A4700, 0xFFD68A)
    static let warningBorder = adaptive(0xF2D28C, 0x77582A)
    static let warningBanner = adaptive(0xFFF6E3, 0x3C301F)
    static let danger = Color(red: 217/255, green: 58/255, blue: 43/255)
    static let dangerText = adaptive(0x8F1C12, 0xFFAAA1)
    static let dangerBackground = adaptive(0xFBD5D1, 0x4A2928)
    static let successText = adaptive(0x17612E, 0x91DBA4)
    static let successBackground = adaptive(0xE3F4E8, 0x233D2B)

    private static func adaptive(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, alpha: 1)
        })
    }

    static func iconColor(_ name: String) -> Color {
        switch name {
        case "orange": Color(red: 242/255, green: 153/255, blue: 74/255)
        case "green": Color(red: 63/255, green: 162/255, blue: 122/255)
        case "blue": Color(red: 107/255, green: 138/255, blue: 253/255)
        default: Color(red: 199/255, green: 125/255, blue: 219/255)
        }
    }

    static func appColor(_ app: ManagedApp) -> Color {
        if let color = app.iconColor { return iconColor(color) }
        let colors = [Color(red: 242/255, green: 153/255, blue: 74/255), Color(red: 63/255, green: 162/255, blue: 122/255), Color(red: 107/255, green: 138/255, blue: 253/255), Color(red: 199/255, green: 125/255, blue: 219/255)]
        let index = app.bundleID.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[index]
    }
}

struct AppIconPicker: View {
    let name: String
    @Binding var iconColor: String?
    @Binding var iconImage: Data?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(AppMateStyle.iconColor(iconColor ?? "purple"))
                    if let iconImage, let image = NSImage(data: iconImage) { Image(nsImage: image).resizable().scaledToFill() }
                    else { Text(String(name.prefix(1))).font(.system(size: 20, weight: .bold)).foregroundStyle(.white) }
                }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 11))
                ForEach(AppCatalog.iconColors, id: \.self) { color in
                    Button { iconColor = color; iconImage = nil } label: {
                        Circle().fill(AppMateStyle.iconColor(color)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(iconColor == color && iconImage == nil ? AppMateStyle.text : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel("アイコンの色：" + color)
                        .accessibilityAddTraits(iconColor == color && iconImage == nil ? .isSelected : [])
                }
                Button("画像を選ぶ…", action: chooseIcon).buttonStyle(AppMateButtonStyle())
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try CredentialFile(url: url, maximumBytes: 1_048_576)
            guard NSImage(data: file.data) != nil else { throw ValidationError.invalidFile }
            iconImage = file.data
            error = nil
        } catch { self.error = "1MB以下のPNG・JPEG画像を選んでください。" }
    }

}

struct AppMateButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 11 : 13, weight: primary ? .medium : .regular))
            .padding(.horizontal, compact ? 8 : 14).frame(minHeight: compact ? 24 : 32)
            .foregroundStyle(primary ? Color.white : AppMateStyle.text)
            .background(primary ? AppMateStyle.accent : AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: compact ? 6 : 8))
            .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 8).stroke(primary ? Color.clear : AppMateStyle.border, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}


struct OnboardingView: View {
    let onFinished: ([URL]) -> Void
    @State private var step: Int
    @State private var sources: [URL] = []
    private let artwork = ["OnboardingWelcome", "OnboardingImport", "OnboardingSecurity"]
    private let titles = ["App Mate へ\nようこそ", "今ある鍵を\n取り込みましょう", "安心して使うための\n設定"]

    init(step: Int = 0, onFinished: @escaping ([URL]) -> Void) {
        self.onFinished = onFinished
        _step = State(initialValue: step)
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(artwork[step]).resizable().frame(width: 320, height: 518).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("STEP \(step + 1) / 3").font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(AppMateStyle.accent)
                Text(titles[step]).font(.system(size: step == 0 ? 30 : 28, weight: .heavy)).lineSpacing(3).padding(.top, 8)
                if step == 0 {
                    Text("鍵と証明書はチームで、プロファイルはアプリごとに保管します。")
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(AppMateStyle.secondary).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 14) {
                        feature("保管先で整理", detail: "鍵と証明書はチーム、プロファイルはアプリにまとめます", symbol: "sidebar.left", color: AppMateStyle.accent, background: AppMateStyle.selectedRow)
                        feature("期限を一覧で確認", detail: "期限切れと30日以内をサイドバーに出します", symbol: "clock", color: AppMateStyle.warningText, background: AppMateStyle.warningBackground)
                        feature("このMacの中だけ", detail: "暗号化して保存。サーバーには送りません", symbol: "lock", color: AppMateStyle.successText, background: AppMateStyle.successBackground)
                    }.padding(.top, 22)
                } else if step == 1 {
                    Text("鍵や証明書をまとめているフォルダがあれば、そのまま選んでください。")
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(AppMateStyle.secondary).padding(.top, 10)
                    VStack(spacing: 10) {
                        Text(sources.isEmpty ? "フォルダかファイルをここにドロップ" : "\(sources.count)件の追加元を選択しました")
                            .font(.system(size: 14, weight: .bold))
                        Button("フォルダを選ぶ…", action: chooseSources).buttonStyle(AppMateButtonStyle())
                    }.frame(maxWidth: .infinity).frame(height: 128)
                        .background(AppMateStyle.selectedRow, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppMateStyle.accent.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                        .padding(.top, 20)
                        .dropDestination(for: URL.self) { urls, _ in sources = urls; return !urls.isEmpty }
                    Text(".p8 · .p12 · .cer · .mobileprovision · .provisionprofile に対応します。チームとアプリを登録した後、内容を確認して取り込みます。元のファイルは変更しません。")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(AppMateStyle.secondary).padding(.top, 12)
                } else {
                    Text("秘密情報を開くときは、このMacで確認します。")
                        .font(.system(size: 14)).foregroundStyle(AppMateStyle.secondary).padding(.top, 10)
                    VStack(spacing: 10) {
                        feature("Macの認証で守る", detail: "Touch ID またはMacのパスワードで確認します", symbol: "touchid", color: AppMateStyle.accent, background: AppMateStyle.selectedRow)
                            .padding(12).background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 14))
                        HStack {
                            feature("表示を自動で閉じる", detail: "パスワードやメモの表示は、操作がないと閉じます", symbol: "eye.slash", color: AppMateStyle.secondary, background: AppMateStyle.search)
                            Spacer(minLength: 0)
                            Text("5分").font(.system(size: 12))
                        }.padding(12).background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 14))
                    }.padding(.top, 18)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { index in
                            Capsule().fill(index == step ? AppMateStyle.accent : AppMateStyle.border).frame(width: index == step ? 22 : 6, height: 6)
                        }
                    }.accessibilityLabel("ステップ \(step + 1) / 3")
                    Spacer()
                    if step == 1 { Button("あとで") { sources = []; step = 2 }.buttonStyle(.borderless) }
                    Button(step == 1 ? "次へ →" : "はじめる →") {
                        if step < 2 { step += 1 } else { onFinished(sources) }
                    }.font(.system(size: 14, weight: .bold)).buttonStyle(.plain)
                        .padding(.horizontal, 26).frame(height: 40).foregroundStyle(.white)
                        .background(AppMateStyle.accent, in: Capsule())
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(.top, 46).padding(.horizontal, 40).padding(.bottom, 26).frame(maxWidth: .infinity)
        }.frame(width: 760, height: 518).background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text)
    }

    private func feature(_ title: String, detail: String, symbol: String, color: Color, background: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color).frame(width: 38, height: 38)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(detail).font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            }
        }
    }

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { sources = panel.urls }
    }
}


struct AppIcon: View {
    let app: ManagedApp
    let size: CGFloat
    var body: some View {
        Group {
            if let data = app.iconImage, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else { AppMateStyle.appColor(app) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}
