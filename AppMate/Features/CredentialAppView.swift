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

private struct CredentialStatusBadge: View {
    let state: CredentialDisplayState
    @Environment(\.colorScheme) private var scheme
    private var foreground: Color {
        switch state {
        case .expired: scheme == .dark ? Color(red: 1, green: 0.65, blue: 0.65) : Color(red: 0.56, green: 0.11, blue: 0.07)
        case .withinDay, .expiring: scheme == .dark ? .yellow : Color(red: 0.48, green: 0.28, blue: 0)
        case .valid: scheme == .dark ? .green : Color(red: 0.09, green: 0.38, blue: 0.18)
        case .stored, .replaced, .revoked: .secondary
        }
    }
    private var background: Color {
        switch state {
        case .expired: Color.red.opacity(0.12)
        case .withinDay, .expiring: Color.yellow.opacity(0.16)
        case .valid: Color.green.opacity(0.12)
        case .stored, .replaced, .revoked: Color.secondary.opacity(0.1)
        }
    }
    var body: some View {
        Text(state.title).font(.system(size: 11, weight: .semibold))
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
    @Query(sort: \StoredCredential.name) private var records: [StoredCredential]
    @State private var access = VaultAccess()
    @State private var selected: UUID?
    @State private var clock = Date.now
    @State private var showReplaced = false
    @State private var error: String?
    @State private var status = ""
    @State private var revealedPassword: String?
    @State private var editingNote = false
    @State private var editingApp = false
    @State private var copyingCI = false
    @State private var deleting = false
    @State private var revealedAt = Date.distantPast

    private var visible: [StoredCredential] {
        records.filter { CredentialSearch.includes($0, scope: scope, app: app, query: search, type: typeFilter, showReplaced: showReplaced, at: clock) }
    }
    private var selectedRecord: StoredCredential? { visible.first { $0.id == selected } }
    private var vault: CredentialVault {
        CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))
    }

    var body: some View {
        HSplitView {
            credentialList
                .frame(minWidth: 340, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            inspector
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .font(.system(size: 13))
        .toolbar { Button("ロック", systemImage: "lock") { lock() } }
        .sheet(isPresented: $importing) {
            if let app {
                CredentialImportView(app: app, vault: vault, access: access, existing: records) { id in
                    selected = id
                    status = "資格情報を暗号化して保存しました。元ファイルは変更していません。"
                }
            }
        }
        .sheet(isPresented: $editingNote) { NoteEditor(vault: vault, app: selectedRecord == nil ? app : nil, record: selectedRecord) }
        .sheet(isPresented: $editingApp) { CatalogEditor(vault: vault, team: nil, app: app) }
        .sheet(isPresented: $copyingCI) { if let record = selectedRecord { CICopyView(vault: vault, record: record) } }
        .confirmationDialog("チーム全体から削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
            Button("認証して削除", role: .destructive) { if let record = selectedRecord { manage(record, trash: true) } }
        } message: {
            if let record = selectedRecord {
                Text((record.isTeamShared ? "影響するApp：" + (record.team?.apps.filter { $0.deletedAt == nil }.map(\.name).joined(separator: "、") ?? "") : "このAppの専用ファイルを削除します。") + (["p8", "p12"].contains(record.fileExtension) ? " 秘密鍵を失うと再発行等が必要です。" : "") + " 30日間は復元できます。Apple側の失効やCI設定は変更しません。")
            }
        }
        .task {
            do {
                try vault.recover()
                if selected == nil { selected = visible.first?.id }
            }
            catch { self.error = "保存状態を確認できません。\(error.localizedDescription)" }
        }
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
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: app == nil ? "key.fill" : "app.fill")
                        .font(.system(size: 24)).foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? app?.name ?? scope.title : "横断検索の結果").font(.system(size: 20, weight: .bold)).lineLimit(2)
                        Text("\(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? app.map { $0.platform + "アプリ · " } ?? "" : "すべてのTeam・App · ")鍵とファイル \(visible.count)件")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if app != nil { Button("App情報") { selected = nil }.buttonStyle(.bordered) }
                }
                let attention = visible.filter { $0.displayState(at: clock).needsRenewal || $0.displayState(at: clock) == .expired }
                if !attention.isEmpty {
                    Label("\(attention.count)件の期限を確認してください。新しい証明書やプロファイルを追加できます。", systemImage: "clock")
                        .font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                }
                HStack(spacing: 6) {
                    Text("名前").frame(maxWidth: .infinity, alignment: .leading)
                    Text("種類").frame(width: 76, alignment: .leading)
                    Text("期限").frame(width: 84, alignment: .leading)
                    Text("状態").frame(width: 82, alignment: .trailing)
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8)
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
            Divider().padding(.horizontal, 20)
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(!CredentialSearch.hasQuery(search) && typeFilter == .all ? "鍵やファイルがありません" : "条件に一致する項目がありません", systemImage: "magnifyingglass")
                } description: {
                    Text(CredentialSearch.hasQuery(search) || typeFilter != .all ? "検索語や種類を変えて確認してください。" : app == nil ? "該当する資格情報はありません。" : "このアプリで使う鍵や証明書を追加しましょう。")
                } actions: {
                    if app != nil { Button("ファイルを追加…") { importing = true } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selected) {
                    if visible.contains(where: { !$0.isTeamShared }) {
                        Section(app == nil ? "アプリ専用" : "このアプリ専用") {
                            ForEach(visible.filter { !$0.isTeamShared }) { row($0) }
                        }
                    }
                    if visible.contains(where: \.isTeamShared) {
                        Section {
                            ForEach(visible.filter(\.isTeamShared)) { row($0) }
                        } header: {
                            HStack {
                                Text("チームで共通")
                                if let count = app?.team?.apps.count { Text("\(count)アプリで共有").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).padding(.horizontal, 12)
            }
            Divider().padding(.horizontal, 20)
            Toggle("置き換え済みを表示", isOn: $showReplaced).font(.system(size: 12))
                .padding(.horizontal, 20).padding(.vertical, 10)
            if access.busy { ProgressView("認証しています…").font(.caption).padding(.horizontal, 20).padding(.bottom, 10) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).textSelection(.enabled).padding(12) }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 10) }
        }.background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ record: StoredCredential) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).fontWeight(.medium).lineLimit(2)
                if app == nil {
                    Text([record.team?.name, record.app?.name, record.app?.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(record.fileExtension == "p8" ? "鍵" : record.isTeamShared ? "証明書" : "プロファイル")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(record.expiresAt?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) ?? "なし")
                .font(.system(size: 12)).frame(width: 84, alignment: .leading)
            CredentialStatusBadge(state: record.displayState(at: clock)).frame(width: 82, alignment: .trailing)
        }
        .padding(.vertical, 7).tag(record.id)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var inspector: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(record.kind) · \(record.isTeamShared ? "チームで共通" : "このアプリ専用")")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(record.name).font(.system(size: 20, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        CredentialStatusBadge(state: record.displayState(at: clock))
                        Text(record.expiresAt.map { $0.formatted(date: .long, time: .omitted) + "に期限切れ" } ?? "期限はありません。失効状態はApple側で確認してください。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    VStack(spacing: 8) {
                        Button { export(record) } label: { Text("ファイルを書き出す").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                        Button { copyingCI = true } label: { Text("CIに登録する値をコピー").frame(maxWidth: .infinity) }
                        Button { export(record, revealInFinder: true) } label: { Text("書き出してFinderで表示").frame(maxWidth: .infinity) }
                    }.buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(access.busy)
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        metadata("ファイルの種類", record.kind)
                        metadata("チーム", record.team?.name ?? "未設定")
                        metadata("チームID", record.team?.teamID ?? "未取得", monospaced: true)
                        if let owner = record.app {
                            metadata("アプリ", owner.name)
                            metadata("Bundle ID", owner.bundleID, monospaced: true)
                        }
                        metadata("追加した日", record.createdAt.formatted(date: .abbreviated, time: .omitted))
                        metadata("元のファイル名", record.originalName, monospaced: true)
                        if let value = record.keyID { metadata("Key ID", value, monospaced: true) }
                        if let value = record.issuerID { metadata("Issuer ID", value, monospaced: true) }
                        if record.fileExtension == "p12" {
                            metadata("パスワード", record.hasSavedPassword ? "••••••••" : "未保存", monospaced: true)
                            if let revealedPassword {
                                Text(revealedPassword.isEmpty ? "空のパスワード" : revealedPassword).monospaced().privacySensitive().textSelection(.disabled)
                                Button("パスワードを隠す") { self.revealedPassword = nil }
                            } else if record.hasSavedPassword {
                                Button("認証して表示") { revealPassword(record) }.disabled(access.busy)
                            }
                        }
                        if let id = record.replacedByID {
                            metadata("置き換え先", records.first { $0.id == id }?.name ?? "未確認")
                            Button("認証して通常一覧に戻す") { restore(record) }.disabled(access.busy)
                        }
                        if let id = record.replacesCredentialID { metadata("置き換え元", records.first { $0.id == id }?.name ?? "未確認") }
                    }
                    Button("暗号化メモを開く…") { editingNote = true }
                    Button(record.revokedAt == nil ? "認証して手動失効にする" : "認証して手動失効を解除") { manage(record, trash: false) }.disabled(access.busy)
                    DisclosureGroup("ファイルの識別情報") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ファイルSHA-256").foregroundStyle(.secondary)
                            Text(record.digest).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            if let fingerprint = record.fingerprint {
                                Text(record.fileExtension == "p8" ? "公開鍵SHA-256" : "証明書SHA-256").foregroundStyle(.secondary)
                                Text(fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                        }.font(.system(size: 11)).padding(.top, 8)
                    }.font(.system(size: 12))
                    Button("チーム全体から削除…", role: .destructive) { deleting = true }.disabled(access.busy)
                    Text("表示・書き出しにはTouch IDまたはMacのパスワードで認証します。発行元の信頼性・オンライン失効は確認していません。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let app {
            VStack(alignment: .leading, spacing: 16) {
                Text("App情報").font(.system(size: 18, weight: .semibold))
                metadata("Bundle ID", app.bundleID, monospaced: true)
                metadata("プラットフォーム", app.platform)
                metadata("チーム", app.team?.name ?? "未設定")
                metadata("チームID", app.team?.teamID ?? "未設定", monospaced: true)
                Divider()
                Button("Appを編集…") { editingApp = true }
                Button("暗号化メモを開く…") { editingNote = true }
                Text("中央の鍵やファイルを選ぶと詳細を表示します。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView("鍵やファイルを選択", systemImage: "sidebar.right",
                                   description: Text("中央の一覧から選ぶと詳細を表示します。"))
        }
    }

    private func metadata(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            Text(value).font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    private func lock(dismissImport: Bool = true) {
        access.lock()
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

private struct CredentialImportView: View {
    let app: ManagedApp
    let vault: CredentialVault
    let access: VaultAccess
    let existing: [StoredCredential]
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
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

    private var parsed: ParsedCredential? { candidates.indices.contains(selected) ? candidates[selected] : nil }
    private var isP8: Bool { file.map { ($0.name as NSString).pathExtension.lowercased() == "p8" } ?? false }
    private var p8: P8Metadata? {
        guard isP8, let purpose else { return nil }
        return P8Metadata(purpose: purpose, keyID: keyID, issuerID: issuerID)
    }
    private var replacementCandidates: [StoredCredential] {
        guard let file else { return [] }
        let ext = (file.name as NSString).pathExtension.lowercased()
        return existing.filter { $0.isVisible(in: app) && $0.replacedByID == nil && $0.fileExtension == ext && $0.keyPurpose == p8?.purpose.rawValue }
    }
    private var validationIssue: String? {
        guard let file, let parsed else { return nil }
        do {
            if replacing && targetID == nil { return "置き換える旧資格情報を選んでください。" }
            try vault.validate(file: file, parsed: parsed, app: app, confirmUnknownTeam: confirmUnknownTeam,
                               p8: p8, replacingID: replacing ? targetID : nil, confirmReplacement: confirmReplacement)
            return nil
        }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("資格情報を取り込む").font(.title2.bold())
            Text("\(app.name) ／ \(app.team?.name ?? "Team未設定")").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button("ファイル・フォルダを選ぶ…", action: chooseFile)
                    Text(".cer・.p12・.p8・.mobileprovision・.provisionprofile、各16MB以下。複数ファイルやフォルダをドロップできます。1件ずつ解析と所属を確認して取り込みます。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !completedItems.isEmpty {
                        DisclosureGroup("処理結果 \(completedItems.count)件・残り \(queue.count + (currentName.isEmpty ? 0 : 1))件") {
                            ForEach(Array(completedItems.enumerated()), id: \.offset) { _, result in Text(result).font(.caption) }
                        }
                    }
                    if !currentName.isEmpty {
                        Text("確認中：" + currentName).font(.headline)
                        Button("この項目をスキップして次へ") { completedItems.append("スキップ：" + currentName + (error.map { " · " + $0 } ?? "")); next() }
                    }
                    if let file { LabeledContent("ファイル", value: file.name) }
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
                        if isP8 {
                            Picker("用途", selection: $purpose) {
                                Text("用途を選択してください").tag(nil as P8Purpose?)
                                ForEach(P8Purpose.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                            }
                            TextField("Key ID（英大文字・数字10文字）", text: $keyID).textFieldStyle(.roundedBorder)
                            if purpose == .appStoreConnect {
                                TextField("Issuer ID（UUID）", text: $issuerID).textFieldStyle(.roundedBorder)
                            }
                            Text("用途と識別情報はApple Developerの登録内容を確認してください。鍵ファイルだけでは確定できません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent("名前", value: parsed.name)
                        LabeledContent("期限", value: parsed.expiresAt?.formatted(date: .abbreviated, time: .standard) ?? "期限なし")
                        LabeledContent("取得したTeam ID", value: parsed.teamID ?? "未取得")
                        if let bundle = parsed.bundleID { LabeledContent("Bundle ID", value: bundle) }
                        if let fingerprint = parsed.fingerprint { Text("SHA-256：\(fingerprint)").font(.caption.monospaced()).textSelection(.enabled) }
                        if parsed.teamID == nil {
                            Toggle("Team IDを判別できないため、\(app.team?.name ?? "選択中のTeam")に割り当てることを確認しました", isOn: $confirmUnknownTeam)
                        }
                        let isP12 = (file?.name as NSString?)?.pathExtension.lowercased() == "p12"
                        Text(parsed.bundleID == nil ? "同じTeamのすべてのAppに表示されます。" : "このApp専用のプロファイルとして保存します。")
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
                                    : "\(app.name)（\(app.bundleID)）"))
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
                guard !reading, !access.busy else { return false }
                start(urls)
                return true
            }
            .disabled(reading || access.busy)
            HStack {
                Button(currentName.isEmpty && !completedItems.isEmpty ? "閉じる" : "キャンセル") { access.lock(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("認証して取り込む", action: save).keyboardShortcut(.defaultAction)
                    .disabled(reading || access.busy || parsed == nil || validationIssue != nil)
            }
        }
        .padding(24).frame(width: 580, height: 660)
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
        let confirmed = confirmUnknownTeam
        let metadata = p8
        let replacingID = replacing ? targetID : nil
        let replacementConfirmed = confirmReplacement
        Task { @MainActor in
            do {
                try vault.validate(file: file, parsed: parsed, app: app, confirmUnknownTeam: confirmed, p8: metadata, replacingID: replacingID, confirmReplacement: replacementConfirmed)
                let canCreate = try vault.canCreateKey()
                let id = try await access.withKey(reason: "資格情報を暗号化して保存します", allowCreation: canCreate, vault: vault) { key in
                    try vault.importFile(file, parsed: parsed, app: app, password: password, confirmUnknownTeam: confirmed, key: key, p8: metadata, replacingID: replacingID, confirmReplacement: replacementConfirmed)
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
