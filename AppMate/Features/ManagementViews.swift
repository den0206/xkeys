import CryptoKit
import AppKit
import SwiftData
import SwiftUI

struct NoteEditor: View {
    let vault: CredentialVault
    var app: ManagedApp? = nil
    var record: StoredCredential? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var access = VaultAccess()
    @State private var note = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var activity = Date.now
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("暗号化メモ").font(.title2.bold())
            Text("表示と保存のたびにMacで認証します。メモは暗号化して保存し、検索には含めません。")
                .font(.caption).foregroundStyle(.secondary)
            if loaded { TextEditor(text: $note).privacySensitive().border(Color.secondary.opacity(0.3)) }
            else { Button("認証してメモを開く") { perform(save: false) } }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("認証して保存") { perform(save: true) }.disabled(!loaded || access.busy || note.utf8.count > 65536)
            }
        }.padding(24).frame(width: 580, height: 420)
            .onChange(of: note) { _, _ in activity = .now }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in if Date.now.timeIntervalSince(activity) >= 300 { close() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in close() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if !access.busy { close() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in close() }
            .onDisappear { access.lock(); note = "" }
    }
    private func close() { access.lock(); note = ""; dismiss() }
    private func perform(save: Bool) {
        Task { @MainActor in
            do {
                let create = try vault.canCreateKey()
                try await access.withKey(reason: save ? "メモを暗号化して保存します" : "暗号化メモを表示します", allowCreation: create, vault: vault) { key in
                    let management = VaultManagement(vault: vault)
                    if let app {
                        if save { try management.saveNote(note, app: app, key: key) }
                        else { note = try management.readNote(app, key: key) ?? "" }
                    } else if let record {
                        if save { try management.saveNote(note, record: record, key: key) }
                        else { note = try vault.read(record, key: key).note ?? "" }
                    }
                }
                loaded = true; activity = .now
                if save { close() }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CatalogEditor: View {
    let vault: CredentialVault
    let team: DeveloperTeam?
    let app: ManagedApp?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parentAppID: UUID?
    @State private var platform = "iOS"
    @State private var iconColor: String?
    @State private var iconImage: Data?
    @State private var error: String?
    @State private var deleting = false
    @Query private var records: [StoredCredential]
    @State private var access = VaultAccess()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app == nil ? "Teamを編集" : "Appを編集").font(.title2.bold())
            TextField("表示名", text: $name)
            Text(app?.bundleID ?? team?.teamID ?? "").font(.body.monospaced()).textSelection(.enabled)
            Text("識別子と所属Teamは資格情報との関連を保つため固定です。別の識別子は新規登録してください。")
                .font(.caption).foregroundStyle(.secondary)
            if app != nil { Picker("プラットフォーム", selection: $platform) { ForEach(AppCatalog.platforms, id: \.self) { Text($0).tag($0) } } }
            if let app {
                LabeledContent("アイコン") {
                    AppIconPicker(name: name, iconColor: $iconColor, iconImage: $iconImage)
                }
                Picker("所属アプリ", selection: $parentAppID) {
                    Text("独立したアプリ（本体）").tag(nil as UUID?)
                    ForEach((app.team?.apps ?? []).filter { $0.id != app.id && $0.parentAppID == nil && $0.deletedAt == nil }.sorted { $0.name < $1.name }) { parent in
                        Text(parent.name).tag(Optional(parent.id))
                    }
                }
                Text("共有拡張などを既存のアプリにまとめられます。Bundle IDと保存済みファイルは変わりません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                // Teams are deleted only from TeamDeletionView, which explains why a team cannot be removed.
                if app != nil { Button("削除…", role: .destructive) { deleting = true } }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { throw RegistrationError.nameRequired }
                        if let app {
                            try AppCatalog(context: vault.context).updateApp(app, name: value, platform: platform, parentAppID: parentAppID,
                                                                           iconColor: iconColor, iconImage: iconImage)
                        } else {
                            try VaultManagement(vault: vault).change { team?.name = value }
                        }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(access.busy)
            }
        }.padding(24).frame(width: 490)
            .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text)
            .onAppear {
                name = app?.name ?? team?.name ?? ""
                platform = app?.platform ?? "iOS"
                parentAppID = app?.parentAppID
                iconColor = app?.iconColor
                iconImage = app?.iconImage
            }
            .sheet(isPresented: $deleting) {
                if let app {
                    TargetDeleteConfirmation(target: app, records: records) {
                        deleting = false
                        Task { @MainActor in
                            do {
                                let create = try vault.canCreateKey()
                                try await access.withKey(reason: "登録と配下のプロファイルを削除します", allowCreation: create, vault: vault) { key in
                                    try VaultManagement(vault: vault).trash(app, key: key)
                                }
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .onDisappear { access.lock() }
    }
}

struct TeamManagementView: View {
    let vault: CredentialVault
    let onDeleted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DeveloperTeam.name) private var teams: [DeveloperTeam]
    @State private var editing: DeveloperTeam?
    @State private var deleting: DeveloperTeam?
    @State private var loggingIn: DeveloperTeam?
    @State private var importing: DeveloperTeam?
    @State private var error: String?

    private let appleSession: AppleDeveloperSession

    init(vault: CredentialVault, appleSession: AppleDeveloperSession = .shared, onDeleted: @escaping (UUID) -> Void) {
        self.vault = vault
        self.appleSession = appleSession
        self.onDeleted = onDeleted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("登録済みチーム（\(teams.count)件）").font(.title2.bold())
            Text("App Mateに登録したすべてのチームです。現在ログイン中のApple Accountにかかわらず表示します。")
                .font(.callout).foregroundStyle(AppMateStyle.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(teams) { team in
                        let loggedIn = appleSession.connected && appleSession.teams.contains { $0.teamID == team.teamID }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(team.name).fontWeight(.medium)
                                    if loggedIn {
                                        Text("ログイン中").font(.caption).foregroundStyle(.green)
                                    }
                                }
                                Text("Team ID: " + team.teamID).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(AppMateStyle.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            if loggedIn {
                                Button("取り込む…") { importing = team }
                                    .disabled(appleSession.busy)
                                    .accessibilityLabel(team.name + "の証明書・プロファイルを取り込む")
                                Button("ログアウト") {
                                    do { try appleSession.disconnect(); error = nil }
                                    catch { self.error = AppleDeveloperError.message(for: error) }
                                }
                            } else {
                                Button("ログイン") {
                                    appleSession.useAnotherAccount()
                                    loggingIn = team
                                }.disabled(appleSession.busy)
                            }
                            Button("編集…") { editing = team }.accessibilityLabel(team.name + "を編集")
                            Button("削除…", role: .destructive) { deleting = team }.accessibilityLabel(team.name + "を削除")
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if teams.isEmpty { Text("登録済みのチームはありません。").foregroundStyle(AppMateStyle.secondary).padding() }
                }
            }
            if appleSession.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("ログイン状態を確認しています…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 600, height: 440)
        .font(.system(size: 13)).buttonStyle(AppMateButtonStyle())
        .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text)
        .task {
            do {
                try appleSession.loadSavedAccount()
                if appleSession.hasSavedSession && !appleSession.connected && !appleSession.busy {
                    try await appleSession.resume()
                }
            } catch AppleDeveloperError.loginRequired {
                // An expired session leaves the cards ready for another login.
            } catch { self.error = AppleDeveloperError.message(for: error) }
        }
        .sheet(item: $loggingIn) { team in
            AppleDeveloperLoginView(onVerified: {
                guard appleSession.teams.contains(where: { $0.teamID == team.teamID }) else {
                    throw AppleDeveloperError.teamAccessRequired
                }
            }, session: appleSession, verificationTitle: team.name + "にログイン", restoreSavedSession: false)
                .onChange(of: appleSession.connected) { _, connected in
                    if connected && appleSession.teams.contains(where: { $0.teamID == team.teamID }) {
                        loggingIn = nil
                    }
                }
        }
        .sheet(item: $editing) { team in CatalogEditor(vault: vault, team: team, app: nil) }
        .sheet(item: $importing) { team in
            AppleDeveloperImportView(team: team, vault: vault, session: appleSession, onSaved: { _ in })
                .modelContainer(vault.context.container)
        }
        .sheet(item: $deleting) { team in
            let id = team.id
            TeamDeletionView(vault: vault, team: team) { onDeleted(id) }
        }
    }
}

struct TeamDeletionView: View {
    let vault: CredentialVault
    let team: DeveloperTeam
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = VaultAccess()
    @State private var error: String?
    @State private var hasContents = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("チームを削除").font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text(team.name).font(.headline)
                Text("Team ID: " + team.teamID).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            if hasContents {
                Label("このチームは削除できません", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppMateStyle.warningText)
                Text("アプリや資格情報が残っています。チームを削除するには、先に所属データを削除し、「最近削除した項目」からも完全に削除する必要があります。")
                    .foregroundStyle(AppMateStyle.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("App Mateからこのチームの登録を削除します。この操作は元に戻せません。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Apple Developerのチームからの脱退や、Apple側の鍵・証明書の削除は行いません。")
                    .foregroundStyle(AppMateStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if access.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(hasContents ? "閉じる" : "キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("認証してチームを削除", role: .destructive, action: remove)
                    .disabled(hasContents || access.busy)
            }
        }
        .padding(24).frame(width: 490).font(.system(size: 13))
        .buttonStyle(AppMateButtonStyle()).background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text)
        .interactiveDismissDisabled(access.busy)
        .onAppear {
            do {
                let records = try vault.records()
                hasContents = !team.apps.isEmpty || records.contains { $0.team?.id == team.id }
            }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { access.lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in access.lock(); dismiss() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in access.lock(); dismiss() }
    }

    private func remove() {
        guard !hasContents, !access.busy else { return }
        Task { @MainActor in
            do {
                let create = try vault.canCreateKey()
                try await access.withKey(reason: "チーム「\(team.name)」の登録を削除します", allowCreation: create, vault: vault) { _ in
                    try VaultManagement(vault: vault).removeTeam(team)
                }
                onDeleted()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct TrashView: View {
    let vault: CredentialVault
    @Query private var records: [StoredCredential]
    @Query private var apps: [ManagedApp]
    @State private var access = VaultAccess()
    @State private var error: String?
    @State private var purging = false
    private var deletedApps: [ManagedApp] { apps.filter { $0.deletedAt != nil } }
    private var deletedRecords: [StoredCredential] { records.filter { $0.deletedAt != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "trash").font(.system(size: 24)).foregroundStyle(AppMateStyle.text.opacity(0.75))
                    .frame(width: 52, height: 52).background(AppMateStyle.search, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近削除した項目").font(.system(size: 22, weight: .bold))
                    Text("削除してから 30 日間は元に戻せます。その後は自動で完全に消えます。").foregroundStyle(AppMateStyle.secondary)
                }
                Spacer()
                Button("すべて完全に削除…", role: .destructive) { purging = true }
                    .buttonStyle(AppMateButtonStyle(compact: true)).foregroundStyle(AppMateStyle.dangerText)
                    .disabled(deletedApps.isEmpty && deletedRecords.isEmpty)
            }
            if deletedApps.isEmpty && deletedRecords.isEmpty {
                ContentUnavailableView("削除した項目はありません", systemImage: "trash").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(deletedApps) { app in
                            let includedApps = [app] + (app.parentAppID == nil ? deletedApps.filter { $0.parentAppID == app.id && $0.deletedAt == app.deletedAt } : [])
                            let profiles = records.filter { record in record.deletedAt == app.deletedAt && includedApps.contains { record.app?.id == $0.id } }.count
                            let targets = includedApps.count - 1
                            trashRow(app.name, detail: "アプリ" + (targets > 0 || profiles > 0 ? "（ターゲット \(targets)・プロファイル \(profiles) を含む）" : "") + " · " + (app.team?.name ?? ""),
                                     deletedAt: app.deletedAt!) {
                                perform { _ in try VaultManagement(vault: vault).restore(app) }
                            }
                        }
                        ForEach(deletedRecords) { record in
                            trashRow(record.name, detail: record.fileTypeTitle + " · " + (record.isTeamShared ? "チーム共通" : record.app?.name ?? ""),
                                     deletedAt: record.deletedAt!, disabled: record.app?.deletedAt != nil) {
                                perform { _ in try VaultManagement(vault: vault).restore(record) }
                            }
                        }
                    }.overlay(alignment: .bottom) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
                }
                Text("完全に削除するときは Touch ID で確認します。作成済みのバックアップの中身は消えません。SSD 上の物理的な消去は保証しません。")
                    .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            }
            if let error { Text(error).foregroundStyle(AppMateStyle.dangerText) }
            Spacer(minLength: 0)
        }.font(.system(size: 13)).padding(.horizontal, 32).padding(.vertical, 22)
            .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text).disabled(access.busy)
            .confirmationDialog("すべて完全に削除しますか？元に戻せません。", isPresented: $purging, titleVisibility: .visible) {
                Button("認証して完全削除", role: .destructive) { perform { key in try VaultManagement(vault: vault).purge(records: deletedRecords, apps: deletedApps, key: key) } }
            }
            .onDisappear { access.lock() }
    }
    private func trashRow(_ name: String, detail: String, deletedAt: Date, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        let remaining = max(0, Int(ceil((deletedAt.addingTimeInterval(30 * 86400).timeIntervalSinceNow) / 86400)))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(AppMateStyle.tertiary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("あと \(remaining) 日").fontWeight(remaining <= 7 ? .semibold : .regular)
                .foregroundStyle(remaining <= 7 ? AppMateStyle.warningText : AppMateStyle.secondary).frame(width: 90, alignment: .leading)
            Button("元に戻す", action: action).buttonStyle(AppMateButtonStyle(compact: true)).disabled(disabled)
                .help(disabled ? "先に、所属するアプリを元に戻してください" : "")
        }.padding(.vertical, 10).frame(minHeight: 52)
            .overlay(alignment: .top) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
    }

    private func perform(_ operation: @escaping (SymmetricKey) throws -> Void) {
        Task { @MainActor in
            do {
                let create = try vault.canCreateKey()
                try await access.withKey(reason: "最近削除した項目を変更します", allowCreation: create, vault: vault) { key in try operation(key) }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}


struct TargetDeleteConfirmation: View {
    let target: ManagedApp
    let records: [StoredCredential]
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var targets: [ManagedApp] { target.parentAppID == nil ? target.targets : [target] }
    private var profiles: [StoredCredential] {
        records.filter { record in
            record.deletedAt == nil && !record.isTeamShared && targets.contains { record.app?.id == $0.id }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("「\(target.name)」と配下のプロファイルを削除しますか？").font(.headline)
            Text(target.parentAppID == nil ? "本体と配下の全ターゲット \(targets.count)件、プロファイル \(profiles.count)件が対象です。" : "ターゲット登録とプロファイル \(profiles.count)件が対象です。")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(targets) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).fontWeight(.semibold)
                            Text(item.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            ForEach(profiles.filter { $0.app?.id == item.id }) { record in
                                Text("・" + record.name).font(.caption)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            Text("「最近削除した項目」へまとめて移し、30日間はまとめて復元できます。チーム共有の鍵・証明書、元ファイル、Apple側の登録やCI設定は変更しません。")
                .foregroundStyle(.secondary)
            HStack {
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("認証してまとめて削除", role: .destructive, action: onDelete)
            }.buttonStyle(AppMateButtonStyle())
        }.font(.system(size: 13)).padding(24).frame(width: 500).background(AppMateStyle.canvas)
    }
}

struct CredentialDeleteConfirmation: View {
    let record: StoredCredential
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "trash").font(.system(size: 24)).foregroundStyle(AppMateStyle.dangerText)
                .frame(width: 48, height: 48).background(AppMateStyle.dangerBackground, in: RoundedRectangle(cornerRadius: 12))
            Text("「\(record.name)」を\(record.isTeamShared ? "チーム全体から" : "")削除しますか？")
                .font(.system(size: 17, weight: .bold))
            if ["p8", "p12"].contains(record.fileExtension) {
                Label(record.fileExtension == "p8" ? "鍵はAppleからもう一度ダウンロードできません。ほかに控えがなければ、鍵を作り直してCIの設定も更新する必要があります。" : "秘密鍵の控えがなければ、証明書の再発行とCI設定の更新が必要になる場合があります。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(AppMateStyle.dangerText).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppMateStyle.dangerBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
            if record.isTeamShared {
                Label("保管先：チーム「\(record.team?.name ?? "未設定")」。実際の利用アプリは記録していません。", systemImage: "person.2")
                    .font(.system(size: 13)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("\(record.isTeamShared ? "チームの鍵・証明書の一覧から外れます。" : "このプロファイルだけを削除し、アプリ・ターゲット登録は残します。")Apple側の鍵やCIの設定は変更しません。30日間は元に戻せます。")
                .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button("キャンセル") { dismiss() }.buttonStyle(AppMateButtonStyle()).keyboardShortcut(.cancelAction)
                Button(action: onDelete) { Label("認証して削除", systemImage: "touchid").padding(.horizontal, 14).frame(height: 34) }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(AppMateStyle.danger, in: RoundedRectangle(cornerRadius: 8))
            }.padding(.top, 4)
        }.padding(26).frame(width: 460).background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text)
    }
}

struct CredentialBatchDeleteConfirmation: View {
    let records: [StoredCredential]
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("選択した\(records.count)件を削除しますか？").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).fontWeight(.medium)
                            Text([record.team?.name, record.originalName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if record.isTeamShared {
                                Text("チーム「\(record.team?.name ?? "未設定")」の鍵・証明書の一覧から外れます。")
                                    .font(.caption).foregroundStyle(AppMateStyle.dangerText)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            if records.contains(where: { ["p8", "p12"].contains($0.fileExtension) }) {
                Label("鍵を再取得できない場合があります。ほかに控えがあることを確認してください。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppMateStyle.dangerText)
            }
            if records.contains(where: { $0.app != nil }) {
                Text("ファイルだけを削除し、アプリ・ターゲット登録は残します。")
            }
            Text("「最近削除した項目」へ移し、30日間は復元できます。元ファイル・Apple側の鍵・CIの設定は変更しません。")
                .foregroundStyle(.secondary)
            HStack {
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("認証して\(records.count)件を削除", role: .destructive, action: onDelete)
            }.buttonStyle(AppMateButtonStyle())
        }.font(.system(size: 13)).padding(24).frame(width: 500).background(AppMateStyle.canvas)
    }
}

struct P8PurposeToggles: View {
    @Binding var purposes: Set<P8Purpose>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(P8Purpose.allCases, id: \.self) { item in
                let on = purposes.contains(item)
                Button {
                    // App Store Connect keys are issued separately and never carry Developer key services.
                    if on { purposes.remove(item) }
                    else if item == .appStoreConnect { purposes = [item] }
                    else { purposes.remove(.appStoreConnect); purposes.insert(item) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 17)).foregroundStyle(item.tint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.shortTitle).fontWeight(.semibold)
                            Text(item == .appStoreConnect ? "単独でのみ選べます" : item.title).font(.system(size: 11)).foregroundStyle(AppMateStyle.secondary)
                        }
                        Spacer(minLength: 0)
                        if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppMateStyle.accent) }
                    }.padding(.horizontal, 12).frame(height: 56).contentShape(Rectangle())
                        .background(on ? AppMateStyle.selectedRow : AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? AppMateStyle.accent : AppMateStyle.border, lineWidth: on ? 1.5 : 1))
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.title).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// Online only on request: reads the key's enabled services, never the private key.
struct P8PurposeFetchButton: View {
    let keyID: String
    let teamID: String
    var session: AppleDeveloperSession = .shared
    @Binding var purposes: Set<P8Purpose>
    @State private var fetching = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    private var value: String { keyID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Apple Developerから用途を取得", systemImage: "icloud.and.arrow.down", action: fetch)
                .disabled(fetching || value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) == nil)
            if fetching { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(AppMateStyle.secondary).fixedSize(horizontal: false, vertical: true) }
        }.onDisappear { work?.cancel() }
    }

    private func fetch() {
        let keyID = value
        fetching = true
        message = nil
        work = Task { @MainActor in
            defer { fetching = false }
            do {
                let key = try await session.key(keyID: keyID, teamID: teamID)
                guard !Task.isCancelled else { return }
                if let key {
                    purposes = Set(key.purposes)
                    message = "Apple Developerの鍵「\(key.name)」の有効なサービスから用途を設定しました。"
                } else {
                    message = "Apple Developerの鍵一覧にこのKey IDは見つかりませんでした。App Store Connect APIの鍵の場合は手動で選んでください。"
                }
            } catch { if !Task.isCancelled { message = AppleDeveloperError.message(for: error) } }
        }
    }
}

struct P8PurposeEditor: View {
    let vault: CredentialVault
    let record: StoredCredential
    var session: AppleDeveloperSession = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var access = VaultAccess()
    @State private var purposes: Set<P8Purpose> = []
    @State private var issuerID = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用途を変更").font(.title2.bold())
            Text("\(record.name) · Key ID \(record.keyID ?? "未設定")").foregroundStyle(AppMateStyle.secondary).textSelection(.enabled)
            P8PurposeToggles(purposes: $purposes)
            if let keyID = record.keyID, let teamID = record.team?.teamID {
                P8PurposeFetchButton(keyID: keyID, teamID: teamID, session: session, purposes: $purposes)
            }
            if purposes.contains(.appStoreConnect) {
                TextField("App Store ConnectのIssuer ID", text: $issuerID).textFieldStyle(.roundedBorder)
            }
            Text("登録名も用途に合わせて変わります。保存時にMacで認証し、暗号化し直します。元ファイルは変わりません。")
                .font(.caption).foregroundStyle(AppMateStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if access.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("認証して保存", action: save).keyboardShortcut(.defaultAction).disabled(access.busy || purposes.isEmpty)
            }
        }
        .padding(24).frame(width: 520).font(.system(size: 13))
        .buttonStyle(AppMateButtonStyle()).background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text)
        .interactiveDismissDisabled(access.busy)
        .onAppear {
            purposes = Set(record.keyPurpose.flatMap(P8Purpose.purposes(stored:)) ?? [])
            issuerID = record.issuerID ?? ""
        }
        .onDisappear { access.lock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in access.lock(); dismiss() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in access.lock(); dismiss() }
    }

    private func save() {
        let metadata = P8Metadata(purposes: Array(purposes), keyID: record.keyID ?? "", issuerID: issuerID)
        error = nil
        Task { @MainActor in
            do {
                try await access.withKey(reason: "鍵の用途を変更します", allowCreation: false, vault: vault) { key in
                    try VaultManagement(vault: vault).updatePurposes(record, metadata: metadata, key: key)
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
