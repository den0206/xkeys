import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum CredentialScope: Hashable {
    case all, expired, expiring, attention, trash, credential(UUID), app(UUID), team(UUID)

    var title: String {
        switch self {
        case .trash: "最近削除した項目"
        case .credential: "資格情報"
        case .all: "すべての鍵とファイル"
        case .expired: "期限切れ"
        case .expiring: "30日以内に期限"
        case .attention: "対応が必要"
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
    @State private var currentTeamID: UUID?
    @State private var addingTeam = false
    @State private var addingApp = false
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
    private var needsBackup: Bool {
        guard historyError == nil, let checkpoint = checkpoints.first else { return false }
        return BackupHistorySummary(changes: changes, checkpoint: checkpoint,
                                    hasStoredItems: !apps.isEmpty || !credentials.isEmpty).needsBackup
    }
    private var active: [StoredCredential] { credentials.filter { $0.deletedAt == nil && $0.app?.deletedAt == nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 260)
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
            selection = navigation.scope == .all ? (rootApps.first { $0.team?.id == currentTeam?.id }.map { .app($0.id) } ?? currentTeam.map { .team($0.id) } ?? .all) : navigation.scope
            onboarding = !onboardingCompleted && ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1"
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in clock = .now }
        .onChange(of: dockBadgeLabel, initial: true) { _, label in
            guard ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1" else { return }
            NSApp.dockTile.badgeLabel = label
        }
        .onChange(of: selection) { _, scope in
            search = ""; typeFilter = .all
            switch scope {
            case .app(let id): if let team = apps.first(where: { $0.id == id })?.team { currentTeamID = team.id }
            case .team(let id): currentTeamID = id
            default: break
            }
        }
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
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                Text("App Mate").font(.system(size: 14, weight: .bold)).fixedSize()
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppMateStyle.secondary)
                TextField("アプリ名・Bundle ID・Key IDで探す", text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                Text("⌘F").font(.system(size: 11)).foregroundStyle(AppMateStyle.tertiary)
            }
            .font(.system(size: 13)).padding(.horizontal, 10).frame(minWidth: 160, idealWidth: 320, maxWidth: 320).frame(height: 32)
            .background(AppMateStyle.search, in: RoundedRectangle(cornerRadius: 8))
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
            }.menuStyle(.button).buttonStyle(.borderedProminent).fixedSize()
                .help("Mac上のファイル、またはApple Developerから取り込みます")
        }.padding(.horizontal, 16).frame(height: 52).background(AppMateStyle.canvas)
    }

    private var trashCount: Int { credentials.filter { $0.deletedAt != nil }.count + apps.filter { $0.deletedAt != nil }.count }
    private var expiredCount: Int { active.filter { $0.displayState(at: clock) == .expired }.count }
    private var expiringCount: Int { active.filter { $0.displayState(at: clock).needsRenewal }.count }
    private var dockBadgeLabel: String? {
        let show = checkpoints.first?.preferencesData.flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0).showDockBadge } ?? true
        return show && expiringCount > 0 ? String(expiringCount) : nil
    }

    /// The team the sidebar shows. Selecting an app or a team page also switches to its team.
    private var currentTeam: DeveloperTeam? { teams.first { $0.id == currentTeamID } ?? teams.first }
    private var teamApps: [ManagedApp] { rootApps.filter { $0.team?.id == currentTeam?.id } }
    private var sidebarScopes: [CredentialScope] {
        (expiredCount + expiringCount > 0 ? [.attention] : []) + teamApps.map { .app($0.id) } + (currentTeam.map { [.team($0.id)] } ?? [])
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            teamSwitcher.padding(.bottom, 8)
            if expiredCount + expiringCount > 0 {
                sidebarRow(scope: .attention) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 15)).foregroundStyle(AppMateStyle.danger).frame(width: 40)
                } title: { Text("対応が必要").fontWeight(.semibold) } status: {
                    Text("すべてのチームで \(expiredCount + expiringCount)件").font(.system(size: 12)).foregroundStyle(AppMateStyle.dangerText)
                }
            }
            sidebarHeading("アプリ · \(teamApps.count)")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if teamApps.isEmpty {
                        Text("まだアプリはありません").font(.system(size: 12)).foregroundStyle(AppMateStyle.tertiary).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(teamApps) { app in appRow(app) }
                    Button { addingApp = true } label: {
                        Label("アプリを追加", systemImage: "plus").fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 8)
                    }.buttonStyle(.plain).foregroundStyle(AppMateStyle.accent).disabled(teams.isEmpty)
                    if let team = currentTeam {
                        sidebarHeading("チーム共通").padding(.top, 8)
                        teamRow(team)
                    }
                }
            }
            .focusable().focusEffectDisabled()
            .onMoveCommand { direction in
                let scopes = sidebarScopes
                guard !scopes.isEmpty, direction == .up || direction == .down else { return }
                let index = scopes.firstIndex { $0 == selection } ?? (direction == .down ? -1 : scopes.count)
                selection = scopes[min(max(index + (direction == .down ? 1 : -1), 0), scopes.count - 1)]
            }
            Spacer(minLength: 8)
            backupStatusLine
            Divider().padding(.vertical, 4)
            HStack(spacing: 4) {
                Button { selection = .trash } label: {
                    Label("最近削除した項目", systemImage: "trash").font(.system(size: 12))
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(selection == .trash ? AppMateStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).foregroundStyle(selection == .trash ? AppMateStyle.text : AppMateStyle.secondary)
                    .accessibilityAddTraits(selection == .trash ? .isSelected : [])
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(AppMateStyle.secondary)
                    .help("設定").accessibilityLabel("設定")
            }
        }.font(.system(size: 13)).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
            .background(AppMateStyle.sidebar)
    }

    private var teamSwitcher: some View {
        Menu {
            Section("表示するチーム") {
                ForEach(teams) { team in
                    Button { switchTeam(team) } label: {
                        if team.id == currentTeam?.id { Label(team.name + "（" + team.teamID + "）", systemImage: "checkmark") }
                        else { Text(team.name + "（" + team.teamID + "）") }
                    }
                }
            }
            Divider()
            Button("チームを追加…") { addingTeam = true }
            Button("登録済みチームを管理…") { managingTeams = true }
            if let team = currentTeam {
                Button("チームを編集…") { editingTeam = team }
                Button("チームを削除…", role: .destructive) { deletingTeam = team }
            }
        } label: {
            HStack(spacing: 10) {
                Text(currentTeam.map { String($0.name.prefix(1)) } ?? "＋").font(.system(size: 14, weight: .bold)).foregroundStyle(AppMateStyle.accent)
                    .frame(width: 32, height: 32).background(AppMateStyle.selection, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTeam?.name ?? "チームを追加").fontWeight(.bold).lineLimit(1)
                    if let team = currentTeam { Text("Team ID " + team.teamID).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppMateStyle.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary)
            }.padding(10).contentShape(Rectangle())
                .background(AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppMateStyle.border))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("表示するチーム：" + (currentTeam.map { "\($0.name)、Team ID \($0.teamID)" } ?? "なし"))
    }

    private func switchTeam(_ team: DeveloperTeam) {
        currentTeamID = team.id
        selection = rootApps.first { $0.team?.id == team.id }.map { .app($0.id) } ?? .team(team.id)
    }

    private func appRow(_ app: ManagedApp) -> some View {
        let relevant = active.filter { record in !record.isTeamShared && app.targets.contains { record.isVisible(in: $0) } }
        let expired = relevant.contains { $0.displayState(at: clock) == .expired || $0.signingCertificatesExpired(in: active, at: clock) }
        let attention = expired || relevant.contains { $0.displayState(at: clock).needsRenewal }
        let targets = app.targets.count > 1 ? Text(" · \(app.targets.count)ターゲット").foregroundStyle(AppMateStyle.secondary) : Text("")
        return sidebarRow(scope: .app(app.id)) {
            AppIcon(app: app, size: 40)
        } title: {
            Text(app.name).fontWeight(.bold).lineLimit(1)
        } status: {
            Group {
                if relevant.isEmpty { Text("まだファイルはありません").foregroundStyle(AppMateStyle.tertiary) + targets }
                else if attention {
                    Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(expired ? AppMateStyle.danger : AppMateStyle.warningText)
                    + Text(expired ? " 対応が必要" : " 期限が近い").foregroundStyle(expired ? AppMateStyle.dangerText : AppMateStyle.warningText) + targets
                } else {
                    Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(AppMateStyle.successText)
                    + Text(" 問題なし").foregroundStyle(AppMateStyle.successText) + targets
                }
            }.font(.system(size: 12))
        }
        .help(app.name + "\n" + app.bundleID)
        .contextMenu {
            Button("ターゲットを追加…") { addingTarget = app.product }
            Button("アプリを編集…") { editingApp = app }
        }
    }

    private func teamRow(_ team: DeveloperTeam) -> some View {
        let shared = active.filter { $0.isTeamShared && $0.team?.id == team.id }
        let expired = shared.filter { $0.displayState(at: clock) == .expired }.count
        let certificates = shared.filter { CredentialGroup($0) == .certificate }.count
        let keys = shared.filter { CredentialGroup($0) == .key }.count
        return sidebarRow(scope: .team(team.id)) {
            Image(systemName: "key").font(.system(size: 17)).foregroundStyle(AppMateStyle.text.opacity(0.75))
                .frame(width: 40, height: 40).background(AppMateStyle.search, in: RoundedRectangle(cornerRadius: 9))
        } title: {
            Text("鍵と証明書").fontWeight(.bold)
        } status: {
            Group {
                if expired > 0 { Text("証明書 \(expired)件が期限切れ").foregroundStyle(AppMateStyle.dangerText) }
                else if shared.isEmpty { Text("まだありません").foregroundStyle(AppMateStyle.tertiary) }
                else { Text("証明書 \(certificates) · 鍵 \(keys)").foregroundStyle(AppMateStyle.secondary) }
            }.font(.system(size: 12))
        }
    }

    private var backupStatusLine: some View {
        Button { creatingBackup = true } label: {
            HStack(spacing: 8) {
                Circle().fill(needsBackup || historyError != nil ? Color(red: 0.96, green: 0.62, blue: 0.04) : AppMateStyle.successText)
                    .frame(width: 7, height: 7)
                if historyError != nil { Text("バックアップの状態を確認できません") }
                else if needsBackup { Text("バックアップが必要") }
                else { Text("バックアップ済み") }
                Spacer(minLength: 0)
                if let date = checkpoints.first.flatMap({ BackupHistorySummary(changes: changes, checkpoint: $0, hasStoredItems: !apps.isEmpty || !credentials.isEmpty).lastCompletedAt }) {
                    Text("前回 " + date.formatted(.dateTime.month(.defaultDigits).day())).foregroundStyle(AppMateStyle.tertiary)
                }
            }.font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).padding(.horizontal, 6).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("バックアップと復元を開きます")
            .accessibilityLabel(needsBackup ? "バックアップ、バックアップが必要" : "バックアップ")
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(AppMateStyle.secondary)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private func sidebarRow<Icon: View, Title: View, Status: View>(scope: CredentialScope, @ViewBuilder icon: () -> Icon,
                                                                 @ViewBuilder title: () -> Title, @ViewBuilder status: () -> Status) -> some View {
        Button { selection = scope } label: {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: 3) { title(); status() }
                Spacer(minLength: 0)
            }.padding(8).contentShape(Rectangle())
                .background(selection == scope ? AppMateStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection == scope ? AppMateStyle.selectionBorder : .clear))
        }.buttonStyle(.plain).accessibilityAddTraits(selection == scope ? .isSelected : [])
    }

    @ViewBuilder private var detail: some View {
        if selection == .trash {
            TrashView(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)))
        } else if teams.isEmpty {
            welcome
        } else {
            CredentialAppView(app: CredentialSearch.hasQuery(search) ? nil : selectedApp, team: CredentialSearch.hasQuery(search) ? nil : credentialTeam, openTeam: { id in selection = .team(id) }, scope: selection ?? .all, container: container, importing: $addingFile, search: search, typeFilter: $typeFilter, initialSources: onboardingSources)
                .id(selection)
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("証明書と鍵を、この Mac に安全にまとめます").font(.system(size: 22, weight: .bold))
                Text("期限が近づいたらお知らせします。まずは Apple Developer のチームを追加しましょう。").foregroundStyle(AppMateStyle.secondary)
            }.multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                welcomeStep(1, "チームを追加", "Apple Developer にサインインして、所属しているチームを選びます", current: true)
                welcomeStep(2, "アプリを追加", "Bundle ID を登録します。プロファイルから自動で入力することもできます", current: false)
                welcomeStep(3, "ファイルを追加", "証明書・プロファイル・鍵をドロップするだけです", current: false)
            }.padding(18).frame(width: 460, alignment: .leading).background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))
            Button("Apple Developer にサインインしてチームを追加") { addingTeam = true }
                .buttonStyle(AppMateButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            Button("バックアップから戻す") { restoringBackup = true }.buttonStyle(.plain).foregroundStyle(AppMateStyle.accent).font(.system(size: 12))
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeStep(_ number: Int, _ title: String, _ detail: String, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(current ? Color.white : AppMateStyle.secondary)
                .frame(width: 26, height: 26).background(current ? AppMateStyle.accent : AppMateStyle.search, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).foregroundStyle(current ? AppMateStyle.text : AppMateStyle.secondary)
                Text(detail).font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            }
        }.accessibilityElement(children: .combine)
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
    // Light only: the app pins `.preferredColorScheme(.light)` until a dark design exists.
    static let accent = hex(0x4338CA)
    static let canvas = hex(0xFFFFFF)
    static let sidebar = hex(0xFAFAFB)
    static let inspector = hex(0xFAFAFB)
    static let search = hex(0xF4F4F6)
    static let text = hex(0x18181B)
    static let secondary = hex(0x71717A)
    static let tertiary = hex(0xA1A1AA)
    static let border = hex(0xE2E2E8)
    static let rowBorder = hex(0xF1F1F4)
    static let selection = hex(0xEEF0FF)
    static let selectionBorder = hex(0xC7CBF5)
    static let selectedRow = hex(0xF3F4FF)
    static let dropBorder = hex(0xA5ABEF)
    static let warningBackground = hex(0xFFFBEB)
    static let warningText = hex(0x8A4B00)
    static let warningBorder = hex(0xF3D9A4)
    static let warningBanner = hex(0xFFFBEB)
    static let danger = hex(0xDC2626)
    static let dangerText = hex(0xB42318)
    static let dangerBackground = hex(0xFEF2F2)
    static let dangerBorder = hex(0xFBD5D1)
    static let successText = hex(0x15803D)
    static let successBackground = hex(0xDCFCE7)

    private static func hex(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255)
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
        panel.allowedContentTypes = [.png, .jpeg, .svg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try CredentialFile(url: url, maximumBytes: 1_048_576)
            guard NSImage(data: file.data) != nil else { throw ValidationError.invalidFile }
            iconImage = file.data
            error = nil
        } catch { self.error = "1MB以下のPNG・JPEG・SVG画像を選んでください。" }
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
                        feature("期限を一覧で確認", detail: "期限切れと30日以内を「対応が必要」にまとめます", symbol: "clock", color: AppMateStyle.warningText, background: AppMateStyle.warningBackground)
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
