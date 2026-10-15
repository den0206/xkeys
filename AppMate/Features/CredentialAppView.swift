import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum CredentialDisplayState: Equatable {
    case revoked, replaced, expired, withinDay, expiring(Int), valid, stored

    var needsRenewal: Bool {
        switch self { case .withinDay, .expiring: true; default: false }
    }
    var title: String {
        switch self {
        case .revoked: "手動失効"
        case .replaced: "置き換え済み"
        case .expired: "期限切れ"
        case .withinDay: "24時間以内"
        case .expiring(let days): "あと\(days)日"
        case .valid: "有効"
        case .stored: "保管中"
        }
    }
}

extension StoredCredential {
    var fileTypeTitle: String {
        if isIntermediateCA { return ParsedCredential.intermediateCAKind }
        return switch fileExtension {
        case "cer": "証明書"
        case "p12": "証明書＋秘密鍵"
        case "p8": "秘密鍵"
        default: "プロファイル"
        }
    }

    func displayState(at now: Date) -> CredentialDisplayState {
        if revokedAt != nil { return .revoked }
        if replacedByID != nil { return .replaced }
        guard let expiresAt else { return .stored }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return .expired }
        if seconds < 86400 { return .withinDay }
        if seconds <= 30 * 86400 { return .expiring(Int(ceil(seconds / 86400))) }
        return .valid
    }
}

struct CredentialStatusBadge: View {
    let state: CredentialDisplayState
    var foreground: Color {
        switch state {
        case .expired, .revoked: AppMateStyle.dangerText
        case .withinDay, .expiring: AppMateStyle.warningText
        case .valid: AppMateStyle.successText
        case .stored, .replaced: AppMateStyle.secondary
        }
    }
    var background: Color {
        switch state {
        case .expired, .revoked: AppMateStyle.dangerBackground
        case .withinDay, .expiring: AppMateStyle.warningBackground
        case .valid: AppMateStyle.successBackground
        case .stored, .replaced: AppMateStyle.sidebar
        }
    }
    var body: some View {
        Text(state.title).font(.system(size: 12, weight: state == .stored ? .regular : .bold))
            .foregroundStyle(foreground).padding(.horizontal, 8).padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

struct CredentialAppView: View {
    let app: ManagedApp?
    let scope: CredentialScope
    let container: ModelContainer
    @Binding var importing: Bool
    let search: String
    let typeFilter: CredentialTypeFilter
    var initialSources: [URL] = []
    @Query(sort: \StoredCredential.name) private var records: [StoredCredential]
    @State private var access = VaultAccess()
    @State private var selected: UUID?
    @State private var droppedSources: [URL] = []
    @State private var clock = Date.now
    @State private var showReplaced = false
    @State private var error: String?
    @State private var status = ""
    @State private var revealedPassword: String?
    @State private var editingNote = false
    @State private var editingApp = false
    @State private var addingTarget = false
    @State private var targetFilter: UUID?
    @State private var copyingCI = false
    @State private var deleting = false
    @State private var deletingApp = false
    @State private var showingRenewalGuide = false
    @State private var inlineInspector = true
    @State private var showingInspector = false
    @State private var showingIdentity = false
    @State private var listWidth: CGFloat = 600
    @State private var revealedAt = Date.distantPast

    private var visible: [StoredCredential] {
        records.filter { record in
            (targetFilter == nil || record.isTeamShared || record.app?.id == targetFilter) && CredentialSearch.includes(record, scope: scope, app: app, query: search, type: typeFilter, showReplaced: showReplaced, at: clock) }
            .sorted { ($0.fileExtension == "p8" ? 1 : 0) < ($1.fileExtension == "p8" ? 1 : 0) }
    }
    private var selectedRecord: StoredCredential? { visible.first { $0.id == selected } }
    private var vault: CredentialVault {
        CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))
    }

