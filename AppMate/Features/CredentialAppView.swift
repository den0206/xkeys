import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum CredentialDisplayState: Equatable {
    case expired, withinDay, expiring(Int), valid, stored

    var needsRenewal: Bool {
        switch self { case .withinDay, .expiring: true; default: false }
    }
    var title: String {
        switch self {
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

    var purposeTitle: String {
        keyPurpose.flatMap(P8Purpose.purposes(stored:))?.map(\.title).joined(separator: "・") ?? "未設定"
    }

    func displayState(at now: Date) -> CredentialDisplayState {
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
        case .expired: AppMateStyle.dangerText
        case .withinDay, .expiring: AppMateStyle.warningText
        case .valid: AppMateStyle.successText
        case .stored: AppMateStyle.secondary
        }
    }
    var background: Color {
        switch state {
        case .expired: AppMateStyle.dangerBackground
        case .withinDay, .expiring: AppMateStyle.warningBackground
        case .valid: AppMateStyle.successBackground
        case .stored: AppMateStyle.sidebar
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
    let team: DeveloperTeam?
    let openTeam: (UUID) -> Void
    let scope: CredentialScope
    let container: ModelContainer
    @Binding var importing: Bool
    let search: String
    @Binding var typeFilter: CredentialTypeFilter
    var initialSources: [URL] = []
    @Query(sort: \StoredCredential.name) private var records: [StoredCredential]
    @State private var access = VaultAccess()
    @State private var selected: UUID?
    @State private var droppedSources: [URL] = []
    @State private var clock = Date.now
    @State private var onlineImporting = false
    @State private var error: String?
    @State private var status = ""
    @State private var revealedPassword: String?
    @State private var editingNote = false
    @State private var editingPurposes = false
    @State private var editingApp = false
    @State private var addingTarget = false
    @State private var targetFilter: UUID?
    @State private var copyingCI = false
    @State private var deleting = false
    @State private var selectingForDeletion = false
    @State private var checkedIDs: Set<UUID> = []
    @State private var deletionTargets: [StoredCredential] = []
    @State private var deletingBatch = false
    @State private var deletingApp = false
    @State private var showingRenewalGuide = false
    @State private var revealedAt = Date.distantPast

    /// Everything on this page, before the target filter. Attention counts use this, so they stay app-wide.
    private var scoped: [StoredCredential] {
        records.filter { CredentialSearch.includes($0, scope: scope, app: app, query: search, type: typeFilter, at: clock) }
    }
    private var visible: [StoredCredential] { scoped.filter { targetFilter == nil || $0.app?.id == targetFilter } }
    private var checkedRecords: [StoredCredential] { visible.filter { checkedIDs.contains($0.id) } }
    private var selectedRecord: StoredCredential? { visible.first { $0.id == selected } }
    private var vault: CredentialVault {
        CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))
    }

    var body: some View {
        credentialList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.system(size: 13))

        .sheet(isPresented: $importing) {
            if let team {
                CredentialImportView(app: app, team: team, vault: vault, initialSources: droppedSources.isEmpty ? initialSources : droppedSources) { id in
                    selected = id
                    status = "暗号化して保存しました。鍵・証明書はチームの一覧、プロファイルは対象アプリの一覧で確認できます。"
                }
            }
        }
        .sheet(isPresented: $onlineImporting) {
            if let team {
                AppleDeveloperImportView(team: team, vault: vault) { id in
                    selected = id
                    status = "Apple Developerから取得したファイルを暗号化して保存しました。"
                }.modelContainer(container)
            }
        }
        .sheet(isPresented: $editingNote) { NoteEditor(vault: vault, app: selectedRecord == nil ? app : nil, record: selectedRecord) }
        .sheet(isPresented: $editingPurposes) { if let record = selectedRecord { P8PurposeEditor(vault: vault, record: record) } }
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
                    trash(record)
                }
            }
        }
        .sheet(isPresented: $deletingBatch) {
            CredentialBatchDeleteConfirmation(records: deletionTargets) {
                deletingBatch = false
                deleteBatch(deletionTargets)
            }
        }
        .onChange(of: visible.map(\.id)) { _, ids in checkedIDs.formIntersection(Set(ids)) }
        .confirmationDialog(app.map { "「\($0.name)」を削除しますか？" } ?? "アプリを削除しますか？", isPresented: $deletingApp, titleVisibility: .visible) {
            Button("認証してアプリを削除", role: .destructive) { deleteApp() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("アプリと配下のターゲット・専用プロファイルを「最近削除した項目」へ移します。30日間は復元できます。チームで共有する鍵・証明書は残ります。")
        }
        .task {
            do {
                try vault.recover()
            }
            catch { self.error = "保存状態を確認できません。\(error.localizedDescription)" }
        }
        .onChange(of: importing) { _, shown in if !shown { droppedSources = [] } }
        .onDisappear { lock() }
        .onChange(of: selected) { _, _ in access.lock(); revealedPassword = nil }
        .onChange(of: search) { _, _ in lock(dismissImport: false) }
        .onChange(of: typeFilter) { _, _ in lock(dismissImport: false) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if Date.now.timeIntervalSince(clock) >= 60 { clock = .now }
            if revealedPassword != nil && Date.now.timeIntervalSince(revealedAt) >= 300 { revealedPassword = nil }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in lock() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !access.busy && !access.presentingPanel && !editingNote && !editingPurposes && !copyingCI && !editingApp { lock(dismissImport: false) }
        }
    }

    private var credentialList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let app, app.parentAppID == nil, app.targets.count > 1, !CredentialSearch.hasQuery(search) { targetFilterBar(app) }
                attentionBanner
                if selectingForDeletion { deletionBar }
                if visible.isEmpty {
                    emptyState
                } else {
                    ForEach(CredentialGroup.allCases.filter { group in visible.contains { CredentialGroup($0) == group } }, id: \.self) { group in
                        let items = visible.filter { CredentialGroup($0) == group }
                        CollapsibleSection(title: group.title, detail: sectionDetail(group, count: items.count),
                                           attention: scoped.filter { CredentialGroup($0) == group && $0.needsAttention(in: records, at: clock) }.count) {
                            ForEach(items) { row($0) }
                        }
                    }
                }
                if let app, let owner = app.team, !CredentialSearch.hasQuery(search) { teamLink(owner) }
                if access.busy { ProgressView("認証しています…").font(.caption) }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(AppMateStyle.dangerText).font(.caption).textSelection(.enabled) }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(AppMateStyle.secondary) }
            }.padding(.horizontal, 32).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppMateStyle.canvas)
        .focusable().focusEffectDisabled()
        .onMoveCommand { direction in
            guard !visible.isEmpty, direction == .up || direction == .down else { return }
            let index = visible.firstIndex { $0.id == selected } ?? (direction == .down ? -1 : visible.count)
            selected = visible[min(max(index + (direction == .down ? 1 : -1), 0), visible.count - 1)].id
        }
        .onChange(of: targetFilter) { _, _ in lock(dismissImport: false) }
        .dropDestination(for: URL.self) { urls, _ in
            guard team != nil, app?.deletedAt == nil, !CredentialSearch.hasQuery(search),
                  !urls.isEmpty, !access.busy, !importing else { return false }
            droppedSources = urls
            importing = true
            return true
        }
    }

    private var pageTitle: String {
        if CredentialSearch.hasQuery(search) { return "検索の結果" }
        if let app { return app.name }
        if case .team = scope { return "鍵と証明書" }
        return scope.title
    }

    private var pageSubtitle: String {
        if CredentialSearch.hasQuery(search) { return "すべてのチームとアプリ · \(visible.count)件" }
        if let app {
            let targets = app.parentAppID == nil && app.targets.count > 1 ? " · \(app.targets.count)ターゲット" : ""
            return "\(app.platform) · \(app.bundleID)\(targets)"
        }
        if case .team = scope, let team { return "\(team.name) のどのアプリでも使えるもの" }
        return "\(visible.count)件"
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let app {
                AppIcon(app: app, size: 52)
            } else {
                Image(systemName: "key").font(.system(size: 24)).foregroundStyle(AppMateStyle.text.opacity(0.75))
                    .frame(width: 52, height: 52).background(AppMateStyle.search, in: RoundedRectangle(cornerRadius: 13))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(pageTitle).font(.system(size: 22, weight: .bold)).lineLimit(2)
                Text(pageSubtitle).foregroundStyle(AppMateStyle.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if app != nil {
                Button("メモ") { selected = nil; editingNote = true }.buttonStyle(AppMateButtonStyle(compact: true)).disabled(access.busy)
            } else if team != nil, case .team = scope, !CredentialSearch.hasQuery(search) {
                Button("Apple Developer から取り込む", systemImage: "icloud.and.arrow.down") { onlineImporting = true }
                    .buttonStyle(AppMateButtonStyle(compact: true)).disabled(access.busy)
            }
            Menu {
                Button("鍵・ファイルを一括削除…") {
                    selectingForDeletion = true
                    checkedIDs = []
                }.disabled(visible.isEmpty || access.busy)
                if app != nil {
                    Divider()
                    Button("ターゲットを追加…") { addingTarget = true }
                    Button("アプリを編集…") { editingApp = true }
                    Button("アプリを削除…", role: .destructive) { deletingApp = true }.disabled(access.busy)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 30, height: 30).overlay(RoundedRectangle(cornerRadius: 8).stroke(AppMateStyle.border))
                .help("表示と管理").accessibilityLabel("表示と管理")
        }
    }

    private func targetFilterBar(_ app: ManagedApp) -> some View {
        HStack(spacing: 6) {
            targetChip("すべて", id: nil)
            ForEach(app.targets) { target in targetChip(target.id == app.id ? "本体" : target.name, id: target.id) }
        }.accessibilityElement(children: .contain).accessibilityLabel("ターゲットで絞り込む")
    }

    private func targetChip(_ title: String, id: UUID?) -> some View {
        let on = targetFilter == id
        return Button(title) { targetFilter = id }
            .buttonStyle(.plain).font(.system(size: 12, weight: on ? .semibold : .regular))
            .padding(.horizontal, 12).frame(height: 28)
            .foregroundStyle(on ? Color.white : AppMateStyle.text.opacity(0.8))
            .background(on ? AppMateStyle.text : AppMateStyle.canvas, in: Capsule())
            .overlay(Capsule().stroke(on ? AppMateStyle.text : AppMateStyle.border))
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var attentionBanner: some View {
        let attention = scoped.filter { $0.needsAttention(in: records, at: clock) }
        if !attention.isEmpty {
            let broken = attention.filter { $0.displayState(at: clock) == .expired || $0.signingCertificatesExpired(in: records, at: clock) }
            let danger = !broken.isEmpty
            HStack(spacing: 12) {
                Image(systemName: danger ? "exclamationmark.circle" : "clock").font(.system(size: 17))
                    .foregroundStyle(danger ? AppMateStyle.danger : AppMateStyle.warningText)
                Text(attentionMessage(attention)).frame(maxWidth: .infinity, alignment: .leading)
                Button("直し方を見る") { showingRenewalGuide = true }
                    .buttonStyle(AppMateButtonStyle(compact: true))
                    .popover(isPresented: $showingRenewalGuide) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("証明書とプロファイルを更新する").font(.headline)
                            Text("1. Apple Developerで新しい証明書やプロファイルを用意します。")
                            Text("2. 「ファイルを追加」で新しいファイルを選びます。")
                            Text("3. 不要になった旧ファイルは削除します。")
                        }.font(.system(size: 13)).padding(20).frame(width: 340)
                    }
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(danger ? Color(red: 0.5, green: 0.11, blue: 0.11) : AppMateStyle.warningText)
                .background(danger ? AppMateStyle.dangerBackground : AppMateStyle.warningBanner, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(danger ? AppMateStyle.dangerBorder : AppMateStyle.warningBorder))
        }
    }

    private func attentionMessage(_ records: [StoredCredential]) -> String {
        let unusable = records.filter { CredentialGroup($0) == .profile && $0.signingCertificatesExpired(in: self.records, at: clock) }
        if !unusable.isEmpty {
            return "署名に使う証明書が期限切れのため、プロファイル \(unusable.count)件が使えません。"
        }
        let dates = records.compactMap(\.expiresAt)
        if let first = dates.first, first > clock, dates.allSatisfy({ Calendar.current.isDate($0, inSameDayAs: first) }) {
            return "\(records.count)件が\(first.formatted(.dateTime.month().day()))に期限切れになります。新しいファイルを追加しましょう。"
        }
        return "\(records.count)件の期限を確認してください。新しいファイルを追加しましょう。"
    }

    private var deletionBar: some View {
        HStack(spacing: 12) {
            Button(checkedRecords.count == visible.count ? "選択を解除" : "すべて選択") {
                checkedIDs = checkedRecords.count == visible.count ? [] : Set(visible.map(\.id))
            }
            Text("\(checkedRecords.count)件選択").foregroundStyle(AppMateStyle.secondary)
            Spacer()
            Button("キャンセル") { selectingForDeletion = false; checkedIDs = [] }
            Button("削除…", role: .destructive) {
                deletionTargets = checkedRecords
                deletingBatch = true
            }.disabled(checkedRecords.isEmpty)
        }.buttonStyle(AppMateButtonStyle(compact: true)).disabled(access.busy)
    }

    private func sectionDetail(_ group: CredentialGroup, count: Int) -> String {
        switch group {
        case .profile: app == nil || CredentialSearch.hasQuery(search) ? "\(count)" : "\(count) · このアプリ専用"
        case .certificate: "\(count)"
        case .key: "\(count) · 期限なし · どのアプリで使っているかは記録していません"
        }
    }

    @ViewBuilder private var emptyState: some View {
        if CredentialSearch.hasQuery(search) || typeFilter != .all {
            ContentUnavailableView("条件に一致する項目がありません", systemImage: "magnifyingglass",
                                   description: Text("検索語や種類を変えて確認してください。"))
        } else if team != nil, app?.deletedAt == nil, app != nil || isTeamScope {
            VStack(spacing: 12) {
                CredentialDropZone(title: app != nil ? "このアプリのプロファイルをドロップ" : "証明書や鍵をドロップ",
                                   formats: app != nil ? [".mobileprovision", ".provisionprofile"] : ["証明書 .p12 · .cer", "鍵 .p8"]) { importing = true }
                AppleImportCard { onlineImporting = true }
            }.disabled(access.busy)
        } else {
            ContentUnavailableView("該当する項目はありません", systemImage: "checkmark.circle")
        }
    }

    private var isTeamScope: Bool { if case .team = scope { true } else { false } }

    private func teamLink(_ owner: DeveloperTeam) -> some View {
        Button { openTeam(owner.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "key")
                Text("署名用の証明書と、通知などに使う鍵は「鍵と証明書」にあります")
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppMateStyle.tertiary)
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(AppMateStyle.text.opacity(0.8))
                .background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppMateStyle.rowBorder))
        }.buttonStyle(.plain)
    }

    private func row(_ record: StoredCredential) -> some View {
        let state = record.displayState(at: clock)
        let certificatesExpired = CredentialGroup(record) == .profile && record.signingCertificatesExpired(in: records, at: clock)
        let broken = state == .expired || certificatesExpired
        let isSelected = selected == record.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if selectingForDeletion {
                    Toggle("\(record.name)を選択", isOn: Binding(
                        get: { checkedIDs.contains(record.id) },
                        set: { if $0 { checkedIDs.insert(record.id) } else { checkedIDs.remove(record.id) } }
                    )).toggleStyle(.checkbox).labelsHidden().disabled(access.busy)
                }
                Circle().fill(broken ? AppMateStyle.danger : state.needsRenewal ? Color(red: 0.96, green: 0.62, blue: 0.04) : AppMateStyle.border)
                    .frame(width: 8, height: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(CredentialGroup(record) == .key ? record.keyID ?? record.name : record.name)
                            .font(.system(size: 13, weight: .semibold, design: CredentialGroup(record) == .key ? .monospaced : .default))
                            .lineLimit(1)
                        if let owner = record.app { targetTag(owner) }
                    }
                    subtitle(record)
                }
                Spacer(minLength: 8)
                status(record, state: state, certificatesExpired: certificatesExpired)
                if isSelected { actions(record) }
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 48)
                .contentShape(Rectangle())
                .onTapGesture { selected = isSelected ? nil : record.id }
            if isSelected { detail(record).padding(.horizontal, 30).padding(.bottom, 14) }
        }
        .background(isSelected ? AppMateStyle.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .top) { if !isSelected { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { selected = isSelected ? nil : record.id }
        .contextMenu {
            Button("削除…", role: .destructive) {
                selected = record.id
                deleting = true
            }.disabled(access.busy)
        }
    }

    private func targetTag(_ owner: ManagedApp) -> some View {
        HStack(spacing: 4) {
            AppIcon(app: owner.product, size: 14)
            Text(app == nil || CredentialSearch.hasQuery(search) ? owner.product.name + (owner.parentAppID == nil ? "" : " · " + owner.name)
                 : owner.parentAppID == nil ? "本体" : owner.name)
        }.font(.system(size: 11)).foregroundStyle(AppMateStyle.text.opacity(0.75))
            .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 1)
            .background(AppMateStyle.search, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private func subtitle(_ record: StoredCredential) -> some View {
        switch CredentialGroup(record) {
        case .key:
            PurposeLabels(record: record)
        case .certificate:
            let users = record.profilesUsing(in: records)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(record.fileTypeTitle) · .\(record.fileExtension)").font(.system(size: 12)).foregroundStyle(AppMateStyle.tertiary)
                if !users.isEmpty {
                    HStack(spacing: 6) {
                        Text("使っているプロファイル").font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary)
                        ForEach(users.compactMap(\.app).reduce(into: [ManagedApp]()) { if !$0.contains($1) { $0.append($1) } }) { targetTag($0) }
                    }
                }
            }
        case .profile:
            if let owner = record.app, app == nil || CredentialSearch.hasQuery(search) {
                Text(owner.bundleID).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppMateStyle.tertiary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func status(_ record: StoredCredential, state: CredentialDisplayState, certificatesExpired: Bool) -> some View {
        if certificatesExpired, let owner = record.team {
            Button("証明書が期限切れ") { openTeam(owner.id) }.buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(AppMateStyle.dangerText).underline()
                .help("「鍵と証明書」で証明書を確認します")
        } else if state == .expired || state.needsRenewal {
            Text(state.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .expired ? AppMateStyle.dangerText : AppMateStyle.warningText)
        } else {
            Text(record.expiresAt.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) + " まで" } ?? "期限なし")
                .foregroundStyle(AppMateStyle.secondary)
        }
    }

    private func actions(_ record: StoredCredential) -> some View {
        HStack(spacing: 6) {
            Button("コピー") { copyingCI = true }.buttonStyle(AppMateButtonStyle(primary: true, compact: true))
            Button("書き出す") { export(record) }.buttonStyle(AppMateButtonStyle(compact: true))
            Menu {
                Button("書き出して Finder で表示") { export(record, revealInFinder: true) }
                if record.fileExtension == "p8" {
                    let linked = record.replacesCredentialID != nil || record.replacedByID != nil
                    Button("用途を変更…") { editingPurposes = true }.disabled(linked)
                }
                if record.fileExtension == "p12" && record.hasSavedPassword {
                    if revealedPassword != nil { Button("パスワードを隠す") { revealedPassword = nil } }
                    else { Button("パスワードを表示") { revealPassword(record) } }
                }
                Button("メモを表示…") { editingNote = true }
                Divider()
                Button("削除…", role: .destructive) { deleting = true }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 24)
                .accessibilityLabel("ほかの操作")
        }.disabled(access.busy)
    }

    private func detail(_ record: StoredCredential) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metadata("ファイルの種類", "\(record.fileTypeTitle)（.\(record.fileExtension)）")
            if record.fileExtension == "p8" { metadata("用途", record.purposeTitle) }
            if record.isIntermediateCA {
                metadata("Team ID", "対象外（中間CA証明書）")
            } else {
                metadata("Team ID", record.team?.teamID ?? "未取得", monospaced: true)
            }
            if let owner = record.app { metadata("Bundle ID", owner.bundleID, monospaced: true) }
            if CredentialGroup(record) == .profile {
                let certificates = record.signingCertificates(in: records)
                if !certificates.isEmpty { metadata("使う証明書", certificates.map(\.name).joined(separator: "、")) }
            }
            if let value = record.keyID { metadata("Key ID", value, monospaced: true) }
            if let value = record.issuerID { metadata("Issuer ID", value, monospaced: true) }
            if record.fileExtension == "p12" {
                HStack(alignment: .top, spacing: 12) {
                    Text("パスワード").foregroundStyle(AppMateStyle.secondary).frame(width: 96, alignment: .leading)
                    Text(revealedPassword.map { $0.isEmpty ? "空のパスワード" : $0 } ?? (record.hasSavedPassword ? "••••••••" : "未保存"))
                        .monospaced().privacySensitive().textSelection(.disabled)
                }
            }
            metadata("追加した日", record.createdAt.formatted(date: .long, time: .omitted))
            metadata("元のファイル名", record.originalName, monospaced: true)
            Label("コピー・書き出しの前に Touch ID で確認します", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary).padding(.top, 4)
        }.font(.system(size: 12))
    }

    private func metadata(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(AppMateStyle.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    // Discards selections and revealed values on sleep, screen lock and view changes; every secret operation authenticates anew.
    private func lock(dismissImport: Bool = true) {
        access.lock()
        deleting = false
        deletingBatch = false
        selectingForDeletion = false
        checkedIDs = []
        deletionTargets = []
        deletingApp = false
        showingRenewalGuide = false
        editingPurposes = false
        if dismissImport { importing = false; onlineImporting = false }
        selected = nil
        revealedPassword = nil
        error = nil
        status = ""
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

    private func trash(_ record: StoredCredential) {
        Task { @MainActor in
            do {
                try await access.withKey(reason: "資格情報を最近削除した項目へ移します", allowCreation: false, vault: vault) { key in
                    try VaultManagement(vault: vault).trash(record, key: key)
                }
                selected = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func deleteBatch(_ targets: [StoredCredential]) {
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: "選択した\(targets.count)件の鍵・ファイルを最近削除した項目へ移します", allowCreation: false, vault: vault) { key in
                    try VaultManagement(vault: vault).trash(targets, key: key)
                }
                checkedIDs = []
                selectingForDeletion = false
                if targets.contains(where: { $0.id == selected }) { selected = nil }
                status = "\(targets.count)件を最近削除した項目へ移しました。30日間は復元できます。"
            } catch { self.error = error.localizedDescription }
            deletionTargets = []
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
    let app: ManagedApp?
    let team: DeveloperTeam
    let vault: CredentialVault
    // 一覧のバックグラウンドロックで取り込み途中の内容を破棄しない。
    @State private var access = VaultAccess()
    var initialSources: [URL] = []
    var initialFiles: [CredentialFile] = []
    var session: AppleDeveloperSession = .shared
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var addingTarget = false
    @State private var importTargetID: UUID?
    @State private var lastSavedID: UUID?
    @State private var sources: [URL] = []
    @State private var queue: [URL] = []
    @State private var memoryQueue: [CredentialFile] = []
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
    @State private var purposes: Set<P8Purpose> = []
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var reading = false
    @State private var parseID = UUID()
    @State private var lastActivity = Date.now
    @State private var error: String?

    private var finished: Bool { currentName.isEmpty && queue.isEmpty && memoryQueue.isEmpty && !completedItems.isEmpty }
    private var parsed: ParsedCredential? { candidates.indices.contains(selected) ? candidates[selected] : nil }
    private var isP8: Bool { file.map { ($0.name as NSString).pathExtension.lowercased() == "p8" } ?? false }
    private var p8: P8Metadata? {
        guard isP8, !purposes.isEmpty else { return nil }
        return P8Metadata(purposes: Array(purposes), keyID: keyID, issuerID: issuerID)
    }
    private var importApp: ManagedApp? {
        if let importTargetID, let target = team.apps.first(where: { $0.id == importTargetID && $0.deletedAt == nil }) { return target }
        guard let app else {
            if let bundle = parsed?.bundleID {
                let matches = team.apps.filter { $0.deletedAt == nil && CredentialVault.profileMatches(bundle, bundleID: $0.bundleID) }
                return matches.count == 1 ? matches[0] : nil
            }
            return nil
        }
        if let bundle = parsed?.bundleID, let target = app.target(forProfileBundleID: bundle) { return target }
        return app
    }
    private var profileTargets: [ManagedApp] {
        app?.product.targets ?? team.apps.filter { $0.deletedAt == nil }.sorted { $0.name < $1.name }
    }
    private var unregisteredBundle: String? {
        guard let bundle = parsed?.bundleID, !bundle.contains("*"),
              parsed?.teamID == team.teamID,
              !team.apps.contains(where: { $0.bundleID.lowercased() == bundle.lowercased() }) else { return nil }
        return bundle
    }
    private var validationIssue: String? {
        guard let file, let parsed else { return nil }
        do {
            try vault.validate(file: file, parsed: parsed, app: importApp, team: team, confirmUnknownTeam: confirmUnknownTeam,
                               p8: p8)
            return nil
        }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(finished ? "ファイルの処理が完了しました" : isP8 ? ".p8の情報を入力" : currentName.isEmpty ? "ファイルを追加" : "\(completedItems.count + queue.count + 1)件のファイルを追加します")
                .font(.system(size: 18, weight: .bold))
            Text(finished ? "処理結果を確認して閉じてください。元ファイルは変更していません。" : "内容と保管先を確認してください。チーム：\(team.name)").foregroundStyle(AppMateStyle.secondary)
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
                        DisclosureGroup("処理結果 \(completedItems.count)件・残り \(queue.count + memoryQueue.count + (currentName.isEmpty ? 0 : 1))件") {
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
                                Text(parsed?.bundleID == nil ? "チーム：" + team.name : importApp?.name ?? "アプリを選択").foregroundStyle(AppMateStyle.accent).frame(width: 100, alignment: .leading)
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
                            Picker("登録先ターゲット", selection: Binding(get: { importApp?.id }, set: { importTargetID = $0; lastActivity = .now })) {
                                Text("対象アプリを選択してください").tag(nil as UUID?)
                                ForEach(profileTargets) { target in
                                    Text("\(target.name) · \(target.bundleID)").tag(Optional(target.id))
                                }
                            }
                            if let bundle = unregisteredBundle {
                                Text("Bundle ID「\(bundle)」のターゲットは未登録です。")
                                    .font(.caption).foregroundStyle(AppMateStyle.secondary)
                                Button(app == nil ? "このBundle IDのアプリを登録…" : "このアプリにターゲットを追加…") { addingTarget = true }
                            }
                        }
                        if isP8 {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                                GridRow {
                                    Text("用途").frame(width: 120, alignment: .leading)
                                    P8PurposeToggles(purposes: $purposes)
                                }
                                GridRow { Text("登録先チーム"); Text("\(team.name)（\(team.teamID)）") }
                                GridRow { Text("Key ID"); TextField("英大文字・数字10文字", text: $keyID).labelsHidden() }
                                GridRow {
                                    Color.clear.frame(width: 120, height: 1)
                                    P8PurposeFetchButton(keyID: keyID, teamID: team.teamID, session: session, purposes: $purposes).id(parseID)
                                }
                                if purposes.contains(.appStoreConnect) {
                                    GridRow { Text("Issuer ID"); TextField("App Store ConnectのIssuer ID", text: $issuerID).labelsHidden() }
                                }
                            }.textFieldStyle(.roundedBorder).controlSize(.large)
                            Text("Apple Developerの鍵の詳細にある「Enabled Services」と同じ用途をすべて選んでください。App Store Connect APIの鍵は別に発行されるため、ほかの用途と組み合わせられません。この鍵はチームの一覧に保管します。")
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
                            Toggle("Team IDを判別できないため、\(team.name)に割り当てることを確認しました", isOn: $confirmUnknownTeam)
                        }
                        let isP12 = (file?.name as NSString?)?.pathExtension.lowercased() == "p12"
                        Text(parsed.isIntermediateCA ? "中間CA証明書には個人のTeam IDはありません。選択中のTeamを保管先として保存します。" : parsed.bundleID == nil ? "チーム「\(team.name)」の鍵・証明書の一覧に保管します。" : "「\(importApp?.name ?? "未選択")」専用のプロファイルとして保存します。")
                        if isP12 {
                            Toggle(".p12のパスワードも暗号化して保存", isOn: $savePassword)
                            Text("証明書チェーンと秘密鍵を含む元の.p12全体を保存・書き出しします。証明書の選択は表示情報だけを変えます。")
                                .font(.caption).foregroundStyle(.secondary)
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
                let parent = app?.product
                RegistrationForm(container: vault.context.container, teams: [team], initialTeam: team.id, isTeam: false, parentApp: parent, initialBundleID: bundle, initialName: parsed?.name ?? "") { id in
                    importTargetID = id
                    error = nil
                }
            }
        }
        .task {
            if !initialFiles.isEmpty {
                guard initialFiles.count <= 200, initialFiles.allSatisfy({ !$0.data.isEmpty && $0.data.count <= CredentialParser.maximumBytes }),
                      initialFiles.reduce(0, { $0 + $1.data.count }) <= 32 * 1_048_576 else {
                    error = AppleDeveloperError.importLimit.localizedDescription
                    return
                }
                memoryQueue = initialFiles; next()
            } else if !initialSources.isEmpty { start(initialSources) }
        }
        .onChange(of: password) { _, _ in lastActivity = .now }
        .onChange(of: selected) { _, _ in lastActivity = .now; confirmUnknownTeam = false }
        .onChange(of: purposes) { _, value in lastActivity = .now; if !value.contains(.appStoreConnect) { issuerID = "" } }
        .onChange(of: keyID) { _, _ in lastActivity = .now }
        .onChange(of: issuerID) { _, _ in lastActivity = .now }
        .onChange(of: confirmUnknownTeam) { _, _ in lastActivity = .now }
        .onChange(of: savePassword) { _, _ in lastActivity = .now }
        .onChange(of: access.generation) { _, _ in clear() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if Date.now.timeIntervalSince(lastActivity) >= 300 { access.lock(); dismiss() }
        }
        .onDisappear { memoryQueue = []; clear(); releaseSources(); access.lock() }
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
        purposes = []
        keyID = ""
        issuerID = ""
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
        memoryQueue = []
        releaseSources()
        sources = urls.filter { $0.startAccessingSecurityScopedResource() }
        do { queue = try ImportSources.collect(urls); completedItems = []; next() }
        catch { self.error = error.localizedDescription; releaseSources() }
    }

    private func next() {
        clear()
        error = nil
        if !memoryQueue.isEmpty {
            let incoming = memoryQueue.removeFirst()
            currentName = incoming.name
            load(file: incoming)
            return
        }
        guard !queue.isEmpty else {
            currentName = ""; releaseSources()
            if let lastSavedID { onSaved(lastSavedID); self.lastSavedID = nil }
            return
        }
        let url = queue.removeFirst()
        currentName = url.lastPathComponent
        load(url)
    }

    private func load(_ url: URL? = nil, file incoming: CredentialFile? = nil) {
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
                    let file: CredentialFile
                    if let incoming { file = incoming }
                    else if let url { file = try CredentialFile(url: url) }
                    else { throw ValidationError.invalidFile }
                    let results = file.requiresPasswordEntry ? [] : try CredentialParser.parseAll(file.data, extension: (file.name as NSString).pathExtension)
                    return (file, results)
                }.value
                guard token == parseID, generation == access.generation else { return }
                self.file = file
                keyID = P8Metadata.keyID(fromFileName: file.name) ?? ""
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
        Task { @MainActor in
            do {
                try vault.validate(file: file, parsed: parsed, app: destination, team: team, confirmUnknownTeam: confirmed, p8: metadata)
                let canCreate = try vault.canCreateKey()
                let id = try await access.withKey(reason: "資格情報を暗号化して保存します", allowCreation: canCreate, vault: vault) { key in
                    try vault.importFile(file, parsed: parsed, app: destination, team: team, password: password, confirmUnknownTeam: confirmed, key: key, p8: metadata)
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
