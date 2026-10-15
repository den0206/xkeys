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
    @State private var platform = "iOS"
    @State private var error: String?
    @State private var deleting = false
    @State private var access = VaultAccess()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app == nil ? "Teamを編集" : "Appを編集").font(.title2.bold())
            TextField("表示名", text: $name)
            Text(app?.bundleID ?? team?.teamID ?? "").font(.body.monospaced()).textSelection(.enabled)
            Text("識別子と所属Teamは資格情報との関連を保つため固定です。別の識別子は新規登録してください。")
                .font(.caption).foregroundStyle(.secondary)
            if app != nil { Picker("プラットフォーム", selection: $platform) { ForEach(AppCatalog.platforms, id: \.self) { Text($0).tag($0) } } }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("削除…", role: .destructive) { deleting = true }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { throw RegistrationError.nameRequired }
                        try VaultManagement(vault: vault).change {
                            if let app { app.name = value; app.platform = platform }
                            else { team?.name = value }
                        }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(access.busy)
            }
        }.padding(24).frame(width: 490)
            .onAppear { name = app?.name ?? team?.name ?? ""; platform = app?.platform ?? "iOS" }
            .confirmationDialog(app == nil ? "空のTeamを削除しますか？" : "Appと専用ファイルを最近削除した項目へ移しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("認証して削除", role: .destructive) {
                    Task { @MainActor in
                        do {
                            let create = try vault.canCreateKey()
                            try await access.withKey(reason: "登録を削除します", allowCreation: create, vault: vault) { key in
                                if let app { try VaultManagement(vault: vault).trash(app, key: key) }
                                else if let team { try VaultManagement(vault: vault).removeTeam(team) }
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("Appの共有鍵・証明書は残します。Appは30日間復元できます。TeamはAppや資格情報が残っていれば削除できません。") }
            .onDisappear { access.lock() }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("最近削除した項目").font(.title.bold())
            Text("30日間復元できます。30日経過後は次回起動・認証時に完全削除します。既存のバックアップは残り、SSD上の物理消去は保証しません。")
                .foregroundStyle(.secondary)
            if deletedApps.isEmpty && deletedRecords.isEmpty { ContentUnavailableView("削除した項目はありません", systemImage: "trash") }
            else {
                List {
                    Section("App") {
                        ForEach(deletedApps) { app in
                            HStack {
                                VStack(alignment: .leading) { Text(app.name); Text(app.deletedAt!.formatted()).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("復元") { perform { _ in try VaultManagement(vault: vault).restore(app) } }
                            }
                        }
                    }
                    Section("鍵とファイル") {
                        ForEach(deletedRecords) { record in
                            HStack {
                                VStack(alignment: .leading) { Text(record.name); Text(record.originalName).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("復元") { perform { _ in try VaultManagement(vault: vault).restore(record) } }.disabled(record.app?.deletedAt != nil)
                            }
                        }
                    }
                }
                Button("すべて完全に削除…", role: .destructive) { purging = true }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(24).disabled(access.busy)
            .confirmationDialog("すべて完全に削除しますか？元に戻せません。", isPresented: $purging, titleVisibility: .visible) {
                Button("認証して完全削除", role: .destructive) { perform { key in try VaultManagement(vault: vault).purge(records: deletedRecords, apps: deletedApps, key: key) } }
            }
            .onDisappear { access.lock() }
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