    var body: some View {
        HStack(spacing: 0) {
            if !inlineInspector && showingInspector {
                VStack(spacing: 0) {
                    HStack {
                        Button("一覧に戻る", systemImage: "chevron.left") { showingInspector = false }.buttonStyle(.borderless)
                        Spacer()
                    }.padding(16)
                    Divider()
                    inspector
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppMateStyle.inspector)
            } else {
                credentialList
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
                if inlineInspector {
                    Divider()
                    inspector.frame(width: 300).frame(maxHeight: .infinity).background(AppMateStyle.inspector)
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 900 } action: { inlineInspector = $0 }
        .sheet(isPresented: $showingIdentity) {
            if let record = selectedRecord {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ファイルの識別情報").font(.system(size: 18, weight: .bold))
                    Text("ファイルSHA-256").foregroundStyle(AppMateStyle.secondary)
                    Text(record.digest).monospaced().textSelection(.enabled)
                    if let fingerprint = record.fingerprint {
                        Text(record.fileExtension == "p8" ? "公開鍵SHA-256" : "証明書SHA-256").foregroundStyle(AppMateStyle.secondary)
                        Text(fingerprint).monospaced().textSelection(.enabled)
                    }
                    Text("発行元の信頼性・オンライン失効は確認していません。").foregroundStyle(AppMateStyle.secondary)
                    HStack { Spacer(); Button("閉じる") { showingIdentity = false }.buttonStyle(AppMateButtonStyle()) }
                }.font(.system(size: 12)).padding(24).frame(width: 440).background(AppMateStyle.canvas)
            }
        }
        .font(.system(size: 13))

        .sheet(isPresented: $importing) {
            if let app {
                CredentialImportView(app: app, vault: vault, existing: records, initialSources: droppedSources.isEmpty ? initialSources : droppedSources) { id in
                    selected = id
                    status = "資格情報を暗号化して保存しました。元ファイルは変更していません。"
                }
            }
        }
        .sheet(isPresented: $editingNote) { NoteEditor(vault: vault, app: selectedRecord == nil ? app : nil, record: selectedRecord) }
        .sheet(isPresented: $addingTarget) {
            if let parent = app?.product {
                RegistrationForm(container: container, teams: parent.team.map { [$0] } ?? [], initialTeam: parent.team?.id, isTeam: false, parentApp: parent) { _ in }
            }
        }
        .sheet(isPresented: $editingApp) { CatalogEditor(vault: vault, team: nil, app: app) }
        .sheet(isPresented: $copyingCI) { if let record = selectedRecord { CICopyView(vault: vault, record: record) } }
        .sheet(isPresented: $deleting) {
            if let record = selectedRecord {
                CredentialDeleteConfirmation(record: record) {
                    deleting = false
                    manage(record, trash: true)
                }
            }
        }
        .confirmationDialog(app.map { "「\($0.name)」を削除しますか？" } ?? "アプリを削除しますか？", isPresented: $deletingApp, titleVisibility: .visible) {
            Button("認証してアプリを削除", role: .destructive) { deleteApp() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("アプリと配下のターゲット・専用プロファイルを「最近削除した項目」へ移します。30日間は復元できます。チームで共有する鍵・証明書は残ります。")
        }
        .task {
            do {
                try vault.recover()
                if selected == nil { selected = visible.first(where: { $0.isTeamShared && $0.displayState(at: clock).needsRenewal })?.id ?? visible.first?.id }
            }
            catch { self.error = "保存状態を確認できません。\(error.localizedDescription)" }
        }
        .onChange(of: importing) { _, shown in if !shown { droppedSources = [] } }
        .onDisappear { lock() }
        .onChange(of: selected) { _, _ in access.lock(); revealedPassword = nil }
        .onChange(of: showReplaced) { _, _ in selected = nil }
        .onChange(of: search) { _, _ in lock(dismissImport: false) }
        .onChange(of: typeFilter) { _, _ in lock(dismissImport: false) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if Date.now.timeIntervalSince(clock) >= 60 { clock = .now }
            if revealedPassword != nil && Date.now.timeIntervalSince(revealedAt) >= 300 { revealedPassword = nil }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in lock() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !access.busy && !access.presentingPanel && !editingNote && !copyingCI && !editingApp { lock(dismissImport: false) }
        }
    }

    private var credentialList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let app {
                    AppIcon(app: app, size: 40)
                } else {
                    Image(systemName: "key.fill").font(.system(size: 24)).foregroundStyle(AppMateStyle.accent)
                        .frame(width: 40, height: 40).background(AppMateStyle.selectedRow, in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(CredentialSearch.hasQuery(search) ? "横断検索の結果" : app?.name ?? scope.title)
                        .font(.system(size: 20, weight: .bold)).lineLimit(2)
                    Text("\(CredentialSearch.hasQuery(search) ? "すべてのTeam・App · " : app.map { $0.platform + "アプリ · " } ?? "")鍵とファイル \(visible.count)件")
                        .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    if app != nil {
                        Button("ターゲットを追加…") { addingTarget = true }
                        Button("App情報") { selected = nil; showingInspector = true }
                        Button("アプリを編集…") { editingApp = true }
                        Button("アプリを削除…", role: .destructive) { deletingApp = true }.disabled(access.busy)
                        Divider()
                    }
                    Toggle("置き換え済みを表示", isOn: $showReplaced)
                    Button("ロック", systemImage: "lock") { lock() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 28, height: 28).help("表示と管理").accessibilityLabel("表示と管理")
            }.padding(.bottom, 16)
            if let app, app.parentAppID == nil, app.targets.count > 1 {
                Picker("ターゲット", selection: $targetFilter) {
                    Text("すべてのターゲット").tag(nil as UUID?)
                    ForEach(app.targets) { target in
                        Text("\(target.id == app.id ? "本体" : target.name) · \(target.bundleID)").tag(Optional(target.id))
                    }
                }
                .onChange(of: targetFilter) { _, _ in lock(dismissImport: false) }
                .padding(.bottom, 8)
            }
            let attention = visible.filter { $0.displayState(at: clock).needsRenewal || $0.displayState(at: clock) == .expired }
            if !attention.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 18)).foregroundStyle(AppMateStyle.warningText)
                    Text(attentionMessage(attention))
                        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    Button("手順を見る") { showingRenewalGuide = true }.buttonStyle(.borderless).foregroundStyle(AppMateStyle.accent)
                        .popover(isPresented: $showingRenewalGuide) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("証明書とプロファイルを更新する").font(.headline)
                                Text("1. Apple Developerで新しい証明書やプロファイルを用意します。")
                                Text("2. 「ファイルを追加」で新しいファイルを選びます。")
                                Text("3. 「既存の資格情報を置き換える」で旧ファイルと共有先を確認します。旧ファイルは保持されます。")
                            }.font(.system(size: 13)).padding(20).frame(width: 340)
                        }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppMateStyle.warningBanner, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppMateStyle.warningBorder, lineWidth: 1))
                    .padding(.bottom, 16)
            }
            HStack(spacing: 0) {
                Text("名前").frame(maxWidth: .infinity, alignment: .leading)
                Text("種類").frame(width: typeWidth, alignment: .leading)
                Text("期限").frame(width: expirationWidth, alignment: .leading)
                Text("状態").frame(width: stateWidth, alignment: .trailing)
            }.font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).padding(8)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(!CredentialSearch.hasQuery(search) && typeFilter == .all ? "鍵やファイルがありません" : "条件に一致する項目がありません", systemImage: "magnifyingglass")
                } description: {
                    Text(CredentialSearch.hasQuery(search) || typeFilter != .all ? "検索語や種類を変えて確認してください。" : app == nil ? "該当する資格情報はありません。" : "このアプリで使う鍵や証明書をここにドラッグ＆ドロップして追加できます。")
                } actions: {
                    if app != nil { Button("ファイルを追加…") { importing = true } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let app, app.deletedAt == nil, !CredentialSearch.hasQuery(search),
                              !urls.isEmpty, !access.busy, !importing else { return false }
                        droppedSources = urls
                        importing = true
                        return true
                    }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if visible.contains(where: { !$0.isTeamShared }) {
                            groupHeading(app == nil ? "アプリ専用" : "このアプリ専用")
                            ForEach(visible.filter { !$0.isTeamShared }) { record in row(record) }
                        }
                        if visible.contains(where: \.isTeamShared) {
                            HStack(spacing: 6) {
                                Text("チームで共通").fontWeight(.bold)
                                if let count = app?.team?.apps.filter({ $0.deletedAt == nil }).count {
                                    Text("\(count)アプリで共有").foregroundStyle(AppMateStyle.accent)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(AppMateStyle.selectedRow, in: Capsule())
                                }
                            }.font(.system(size: 12)).padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 6)
                            ForEach(visible.filter(\.isTeamShared)) { record in row(record) }
                        }
                    }
                }.frame(maxHeight: .infinity)
                    .focusable().focusEffectDisabled()
                    .onMoveCommand { direction in
                        guard !visible.isEmpty, direction == .up || direction == .down else { return }
                        let index = visible.firstIndex { $0.id == selected } ?? (direction == .down ? -1 : visible.count)
                        selected = visible[min(max(index + (direction == .down ? 1 : -1), 0), visible.count - 1)].id
                    }
            }
            if access.busy { ProgressView("認証しています…").font(.caption).padding(.vertical, 10) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).textSelection(.enabled).padding(.vertical, 10) }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(AppMateStyle.secondary).padding(.vertical, 10) }
        }.padding(.horizontal, 24).padding(.top, 20).background(AppMateStyle.canvas)
    }

    private var typeWidth: CGFloat { max(76, (listWidth - 48) * 0.22) }
    private var expirationWidth: CGFloat { max(84, (listWidth - 48) * 0.21) }
    private var stateWidth: CGFloat { max(82, (listWidth - 48) * 0.16) }

    private func attentionMessage(_ records: [StoredCredential]) -> String {
        let dates = records.compactMap(\.expiresAt)
        if let first = dates.first, first > clock, dates.allSatisfy({ Calendar.current.isDate($0, inSameDayAs: first) }) {
            return "\(records.count)件が\(first.formatted(.dateTime.month().day()))に期限切れ。新しい証明書とプロファイルを追加しましょう"
        }
        return "\(records.count)件の期限を確認してください。新しい証明書とプロファイルを追加しましょう"
    }

    private func groupHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .bold)).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
    }

    private func row(_ record: StoredCredential) -> some View {
        Button { selected = record.id; if !inlineInspector { showingInspector = true } } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name).fontWeight(.medium).lineLimit(2)
                    if app == nil {
                        Text([record.team?.name, record.app?.name, record.app?.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(AppMateStyle.secondary).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.fileTypeTitle).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Text("." + record.fileExtension).font(.system(size: 10, design: .monospaced))
                }.foregroundStyle(AppMateStyle.secondary).frame(width: typeWidth, alignment: .leading)
                Text(record.expiresAt?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) ?? "なし")
                    .font(.system(size: 12)).frame(width: expirationWidth, alignment: .leading)
                CredentialStatusBadge(state: record.displayState(at: clock)).frame(width: stateWidth, alignment: .trailing)
            }.padding(.horizontal, 8).padding(.vertical, 8).frame(minHeight: 36)
                .background(selected == record.id ? AppMateStyle.selectedRow : .clear)
                .overlay(alignment: .bottom) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected == record.id ? .isSelected : [])
    }

    @ViewBuilder private var inspector: some View {
        if let record = selectedRecord {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(record.fileTypeTitle)（.\(record.fileExtension)） · \(record.isTeamShared ? "チームで共通" : "このアプリ専用")")
                                .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                            Text(record.name).font(.system(size: 20, weight: .bold))
                            Text(record.isIntermediateCA ? "署名用証明書の発行元となる中間CA証明書です。アプリへの署名に使う個人の証明書とは異なります。" : record.fileExtension == "p12" ? "アプリへの署名に使う証明書と秘密鍵です" : record.fileExtension == "p8" ? "Appleのサービスへの認証に使います" : record.isTeamShared ? "アプリへの署名に使う証明書です" : "このアプリの署名と配布に使います")
                                .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayState(at: clock).title).font(.system(size: 22, weight: .bold))
                                .foregroundStyle(CredentialStatusBadge(state: record.displayState(at: clock)).foreground)
                            Text(record.expiresAt.map { $0.formatted(date: .long, time: .omitted) + "に期限切れ" } ?? "期限はありません。失効状態はApple側で確認してください。")
                                .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                        }.padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(CredentialStatusBadge(state: record.displayState(at: clock)).background, in: RoundedRectangle(cornerRadius: 10))
                        VStack(spacing: 8) {
                            Button { export(record) } label: { Text("ファイルを書き出す").frame(maxWidth: .infinity) }
                                .buttonStyle(AppMateButtonStyle(primary: true))
                            Button { copyingCI = true } label: { Text("CIに登録する値をコピー").frame(maxWidth: .infinity) }
                            Button { copyingCI = true } label: { Text("コピー項目を選ぶ…").frame(maxWidth: .infinity, alignment: .leading) }
                                .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(AppMateStyle.accent)
                            Button { export(record, revealInFinder: true) } label: {
                                Label("書き出してFinderで表示", systemImage: "folder").frame(maxWidth: .infinity)
                            }
                        }.buttonStyle(AppMateButtonStyle()).frame(maxWidth: .infinity).disabled(access.busy)
                        VStack(alignment: .leading, spacing: 10) {
                            metadata("ファイルの種類", "\(record.fileTypeTitle)（.\(record.fileExtension)）")
                            if record.isIntermediateCA {
                                metadata("Team ID", "対象外（中間CA証明書）")
                                metadata("保管先チーム", record.team?.name ?? "未設定")
                            } else {
                                metadata("チームID", record.team?.teamID ?? "未取得", monospaced: true)
                            }
                            if let owner = record.app { metadata("アプリ", owner.name); metadata("Bundle ID", owner.bundleID, monospaced: true) }
                            metadata("追加した日", record.createdAt.formatted(date: .long, time: .omitted))
                            metadata("元のファイル名", record.originalName, monospaced: true)
                            if let value = record.keyID { metadata("Key ID", value, monospaced: true) }
                            if let value = record.issuerID { metadata("Issuer ID", value, monospaced: true) }
                            if record.fileExtension == "p12" {
                                HStack(alignment: .top, spacing: 12) {
                                    Text("パスワード").foregroundStyle(AppMateStyle.secondary).frame(width: 96, alignment: .leading)
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(revealedPassword.map { $0.isEmpty ? "空のパスワード" : $0 } ?? (record.hasSavedPassword ? "••••••••" : "未保存"))
                                            .monospaced().privacySensitive().textSelection(.disabled).frame(maxWidth: .infinity, alignment: .leading)
                                        if revealedPassword != nil { Button("パスワードを隠す") { revealedPassword = nil } }
                                        else if record.hasSavedPassword { Button("認証して表示") { revealPassword(record) }.fixedSize().disabled(access.busy) }
                                    }.font(.system(size: 12)).buttonStyle(AppMateButtonStyle(compact: true))
                                }
                            }
                            HStack(alignment: .top, spacing: 12) {
                                Text("メモ").foregroundStyle(AppMateStyle.secondary).frame(width: 96, alignment: .leading)
                                Button("認証してメモを表示") { editingNote = true }.buttonStyle(AppMateButtonStyle(compact: true)).font(.system(size: 12))
                            }
                            if let id = record.replacedByID {
                                metadata("置き換え先", records.first { $0.id == id }?.name ?? "未確認")
                                Button("認証して通常一覧に戻す") { restore(record) }.disabled(access.busy)
                            }
                            if let id = record.replacesCredentialID { metadata("置き換え元", records.first { $0.id == id }?.name ?? "未確認") }
                        }.buttonStyle(.borderless)
                        Text("表示・書き出し・コピーにはTouch IDまたはMacのパスワードで認証します。コピーした値は60秒後、内容が変わっていない場合だけ消去します。")
                            .font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary)
                        Spacer(minLength: 12)
                        Divider()
                        HStack {
                            Button("削除…", role: .destructive) { deleting = true }.foregroundStyle(AppMateStyle.dangerText)
                            Spacer()
                            Menu {
                                Button(record.revokedAt == nil ? "認証して手動失効にする" : "認証して手動失効を解除") { manage(record, trash: false) }
                                Button("ファイルの識別情報…") { showingIdentity = true }
                                Button("ロック", systemImage: "lock") { lock() }
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                                .frame(width: 28, height: 28).accessibilityLabel("資格情報の管理")
                        }.font(.system(size: 12)).buttonStyle(.borderless).disabled(access.busy)
                    }.padding(22).frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
        } else if let app {
            VStack(alignment: .leading, spacing: 16) {
                Text("App情報").font(.system(size: 18, weight: .semibold))
                metadata(app.parentAppID == nil ? "本体のBundle ID" : "Bundle ID", app.bundleID, monospaced: true)
                if app.parentAppID != nil { metadata("所属アプリ", app.product.name) }
                if app.parentAppID == nil && app.targets.count > 1 {
                    metadata("ターゲット", app.targets.map { $0.id == app.id ? "本体" : $0.name }.joined(separator: "・"))
                }
                metadata("プラットフォーム", app.platform)
                metadata("チーム", app.team?.name ?? "未設定")
                metadata("チームID", app.team?.teamID ?? "未設定", monospaced: true)
                Divider()
                Button("ターゲットを追加…") { addingTarget = true }
                Button("App・ターゲットを編集…") { editingApp = true }
                Button("暗号化メモを開く…") { editingNote = true }
                Text("中央の鍵やファイルを選ぶと詳細を表示します。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Divider()
                Button("アプリを削除…", role: .destructive) { deletingApp = true }
                    .foregroundStyle(AppMateStyle.dangerText).disabled(access.busy)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView("鍵やファイルを選択", systemImage: "sidebar.right",
                                   description: Text("中央の一覧から選ぶと詳細を表示します。"))
        }
    }

    private func metadata(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(AppMateStyle.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    private func lock(dismissImport: Bool = true) {
        access.lock()
        deleting = false
        deletingApp = false
        showingRenewalGuide = false
        showingIdentity = false
        showingInspector = false
        if dismissImport { importing = false }
        selected = nil
        revealedPassword = nil
        error = nil
        status = "ロックしました。書き出すときは再認証します。"
    }

    private func export(_ record: StoredCredential, revealInFinder: Bool = false) {
        let generation = access.generation
        access.presentingPanel = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.originalName
        panel.message = "元の形式で書き出します。保存先ではApp Mateの暗号化保護の対象外になります。新しい名前を指定してください。既存ファイルは上書きしません。"
        let response = panel.runModal()
        access.presentingPanel = false
        guard response == .OK, let url = panel.url, generation == access.generation else { return }
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: "資格情報の元ファイルを書き出します", allowCreation: false, vault: vault) { key in
                    try vault.export(record, to: url, key: key)
                }
                if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                status = "ファイルを書き出しました。保存先のファイルはご自身で管理してください。"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func restore(_ record: StoredCredential) {
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: "旧資格情報を通常一覧に戻します", allowCreation: false, vault: vault) { key in
                    try vault.restoreToList(record, key: key)
                }
                status = "旧資格情報を通常一覧に戻しました。新旧どちらのファイルも保持しています。"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func manage(_ record: StoredCredential, trash: Bool) {
        Task { @MainActor in
            do {
                try await access.withKey(reason: trash ? "資格情報を最近削除した項目へ移します" : "手動失効の状態を変更します", allowCreation: false, vault: vault) { key in
                    if trash { try VaultManagement(vault: vault).trash(record, key: key) }
                    else { try VaultManagement(vault: vault).setRevoked(record, key: key) }
                }
                if trash { selected = nil }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func deleteApp() {
        guard let app else { return }
        Task { @MainActor in
            do {
                let create = try vault.canCreateKey()
                try await access.withKey(reason: "登録済みアプリを削除します", allowCreation: create, vault: vault) { key in
                    try VaultManagement(vault: vault).trash(app, key: key)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func revealPassword(_ record: StoredCredential) {
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: "保存済みの.p12パスワードを表示します", allowCreation: false, vault: vault) { key in
                    guard let password = try vault.read(record, key: key).password else { throw ValidationError.invalidFile }
                    revealedPassword = password
                    revealedAt = .now
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CredentialImportView: View {
    let app: ManagedApp
    let vault: CredentialVault
    // 一覧のバックグラウンドロックで取り込み途中の内容を破棄しない。
    @State private var access = VaultAccess()
    let existing: [StoredCredential]
    var initialSources: [URL] = []
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var addingTarget = false
    @State private var importTargetID: UUID?
    @State private var lastSavedID: UUID?
    @State private var sources: [URL] = []
    @State private var queue: [URL] = []
    @State private var completedItems: [String] = []
    @State private var currentName = ""
    @State private var file: CredentialFile?
    @State private var candidates: [ParsedCredential] = []
    @State private var selected = -1
    @State private var password = ""
    @State private var parsedPassword = ""
    @FocusState private var passwordFocused: Bool
    @State private var savePassword = true
    @State private var confirmUnknownTeam = false
    @State private var purpose: P8Purpose?
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var replacing = false
    @State private var targetID: UUID?
    @State private var confirmReplacement = false
    @State private var reading = false
    @State private var parseID = UUID()
    @State private var lastActivity = Date.now
    @State private var error: String?

    private var finished: Bool { currentName.isEmpty && queue.isEmpty && !completedItems.isEmpty }
    private var parsed: ParsedCredential? { candidates.indices.contains(selected) ? candidates[selected] : nil }
    private var isP8: Bool { file.map { ($0.name as NSString).pathExtension.lowercased() == "p8" } ?? false }
    private var p8: P8Metadata? {
        guard isP8, let purpose else { return nil }
        return P8Metadata(purpose: purpose, keyID: keyID, issuerID: issuerID)
    }
    private var replacementCandidates: [StoredCredential] {
        guard let file else { return [] }
        let ext = (file.name as NSString).pathExtension.lowercased()
        return existing.filter { $0.isVisible(in: importApp) && $0.replacedByID == nil && $0.fileExtension == ext && $0.keyPurpose == p8?.purpose.rawValue }
    }
    private var importApp: ManagedApp {
        let targets = app.product.targets
        if let importTargetID, let target = targets.first(where: { $0.id == importTargetID }) { return target }
        if let bundle = parsed?.bundleID {
            if let target = app.target(forProfileBundleID: bundle) { return target }
        }
        return app
    }
    private var unregisteredBundle: String? {
        guard let bundle = parsed?.bundleID, !bundle.contains("*"),
              parsed?.teamID == app.team?.teamID,
              !app.product.targets.contains(where: { $0.bundleID == bundle }) else { return nil }
        return bundle
    }
    private var validationIssue: String? {
        guard let file, let parsed else { return nil }
        do {
            if replacing && targetID == nil { return "置き換える旧資格情報を選んでください。" }
            try vault.validate(file: file, parsed: parsed, app: importApp, confirmUnknownTeam: confirmUnknownTeam,
                               p8: p8, replacingID: replacing ? targetID : nil, confirmReplacement: confirmReplacement)
            return nil
        }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(finished ? "ファイルの処理が完了しました" : isP8 ? ".p8の情報を入力" : currentName.isEmpty ? "ファイルを追加" : "\(completedItems.count + queue.count + 1)件のファイルを追加します")
                .font(.system(size: 18, weight: .bold))
            Text(finished ? "処理結果を確認して閉じてください。元ファイルは変更していません。" : "内容と追加先を確認してください。\(app.name) ／ \(app.team?.name ?? "チーム未設定")").foregroundStyle(AppMateStyle.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if finished {
                        Label("処理済み \(completedItems.count)件", systemImage: "checkmark.circle")
                            .font(.headline).foregroundStyle(AppMateStyle.accent)
                        ForEach(Array(completedItems.enumerated()), id: \.offset) { _, result in
                            Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if file == nil {
                    Button(action: chooseFile) {
                        VStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 24))
                            Text("ファイル・フォルダを選ぶ…").fontWeight(.medium)
                            Text("ここにドロップして追加できます").font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                        }.frame(maxWidth: .infinity).padding(18)
                            .background(AppMateStyle.selectedRow, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppMateStyle.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    }.buttonStyle(.plain).foregroundStyle(AppMateStyle.accent)
                    Text(".cer・.p12・.p8・.mobileprovision・.provisionprofile、各16MB以下。複数ファイルやフォルダをドロップできます。1件ずつ解析と所属を確認して取り込みます。")
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(currentName).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button("ファイルを選び直す…", action: chooseFile).buttonStyle(.borderless).foregroundStyle(AppMateStyle.accent)
                        }
                    }
                    if !finished && !completedItems.isEmpty {
                        DisclosureGroup("処理結果 \(completedItems.count)件・残り \(queue.count + (currentName.isEmpty ? 0 : 1))件") {
                            ForEach(Array(completedItems.enumerated()), id: \.offset) { _, result in Text(result).font(.caption) }
                        }
                    }
                    if let file, !isP8 {
                        VStack(spacing: 0) {
                            HStack {
                                Text("ファイル").frame(maxWidth: .infinity, alignment: .leading)
                                Text("種類").frame(width: 100, alignment: .leading)
                                Text("期限").frame(width: 100, alignment: .leading)
                                Text("追加先").frame(width: 100, alignment: .leading)
                            }.font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).padding(.vertical, 8)
                            Divider()
                            HStack(alignment: .top) {
                                Text(file.name).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(parsed?.kind ?? "確認中").frame(width: 100, alignment: .leading)
                                Text(parsed?.expiresAt?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) ?? "なし・未確認").frame(width: 100, alignment: .leading)
                                Text(parsed?.bundleID == nil ? "チームで共通" : importApp.name).foregroundStyle(AppMateStyle.accent).frame(width: 100, alignment: .leading)
                            }.padding(.vertical, 10)
                            Divider()
                            ForEach(queue, id: \.self) { url in
                                HStack {
                                    Text(url.lastPathComponent).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("次に確認").foregroundStyle(AppMateStyle.secondary)
                                }.padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                    if let file, file.requiresPasswordEntry, candidates.isEmpty {
                        SecureField("この.p12のパスワード", text: $password)
                            .textFieldStyle(.roundedBorder).focused($passwordFocused)
                            .onSubmit(parsePKCS12)
                        Text("パスワードが設定されていない場合は空欄のまま解析してください。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("パスワードを使って解析", action: parsePKCS12)
                    }
                    if candidates.count > 1 {
                        Picker("証明書", selection: $selected) {
                            Text("表示と期限の基準にする証明書を選択").tag(-1)
                            ForEach(candidates.indices, id: \.self) { index in
                                Text("\(candidates[index].name) — \(candidates[index].fingerprint?.prefix(12) ?? "")").tag(index)
                            }
                        }
                    }
                    if let parsed {
                        if parsed.bundleID != nil {
                            Picker("登録先ターゲット", selection: Binding(get: { importApp.id }, set: { importTargetID = $0; targetID = nil; confirmReplacement = false; lastActivity = .now })) {
                                ForEach(app.product.targets) { target in
                                    Text("\(target.name) · \(target.bundleID)").tag(target.id)
                                }
                            }
                            if let bundle = unregisteredBundle {
                                Text("Bundle ID「\(bundle)」のターゲットは未登録です。")
                                    .font(.caption).foregroundStyle(AppMateStyle.secondary)
                                Button("このアプリにターゲットを追加…") { addingTarget = true }
                            }
                        }
                        if isP8 {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                                GridRow {
                                    Text("用途").frame(width: 120, alignment: .leading)
                                    Picker("用途", selection: $purpose) {
                                        Text("用途を選択してください").tag(nil as P8Purpose?)
                                        ForEach(P8Purpose.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                                    }.labelsHidden()
                                }
                                GridRow { Text("登録先チーム"); Text("\(app.team?.name ?? "")（\(app.team?.teamID ?? "")）") }
                                GridRow { Text("Key ID"); TextField("英大文字・数字10文字", text: $keyID).labelsHidden() }
                                if purpose == .appStoreConnect {
                                    GridRow { Text("Issuer ID"); TextField("App Store ConnectのIssuer ID", text: $issuerID).labelsHidden() }
                                }
                            }.textFieldStyle(.roundedBorder).controlSize(.large)
                            Text("このチームの全アプリに自動表示します。用途と識別情報はApple Developerの登録内容を確認してください。")
                                .font(.system(size: 12)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppMateStyle.warningBackground, in: RoundedRectangle(cornerRadius: 9))
                        }
                        DisclosureGroup("読み取った識別情報") {
                            VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("名前", value: parsed.name)
                        LabeledContent("期限", value: parsed.expiresAt?.formatted(date: .abbreviated, time: .standard) ?? "期限なし")
                        LabeledContent("取得したTeam ID", value: parsed.isIntermediateCA ? "対象外（中間CA証明書）" : parsed.teamID ?? "未取得")
                        if let bundle = parsed.bundleID { LabeledContent("Bundle ID", value: bundle) }
                        if let fingerprint = parsed.fingerprint { Text("SHA-256：\(fingerprint)").font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                        if !isP8 && !parsed.isIntermediateCA && parsed.teamID == nil {
                            Toggle("Team IDを判別できないため、\(app.team?.name ?? "選択中のTeam")に割り当てることを確認しました", isOn: $confirmUnknownTeam)
                        }
                        let isP12 = (file?.name as NSString?)?.pathExtension.lowercased() == "p12"
                        Text(parsed.isIntermediateCA ? "中間CA証明書には個人のTeam IDはありません。選択中のTeamを保管先として保存します。" : parsed.bundleID == nil ? "同じTeamのすべてのAppに表示されます。" : "「\(importApp.name)」専用のプロファイルとして保存します。")
                        if isP12 {
                            Toggle(".p12のパスワードも暗号化して保存", isOn: $savePassword)
                            Text("証明書チェーンと秘密鍵を含む元の.p12全体を保存・書き出しします。証明書の選択は表示情報だけを変えます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("既存の資格情報を置き換える", isOn: $replacing)
                        if replacing {
                            Picker("置き換え元", selection: $targetID) {
                                Text("旧資格情報を選択してください").tag(nil as UUID?)
                                ForEach(replacementCandidates) { old in Text("\(old.name) ／ \(old.originalName)").tag(Optional(old.id)) }
                            }
                            if let old = replacementCandidates.first(where: { $0.id == targetID }) {
                                Text("旧：\(old.name) → 新：\(p8?.purpose.title ?? parsed.name)（\(file?.name ?? "")）")
                                Text("影響するApp：" + (old.isTeamShared
                                    ? (app.team?.apps.map { "\($0.name)（\($0.bundleID)）" }.sorted().joined(separator: "、") ?? app.name)
                                    : "\(importApp.name)（\(importApp.bundleID)）"))
                                Toggle("旧→新と共有先を確認しました。旧ファイルを保持して置き換えます", isOn: $confirmReplacement)
                            }
                        }
                        Text("解析はローカルの内容の確認です。Apple発行元の信頼性・失効状態・秘密鍵との対応は検証していません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if reading || access.busy { ProgressView(reading ? "解析しています…" : "認証して暗号化保存しています…") }
                    if let issue = error ?? validationIssue {
                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !finished, !reading, !access.busy else { return false }
                start(urls)
                return true
            }
            .disabled(reading || access.busy)
            Divider()
            HStack(spacing: 10) {
                if !finished {
                    Button("キャンセル") { access.lock(); dismiss() }.keyboardShortcut(.cancelAction)
                    if !currentName.isEmpty {
                        Button("スキップ") { completedItems.append("スキップ：" + currentName + (error.map { " · " + $0 } ?? "")); next() }
                    }
                    Spacer()
                    Button("認証して取り込む", action: save).keyboardShortcut(.defaultAction).buttonStyle(AppMateButtonStyle(primary: true))
                        .disabled(reading || access.busy || parsed == nil || validationIssue != nil)
                } else {
                    Spacer()
                    Button("閉じる") { access.lock(); dismiss() }
                        .keyboardShortcut(.defaultAction).buttonStyle(AppMateButtonStyle(primary: true))
                }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 24).frame(width: isP8 ? 600 : 720, height: 620)
        .font(.system(size: 13)).buttonStyle(AppMateButtonStyle()).background(AppMateStyle.canvas).tint(AppMateStyle.accent)
        .sheet(isPresented: $addingTarget) {
            if let bundle = unregisteredBundle {
                let parent = app.product
                RegistrationForm(container: vault.context.container, teams: parent.team.map { [$0] } ?? [], initialTeam: parent.team?.id, isTeam: false, parentApp: parent, initialBundleID: bundle, initialName: parsed?.name ?? "") { id in
                    importTargetID = id
                    error = nil
                }
            }
        }
        .task { if !initialSources.isEmpty { start(initialSources) } }
        .onChange(of: password) { _, _ in lastActivity = .now }
        .onChange(of: selected) { _, _ in lastActivity = .now; confirmUnknownTeam = false; targetID = nil; confirmReplacement = false }
        .onChange(of: purpose) { _, _ in lastActivity = .now; issuerID = ""; targetID = nil; confirmReplacement = false }
        .onChange(of: keyID) { _, _ in lastActivity = .now; confirmReplacement = false }
        .onChange(of: issuerID) { _, _ in lastActivity = .now; confirmReplacement = false }
        .onChange(of: targetID) { _, _ in lastActivity = .now; confirmReplacement = false }
        .onChange(of: replacing) { _, _ in lastActivity = .now; targetID = nil; confirmReplacement = false }
        .onChange(of: confirmUnknownTeam) { _, _ in lastActivity = .now }
        .onChange(of: savePassword) { _, _ in lastActivity = .now }
        .onChange(of: access.generation) { _, _ in clear() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if Date.now.timeIntervalSince(lastActivity) >= 300 { access.lock(); dismiss() }
        }
        .onDisappear { clear(); releaseSources(); access.lock() }
    }

    private func clear() {
        importTargetID = nil
        parseID = UUID()
        file = nil
        candidates = []
        selected = -1
        password = ""
        parsedPassword = ""
        confirmUnknownTeam = false
        purpose = nil
        keyID = ""
        issuerID = ""
        replacing = false
        targetID = nil
        confirmReplacement = false
    }

    private func chooseFile() {
        access.presentingPanel = true
        defer { access.presentingPanel = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["cer", "p12", "p8", "mobileprovision", "provisionprofile"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { start(panel.urls) }
    }

    private func releaseSources() {
        for url in sources { url.stopAccessingSecurityScopedResource() }
        sources = []
    }

    private func start(_ urls: [URL]) {
        releaseSources()
        sources = urls.filter { $0.startAccessingSecurityScopedResource() }
        do { queue = try ImportSources.collect(urls); completedItems = []; next() }
        catch { self.error = error.localizedDescription; releaseSources() }
    }

    private func next() {
        clear()
        error = nil
        guard !queue.isEmpty else {
            currentName = ""; releaseSources()
            if let lastSavedID { onSaved(lastSavedID); self.lastSavedID = nil }
            return
        }
        let url = queue.removeFirst()
        currentName = url.lastPathComponent
        load(url)
    }

    private func load(_ url: URL) {
        clear()
        error = nil
        let token = parseID
        let generation = access.generation
        lastActivity = .now
        reading = true
        Task { @MainActor in
            defer { reading = false }
            do {
                let (file, results) = try await Task.detached(priority: .userInitiated) {
                    let file = try CredentialFile(url: url)
                    let results = file.requiresPasswordEntry ? [] : try CredentialParser.parseAll(file.data, extension: url.pathExtension)
                    return (file, results)
                }.value
                guard token == parseID, generation == access.generation else { return }
                self.file = file
                candidates = results
                selected = results.count == 1 ? 0 : -1
                passwordFocused = file.requiresPasswordEntry
            } catch {
                if token == parseID, generation == access.generation { self.error = error.localizedDescription }
            }
        }
    }

    private func parsePKCS12() {
        guard let file, file.requiresPasswordEntry, !reading, !access.busy else { return }
        let inputPassword = password
        password = ""
        error = nil
        guard inputPassword.utf8.count <= 4096 else { error = "パスワードが長すぎます。"; passwordFocused = true; return }
        let token = parseID
        let generation = access.generation
        lastActivity = .now
        reading = true
        Task { @MainActor in
            defer { reading = false }
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try CredentialParser.parseAll(file.data, extension: "p12", password: inputPassword)
                }.value
                guard token == parseID, generation == access.generation else { return }
                candidates = results
                selected = results.count == 1 ? 0 : -1
                parsedPassword = inputPassword
                passwordFocused = false
            } catch {
                if token == parseID, generation == access.generation {
                    self.error = error.localizedDescription
                    passwordFocused = true
                }
            }
        }
    }

    private func save() {
        guard let file, let parsed else { return }
        error = nil
        lastActivity = .now
        let password = savePassword ? parsedPassword : nil
        let destination = importApp
        let confirmed = confirmUnknownTeam
        let metadata = p8
        let replacingID = replacing ? targetID : nil
        let replacementConfirmed = confirmReplacement
        Task { @MainActor in
            do {
                try vault.validate(file: file, parsed: parsed, app: destination, confirmUnknownTeam: confirmed, p8: metadata, replacingID: replacingID, confirmReplacement: replacementConfirmed)
                let canCreate = try vault.canCreateKey()
                let id = try await access.withKey(reason: "資格情報を暗号化して保存します", allowCreation: canCreate, vault: vault) { key in
                    try vault.importFile(file, parsed: parsed, app: destination, password: password, confirmUnknownTeam: confirmed, key: key, p8: metadata, replacingID: replacingID, confirmReplacement: replacementConfirmed)
                }
                lastSavedID = id
                completedItems.append("保存済み：" + file.name)
                next()
            } catch {
                parsedPassword = ""
                if file.requiresPasswordEntry { candidates = []; selected = -1; passwordFocused = true }
                self.error = error.localizedDescription
            }
        }
    }
}
