import SwiftData
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

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
    @State private var onboardingSources: [URL] = []
    @AppStorage("AppMate.onboardingCompleted") private var onboardingCompleted = false
    @State private var typeFilter: CredentialTypeFilter = .all

    private var selectedApp: ManagedApp? {
        guard case .app(let id) = selection else { return nil }
        return apps.first { $0.id == id }
    }
    private var active: [StoredCredential] { credentials.filter { $0.replacedByID == nil && $0.deletedAt == nil && $0.app?.deletedAt == nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 236)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppMateStyle.canvas)
        .foregroundStyle(AppMateStyle.text)
        .background(Button("横断検索へ移動") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true))
        .tint(Color(red: 10 / 255, green: 100 / 255, blue: 214 / 255))
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
        .onChange(of: selectedApp?.deletedAt) { _, deletedAt in
            if deletedAt != nil { selection = .all }
        }
        .onChange(of: navigation.request) { _, _ in
            search = ""
            typeFilter = .all
            selection = navigation.scope
        }
        .sheet(isPresented: $onboarding, onDismiss: {
            guard !onboardingSources.isEmpty else { return }
            if teams.isEmpty { addingTeam = true }
            else if let app = apps.first(where: { $0.deletedAt == nil }) { selection = .app(app.id); addingFile = true }
            else { addingApp = true }
        }) {
            OnboardingView { sources in
                onboardingSources = sources
                onboardingCompleted = true
                onboarding = false
            }
        }
        .onChange(of: addingFile) { _, shown in if !shown { onboardingSources = [] } }
        .sheet(item: $editingTeam) { team in CatalogEditor(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), team: team, app: nil) }
        .sheet(item: $editingApp) { app in CatalogEditor(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)), team: nil, app: app) }
        .sheet(isPresented: $restoringBackup) {
            BackupView(container: container, restoring: true)
        }
        .sheet(isPresented: $creatingBackup) {
            BackupView(container: container)
        }
        .sheet(isPresented: $addingTeam, onDismiss: {
            if !onboardingSources.isEmpty && selectedTeam != nil { addingApp = true } else { onboardingSources = [] }
        }) {
            RegistrationForm(container: container, teams: teams, initialTeam: selectedTeam, isTeam: true) { id in
                selectedTeam = id
                selection = .all
            }
        }
        .sheet(isPresented: $addingApp, onDismiss: {
            if !onboardingSources.isEmpty && selectedApp != nil { addingFile = true } else { onboardingSources = [] }
        }) {
            RegistrationForm(container: container, teams: teams, initialTeam: selectedApp?.team?.id ?? selectedTeam, isTeam: false) { id in
                selection = .app(id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("App Mate").font(.system(size: 14, weight: .bold))
                .padding(.leading, 78)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppMateStyle.secondary)
                TextField("アプリ・鍵・IDを横断検索", text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
            }
            .font(.system(size: 13)).padding(.horizontal, 10).frame(width: 320, height: 30)
            .background(AppMateStyle.search, in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 12)
            Menu {
                Picker("種類", selection: $typeFilter) {
                    ForEach(CredentialTypeFilter.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Menu("チームを編集…") { ForEach(teams) { team in Button(team.name) { editingTeam = team } } }
                Button("バックアップから復元…") { restoringBackup = true }
            } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).frame(width: 24).help("種類で絞り込む・チームを管理")
            Button("ファイルを追加", systemImage: "plus") { addingFile = true }
                .buttonStyle(AppMateButtonStyle(primary: true))
                .disabled(selectedApp == nil || CredentialSearch.hasQuery(search))
                .help("左側で追加先のアプリを選択してください")
        }.padding(.horizontal, 16).frame(height: 52).background(AppMateStyle.sidebar)
    }

    private var expiredCount: Int { active.filter { $0.displayState(at: clock) == .expired }.count }
    private var expiringCount: Int { active.filter { $0.displayState(at: clock).needsRenewal }.count }

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
                    sidebarItem("最近削除した項目", symbol: "trash", scope: .trash,
                                count: credentials.filter { $0.deletedAt != nil }.count + apps.filter { $0.deletedAt != nil }.count)
                    sidebarHeading("アプリ").padding(.top, 10)
                    ForEach(apps.filter { $0.deletedAt == nil }) { app in
                        Button { selection = .app(app.id) } label: {
                            HStack(spacing: 10) {
                                AppIcon(app: app, size: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).lineLimit(1)
                                    if teams.count > 1 { Text(app.team?.name ?? "").font(.system(size: 10)).foregroundStyle(AppMateStyle.secondary) }
                                }
                                Spacer(minLength: 0)
                                if active.contains(where: { $0.isVisible(in: app) && $0.displayState(at: clock) == .expired }) {
                                    Text("期限切れ").foregroundStyle(AppMateStyle.dangerText).padding(.horizontal, 7).padding(.vertical, 1)
                                        .background(AppMateStyle.dangerBackground, in: Capsule()).font(.system(size: 11, weight: .bold))
                                } else if active.contains(where: { $0.isVisible(in: app) && $0.displayState(at: clock).needsRenewal }) {
                                    Text("注意").foregroundStyle(AppMateStyle.warningText).padding(.horizontal, 7).padding(.vertical, 1)
                                        .background(AppMateStyle.warningBackground, in: Capsule()).font(.system(size: 11, weight: .bold))
                                }
                            }.padding(.horizontal, 10).padding(.vertical, 7)
                                .background(selection == .app(app.id) ? AppMateStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(selection == .app(app.id) ? .isSelected : [])
                            .contextMenu { Button("Appを編集…") { editingApp = app } }
                    }
                    sidebarHeading("複数のアプリで使う鍵").padding(.top, 10)
                    sidebarItem("App Store Connect の鍵", symbol: "lock", scope: .shared(.appStoreConnect))
                    sidebarItem("プッシュ通知の鍵", symbol: "lock", scope: .shared(.apns))
                    sidebarItem("Sign in with Apple の鍵", symbol: "lock", scope: .shared(.signInWithApple))

                }.font(.system(size: 13)).buttonStyle(.borderless).padding(.horizontal, 10).padding(.top, 14)
            }
            .focusable().focusEffectDisabled()
            .onMoveCommand { direction in
                let scopes: [CredentialScope] = (expiredCount > 0 ? [.expired] : []) + (expiringCount > 0 ? [.expiring] : []) + [.all, .trash] + apps.filter { $0.deletedAt == nil }.map { .app($0.id) } + [.shared(.appStoreConnect), .shared(.apns), .shared(.signInWithApple)]
                guard direction == .up || direction == .down else { return }
                let index = scopes.firstIndex { $0 == selection } ?? (direction == .down ? -1 : scopes.count)
                selection = scopes[min(max(index + (direction == .down ? 1 : -1), 0), scopes.count - 1)]
            }
            VStack(alignment: .leading, spacing: 8) {
                if let historyError {
                    Text(historyError).foregroundStyle(AppMateStyle.dangerText)
                    Button("変更状態を再確認", action: loadHistory)
                } else if let checkpoint = checkpoints.first {
                    let history = BackupHistorySummary(changes: changes, checkpoint: checkpoint)
                    Text("バックアップしていない変更が \(history.pendingCount)件 あります").fontWeight(.medium)
                    if let date = history.lastCompletedAt {
                        Text("前回：" + date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary)
                    }
                } else { Text("バックアップ状態を確認中…") }
                Button { creatingBackup = true } label: { Text("今すぐバックアップ").frame(maxWidth: .infinity) }
                    .buttonStyle(AppMateButtonStyle())
            }.font(.system(size: 12)).padding(12)
                .background(AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppMateStyle.border, lineWidth: 1))
                .padding(14)
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
            }.padding(.horizontal, 14).padding(.bottom, 14)
        }.background(AppMateStyle.sidebar)
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
        } else if apps.filter({ $0.deletedAt == nil }).isEmpty && active.isEmpty {
            ContentUnavailableView {
                Label("アプリを追加しましょう", systemImage: "app.dashed")
            } description: {
                Text("名前・Bundle ID・プラットフォームを登録すると、ファイルを追加できます。")
            } actions: { Button("アプリを追加") { addingApp = true } }
        } else {
            CredentialAppView(app: CredentialSearch.hasQuery(search) ? nil : selectedApp, scope: selection ?? .all, container: container, importing: $addingFile, search: search, typeFilter: typeFilter, initialSources: onboardingSources)
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
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var identifier = ""
    @State private var platform = "iOS"
    @State private var iconColor = "purple"
    @State private var iconImage: Data?
    @State private var showingAddTeam = false
    @Query(sort: \DeveloperTeam.name) private var registeredTeams: [DeveloperTeam]
    @State private var teamID: UUID?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isTeam ? "チームを追加" : "アプリを追加").font(.system(size: 18, weight: .bold))
                Text(isTeam ? "Apple Developerのチーム名とTeam IDを入力してください。" : "あとから鍵やファイルを追加できます。")
                    .foregroundStyle(AppMateStyle.secondary)
            }
            if !isTeam {
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
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Text(isTeam ? "チーム名" : "表示名").frame(width: 120, alignment: .leading)
                    TextField("表示名", text: $name).focused($nameFocused).labelsHidden()
                }
                GridRow {
                    Text(isTeam ? "Team ID" : "Bundle ID")
                    TextField(isTeam ? "A1B2C3D4E5" : "com.example.app", text: $identifier)
                        .font(.system(size: 13, design: .monospaced)).labelsHidden()
                }
                if !isTeam {
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
                        }.labelsHidden()
                    }
                    GridRow {
                        Color.clear.frame(width: 120, height: 1)
                        Button("チームを追加…") { showingAddTeam = true }.buttonStyle(.borderless).foregroundStyle(AppMateStyle.accent)
                    }
                    GridRow {
                        Text("アイコン")
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11).fill(AppMateStyle.iconColor(iconColor))
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
                    }
                }
            }.textFieldStyle(.roundedBorder).controlSize(.large).padding(.vertical, 4)
            if isTeam {
                Text("Team IDは10文字の英大文字・数字です。Apple IDのパスワードは不要です。")
                    .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            }
            Text(isTeam ? "同じチームの証明書と鍵は、チーム内のすべてのアプリに表示します。アプリが0件でも鍵は保管します。" : "チームで共通の証明書と鍵は、このアプリにも自動で表示されます。")
                .font(.system(size: 12)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(isTeam ? AppMateStyle.warningBackground : AppMateStyle.selectedRow, in: RoundedRectangle(cornerRadius: 9))
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(AppMateButtonStyle())
                Button(isTeam ? "チームを追加" : "追加", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(AppMateButtonStyle(primary: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || identifier.isEmpty || (!isTeam && teamID == nil))
            }
        }
        .font(.system(size: 13)).padding(.horizontal, 26).padding(.vertical, 24).frame(width: isTeam ? 600 : 560)
        .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text).tint(AppMateStyle.accent)
        .sheet(isPresented: $showingAddTeam) {
            RegistrationForm(container: container, teams: registeredTeams, initialTeam: nil, isTeam: true) { teamID = $0 }
        }
        .onAppear {
            teamID = initialTeam ?? (teams.count == 1 ? teams.first?.id : nil)
            nameFocused = true
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

    private func readProfile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.lowercased()
            guard ["mobileprovision", "provisionprofile"].contains(ext) else { throw ValidationError.invalidFile }
            let file = try CredentialFile(url: url)
            let profile = try CredentialParser.parse(file.data, extension: ext)
            guard let bundle = profile.bundleID, !bundle.contains("*") else { throw RegistrationError.invalidBundleID }
            name = profile.name
            identifier = bundle
            if let sourceTeam = profile.teamID { teamID = registeredTeams.first { $0.teamID == sourceTeam }?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            let catalog = AppCatalog(context: container.mainContext)
            let id: UUID
            if isTeam {
                id = try catalog.addTeam(name: name, teamID: identifier)
            } else {
                guard let teamID else { throw RegistrationError.teamMissing }
                id = try catalog.addApp(name: name, bundleID: identifier, platform: platform, teamID: teamID, iconColor: iconColor, iconImage: iconImage)
            }
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
    @State private var notificationMessage: String?
    @State private var requesting = false
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
                    Text("App Store に出すための鍵と証明書を、アプリごとに1か所で保管します。")
                        .font(.system(size: 14)).lineSpacing(5).foregroundStyle(AppMateStyle.secondary).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 14) {
                        feature("アプリごとに整理", detail: "どの鍵がどのアプリ用か、もう迷いません", symbol: "sidebar.left", color: AppMateStyle.accent, background: AppMateStyle.selectedRow)
                        feature("期限前にお知らせ", detail: "Macの通知許可後、期限前にお知らせします", symbol: "clock", color: AppMateStyle.warningText, background: AppMateStyle.warningBackground)
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
                    Text("あとから設定でいつでも変えられます。")
                        .font(.system(size: 14)).foregroundStyle(AppMateStyle.secondary).padding(.top, 10)
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "bell").foregroundStyle(AppMateStyle.warningText).frame(width: 36, height: 36)
                                .background(AppMateStyle.warningBackground, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("期限の通知").fontWeight(.bold)
                                Text(notificationMessage ?? "30日前・7日前・前日・当日にお知らせします").font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("通知を許可", action: requestNotifications).buttonStyle(AppMateButtonStyle(primary: true)).disabled(requesting)
                        }.padding(12).background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 14))
                        feature("Macの認証で守る", detail: "Touch ID またはMacのパスワードで確認します", symbol: "touchid", color: AppMateStyle.accent, background: AppMateStyle.selectedRow)
                            .padding(12).background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 14))
                        HStack {
                            feature("自動ロック", detail: "しばらく操作がないとロックします", symbol: "lock", color: AppMateStyle.secondary, background: AppMateStyle.search)
                            Spacer(minLength: 0)
                            Text("5分後").font(.system(size: 12))
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

    private func requestNotifications() {
        guard ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1" else { return }
        requesting = true
        Task { @MainActor in
            defer { requesting = false }
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                notificationMessage = allowed ? "通知を許可しました" : "通知なしで続けられます。設定から変更できます。"
            } catch { notificationMessage = error.localizedDescription }
        }
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
