import AppKit
import SwiftData
import SwiftUI

struct BackupView: View {
    let container: ModelContainer
    var onSafetyBackup: ((SafetyBackup) -> Void)? = nil
    @Query private var teams: [DeveloperTeam]
    @Query private var apps: [ManagedApp]
    @Query private var credentials: [StoredCredential]
    @Query private var changes: [BackupChange]
    @Query private var checkpoints: [BackupCheckpoint]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOnly = false
    @State private var selectedApps: Set<UUID> = []
    @State private var protected = true
    @State private var password = ""
    @State private var confirmation = ""
    @State private var confirmUnprotected = false
    @State private var working = false
    @State private var error: String?
    @State private var completed = false
    @State private var trackingWarning = false
    @State private var access = VaultAccess()
    @State private var work: Task<Void, Never>?

    private var vault: CredentialVault {
        CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))
    }
    private var history: BackupHistorySummary { BackupHistorySummary(changes: changes, checkpoint: checkpoints.first) }
    private var canSave: Bool {
        !working && (!selectedOnly || !selectedApps.isEmpty) && (!protected || (password.count >= 12 && password.utf8.count <= 1024 && password == confirmation))
    }
    private var strength: String {
        if password.count < 12 { return "12文字以上にしてください" }
        return password.count >= 20 ? "長いパスワードです" : "さらに長くすると強くなります"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("バックアップを作る").font(.title2.bold())
            Text("すべてのデータを1つのファイルにまとめます。保存先を選んで、ご自身で保管してください。")
                .foregroundStyle(.secondary)
            if completed {
                Label("バックアップを保存しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                Text("保存したファイルを読み戻し、内容の一致を確認しました。")
                if trackingWarning {
                    Text("バックアップは保存しましたが、変更状態を更新できませんでした。未バックアップの表示を残しています。")
                        .foregroundStyle(.orange)
                } else if history.pendingCount > 0 {
                    Text("未バックアップの変更が\(history.pendingCount)件あります。作成開始後の変更は今回の保存には含まれません。")
                        .foregroundStyle(.secondary)
                }
                Text("バックアップには秘密鍵や保存済みのパスワードが含まれます。安全な場所で管理してください。")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 20) {
                    GridRow {
                        Text("対象").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("すべて（チーム \(teams.count) · アプリ \(apps.count) · 鍵とファイル \(credentials.count)）")
                            if onSafetyBackup == nil {
                                Toggle("Appを選んでエクスポート", isOn: $selectedOnly)
                                if selectedOnly {
                                    ScrollView {
                                        ForEach(apps) { app in
                                            Toggle(app.name, isOn: Binding(get: { selectedApps.contains(app.id) }, set: { if $0 { selectedApps.insert(app.id) } else { selectedApps.remove(app.id) } }))
                                        }
                                    }.frame(maxHeight: 100)
                                    Text("必要なTeamと共有資格情報を含めます。全体の未バックアップ件数は解除しません。").font(.caption)
                                }
                            }
                            Text("元ファイル・メモ・設定・削除状態・保存済み.p12パスワード・置き換え履歴を含みます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("保護").foregroundStyle(.secondary)
                        Picker("保護", selection: $protected) {
                            Text("パスワードで保護する（推奨）").tag(true)
                            Text("パスワードなし").tag(false)
                        }.pickerStyle(.radioGroup).labelsHidden()
                    }
                    if protected {
                        GridRow { Text("パスワード"); SecureField("バックアップ用パスワード", text: $password) }
                        GridRow { Text("もう一度入力"); SecureField("確認用パスワード", text: $confirmation) }
                        GridRow {
                            Text("強さ").foregroundStyle(.secondary)
                            Text(strength).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
                if protected {
                    Text("Macのログインパスワードとは別の値を12文字以上で指定してください。忘れると復元できません。App Mateはバックアップ用パスワードを保存しません。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Label("暗号化されません。ファイルを持つ人は秘密鍵・保存済みパスワードを取り出せます。作成前に再確認します。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let date = history.lastCompletedAt {
                    Text("前回のバックアップ：\(date.formatted()) · 未バックアップの変更 \(history.pendingCount)件")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !checkpoints.isEmpty {
                    Text("バックアップの記録なし · 未バックアップの変更 \(history.pendingCount)件")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("変更状態は作成前に確認します。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if working { ProgressView().controlSize(.small); Text("認証・バックアップ作成中…").foregroundStyle(.secondary) }
                    Spacer()
                    Button("キャンセル") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存先を選んで作成…") {
                        if protected { save() } else { confirmUnprotected = true }
                    }.buttonStyle(.borderedProminent).disabled(!canSave)
                }
            }
        }
        .padding(28).frame(width: 620)
        .disabled(working)
        .interactiveDismissDisabled(working)
        .confirmationDialog("暗号化せずに作成しますか？", isPresented: $confirmUnprotected, titleVisibility: .visible) {
            Button("保護なしで作成…", role: .destructive) { save() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ファイルを持つ人は秘密鍵や保存済み.p12パスワードを取り出せます。安全な保存先を選んでください。")
        }
        .onChange(of: protected) { _, _ in password = ""; confirmation = ""; error = nil }
        .onDisappear { cancel() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in cancel(); dismiss() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in cancel(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !working && !access.presentingPanel { password = ""; confirmation = "" }
        }
    }

    private func cancel() {
        access.lock()
        work?.cancel()
        password = ""
        confirmation = ""
    }

    private func save() {
        guard canSave else { return }
        access.presentingPanel = true
        let panel = NSSavePanel()
        let date = DateFormatter()
        date.dateFormat = "yyyyMMdd_HHmmss"
        date.locale = Locale(identifier: "en_US_POSIX")
        panel.nameFieldStringValue = "AppMate_\(date.string(from: .now)).appmatebackup"
        panel.message = "新しいファイルとして保存します。既存のファイルは上書きしません。"
        let response = panel.runModal()
        access.presentingPanel = false
        guard response == .OK, let destination = panel.url else { return }
        let secret = protected ? password : nil
        password = ""
        confirmation = ""
        working = true
        error = nil
        let generation = access.generation
        work = Task { @MainActor in
            defer { working = false; work = nil }
            do {
                let canCreate = try vault.canCreateKey()
                let (snapshot, watermark) = try await access.withKey(reason: "すべての資格情報をバックアップします", allowCreation: canCreate, vault: vault) { key in
                    try BackupHistory.bootstrap(in: vault.context)
                    let full = try BackupSnapshot.capture(vault: vault, key: key)
                    let snapshot = selectedOnly ? try full.selecting(appIDs: selectedApps) : full
                    return (snapshot, try BackupHistory.watermark(in: vault.context, capturedAt: snapshot.createdAt))
                }
                // No plaintext temporary file: derivation and verification use memory only.
                let archive = try await Task.detached(priority: .userInitiated) {
                    let bytes = try BackupArchive.encode(snapshot, password: secret)
                    _ = try BackupArchive.decode(bytes, password: secret)
                    return bytes
                }.value
                guard !Task.isCancelled, access.generation == generation else { throw VaultError.cancelled }
                if let onSafetyBackup {
                    let proof = try SafetyBackup.export(archive, password: secret, snapshot: snapshot, to: destination)
                    onSafetyBackup(proof)
                    dismiss()
                } else if selectedOnly {
                    try CredentialFile(data: archive, name: destination.lastPathComponent).export(to: destination)
                } else {
                    trackingWarning = try !BackupHistory.export(archive, to: destination, covering: watermark, in: vault.context)
                }
                completed = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
