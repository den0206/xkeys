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
    @State private var restoring = false
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

    init(container: ModelContainer, onSafetyBackup: ((SafetyBackup) -> Void)? = nil, restoring: Bool = false) {
        self.container = container
        self.onSafetyBackup = onSafetyBackup
        _restoring = State(initialValue: restoring)
    }

    private var vault: CredentialVault {
        CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory))
    }
    private var history: BackupHistorySummary { BackupHistorySummary(changes: changes, checkpoint: checkpoints.first, hasStoredItems: !apps.isEmpty || !credentials.isEmpty) }
    private var canSave: Bool {
        !working && (!selectedOnly || !selectedApps.isEmpty) && (!protected || (password.count >= 6 && password.utf8.count <= 1024 && password == confirmation))
    }
    @State private var showingPassword = false
    private var passwordStatus: String {
        if password.count < 6 { return String(localized: "6文字以上にしてください") }
        if password != confirmation { return confirmation.isEmpty ? String(localized: "確認のため、もう一度入力してください") : String(localized: "2つが一致していません") }
        return (password.count >= 20 ? String(localized: "長いパスワードです") : String(localized: "さらに長くすると強くなります")) + String(localized: " · 2つが一致しています")
    }

    private func passwordField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Group {
                if showingPassword { TextField(prompt, text: text) } else { SecureField(prompt, text: text) }
            }.textFieldStyle(.plain)
            Button { showingPassword.toggle() } label: { Image(systemName: showingPassword ? "eye.slash" : "eye") }
                .buttonStyle(.plain).foregroundStyle(XkeysStyle.secondary)
                .help(showingPassword ? "パスワードを隠す" : "パスワードを表示")
                .accessibilityLabel(showingPassword ? "パスワードを隠す" : "パスワードを表示")
        }.padding(.horizontal, 10).frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(XkeysStyle.border))
    }

    var body: some View {
        if restoring {
            RestoreView(container: container, onCreate: { restoring = false })
        } else { creation }
    }

    private var creation: some View {
        VStack(alignment: .leading, spacing: 18) {
            if onSafetyBackup == nil {
                BackupTabs(creating: true) { restoring = true }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(onSafetyBackup == nil ? "すべてのデータを1つのファイルに保存します" : "今のデータを先に保存します").font(.system(size: 18, weight: .bold))
                Text("Mac の故障や買い替えのときに、このファイルから元に戻せます。保存先はご自身で選んで保管してください。")
                    .foregroundStyle(XkeysStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if completed {
                Label("バックアップを保存しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(XkeysStyle.successText).font(.headline)
                Text("保存したファイルを読み戻して、中身が一致することを確認しました。").foregroundStyle(XkeysStyle.successText)
                if trackingWarning {
                    Text("バックアップは保存しましたが、変更状態を更新できませんでした。未バックアップの表示を残しています。")
                        .foregroundStyle(XkeysStyle.warningText)
                } else if history.needsBackup {
                    Text("バックアップが必要な変更があります。作成開始後の変更は今回の保存には含まれません。")
                        .foregroundStyle(XkeysStyle.secondary)
                }
                Text("このファイルには秘密鍵・保存済みパスワード・任意Secretが含まれます。外付けドライブなど、安全な場所に保管してください。")
                    .foregroundStyle(XkeysStyle.secondary)
                HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(XkeysButtonStyle(primary: true)) }
            } else {
                if history.needsBackup {
                    HStack(spacing: 10) {
                        Circle().fill(Color(red: 0.96, green: 0.62, blue: 0.04)).frame(width: 8, height: 8)
                        Text("バックアップが必要です")
                    }.padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(XkeysStyle.warningText)
                        .background(XkeysStyle.warningBanner, in: RoundedRectangle(cornerRadius: 10))
                }
                if protected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("パスワードで守る").font(.system(size: 12, weight: .bold)).foregroundStyle(XkeysStyle.text.opacity(0.75))
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow { Text("パスワード").frame(width: 100, alignment: .leading); passwordField(String(localized: "6文字以上"), text: $password) }
                            GridRow { Text("もう一度"); passwordField(String(localized: "確認用パスワード"), text: $confirmation) }
                            GridRow {
                                Color.clear.frame(width: 1, height: 1)
                                Text(passwordStatus).font(.system(size: 12))
                                    .foregroundStyle(canSave ? XkeysStyle.successText : XkeysStyle.secondary)
                            }
                        }
                        (Text("このパスワードは保存しません。") + Text("忘れると戻せなくなる").foregroundStyle(XkeysStyle.dangerText).fontWeight(.semibold)
                         + Text("ので、パスワード管理アプリなどに控えてください。Mac のログインパスワードとは別にしてください。"))
                            .font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("暗号化されません。ファイルを持つ人は秘密鍵・保存済みパスワード・任意Secretを取り出せます。作成前に再確認します。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(XkeysStyle.warningText)
                }
                DisclosureGroup("そのほかの設定") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("対象").font(.system(size: 12, weight: .bold))
                            if onSafetyBackup == nil {
                                Picker("対象", selection: $selectedOnly) {
                                    Text("すべて（アプリ \(apps.filter { $0.parentAppID == nil }.count) · 鍵とファイル \(credentials.count) · 設定）").tag(false)
                                    Text("特定のアプリだけ").tag(true)
                                }.pickerStyle(.radioGroup).labelsHidden()
                            } else { Text("すべて（チーム \(teams.count) · アプリ \(apps.filter { $0.parentAppID == nil }.count) · 鍵とファイル \(credentials.count)）") }
                            if selectedOnly {
                                ScrollView {
                                    VStack(alignment: .leading) {
                                        ForEach(apps.filter { $0.parentAppID == nil }) { app in
                                            Toggle(app.name, isOn: Binding(get: { selectedApps.contains(app.id) }, set: { if $0 { selectedApps.insert(app.id) } else { selectedApps.remove(app.id) } }))
                                        }
                                    }
                                }.frame(maxHeight: 100)
                                Text("配下の全ターゲット・必要なチームと共通の鍵・証明書も含めます。全体の「バックアップが必要」の表示は解除しません。").font(.caption)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("保護").font(.system(size: 12, weight: .bold))
                            Picker("保護", selection: $protected) {
                                Text("パスワードで保護する（おすすめ）").tag(true)
                                Text("パスワードなし").tag(false)
                            }.pickerStyle(.radioGroup).labelsHidden()
                        }
                    }.padding(.top, 8).padding(.leading, 14)
                }.font(.system(size: 12)).foregroundStyle(XkeysStyle.text.opacity(0.8))
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Divider()
                HStack(spacing: 10) {
                    if working { ProgressView().controlSize(.small); Text("認証・バックアップ作成中…").foregroundStyle(.secondary) }
                    Spacer()
                    Button("キャンセル") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存先を選んで作る…") {
                        if protected { save() } else { confirmUnprotected = true }
                    }.buttonStyle(XkeysButtonStyle(primary: true)).disabled(!canSave)
                }
            }
        }
        .font(.system(size: 13)).buttonStyle(XkeysButtonStyle())
        .padding(.horizontal, 26).padding(.vertical, 22).frame(width: 600)
        .background(XkeysStyle.canvas).foregroundStyle(XkeysStyle.text).tint(XkeysStyle.accent)
        .disabled(working)
        .interactiveDismissDisabled(working)
        .confirmationDialog("暗号化せずに作成しますか？", isPresented: $confirmUnprotected, titleVisibility: .visible) {
            Button("保護なしで作成…", role: .destructive) { save() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ファイルを持つ人は秘密鍵・保存済み.p12パスワード・任意Secretを取り出せます。安全な保存先を選んでください。")
        }
        .onChange(of: protected) { _, _ in password = ""; confirmation = ""; error = nil }
        .onDisappear { cancel() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in cancel(); dismiss() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in cancel(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !working && !access.presentingPanel { password = ""; confirmation = ""; showingPassword = false }
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
        panel.nameFieldStringValue = "Xkeys_\(date.string(from: .now)).xkeysbackup"
        panel.message = String(localized: "新しいファイルとして保存します。既存のファイルは上書きしません。")
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
                let (snapshot, watermark) = try await access.withKey(reason: String(localized: "すべての資格情報をバックアップします"), allowCreation: canCreate, vault: vault) { key in
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

/// The two tabs at the top of the backup sheet.
struct BackupTabs: View {
    let creating: Bool
    let switchTab: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            tab(String(localized: "バックアップを作る"), selected: creating)
            tab(String(localized: "バックアップから戻す"), selected: !creating)
        }.padding(3).background(XkeysStyle.search, in: RoundedRectangle(cornerRadius: 10))
    }

    private func tab(_ title: String, selected: Bool) -> some View {
        Button { if !selected { switchTab() } } label: {
            Text(title).fontWeight(selected ? .bold : .regular).frame(maxWidth: .infinity).frame(height: 28)
                .foregroundStyle(selected ? XkeysStyle.text : XkeysStyle.secondary)
                .background(selected ? XkeysStyle.canvas : .clear, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: selected ? .black.opacity(0.1) : .clear, radius: 1, y: 1)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
