import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum CredentialScope: Hashable {
    case all, expired, expiring, attention, trash, credential(UUID), app(UUID), team(UUID)

    var title: String {
        switch self {
        case .trash: String(localized: "最近削除した項目")
        case .credential: String(localized: "資格情報")
        case .all: String(localized: "すべての鍵とファイル")
        case .expired: String(localized: "期限切れ")
        case .expiring: String(localized: "30日以内に期限")
        case .attention: String(localized: "対応が必要")
        case .app: "App"
        case .team: String(localized: "チームの鍵・証明書")
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
    @AppStorage(OnboardingView.completedKey) private var onboardingCompleted = false
    @AppStorage(GuideMode.storageKey) private var guideMode = false
    @State private var tourStep: Int?
    @State private var showingGlossary = false
    @State private var movingToApplications = false
    private let installLocation = InstallLocation(bundleURL: Bundle.main.bundleURL)
    @State private var typeFilter: CredentialTypeFilter = .all
    private var testing: Bool { ProcessInfo.processInfo.environment["XKEYS_TESTING"] == "1" }

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
        .background(XkeysStyle.canvas)
        .foregroundStyle(XkeysStyle.text)
        .background(Button("横断検索へ移動") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true))
        .tint(XkeysStyle.accent)
        .task {
            loadHistory()
            do { try VaultManagement(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))).pruneExpired() }
            catch { historyError = String(localized: "削除済みデータの整理を完了できませんでした。再起動して確認してください。") }
            selection = navigation.scope == .all ? (rootApps.first { $0.team?.id == currentTeam?.id }.map { .app($0.id) } ?? currentTeam.map { .team($0.id) } ?? .all) : navigation.scope
            // Moving first keeps the onboarding for the copy that stays; the data is shared, so nothing is lost either way.
            if !testing && installLocation.suggestsMove && !UserDefaults.standard.bool(forKey: InstallLocation.skipKey) { movingToApplications = true }
            else { onboarding = !onboardingCompleted && !testing }
        }
        .onChange(of: onboardingCompleted) { _, completed in
            // Settings clears the flag to show the onboarding again.
            if !completed && !testing { onboarding = true }
        }
        .onChange(of: guideMode) { _, on in tourStep = on ? 0 : nil }
        .overlay(alignment: .bottomTrailing) {
            if guideMode, let tourStep {
                GuideTourCard(step: tourStep, onBack: { self.tourStep = max(tourStep - 1, 0) },
                              onNext: { self.tourStep = tourStep + 1 < GuideTour.steps.count ? tourStep + 1 : nil },
                              onClose: { self.tourStep = nil }, onGlossary: { showingGlossary = true })
                    .padding(24)
            }
        }
        .sheet(isPresented: $movingToApplications, onDismiss: { onboarding = !onboardingCompleted && !testing }) {
            MoveToApplicationsView(location: installLocation) { movingToApplications = false }
        }
        .sheet(isPresented: $showingGlossary) { GuideGlossaryView() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in clock = .now }
        .onChange(of: dockBadgeLabel, initial: true) { _, label in
            guard ProcessInfo.processInfo.environment["XKEYS_TESTING"] != "1" else { return }
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
        .sheet(item: $addingTarget, onDismiss: {
            if !onboardingSources.isEmpty && selectedApp != nil { addingFile = true } else { onboardingSources = [] }
        }) { parent in
            RegistrationForm(container: container, teams: teams, initialTeam: parent.team?.id, isTeam: false, parentApp: parent,
                             onProfile: { onboardingSources = [$0] }) { id in
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
            RegistrationForm(container: container, teams: teams, initialTeam: credentialTeam?.id ?? selectedTeam, isTeam: false,
                             onProfile: { onboardingSources = [$0] }) { id in
                selection = .app(id)
            }
        }
        .environment(\.guide, GuideState(active: guideMode, tourStep: tourStep))
    }

    @ViewBuilder private var guideControl: some View {
        if guideMode {
            Menu {
                Button("画面のガイドを見る", systemImage: "map") { tourStep = 0 }
                Button("用語集", systemImage: "book") { showingGlossary = true }
                Divider()
                Button("説明モードをオフ") { guideMode = false }
            } label: {
                Label("説明モード オン", systemImage: "questionmark.circle")
            }.menuStyle(.button).buttonStyle(.bordered).fixedSize()
                .help("画面の見方と言葉の意味を表示しています")
        } else {
            Button { guideMode = true } label: { Label("説明モード", systemImage: "questionmark.circle") }
                .buttonStyle(.bordered).fixedSize()
                .help("画面の見方と言葉の意味を表示します")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                Text("Xkeys").font(.system(size: 14, weight: .bold)).fixedSize()
            }
            Spacer(minLength: 12)
            guideControl
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(XkeysStyle.secondary)
                TextField("アプリ名・Bundle ID・Key IDで探す", text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                Text("⌘F").font(.system(size: 11)).foregroundStyle(XkeysStyle.tertiary)
            }
            .font(.system(size: 13)).padding(.horizontal, 10).frame(minWidth: 160, idealWidth: 320, maxWidth: 320).frame(height: 32)
            .background(XkeysStyle.search, in: RoundedRectangle(cornerRadius: 8))
            Menu {
                Button("Macからファイルを追加…", systemImage: "folder") { addingFile = true }
                    .disabled(credentialTeam == nil || CredentialSearch.hasQuery(search))
                Menu("Apple Developerから取り込む…", systemImage: "icloud.and.arrow.down") {
                    ForEach(teams) { team in
                        Button(String(localized: "\(team.name)（\(team.teamID)）")) { onlineImportTeam = team }
                    }
                }.disabled(teams.isEmpty)
            } label: {
                Label("ファイルを追加", systemImage: "plus")
            }.menuStyle(.button).buttonStyle(.borderedProminent).fixedSize()
                .help("Mac上のファイル、またはApple Developerから取り込みます")
                .guideSpot(5)
        }.padding(.horizontal, 16).frame(height: 52).background(XkeysStyle.canvas)
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
            teamSwitcher.guideSpot(1).padding(.bottom, 8)
            if expiredCount + expiringCount > 0 {
                sidebarRow(scope: .attention) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 15)).foregroundStyle(XkeysStyle.danger).frame(width: 40)
                } title: { Text("対応が必要").fontWeight(.semibold) } status: {
                    Text("すべてのチームで \(expiredCount + expiringCount)件").font(.system(size: 12)).foregroundStyle(XkeysStyle.dangerText)
                }
            }
            HStack(spacing: 6) {
                sidebarHeading(String(localized: "アプリ · \(teamApps.count)"))
                GuideTermButton(term: .bundleID).padding(.top, 4)
                Spacer(minLength: 0)
            }.guideSpot(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if teamApps.isEmpty {
                        Text("まだアプリはありません").font(.system(size: 12)).foregroundStyle(XkeysStyle.tertiary).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(teamApps) { app in appRow(app) }
                    Button { addingApp = true } label: {
                        Label("アプリを追加", systemImage: "plus").fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 8)
                    }.buttonStyle(.plain).foregroundStyle(XkeysStyle.accent).disabled(teams.isEmpty)
                    if let team = currentTeam {
                        sidebarHeading(String(localized: "チーム共通")).padding(.top, 8)
                        teamRow(team).guideSpot(3)
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
            backupStatusLine.guideSpot(4)
            Divider().padding(.vertical, 4)
            if teams.isEmpty { addTeamPrompt.padding(.horizontal, 6).padding(.bottom, 2) }
            else { AppleDeveloperAccountView(session: appleSession, compact: true).padding(.horizontal, 6).padding(.bottom, 2) }
            HStack(spacing: 4) {
                Button { selection = .trash } label: {
                    Label("最近削除した項目", systemImage: "trash").font(.system(size: 12))
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(selection == .trash ? XkeysStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).foregroundStyle(selection == .trash ? XkeysStyle.text : XkeysStyle.secondary)
                    .accessibilityAddTraits(selection == .trash ? .isSelected : [])
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(XkeysStyle.secondary)
                    .help("設定").accessibilityLabel("設定")
            }
        }.font(.system(size: 13)).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
            .background(XkeysStyle.sidebar)
    }

    private var teamSwitcher: some View {
        Menu {
            Section("表示するチーム") {
                ForEach(teams) { team in
                    Button { switchTeam(team) } label: {
                        if team.id == currentTeam?.id { Label(String(localized: "\(team.name)（\(team.teamID)）"), systemImage: "checkmark") }
                        else { Text(String(localized: "\(team.name)（\(team.teamID)）")) }
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
                Text(currentTeam.map { String($0.name.prefix(1)) } ?? "＋").font(.system(size: 14, weight: .bold)).foregroundStyle(XkeysStyle.accent)
                    .frame(width: 32, height: 32).background(XkeysStyle.selection, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTeam?.name ?? String(localized: "チームを追加")).fontWeight(.bold).lineLimit(1)
                    if let team = currentTeam { Text("Team ID " + team.teamID).font(.system(size: 11, design: .monospaced)).foregroundStyle(XkeysStyle.secondary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(XkeysStyle.secondary)
            }.padding(10).contentShape(Rectangle())
                .background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(XkeysStyle.border))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel(String(localized: "表示するチーム：") + (currentTeam.map { "\($0.name)、Team ID \($0.teamID)" } ?? String(localized: "なし")))
    }

    private func switchTeam(_ team: DeveloperTeam) {
        currentTeamID = team.id
        selection = rootApps.first { $0.team?.id == team.id }.map { .app($0.id) } ?? .team(team.id)
    }

    private func appRow(_ app: ManagedApp) -> some View {
        let relevant = active.filter { record in !record.isTeamShared && app.targets.contains { record.isVisible(in: $0) } }
        let expired = relevant.contains { $0.displayState(at: clock) == .expired || $0.signingCertificatesExpired(in: active, at: clock) }
        let attention = expired || relevant.contains { $0.displayState(at: clock).needsRenewal }
        let targets = app.targets.count > 1 ? Text(" · \(app.targets.count)ターゲット").foregroundStyle(XkeysStyle.secondary) : Text("")
        return sidebarRow(scope: .app(app.id)) {
            AppIcon(app: app, size: 40)
        } title: {
            Text(app.name).fontWeight(.bold).lineLimit(1)
        } status: {
            Group {
                if relevant.isEmpty { Text("まだファイルはありません").foregroundStyle(XkeysStyle.tertiary) + targets }
                else if attention {
                    Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(expired ? XkeysStyle.danger : XkeysStyle.warningText)
                    + Text(expired ? " 対応が必要" : " 期限が近い").foregroundStyle(expired ? XkeysStyle.dangerText : XkeysStyle.warningText) + targets
                } else {
                    Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(XkeysStyle.successText)
                    + Text(" 問題なし").foregroundStyle(XkeysStyle.successText) + targets
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
            Image(systemName: "key").font(.system(size: 17)).foregroundStyle(XkeysStyle.text.opacity(0.75))
                .frame(width: 40, height: 40).background(XkeysStyle.search, in: RoundedRectangle(cornerRadius: 9))
        } title: {
            Text("鍵と証明書").fontWeight(.bold)
        } status: {
            Group {
                if expired > 0 { Text("証明書 \(expired)件が期限切れ").foregroundStyle(XkeysStyle.dangerText) }
                else if shared.isEmpty { Text("まだありません").foregroundStyle(XkeysStyle.tertiary) }
                else { Text("証明書 \(certificates) · 鍵 \(keys)").foregroundStyle(XkeysStyle.secondary) }
            }.font(.system(size: 12))
        }
    }

    // Without a team, the saved Apple login is only useful for choosing one, so lead there instead of showing the account menu.
    private var addTeamPrompt: some View {
        Button { addingTeam = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("チームを追加", systemImage: "person.crop.circle.badge.plus").font(.system(size: 12))
                if let account = appleSession.currentAccount ?? appleSession.savedAccount {
                    Text("\(account.label) の所属チームから選択").font(.system(size: 11)).foregroundStyle(XkeysStyle.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(XkeysStyle.accent)
        .task { try? appleSession.loadSavedAccount() }
    }

    private var backupStatusLine: some View {
        Button { creatingBackup = true } label: {
            HStack(spacing: 8) {
                Circle().fill(needsBackup || historyError != nil ? Color(red: 0.96, green: 0.62, blue: 0.04) : XkeysStyle.successText)
                    .frame(width: 7, height: 7)
                if historyError != nil { Text("バックアップの状態を確認できません") }
                else if needsBackup { Text("バックアップが必要") }
                else { Text("バックアップ済み") }
                Spacer(minLength: 0)
                if let date = checkpoints.first.flatMap({ BackupHistorySummary(changes: changes, checkpoint: $0, hasStoredItems: !apps.isEmpty || !credentials.isEmpty).lastCompletedAt }) {
                    Text(String(localized: "前回 ") + date.formatted(.dateTime.month(.defaultDigits).day())).foregroundStyle(XkeysStyle.tertiary)
                }
            }.font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary).padding(.horizontal, 6).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("バックアップと復元を開きます")
            .accessibilityLabel(needsBackup ? "バックアップ、バックアップが必要" : "バックアップ")
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(XkeysStyle.secondary)
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
                .background(selection == scope ? XkeysStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection == scope ? XkeysStyle.selectionBorder : .clear))
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
                Text("期限切れや期限が近いものを、ひと目で分かるようにします。まずは Apple Developer のチームを追加しましょう。").foregroundStyle(XkeysStyle.secondary)
            }.multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                welcomeStep(1, String(localized: "チームを追加"), String(localized: "Apple Developer にサインインして、所属しているチームを選びます"), current: true)
                welcomeStep(2, String(localized: "アプリを追加"), String(localized: "Bundle ID を登録します。プロファイルから自動で入力することもできます"), current: false)
                welcomeStep(3, String(localized: "ファイルを追加"), String(localized: "証明書・プロファイル・鍵をドロップするだけです"), current: false)
            }.padding(18).frame(width: 460, alignment: .leading).background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))
            Button("Apple Developer にサインインしてチームを追加") { addingTeam = true }
                .buttonStyle(XkeysButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            Button("バックアップから戻す") { restoringBackup = true }.buttonStyle(.plain).foregroundStyle(XkeysStyle.accent).font(.system(size: 12))
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeStep(_ number: Int, _ title: String, _ detail: String, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(current ? Color.white : XkeysStyle.secondary)
                .frame(width: 26, height: 26).background(current ? XkeysStyle.accent : XkeysStyle.search, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).foregroundStyle(current ? XkeysStyle.text : XkeysStyle.secondary)
                Text(detail).font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private func loadHistory() {
        do { try BackupHistory.bootstrap(in: container.mainContext); historyError = nil }
        catch { historyError = String(localized: "バックアップの変更状態を確認できません。再確認してください。") }
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
    // Receives the profile used to fill the form so the caller can offer to store it after registration.
    var onProfile: ((URL) -> Void)? = nil
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
    @State private var profile: (url: URL, bundleID: String)?
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
                    .foregroundStyle(XkeysStyle.secondary)
            }
            Button(action: chooseProfile) {
                Label("プロファイルをドロップするか、クリックして選ぶと下の項目を自動で入力します", systemImage: "arrow.down.to.line")
                    .font(.system(size: 13)).foregroundStyle(XkeysStyle.accent)
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .background(XkeysStyle.selectedRow, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(XkeysStyle.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
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
                    Button("チームを追加…") { showingAddTeam = true }.buttonStyle(.borderless).foregroundStyle(XkeysStyle.accent).disabled(parentApp != nil)
                }
                GridRow {
                    Text("アイコン")
                    AppIconPicker(name: name, iconColor: $iconColor, iconImage: $iconImage)
                }

            }.textFieldStyle(.roundedBorder).controlSize(.large).padding(.vertical, 4)
            Text("このアプリのプロファイルはアプリの一覧に、鍵と証明書はチームの一覧に保管します。")
                .font(.system(size: 12)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(XkeysStyle.selectedRow, in: RoundedRectangle(cornerRadius: 9))
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(XkeysButtonStyle())
                Button("追加", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(XkeysButtonStyle(primary: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || identifier.isEmpty || teamID == nil)
            }
        }
        .font(.system(size: 13)).padding(.horizontal, 26).padding(.vertical, 24).frame(width: isTeam ? 600 : 560)
        .background(XkeysStyle.canvas).foregroundStyle(XkeysStyle.text).tint(XkeysStyle.accent)
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


    private func chooseProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mobileprovision", "provisionprofile"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { readProfile(url) }
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
            self.profile = (url, bundle)
            if parentApp == nil, let sourceTeam = profile.teamID { teamID = registeredTeams.first { $0.teamID == sourceTeam }?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            let catalog = AppCatalog(context: container.mainContext)
            guard let teamID else { throw RegistrationError.teamMissing }
            let id = try catalog.addApp(name: name, bundleID: identifier, platform: platform, teamID: teamID, iconColor: iconColor, iconImage: iconImage, parentAppID: parentApp?.id)
            // A profile whose Bundle ID was edited away no longer belongs to this app.
            if let profile, profile.bundleID == identifier { onProfile?(profile.url) }
            onSaved(id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}


enum XkeysStyle {
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
    static let profileBackground = hex(0xF7F8FF)
    static let profileBorder = hex(0xE3E6FB)
    static let certificateBackground = hex(0xF4FBF6)
    static let certificateBorder = hex(0xD6EFDD)
    static let keyBackground = hex(0xFFFAF0)
    static let keyBorder = hex(0xF3E3C3)

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
                    RoundedRectangle(cornerRadius: 11).fill(XkeysStyle.iconColor(iconColor ?? "purple"))
                    if let iconImage, let image = NSImage(data: iconImage) { Image(nsImage: image).resizable().scaledToFill() }
                    else { Text(String(name.prefix(1))).font(.system(size: 20, weight: .bold)).foregroundStyle(.white) }
                }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 11))
                ForEach(AppCatalog.iconColors, id: \.self) { color in
                    Button { iconColor = color; iconImage = nil } label: {
                        Circle().fill(XkeysStyle.iconColor(color)).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(iconColor == color && iconImage == nil ? XkeysStyle.text : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel(String(localized: "アイコンの色：") + color)
                        .accessibilityAddTraits(iconColor == color && iconImage == nil ? .isSelected : [])
                }
                Button("画像を選ぶ…", action: chooseIcon).buttonStyle(XkeysButtonStyle())
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
        } catch { self.error = String(localized: "1MB以下のPNG・JPEG・SVG画像を選んでください。") }
    }

}

struct XkeysButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 11 : 13, weight: primary ? .medium : .regular))
            .padding(.horizontal, compact ? 8 : 14).frame(minHeight: compact ? 24 : 32)
            .foregroundStyle(primary ? Color.white : XkeysStyle.text)
            .background(primary ? XkeysStyle.accent : XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: compact ? 6 : 8))
            .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 8).stroke(primary ? Color.clear : XkeysStyle.border, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}


struct OnboardingView: View {
    static let completedKey = "Xkeys.onboardingCompleted"
    static let stepCount = 4

    let onFinished: ([URL]) -> Void
    @State private var step: Int
    @State private var sources: [URL] = []
    @AppStorage(GuideMode.storageKey) private var guideMode = false
    private let artwork = ["OnboardingWelcome", "OnboardingFiles", "OnboardingImport", "OnboardingSecurity"]
    private let titles = [String(localized: "Xkeys へ\nようこそ"), String(localized: "3種類のファイルを\n分けて持ちます"),
                          String(localized: "今ある鍵を\n取り込みましょう"), String(localized: "安心して使うための\n設定")]

    init(step: Int = 0, onFinished: @escaping ([URL]) -> Void) {
        self.onFinished = onFinished
        _step = State(initialValue: step)
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(artwork[step]).resizable().frame(width: 320, height: 518).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("STEP \(step + 1) / \(Self.stepCount)").font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(XkeysStyle.accent)
                Text(titles[step]).font(.system(size: step == 0 ? 30 : 28, weight: .heavy)).lineSpacing(3).padding(.top, 8)
                if step == 0 {
                    Text("鍵と証明書はチームで、プロファイルはアプリごとに保管します。")
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(XkeysStyle.secondary).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 14) {
                        feature(String(localized: "保管先で整理"), detail: String(localized: "鍵と証明書はチーム、プロファイルはアプリにまとめます"), symbol: "sidebar.left", color: XkeysStyle.accent, background: XkeysStyle.selectedRow)
                        feature(String(localized: "期限を一覧で確認"), detail: String(localized: "期限切れと30日以内を「対応が必要」にまとめます"), symbol: "clock", color: XkeysStyle.warningText, background: XkeysStyle.warningBackground)
                        feature(String(localized: "このMacの中だけ"), detail: String(localized: "暗号化して保存。サーバーには送りません"), symbol: "lock", color: XkeysStyle.successText, background: XkeysStyle.successBackground)
                    }.padding(.top, 22)
                } else if step == 1 {
                    Text("拡張子が分からなくても大丈夫です。取り込むときに Xkeys が見分けます。")
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(XkeysStyle.secondary).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 14) {
                        kind(.certificate, String(localized: "証明書 · チーム共通"), detail: String(localized: "アプリの署名に使います。だいたい1年で期限が来ます"))
                        kind(.key, String(localized: "鍵（.p8）· チーム共通"), detail: String(localized: "通知や API に使います。再ダウンロードできません"))
                        kind(.profile, String(localized: "プロファイル · アプリごと"), detail: String(localized: "証明書が切れると、一緒に使えなくなります"))
                    }.padding(.top, 22)
                } else if step == 2 {
                    Text("鍵や証明書をまとめているフォルダがあれば、そのまま選んでください。")
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(XkeysStyle.secondary).padding(.top, 10)
                    VStack(spacing: 10) {
                        Text(sources.isEmpty ? "フォルダかファイルをここにドロップ" : "\(sources.count)件の追加元を選択しました")
                            .font(.system(size: 14, weight: .bold))
                        Button("フォルダを選ぶ…", action: chooseSources).buttonStyle(XkeysButtonStyle())
                    }.frame(maxWidth: .infinity).frame(height: 128)
                        .background(XkeysStyle.selectedRow, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(XkeysStyle.accent.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                        .padding(.top, 20)
                        .dropDestination(for: URL.self) { urls, _ in sources = urls; return !urls.isEmpty }
                    Text(".p8 · .p12 · .cer · .mobileprovision · .provisionprofile に対応します。チームとアプリを登録した後、内容を確認して取り込みます。元のファイルは変更しません。")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(XkeysStyle.secondary).padding(.top, 12)
                } else {
                    Text("秘密情報を開くときは、このMacで確認します。")
                        .font(.system(size: 14)).foregroundStyle(XkeysStyle.secondary).padding(.top, 10)
                    VStack(spacing: 10) {
                        feature(String(localized: "Macの認証で守る"), detail: String(localized: "Touch ID またはMacのパスワードで確認します"), symbol: "touchid", color: XkeysStyle.accent, background: XkeysStyle.selectedRow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 14))
                        HStack {
                            feature(String(localized: "表示を自動で閉じる"), detail: String(localized: "パスワードやメモの表示は、操作がないと閉じます"), symbol: "eye.slash", color: XkeysStyle.secondary, background: XkeysStyle.search)
                            Spacer(minLength: 0)
                            Text("5分").font(.system(size: 12))
                        }.padding(12).background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 14))
                        HStack {
                            feature(String(localized: "説明モード"), detail: String(localized: "画面の見方と言葉の意味を表示します"), symbol: "questionmark.circle", color: XkeysStyle.accent, background: XkeysStyle.selectedRow)
                            Spacer(minLength: 0)
                            Toggle("説明モード", isOn: $guideMode).labelsHidden().toggleStyle(.switch)
                        }.padding(12).background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 14))
                    }.padding(.top, 18)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(0..<Self.stepCount, id: \.self) { index in
                            Capsule().fill(index == step ? XkeysStyle.accent : XkeysStyle.border).frame(width: index == step ? 22 : 6, height: 6)
                        }
                    }.accessibilityLabel("ステップ \(step + 1) / \(Self.stepCount)")
                    Spacer()
                    if step > 0 { Button("戻る") { step -= 1 }.buttonStyle(.borderless).foregroundStyle(XkeysStyle.secondary) }
                    if step == 2 { Button("あとで") { sources = []; step = 3 }.buttonStyle(.borderless) }
                    Button(step + 1 < Self.stepCount ? "次へ →" : "はじめる →") {
                        if step + 1 < Self.stepCount { step += 1 } else { onFinished(sources) }
                    }.font(.system(size: 14, weight: .bold)).buttonStyle(.plain)
                        .padding(.horizontal, 26).frame(height: 40).foregroundStyle(.white)
                        .background(XkeysStyle.accent, in: Capsule())
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(.top, 46).padding(.horizontal, 40).padding(.bottom, 26).frame(maxWidth: .infinity)
        }.frame(width: 760, height: 518).background(XkeysStyle.canvas).foregroundStyle(XkeysStyle.text)
    }

    private func kind(_ group: CredentialGroup, _ title: String, detail: String) -> some View {
        feature(title, detail: detail, symbol: group.symbol, color: group.tint, background: group.background)
    }

    private func feature(_ title: String, detail: String, symbol: String, color: Color, background: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color).frame(width: 38, height: 38)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(detail).font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
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
            } else { XkeysStyle.appColor(app) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}
