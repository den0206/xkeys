import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var copiedSecret: String?
    @State private var hoveredRow: UUID?
    @State private var revealedPassword: String?
    @State private var editingNote = false
    @State private var editingCustomSecrets = false
    @State private var addingCustomSecret = false
    @State private var showingCustomSecrets = false
    @State private var showingNote = false
    @State private var revealedNote: String?
    @State private var noteRevealedAt = Date.distantPast
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
    @State private var renewalDone: Set<Int> = []
    @State private var renewalAction: RenewalAction?
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
                    status = String(localized: "暗号化して保存しました。鍵・証明書はチームの一覧、プロファイルは対象アプリの一覧で確認できます。")
                }
            }
        }
        .sheet(isPresented: $onlineImporting) {
            if let team {
                AppleDeveloperImportView(team: team, vault: vault) { id in
                    selected = id
                    status = String(localized: "Apple Developerから取得したファイルを暗号化して保存しました。")
                }.modelContainer(container)
            }
        }
        .sheet(isPresented: $editingCustomSecrets) { if let app { AppSecretEditor(vault: vault, app: app.product, startAdding: addingCustomSecret) } }
        // A revealed note is stale once the editor may have changed it.
        .sheet(isPresented: $editingNote, onDismiss: { revealedNote = nil }) { NoteEditor(vault: vault, app: selectedRecord == nil ? app : nil, record: selectedRecord) }
        .sheet(isPresented: $editingPurposes) { if let record = selectedRecord { P8PurposeEditor(vault: vault, record: record) } }
        .sheet(isPresented: $addingTarget, onDismiss: { if !droppedSources.isEmpty { importing = true } }) {
            if let parent = app?.product {
                RegistrationForm(container: container, teams: parent.team.map { [$0] } ?? [], initialTeam: parent.team?.id, isTeam: false, parentApp: parent,
                                 onProfile: { droppedSources = [$0] }) { _ in }
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
        .onChange(of: app?.id) { _, _ in showingCustomSecrets = false; showingNote = false; revealedNote = nil }
        .onChange(of: app?.targets.map(\.id)) { _, ids in
            if let targetFilter, ids?.contains(targetFilter) != true { self.targetFilter = nil }
        }
        .onChange(of: visible.map(\.id)) { _, ids in checkedIDs.formIntersection(Set(ids)) }
        .task {
            do {
                try vault.recover()
            }
            catch { self.error = String(localized: "保存状態を確認できません。\(error.localizedDescription)") }
        }
        .onChange(of: importing) { _, shown in if !shown { droppedSources = [] } }
        .onDisappear { lock() }
        .onChange(of: selected) { _, _ in access.lock(); revealedPassword = nil }
        .onChange(of: search) { _, _ in lock(dismissImport: false) }
        .onChange(of: typeFilter) { _, _ in lock(dismissImport: false) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if Date.now.timeIntervalSince(clock) >= 60 { clock = .now }
            if revealedPassword != nil && Date.now.timeIntervalSince(revealedAt) >= 300 { revealedPassword = nil }
            if revealedNote != nil && Date.now.timeIntervalSince(noteRevealedAt) >= 300 { revealedNote = nil }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in lock() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !access.busy && !access.presentingPanel && !showingRenewalGuide && !editingNote && !editingCustomSecrets && !editingPurposes && !copyingCI && !creatingSecretFile && !editingApp && editingTarget == nil { lock(dismissImport: false) }
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
                                           attention: scoped.filter { CredentialGroup($0) == group && $0.needsAttention(in: records, at: clock) }.count,
                                           term: group.guideTerm) {
                            columnHeader(group)
                            ForEach(items) { row($0) }
                        }
                    }
                }
                if let app, let owner = app.team, !CredentialSearch.hasQuery(search) { teamLink(owner) }
                if let app, !CredentialSearch.hasQuery(search), typeFilter == .all, !selectingForDeletion {
                    customSecretsSection(app.product)
                    if app.noteBlobID != nil { noteSection(app) }
                }
                if access.busy { AuthenticatingLabel().font(.caption).foregroundStyle(XkeysStyle.secondary) }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(XkeysStyle.dangerText).font(.caption).textSelection(.enabled) }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(XkeysStyle.secondary) }
            }.padding(.horizontal, 32).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(XkeysStyle.canvas)
        .focusable().focusEffectDisabled()
        .onMoveCommand { direction in
            guard !visible.isEmpty, direction == .up || direction == .down else { return }
            let index = visible.firstIndex { $0.id == selected } ?? (direction == .down ? -1 : visible.count)
            select(visible[min(max(index + (direction == .down ? 1 : -1), 0), visible.count - 1)].id)
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
                    Image(systemName: "square.and.arrow.down").font(.system(size: 28)).foregroundStyle(XkeysStyle.accent)
                    Text("離すと \(app?.name ?? String(localized: "鍵と証明書")) に追加します").font(.system(size: 17, weight: .bold))
                    Text("証明書と鍵は「鍵と証明書」に入ります").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(XkeysStyle.selectedRow.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(XkeysStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                    .padding(10).allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(XkeysMotion.feedback, value: dropTargeted)
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
        if CredentialSearch.hasQuery(search) { return String(localized: "検索の結果") }
        if let app { return app.name }
        if case .team = scope { return String(localized: "鍵と証明書") }
        return scope.title
    }

    private var pageSubtitle: String {
        if CredentialSearch.hasQuery(search) { return String(localized: "すべてのチームとアプリ · \(visible.count)件") }
        if let app {
            let targets = app.parentAppID == nil && app.targets.count > 1 ? String(localized: " · \(app.targets.count)ターゲット") : ""
            return "\(app.platform) · \(app.bundleID)\(targets)"
        }
        if case .team = scope, let team { return String(localized: "\(team.name) のどのアプリでも使えるもの") }
        return String(localized: "\(visible.count)件")
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let app {
                AppIcon(app: app, size: 52)
            } else {
                Image(systemName: "key").font(.system(size: 24)).foregroundStyle(XkeysStyle.text.opacity(0.75))
                    .frame(width: 52, height: 52).background(XkeysStyle.search, in: RoundedRectangle(cornerRadius: 13))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(pageTitle).font(.system(size: 22, weight: .bold)).lineLimit(2)
                Text(pageSubtitle).foregroundStyle(XkeysStyle.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if app != nil {
                Button("メモ") { selected = nil; editingNote = true }.buttonStyle(XkeysButtonStyle(compact: true)).disabled(access.busy)
            } else if team != nil, case .team = scope, !CredentialSearch.hasQuery(search) {
                Button("Apple Developer から取り込む", systemImage: "icloud.and.arrow.down") { onlineImporting = true }
                    .buttonStyle(XkeysButtonStyle(compact: true)).disabled(access.busy)
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
                .frame(width: 30, height: 30).overlay(RoundedRectangle(cornerRadius: 8).stroke(XkeysStyle.border))
                .help("表示と管理").accessibilityLabel("表示と管理")
        }
    }

    private func targetFilterBar(_ app: ManagedApp) -> some View {
        HStack(spacing: 6) {
            targetChip(String(localized: "すべて"), id: nil)
            ForEach(app.targets) { target in
                targetChip(target.id == app.id ? String(localized: "本体") : target.name, id: target.id)
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
            .foregroundStyle(on ? Color.white : XkeysStyle.text.opacity(0.8))
            .background(on ? XkeysStyle.text : XkeysStyle.canvas, in: Capsule())
            .overlay(Capsule().stroke(on ? XkeysStyle.text : XkeysStyle.border))
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var attentionBanner: some View {
        let attention = scoped.filter { $0.needsAttention(in: records, at: clock) }
        if !attention.isEmpty {
            let broken = attention.filter { $0.displayState(at: clock) == .expired || $0.signingCertificatesExpired(in: records, at: clock) }
            let danger = !broken.isEmpty
            HStack(spacing: 12) {
                Image(systemName: danger ? "exclamationmark.circle" : "clock").font(.system(size: 17))
                    .foregroundStyle(danger ? XkeysStyle.danger : XkeysStyle.warningText)
                Text(attentionMessage(attention)).frame(maxWidth: .infinity, alignment: .leading)
                Button("直し方を見る") { showingRenewalGuide = true }
                    .buttonStyle(XkeysButtonStyle(compact: true))
                    .sheet(isPresented: $showingRenewalGuide, onDismiss: runRenewalAction) {
                        RenewalGuideView(expired: danger, canImportOnline: team != nil, done: $renewalDone) { action in
                            renewalAction = action
                            showingRenewalGuide = false
                        }
                    }
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(danger ? Color(red: 0.5, green: 0.11, blue: 0.11) : XkeysStyle.warningText)
                .background(danger ? XkeysStyle.dangerBackground : XkeysStyle.warningBanner, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(danger ? XkeysStyle.dangerBorder : XkeysStyle.warningBorder))
        }
    }

    // Sheets open one at a time, so the guide's buttons act after it has closed.
    private func runRenewalAction() {
        guard let action = renewalAction else { return }
        renewalAction = nil
        switch action {
        case .addFile: importing = true
        case .importOnline: onlineImporting = true
        }
    }

    private func attentionMessage(_ records: [StoredCredential]) -> String {
        let unusable = records.filter { CredentialGroup($0) == .profile && $0.signingCertificatesExpired(in: self.records, at: clock) }
        if !unusable.isEmpty {
            return String(localized: "署名に使う証明書が期限切れのため、プロファイル \(unusable.count)件が使えません。")
        }
        let dates = records.compactMap(\.expiresAt)
        if let first = dates.first, first > clock, dates.allSatisfy({ Calendar.current.isDate($0, inSameDayAs: first) }) {
            return String(localized: "\(records.count)件が\(first.formatted(.dateTime.month().day()))に期限切れになります。新しいファイルを追加しましょう。")
        }
        return String(localized: "\(records.count)件の期限を確認してください。新しいファイルを追加しましょう。")
    }

    private var deletionBar: some View {
        HStack(spacing: 12) {
            Button(checkedRecords.count == visible.count ? "選択を解除" : "すべて選択") {
                checkedIDs = checkedRecords.count == visible.count ? [] : Set(visible.map(\.id))
            }
            Text("\(checkedRecords.count)件選択").foregroundStyle(XkeysStyle.secondary)
            Spacer()
            Button("キャンセル") { selectingForDeletion = false; checkedIDs = [] }
            Button("削除…", role: .destructive) {
                batchDeletion = BatchDeletion(records: checkedRecords)
            }.disabled(checkedRecords.isEmpty)
        }.buttonStyle(XkeysButtonStyle(compact: true)).disabled(access.busy)
    }

    private func sectionDetail(_ group: CredentialGroup, count: Int) -> String {
        switch group {
        case .profile: app == nil || CredentialSearch.hasQuery(search) ? "\(count)" : String(localized: "\(count) · このアプリ専用")
        case .certificate: "\(count)"
        case .key: String(localized: "\(count) · 期限なし · どのアプリで使っているかは記録していません")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if CredentialSearch.hasQuery(search) || typeFilter != .all {
            ContentUnavailableView("条件に一致する項目がありません", systemImage: "magnifyingglass",
                                   description: Text("検索語や種類を変えて確認してください。"))
        } else if team != nil, app?.deletedAt == nil, app != nil || isTeamScope {
            VStack(spacing: 12) {
                CredentialDropZone(title: app != nil ? String(localized: "このアプリのプロファイルをドロップ") : String(localized: "証明書や鍵をドロップ"),
                                   formats: app != nil ? [".mobileprovision", ".provisionprofile"] : [String(localized: "証明書 .p12 · .cer"), String(localized: "鍵 .p8")]) { importing = true }
                AppleImportCard { onlineImporting = true }
            }.disabled(access.busy)
        } else {
            ContentUnavailableView("該当する項目はありません", systemImage: "checkmark.circle")
        }
    }

    private var isTeamScope: Bool { if case .team = scope { true } else { false } }

    private func customSecretsSection(_ app: ManagedApp) -> some View {
        let names = (app.customSecretNames ?? "").split(separator: "\n").map(String.init)
        return DisclosureGroup(isExpanded: $showingCustomSecrets) {
            VStack(alignment: .leading, spacing: 14) {
                if names.isEmpty {
                    Text("APIキーやURLなど、アプリ専用のKeyとValueを登録できます。")
                        .font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                } else {
                    ForEach(names, id: \.self) { name in
                        HStack {
                            Text(name).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { copyCustomSecret(name, app: app) } label: { CopyLabel(copied: copiedSecret == name) }
                                .buttonStyle(XkeysButtonStyle(primary: true, compact: true)).disabled(access.busy)
                                .help("値をコピー")
                        }
                        if name != names.last { Divider() }
                    }
                }
                Divider()
                HStack {
                    Button("Secretを追加", systemImage: "plus") { addingCustomSecret = true; editingCustomSecrets = true }
                        .buttonStyle(XkeysButtonStyle()).disabled(access.busy || names.count >= 100)
                    Spacer()
                    if !names.isEmpty {
                        Button("編集") { addingCustomSecret = false; editingCustomSecrets = true }
                            .buttonStyle(XkeysButtonStyle()).disabled(access.busy)
                    }
                }
            }.padding(.top, 12)
                .resettingCopied($copiedSecret)
        } label: {
            HStack {
                Text("任意のSecret").font(.system(size: 14, weight: .semibold))
                Text("\(names.count)項目").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(XkeysStyle.border))
    }

    /// Shown only when the app has a saved note; the text appears after authentication, like a revealed .p12 password.
    private func noteSection(_ app: ManagedApp) -> some View {
        // Collapsing hides the text again.
        DisclosureGroup(isExpanded: Binding(get: { showingNote }, set: { showingNote = $0; if !$0 { revealedNote = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                if let revealedNote {
                    Text(revealedNote.isEmpty ? String(localized: "メモは空です") : revealedNote)
                        .font(.system(size: 13)).foregroundStyle(revealedNote.isEmpty ? XkeysStyle.secondary : XkeysStyle.text)
                        .textSelection(.enabled).privacySensitive().fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("メモは暗号化して保存しています。表示するには認証してください。")
                        .font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                }
                Divider()
                HStack {
                    if revealedNote == nil {
                        Button("認証して表示") { revealNote(app) }.buttonStyle(XkeysButtonStyle(primary: true, compact: true)).disabled(access.busy)
                    } else {
                        Button("隠す") { revealedNote = nil }.buttonStyle(XkeysButtonStyle(compact: true))
                    }
                    Spacer()
                    Button("編集") { selected = nil; editingNote = true }.buttonStyle(XkeysButtonStyle()).disabled(access.busy)
                }
            }.padding(.top, 12)
        } label: {
            Text("メモ").font(.system(size: 14, weight: .semibold))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(XkeysStyle.border))
    }

    private func revealNote(_ app: ManagedApp) {
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: String(localized: "暗号化メモを表示します"), allowCreation: false, vault: vault) { key in
                    revealedNote = try VaultManagement(vault: vault).readNote(app, key: key) ?? ""
                    noteRevealedAt = .now
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func copyCustomSecret(_ name: String, app: ManagedApp) {
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: String(localized: "任意Secretをコピーします"), allowCreation: false, vault: vault) { key in
                    guard let secret = try VaultManagement(vault: vault).readCustomSecrets(app, key: key).first(where: { $0.name == name }) else {
                        throw ValidationError.invalidFile
                    }
                    try SecretClipboard.copy(secret.value)
                }
                status = String(localized: "「\(name)」の値をコピーしました")
                copiedSecret = name
                XkeysMotion.confirm()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func teamLink(_ owner: DeveloperTeam) -> some View {
        Button { openTeam(owner.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "key")
                Text("署名用の証明書と、通知などに使う鍵は「鍵と証明書」にあります")
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(XkeysStyle.tertiary)
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(XkeysStyle.text.opacity(0.8))
                .background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(XkeysStyle.rowBorder))
        }.buttonStyle(.plain)
    }

    private func targetSection(_ target: ManagedApp) -> some View {
        let profiles = visible.filter { $0.app?.id == target.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppIcon(app: target.product, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.name + (target.parentAppID == nil ? String(localized: "（本体）") : "")).fontWeight(.semibold)
                    Text(target.bundleID).font(.caption.monospaced()).foregroundStyle(XkeysStyle.secondary)
                }
                Spacer()
                GuideTermButton(term: .profile)
                Text("プロファイル \(profiles.count)件").foregroundStyle(XkeysStyle.secondary)
                Menu {
                    Button("編集…") { editingTarget = target }
                    Button(target.parentAppID == nil ? "アプリと全ターゲットを削除…" : "ターゲットとプロファイルを削除…", role: .destructive) {
                        deletingTarget = target
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                    .accessibilityLabel(String(localized: "\(target.name)の操作")).disabled(access.busy)
            }.padding(.vertical, 8)
            if profiles.isEmpty {
                Text("プロファイルはまだありません").foregroundStyle(XkeysStyle.secondary).padding(.vertical, 8)
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
        }.font(.system(size: 11, weight: .semibold)).foregroundStyle(XkeysStyle.secondary)
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
                    .frame(width: 36, height: 36).background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 9))
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
                .onTapGesture { select(isSelected ? nil : record.id) }
            if isSelected {
                VStack(alignment: .leading, spacing: 12) {
                    actions(record)
                    detail(record)
                }.padding(.leading, 64).padding(.trailing, 14).padding(.bottom, 14)
            }
        }
        .background(group.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isSelected ? XkeysStyle.selectionBorder : broken ? XkeysStyle.dangerBorder : hoveredRow == record.id ? XkeysStyle.selectionBorder : group.border,
                    lineWidth: isSelected ? 1.5 : 1))
        .onHover { hoveredRow = $0 ? record.id : hoveredRow == record.id ? nil : hoveredRow }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { select(isSelected ? nil : record.id) }
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

    /// Opens or closes a row's card. A revealed password is dropped first, in the same update,
    /// so the closing card is never drawn with it while it animates away.
    private func select(_ id: UUID?) {
        revealedPassword = nil
        withAnimation(XkeysMotion.feedback) { selected = id }
    }

    private func targetTag(_ owner: ManagedApp) -> some View {
        HStack(spacing: 4) {
            AppIcon(app: owner.product, size: 14)
            Text(owner.product.name + (owner.parentAppID == nil ? "" : " · " + owner.name))
        }.font(.system(size: 11)).foregroundStyle(XkeysStyle.text.opacity(0.75))
            .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 1)
            .background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 5))
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
                  ".\(record.fileExtension)" + (bundled > 0 ? String(localized: "（ほか\(bundled)件を含む）") : "")].joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private func detailColumn(_ record: StoredCredential) -> some View {
        switch CredentialGroup(record) {
        case .key:
            PurposeLabels(record: record)
        case .profile:
            Text(record.bundleID ?? record.app?.bundleID ?? "—").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(XkeysStyle.text.opacity(0.8)).lineLimit(1).truncationMode(.middle)
        case .certificate:
            let targets = record.profilesUsing(in: records).compactMap(\.app)
            let products = targets.map(\.product).reduce(into: [ManagedApp]()) { if !$0.contains($1) { $0.append($1) } }
            if products.isEmpty {
                Text("なし").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(products) { product in
                        let names = targets.filter { $0.product == product }.map { $0.parentAppID == nil ? String(localized: "本体") : $0.name }
                        HStack(spacing: 6) {
                            AppIcon(app: product, size: 16)
                            Text(product.name).lineLimit(1)
                            Text(names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: String(localized: "・")))
                                .foregroundStyle(XkeysStyle.secondary).lineLimit(1)
                        }.font(.system(size: 12)).padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 2)
                            .background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CredentialGroup.certificate.border))
                    }
                }
            }
        }
    }

    @ViewBuilder private func status(_ record: StoredCredential, state: CredentialDisplayState, certificatesExpired: Bool) -> some View {
        if certificatesExpired, let owner = record.team {
            Button("証明書が期限切れ") { openTeam(owner.id) }.buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(XkeysStyle.dangerText).underline()
                .help("「鍵と証明書」で証明書を確認します")
        } else if state == .expired || state.needsRenewal {
            Text(state.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .expired ? XkeysStyle.dangerText : XkeysStyle.warningText)
        } else {
            Text(record.expiresAt.map { $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) } ?? String(localized: "なし"))
                .foregroundStyle(XkeysStyle.secondary)
        }
    }

    private func actions(_ record: StoredCredential) -> some View {
        HStack(spacing: 6) {
            Button("コピー") { copyingCI = true }.buttonStyle(XkeysButtonStyle(primary: true, compact: true))
            Button("書き出す") { export(record) }.buttonStyle(XkeysButtonStyle(compact: true))
            Menu {
                Button("書き出して Finder で表示") { export(record, revealInFinder: true) }
                if record.fileExtension == "p8" {
                    Button("用途を変更…") { editingPurposes = true }
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
            metadata(String(localized: "ファイルの種類"), "\(record.fileTypeTitle)（.\(record.fileExtension)）")
            if record.fileExtension == "p8" { metadata(String(localized: "用途"), record.purposeTitle) }
            if record.isIntermediateCA {
                metadata("Team ID", String(localized: "対象外（中間CA証明書）"))
            } else {
                metadata("Team ID", record.team?.teamID ?? String(localized: "未取得"), monospaced: true)
            }
            if let owner = record.app { metadata("Bundle ID", owner.bundleID, monospaced: true) }
            if CredentialGroup(record) == .profile {
                let certificates = record.signingCertificates(in: records)
                if !certificates.isEmpty { metadata(String(localized: "使う証明書"), certificates.map(\.name).joined(separator: String(localized: "、"))) }
            }
            if let value = record.keyID { metadata("Key ID", value, monospaced: true) }
            if let value = record.issuerID { metadata("Issuer ID", value, monospaced: true) }
            if record.fileExtension == "p12" {
                let bundled = record.bundledCertificates
                metadata(String(localized: "同梱の証明書"), record.p12Certificates == nil ? (record.hasSavedPassword ? String(localized: "未確認（次の認証後に表示）") : String(localized: "未確認（パスワード未保存）"))
                         : bundled.isEmpty ? String(localized: "なし")
                         : bundled.map { $0.name + ($0.expiresAt.map { String(localized: "（\($0.formatted(date: .abbreviated, time: .omitted))まで）") } ?? "") }.joined(separator: "\n"))
                HStack(alignment: .top, spacing: 12) {
                    Text("パスワード").foregroundStyle(XkeysStyle.secondary).frame(width: 96, alignment: .leading)
                    Text(revealedPassword.map { $0.isEmpty ? String(localized: "空のパスワード") : $0 } ?? (record.hasSavedPassword ? "••••••••" : String(localized: "未保存")))
                        .monospaced().privacySensitive().textSelection(.disabled)
                }
            }
            metadata(String(localized: "追加した日"), record.createdAt.formatted(date: .long, time: .omitted))
            metadata(String(localized: "元のファイル名"), record.originalName, monospaced: true)
            Label("コピー・書き出しの前に Touch ID で確認します", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(XkeysStyle.secondary).padding(.top, 4)
        }.font(.system(size: 12))
    }

    private func metadata(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(XkeysStyle.secondary).frame(width: 96, alignment: .leading)
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
        revealedNote = nil
        error = nil
        status = ""
    }

    private func export(_ record: StoredCredential, revealInFinder: Bool = false) {
        let generation = access.generation
        access.presentingPanel = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.originalName
        panel.message = String(localized: "元の形式で書き出します。保存先ではXkeysの暗号化保護の対象外になります。新しい名前を指定してください。既存ファイルは上書きしません。")
        let response = panel.runModal()
        access.presentingPanel = false
        guard response == .OK, let url = panel.url, generation == access.generation else { return }
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: String(localized: "資格情報の元ファイルを書き出します"), allowCreation: false, vault: vault) { key in
                    try vault.export(record, to: url, key: key)
                }
                if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                status = String(localized: "ファイルを書き出しました。保存先のファイルはご自身で管理してください。")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func trash(_ record: StoredCredential) {
        Task { @MainActor in
            do {
                try await access.withKey(reason: String(localized: "資格情報を最近削除した項目へ移します"), allowCreation: false, vault: vault) { key in
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
                try await access.withKey(reason: String(localized: "選択した\(targets.count)件の鍵・ファイルを最近削除した項目へ移します"), allowCreation: false, vault: vault) { key in
                    try VaultManagement(vault: vault).trash(targets, key: key)
                }
                checkedIDs = []
                selectingForDeletion = false
                if targets.contains(where: { $0.id == selected }) { selected = nil }
                status = String(localized: "\(targets.count)件を最近削除した項目へ移しました。30日間は復元できます。")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func deleteTarget(_ target: ManagedApp) {
        Task { @MainActor in
            do {
                let create = try vault.canCreateKey()
                try await access.withKey(reason: String(localized: "登録と配下のプロファイルを削除します"), allowCreation: create, vault: vault) { key in
                    try VaultManagement(vault: vault).trash(target, key: key)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func revealPassword(_ record: StoredCredential) {
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: String(localized: "保存済みの.p12パスワードを表示します"), allowCreation: false, vault: vault) { key in
                    guard let password = try vault.read(record, key: key).password else { throw ValidationError.invalidFile }
                    revealedPassword = password
                    revealedAt = .now
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
