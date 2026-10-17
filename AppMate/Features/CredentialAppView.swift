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
    @State private var panelSources: [URL] = []
    @State private var dropTargeted = false
    @State private var clock = Date.now
    @State private var onlineImporting = false
    @State private var error: String?
    @State private var status = ""
    @State private var revealedPassword: String?
    @State private var editingNote = false
    @State private var editingPurposes = false
    @State private var editingApp = false
    @State private var editingTarget: ManagedApp?
    @State private var addingTarget = false
    @State private var targetFilter: UUID?
    @State private var copyingCI = false
    @State private var creatingSecretFile = false
    @State private var deletingRecord: StoredCredential?
    @State private var selectingForDeletion = false
    @State private var checkedIDs: Set<UUID> = []
    @State private var batchDeletion: BatchDeletion?
    @State private var deletingTarget: ManagedApp?
    @State private var showingRenewalGuide = false
    @State private var revealedAt = Date.distantPast

    private struct BatchDeletion: Identifiable {
        let id = UUID()
        let records: [StoredCredential]
    }

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
        .sheet(item: $editingTarget) { target in CatalogEditor(vault: vault, team: nil, app: target) }
        .sheet(isPresented: $copyingCI) { if let record = selectedRecord { CICopyView(vault: vault, record: record) } }
        .sheet(isPresented: $creatingSecretFile) { if let app { CISecretFileView(vault: vault, app: app, records: records) } }
        .sheet(item: $deletingRecord) { record in
            CredentialDeleteConfirmation(record: record) {
                deletingRecord = nil
                trash(record)
            }
        }
        .sheet(item: $deletingTarget) { target in
            TargetDeleteConfirmation(target: target, records: records) {
                deletingTarget = nil
                deleteTarget(target)
            }
        }
        .sheet(item: $batchDeletion) { deletion in
            CredentialBatchDeleteConfirmation(records: deletion.records) {
                batchDeletion = nil
                deleteBatch(deletion.records)
            }
        }
        .onChange(of: app?.targets.map(\.id)) { _, ids in
            if let targetFilter, ids?.contains(targetFilter) != true { self.targetFilter = nil }
        }
        .onChange(of: visible.map(\.id)) { _, ids in checkedIDs.formIntersection(Set(ids)) }
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
            if !access.busy && !access.presentingPanel && !editingNote && !editingPurposes && !copyingCI && !creatingSecretFile && !editingApp && editingTarget == nil { lock(dismissImport: false) }
        }
    }

    private var credentialList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let app, app.parentAppID == nil, app.targets.count > 1, !CredentialSearch.hasQuery(search) { targetFilterBar(app) }
                attentionBanner
                if selectingForDeletion { deletionBar }
                if let app, !CredentialSearch.hasQuery(search), typeFilter == .all {
                    ForEach((app.parentAppID == nil ? app.targets : [app]).filter { targetFilter == nil || $0.id == targetFilter }) { target in
                        targetSection(target)
                    }
                } else if visible.isEmpty {
                    emptyState.frame(maxWidth: .infinity)
                } else {
                    ForEach(CredentialGroup.allCases.filter { group in visible.contains { CredentialGroup($0) == group } }, id: \.self) { group in
                        let items = visible.filter { CredentialGroup($0) == group }
                        CollapsibleSection(title: group.title, detail: sectionDetail(group, count: items.count),
                                           attention: scoped.filter { CredentialGroup($0) == group && $0.needsAttention(in: records, at: clock) }.count) {
                            columnHeader(group)
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
                  !urls.isEmpty, !access.busy, !importing, panelSources.isEmpty else { return false }
            panelSources = urls
            return true
        } isTargeted: { dropTargeted = $0 && team != nil && app?.deletedAt == nil && !CredentialSearch.hasQuery(search) }
        .overlay {
            if dropTargeted {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 28)).foregroundStyle(AppMateStyle.accent)
                    Text("離すと \(app?.name ?? "鍵と証明書") に追加します").font(.system(size: 17, weight: .bold))
                    Text("証明書と鍵は「鍵と証明書」に入ります").font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppMateStyle.selectedRow.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppMateStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !panelSources.isEmpty, let team {
                DropImportPanel(sources: panelSources, app: app, team: team, vault: vault, openSheet: { urls in
                    panelSources = []
                    droppedSources = urls
                    importing = true
                }, close: { id in
                    panelSources = []
                    if let id { selected = id }
                }).padding(20).id(panelSources)
            }
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
                Button("ファイルだけを一括削除…") {
                    selectingForDeletion = true
                    checkedIDs = []
                }.disabled(visible.isEmpty || access.busy)
                if app != nil {
                    Button("CI 用の Secret ファイルを作成…") { creatingSecretFile = true }.disabled(access.busy)
                    Divider()
                    Button("ターゲットを追加…") { addingTarget = true }
                    Button("アプリを編集…") { editingApp = true }
                    Button("アプリを削除…", role: .destructive) { deletingTarget = app }.disabled(access.busy)
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
            ForEach(app.targets) { target in
                targetChip(target.id == app.id ? "本体" : target.name, id: target.id)
                    .contextMenu {
                        if target.id != app.id {
                            Button("ターゲットを編集…") { editingTarget = target }
                        }
                    }
            }
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
                batchDeletion = BatchDeletion(records: checkedRecords)
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

    private func targetSection(_ target: ManagedApp) -> some View {
        let profiles = visible.filter { $0.app?.id == target.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppIcon(app: target.product, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.name + (target.parentAppID == nil ? "（本体）" : "")).fontWeight(.semibold)
                    Text(target.bundleID).font(.caption.monospaced()).foregroundStyle(AppMateStyle.secondary)
                }
                Spacer()
                Text("プロファイル \(profiles.count)件").foregroundStyle(AppMateStyle.secondary)
                Menu {
                    Button("編集…") { editingTarget = target }
                    Button(target.parentAppID == nil ? "アプリと全ターゲットを削除…" : "ターゲットとプロファイルを削除…", role: .destructive) {
                        deletingTarget = target
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                    .accessibilityLabel(target.name + "の操作").disabled(access.busy)
            }.padding(.vertical, 8)
            if profiles.isEmpty {
                Text("プロファイルはまだありません").foregroundStyle(AppMateStyle.secondary).padding(.vertical, 8)
            } else {
                columnHeader(.profile)
                ForEach(profiles) { row($0) }
            }
        }
    }

    private static let detailColumnWidth: CGFloat = 240
    private static let expiryColumnWidth: CGFloat = 110

    private func columnHeader(_ group: CredentialGroup) -> some View {
        HStack(spacing: 14) {
            if selectingForDeletion { Color.clear.frame(width: 14, height: 1) }
            Color.clear.frame(width: 36, height: 1)
            Text(group.columns.name).frame(maxWidth: .infinity, alignment: .leading)
            Text(group.columns.detail).frame(width: Self.detailColumnWidth, alignment: .leading)
            Text("期限").frame(width: Self.expiryColumnWidth, alignment: .trailing)
        }.font(.system(size: 11, weight: .semibold)).foregroundStyle(AppMateStyle.secondary)
            .padding(.horizontal, 15).accessibilityHidden(true)
    }

    private func row(_ record: StoredCredential) -> some View {
        let group = CredentialGroup(record)
        let state = record.displayState(at: clock)
        let certificatesExpired = group == .profile && record.signingCertificatesExpired(in: records, at: clock)
        let broken = state == .expired || certificatesExpired
        let isSelected = selected == record.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if selectingForDeletion {
                    Toggle("\(record.name)を選択", isOn: Binding(
                        get: { checkedIDs.contains(record.id) },
                        set: { if $0 { checkedIDs.insert(record.id) } else { checkedIDs.remove(record.id) } }
                    )).toggleStyle(.checkbox).labelsHidden().disabled(access.busy)
                }
                Image(systemName: group.symbol).font(.system(size: 16)).foregroundStyle(group.tint)
                    .frame(width: 36, height: 36).background(AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    title(record)
                    subtitle(record)
                }.frame(maxWidth: .infinity, alignment: .leading)
                detailColumn(record).frame(width: Self.detailColumnWidth, alignment: .leading)
                status(record, state: state, certificatesExpired: certificatesExpired)
                    .frame(width: Self.expiryColumnWidth, alignment: .trailing)
            }.padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture { selected = isSelected ? nil : record.id }
            if isSelected {
                VStack(alignment: .leading, spacing: 12) {
                    actions(record)
                    detail(record)
                }.padding(.leading, 64).padding(.trailing, 14).padding(.bottom, 14)
            }
        }
        .background(group.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isSelected ? AppMateStyle.selectionBorder : broken ? AppMateStyle.dangerBorder : group.border, lineWidth: isSelected ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { selected = isSelected ? nil : record.id }
        .contextMenu {
            if let owner = record.app {
                Button(owner.parentAppID == nil ? "アプリと全ターゲットを削除…" : "ターゲットとプロファイルを削除…", role: .destructive) {
                    deletingTarget = owner
                }.disabled(access.busy)
            } else {
                Button("削除…", role: .destructive) { deletingRecord = record }.disabled(access.busy)
            }
        }
    }

    private func targetTag(_ owner: ManagedApp) -> some View {
        HStack(spacing: 4) {
            AppIcon(app: owner.product, size: 14)
            Text(owner.product.name + (owner.parentAppID == nil ? "" : " · " + owner.name))
        }.font(.system(size: 11)).foregroundStyle(AppMateStyle.text.opacity(0.75))
            .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 1)
            .background(AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private func title(_ record: StoredCredential) -> some View {
        switch CredentialGroup(record) {
        case .key:
            Text(record.keyID ?? record.name).font(.system(size: 13, weight: .bold, design: .monospaced)).lineLimit(1)
        case .certificate:
            Text(record.certificateNameParts.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
        case .profile:
            HStack(spacing: 8) {
                Text(record.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                // Target sections on app pages already name the target.
                if let owner = record.app, app == nil || CredentialSearch.hasQuery(search) { targetTag(owner) }
            }
        }
    }

    @ViewBuilder private func subtitle(_ record: StoredCredential) -> some View {
        if CredentialGroup(record) == .certificate {
            let bundled = record.bundledCertificates.count
            Text([record.certificateNameParts.holder ?? record.fileTypeTitle,
                  ".\(record.fileExtension)" + (bundled > 0 ? "（ほか\(bundled)件を含む）" : "")].joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private func detailColumn(_ record: StoredCredential) -> some View {
        switch CredentialGroup(record) {
        case .key:
            PurposeLabels(record: record)
        case .profile:
            Text(record.bundleID ?? record.app?.bundleID ?? "—").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(AppMateStyle.text.opacity(0.8)).lineLimit(1).truncationMode(.middle)
        case .certificate:
            let targets = record.profilesUsing(in: records).compactMap(\.app)
            let products = targets.map(\.product).reduce(into: [ManagedApp]()) { if !$0.contains($1) { $0.append($1) } }
            if products.isEmpty {
                Text("なし").font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(products) { product in
                        let names = targets.filter { $0.product == product }.map { $0.parentAppID == nil ? "本体" : $0.name }
                        HStack(spacing: 6) {
                            AppIcon(app: product, size: 16)
                            Text(product.name).lineLimit(1)
                            Text(names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "・"))
                                .foregroundStyle(AppMateStyle.secondary).lineLimit(1)
                        }.font(.system(size: 12)).padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 2)
                            .background(AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CredentialGroup.certificate.border))
                    }
                }
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
            Text(record.expiresAt.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) } ?? "なし")
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
                Button(record.app == nil ? "削除…" : "このプロファイルだけを削除…", role: .destructive) { deletingRecord = record }
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
                let bundled = record.bundledCertificates
                metadata("同梱の証明書", record.p12Certificates == nil ? (record.hasSavedPassword ? "未確認（次の認証後に表示）" : "未確認（パスワード未保存）")
                         : bundled.isEmpty ? "なし"
                         : bundled.map { $0.name + ($0.expiresAt.map { "（" + $0.formatted(date: .abbreviated, time: .omitted) + "まで）" } ?? "") }.joined(separator: "\n"))
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
        deletingRecord = nil
        batchDeletion = nil
        selectingForDeletion = false
        checkedIDs = []
        deletingTarget = nil
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
        }
    }

    private func deleteTarget(_ target: ManagedApp) {
        Task { @MainActor in
            do {
                let create = try vault.canCreateKey()
                try await access.withKey(reason: "登録と配下のプロファイルを削除します", allowCreation: create, vault: vault) { key in
                    try VaultManagement(vault: vault).trash(target, key: key)
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
    @State private var showingPassword = false
    /// Files checked so far. They are saved together after one authentication at the end.
    @State private var pending: [PendingImport] = []

    private struct PendingImport {
        let file: CredentialFile
        let parsed: ParsedCredential
        let app: ManagedApp?
        let password: String?
        let confirmed: Bool
        let p8: P8Metadata?
    }

    private var finished: Bool { currentName.isEmpty && queue.isEmpty && memoryQueue.isEmpty && pending.isEmpty && !completedItems.isEmpty }
    private var readyToCommit: Bool { currentName.isEmpty && queue.isEmpty && memoryQueue.isEmpty && !pending.isEmpty }
    private var isLastItem: Bool { queue.isEmpty && memoryQueue.isEmpty }
    private var needsPassword: Bool { file.map { $0.requiresPasswordEntry && candidates.isEmpty } ?? false }
    private var showsQueue: Bool { !currentName.isEmpty || !pending.isEmpty || !completedItems.isEmpty }

    private var headline: String {
        if finished { return "ファイルの追加が終わりました" }
        if readyToCommit { return "\(pending.count)件の確認が終わりました" }
        if file == nil { return currentName.isEmpty ? "ファイルを追加" : "読み取っています…" }
        if needsPassword { return ".p12 のパスワードを入力してください" }
        if isP8 { return "この鍵の用途を選んでください" }
        if unregisteredBundle != nil { return "どのアプリのプロファイルですか？" }
        return "内容を確認してください"
    }

    private var subheadline: String {
        if finished { return "元のファイルは変更していません。" }
        if readyToCommit { return "Touch ID で確認すると、まとめて暗号化して保存します。" }
        if needsPassword { return ".p12 を書き出したときに決めたパスワードです。設定していない場合は空欄のまま「読み取る」を押します。" }
        if isP8 { return ".p8 のファイルには用途が書かれていません。Apple Developer の鍵のページにある「Enabled Services」と同じものを選びます。" }
        return "追加先：\(team.name)"
    }
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
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .top, spacing: 0) {
            if showsQueue { queueList }
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline).font(.system(size: 18, weight: .bold))
                Text(subheadline).foregroundStyle(AppMateStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if finished {
                        Label("処理済み \(completedItems.count)件", systemImage: "checkmark.circle")
                            .font(.headline).foregroundStyle(AppMateStyle.accent)
                        ForEach(Array(completedItems.enumerated()), id: \.offset) { _, result in
                            Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if file == nil && !readyToCommit && currentName.isEmpty {
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
                    }
                    if needsPassword {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Group {
                                    if showingPassword { TextField(".p12 のパスワード", text: $password) }
                                    else { SecureField(".p12 のパスワード", text: $password) }
                                }.textFieldStyle(.plain).focused($passwordFocused).onSubmit(parsePKCS12)
                                Button { showingPassword.toggle(); passwordFocused = true } label: {
                                    Image(systemName: showingPassword ? "eye.slash" : "eye").frame(width: 24, height: 24)
                                }.buttonStyle(.plain).foregroundStyle(AppMateStyle.secondary)
                                    .help(showingPassword ? "パスワードを隠す" : "パスワードを表示")
                                    .accessibilityLabel(showingPassword ? "パスワードを隠す" : "パスワードを表示")
                            }.padding(.leading, 10).padding(.trailing, 4).frame(width: 320, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(error == nil ? AppMateStyle.accent : AppMateStyle.danger, lineWidth: 1.5))
                            Button("読み取る", action: parsePKCS12)
                        }
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
                            Text("用途（複数選べます）").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppMateStyle.text.opacity(0.75))
                            P8PurposeToggles(purposes: $purposes)
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                                GridRow { Text("登録先チーム").frame(width: 120, alignment: .leading); Text("\(team.name)（\(team.teamID)）") }
                                GridRow { Text("Key ID"); TextField("英大文字・数字10文字", text: $keyID).labelsHidden() }
                                GridRow {
                                    Color.clear.frame(width: 120, height: 1)
                                    P8PurposeFetchButton(keyID: keyID, teamID: team.teamID, session: session, purposes: $purposes).id(parseID)
                                }
                                if purposes.contains(.appStoreConnect) {
                                    GridRow { Text("Issuer ID"); TextField("App Store ConnectのIssuer ID", text: $issuerID).labelsHidden() }
                                }
                            }.textFieldStyle(.roundedBorder).controlSize(.large)
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
                        if (file?.name as NSString?)?.pathExtension.lowercased() == "cer" {
                            Text(".cerはApple Developerからいつでも再ダウンロードできるため、保存は任意です。署名に使うには秘密鍵を含む.p12を保存してください。")
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
            }.padding(.horizontal, 26).padding(.vertical, 22)
          }.frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: 10) {
                if !finished {
                    Button("キャンセル") { access.lock(); dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if !currentName.isEmpty {
                        Button("このファイルを飛ばす") { completedItems.append("スキップ：" + currentName + (error.map { " · " + $0 } ?? "")); next() }
                            .buttonStyle(.plain).foregroundStyle(AppMateStyle.secondary).disabled(access.busy)
                    }
                    if readyToCommit {
                        Button { commit() } label: { Label("Touch ID で \(pending.count)件を追加", systemImage: "touchid") }
                            .keyboardShortcut(.defaultAction).buttonStyle(AppMateButtonStyle(primary: true)).disabled(access.busy)
                    } else {
                        Button(action: confirmCurrent) {
                            if isLastItem { Label("Touch ID で \(pending.count + 1)件を追加", systemImage: "touchid") } else { Text("次へ") }
                        }.keyboardShortcut(.defaultAction).buttonStyle(AppMateButtonStyle(primary: true))
                            .disabled(reading || access.busy || parsed == nil || validationIssue != nil)
                    }
                } else {
                    Spacer()
                    Button("閉じる") { access.lock(); dismiss() }
                        .keyboardShortcut(.defaultAction).buttonStyle(AppMateButtonStyle(primary: true))
                }
            }.padding(.horizontal, 26).padding(.top, 14)
        }
        .padding(.bottom, 14).padding(.horizontal, 0).frame(width: showsQueue ? 860 : 680, height: 640)
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
        .onChange(of: access.generation) { _, _ in clear(); pending = [] }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if Date.now.timeIntervalSince(lastActivity) >= 300 { access.lock(); dismiss() }
        }
        .onDisappear { memoryQueue = []; pending = []; clear(); releaseSources(); access.lock() }
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
        showingPassword = false
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
            currentName = ""
            // All files are checked: authenticate once and save them together.
            if !pending.isEmpty { commit(); return }
            releaseSources()
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

    /// Validates the current file and keeps it for the final save. Nothing is written yet.
    private func confirmCurrent() {
        guard let file, let parsed else { return }
        error = nil
        lastActivity = .now
        let item = PendingImport(file: file, parsed: parsed, app: importApp, password: savePassword ? parsedPassword : nil,
                                 confirmed: confirmUnknownTeam, p8: p8)
        do {
            try vault.validate(file: item.file, parsed: item.parsed, app: item.app, team: team, confirmUnknownTeam: item.confirmed, p8: item.p8)
            pending.append(item)
            next()
        } catch { self.error = error.localizedDescription }
    }

    /// One authentication for every checked file. Each file is saved on its own, so one failure keeps the others.
    private func commit() {
        let items = pending
        guard !items.isEmpty else { return }
        error = nil
        lastActivity = .now
        Task { @MainActor in
            do {
                let canCreate = try vault.canCreateKey()
                try await access.withKey(reason: "\(items.count)件の資格情報を暗号化して保存します", allowCreation: canCreate, vault: vault) { key in
                    for item in items {
                        do {
                            lastSavedID = try vault.importFile(item.file, parsed: item.parsed, app: item.app, team: team, password: item.password,
                                                               confirmUnknownTeam: item.confirmed, key: key, p8: item.p8)
                            completedItems.append("保存済み：" + item.file.name)
                        } catch {
                            completedItems.append("保存できませんでした：" + item.file.name + " · " + error.localizedDescription)
                        }
                    }
                }
                pending = []
                releaseSources()
                if let lastSavedID { onSaved(lastSavedID); self.lastSavedID = nil }
            } catch {
                // Authentication was cancelled or failed: keep the checked files so the user can try again.
                self.error = error.localizedDescription
            }
        }
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(pending.count + completedItems.count + queue.count + memoryQueue.count + (currentName.isEmpty ? 0 : 1))件のファイル")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppMateStyle.secondary).padding(.horizontal, 8).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(completedItems.enumerated()), id: \.offset) { _, item in
                        let saved = item.hasPrefix("保存済み：")
                        queueRow(item.split(separator: "：", maxSplits: 1).last.map(String.init) ?? item,
                                 symbol: saved ? "checkmark.circle" : item.hasPrefix("スキップ：") ? "minus.circle" : "exclamationmark.circle",
                                 tint: saved ? AppMateStyle.successText : item.hasPrefix("スキップ：") ? AppMateStyle.tertiary : AppMateStyle.dangerText, current: false)
                    }
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, item in
                        queueRow(item.file.name, symbol: "checkmark.circle", tint: AppMateStyle.accent, current: false)
                    }
                    if !currentName.isEmpty { queueRow(currentName, symbol: "smallcircle.filled.circle", tint: AppMateStyle.accent, current: true) }
                    ForEach(Array(memoryQueue.enumerated()), id: \.offset) { _, item in queueRow(item.name, symbol: "circle", tint: AppMateStyle.tertiary, current: false) }
                    ForEach(queue, id: \.self) { url in queueRow(url.lastPathComponent, symbol: "circle", tint: AppMateStyle.tertiary, current: false) }
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 20).frame(width: 250).frame(maxHeight: .infinity, alignment: .top)
            .background(AppMateStyle.sidebar)
            .overlay(alignment: .trailing) { Rectangle().fill(AppMateStyle.rowBorder).frame(width: 1) }
    }

    private func queueRow(_ name: String, symbol: String, tint: Color, current: Bool) -> some View {
        let ext = (name as NSString).pathExtension.lowercased()
        let kind = ext == "p8" ? "鍵（.p8）" : ["cer", "p12"].contains(ext) ? "証明書" : "プロファイル"
        return HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind).fontWeight(current ? .semibold : .regular)
                Text(name).font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? AppMateStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? AppMateStyle.selectionBorder : .clear))
            .accessibilityElement(children: .combine)
    }
}
