import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RestoreView: View {
    let container: ModelContainer
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: CredentialFile?
    @State private var protected = false
    @State private var password = ""
    @State private var snapshot: BackupSnapshot?
    @State private var plan: RestorePlan?
    @State private var apple = AppleDeveloperSession.shared
    @State private var authorization = RestoreTeamAuthorization()
    @State private var verifyingTeams = false
    @State private var choices: [String: RestoreChoice] = [:]
    @State private var result: BackupRestore.Result?
    @State private var error: String?
    @State private var replaceAll = false
    @State private var makingSafetyBackup = false
    @State private var safetyBackup: SafetyBackup?
    @State private var working = false
    @State private var access = VaultAccess()
    @State private var work: Task<Void, Never>?
    @State private var lastActivity = Date.now
    @FocusState private var passwordFocused: Bool

    private var restore: BackupRestore {
        BackupRestore(vault: CredentialVault(context: container.mainContext, blobs: EncryptedBlobStore(directory: CredentialVault.directory)))
    }
    private var ready: Bool {
        guard let plan else { return false }
        guard plan.requiredTeamIDs.isEmpty || (try? authorization.validate(plan)) != nil else { return false }
        if replaceAll { return !working && (!plan.requiresSafetyBackup || safetyBackup?.revision == plan.localRevision) }
        return !working && plan.conflicts.allSatisfy { choices[$0.id] != nil } && (plan.addedCount > 0 || !plan.conflicts.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("バックアップ").font(.system(size: 18, weight: .bold))
                Spacer()
                HStack(spacing: 0) {
                    Button("作る", action: onCreate).buttonStyle(.plain).padding(.horizontal, 14).frame(height: 28)
                    Text("復元・移行").padding(.horizontal, 14).frame(height: 28).background(AppMateStyle.selection)
                }.font(.system(size: 12)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppMateStyle.border, lineWidth: 1))
            }
            if let result {
                Label("復元が完了しました", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Text("追加 \(result.added)件 · 更新 \(result.updated)件 · スキップ \(result.skipped)件")
                Text(replaceAll ? "バックアップの内容で全体を置き換えました。金庫鍵は維持しています。" : "既存のデータと金庫鍵を維持して、選んだ内容をまとめました。件数にはTeam・Appも含みます。")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("メイン画面へ") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file?.name ?? "バックアップファイルを選んでください").font(.headline).lineLimit(2)
                        if let snapshot {
                            Text("\(snapshot.createdAt.formatted())に作成").font(.caption).foregroundStyle(.secondary)
                            Label(protected ? "パスワード保護あり · 復号・整合性チェック済み" : "暗号化なし · 破損チェック済み", systemImage: protected ? "lock.shield" : "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(protected ? Color.secondary : .orange)
                            if !protected { Text("改ざんの有無は保証できません。").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Spacer()
                    Button(file == nil ? "ファイルを選ぶ…" : "別のファイル…", action: choose)
                }
                if file != nil && snapshot == nil && protected {
                    SecureField("バックアップ用パスワード", text: $password).focused($passwordFocused)
                        .onSubmit { unlock() }
                    Button("復号して確認", action: unlock).disabled(password.isEmpty)
                } else if file != nil && snapshot == nil {
                    Button("内容を確認", action: unlock)
                }
                if let plan {
                    Divider()
                    if !plan.requiredTeamIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("復元するチームへの所属確認").font(.headline)
                            ForEach(plan.incoming.teams.filter { plan.requiredTeamIDs.contains($0.teamID) }, id: \.teamID) { team in
                                let verified = (try? authorization.confirmedTeamIDs(for: plan).contains(team.teamID)) == true
                                Label("\(team.name)（\(team.teamID)） · \(verified ? "確認済み" : "要確認")",
                                      systemImage: verified ? "checkmark.circle" : "person.crop.circle.badge.questionmark")
                            }
                            Button("Apple Developerで所属を確認…") { verifyingTeams = true }
                            Text("未登録のすべてのチームへの所属確認が必要です。アカウントを切り替えて確認できます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("今のデータとの違い").font(.headline)
                    HStack(spacing: 28) {
                        count(plan.addedCount, title: "新しく追加")
                        count(plan.duplicateCount, title: "同じもの（スキップ）")
                        count(plan.conflicts.count, title: "内容が違う（選択が必要）")
                    }
                    Text("件数はTeam・App・資格情報の合計です。").font(.caption).foregroundStyle(.secondary)
                    if plan.addedCount == 0 && plan.conflicts.isEmpty {
                        Text("追加・変更する項目はありません。").foregroundStyle(.secondary)
                    }
                    if !plan.conflicts.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(plan.conflicts) { item in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.title).font(.headline)
                                        Text("異なる内容：" + item.detail).font(.caption).foregroundStyle(.secondary)
                                        Text("現在：" + (item.current ?? "")).font(.caption).textSelection(.enabled)
                                        Text("バックアップ：" + item.incoming).font(.caption).textSelection(.enabled)
                                        Picker("使う内容", selection: Binding<RestoreChoice?>(get: { choices[item.id] }, set: { choices[item.id] = $0 })) {
                                            Text("選択してください").tag(nil as RestoreChoice?)
                                            Text("今のまま").tag(Optional(RestoreChoice.current))
                                            Text("バックアップの内容").tag(Optional(RestoreChoice.backup))
                                        }.pickerStyle(.menu)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }.frame(maxHeight: 230)
                    }
                    DisclosureGroup("追加される項目") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(plan.items.filter { $0.state == .added }) { item in
                                    Text(item.title + " · " + item.incoming).font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("全体をバックアップの内容で置き換える", isOn: $replaceAll)
                        if replaceAll && plan.requiresSafetyBackup {
                            Text("バックアップに含まれない現在の項目は削除されます。まず現在の全データを別ファイルに退避してください。").foregroundStyle(.orange)
                            Button(safetyBackup == nil ? "現在のデータを退避する…" : "退避を作り直す…") { makingSafetyBackup = true }
                            if safetyBackup?.revision == plan.localRevision { Label("事前退避済み", systemImage: "checkmark.shield") }
                        }
                        if replaceAll && !plan.requiresSafetyBackup {
                            Text("現在のデータは空で、設定も初期値のため、事前退避なしで復元できます。")
                        }
                        Text("まとめる場合は現在の項目を残します。置き換える場合は、現在のデータや変更済みの設定があれば事前退避が必要です。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if working { ProgressView().controlSize(.small); Text("確認・認証中…").foregroundStyle(.secondary) }
                    else if snapshot != nil { Button("差分を更新") { refresh() } }
                    Spacer()
                    Button("キャンセル") { clear(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("認証して復元する", action: merge).buttonStyle(AppMateButtonStyle(primary: true)).disabled(!ready)
                }
            }
        }
        .font(.system(size: 13)).buttonStyle(AppMateButtonStyle())
        .padding(.horizontal, 26).padding(.vertical, 22).frame(width: 640)
        .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text).tint(AppMateStyle.accent)
        .disabled(working)
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $verifyingTeams) {
            AppleDeveloperLoginView(onVerified: {
                guard let plan else { throw RestoreError.stale }
                try apple.confirm(authorization, plan: plan)
                lastActivity = .now
            }).modelContainer(container)
        }
        .sheet(isPresented: $makingSafetyBackup) { BackupView(container: container, onSafetyBackup: { safetyBackup = $0 }) }
        .onDisappear { clear() }
        .onChange(of: password) { _, _ in lastActivity = .now }
        .onChange(of: choices) { _, _ in lastActivity = .now }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !working && result == nil && (file != nil || snapshot != nil) && Date.now.timeIntervalSince(lastActivity) >= 300 {
                clear(); error = "5分間操作がなかったため、読み込んだバックアップを閉じました。"
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in clear(); dismiss() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in clear(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !working && !access.presentingPanel && !makingSafetyBackup && !verifyingTeams && result == nil { clear() }
        }
    }

    private func count(_ value: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func clear() {
        authorization.clear()
        verifyingTeams = false
        access.lock()
        work?.cancel()
        password = ""
        snapshot = nil
        plan = nil
        file = nil
        choices = [:]
        safetyBackup = nil
        error = nil
    }

    private func choose() {
        access.presentingPanel = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let response = panel.runModal()
        access.presentingPanel = false
        guard response == .OK, let url = panel.url else { return }
        clear()
        working = true
        let generation = access.generation
        work = Task { @MainActor in
            defer { working = false; work = nil }
            do {
                let (loaded, needsPassword) = try await Task.detached(priority: .userInitiated) {
                    let file = try CredentialFile(url: url, maximumBytes: BackupArchive.maximumFileBytes)
                    return (file, try BackupArchive.requiresPassword(file.data))
                }.value
                guard generation == access.generation, !Task.isCancelled else { throw VaultError.cancelled }
                file = loaded
                protected = needsPassword
                lastActivity = .now
                if needsPassword { passwordFocused = true }
                else { try await prepare(loaded, password: nil, generation: generation) }
            } catch { if generation == access.generation { self.error = error.localizedDescription } }
        }
    }

    private func unlock() {
        guard !working, let file else { return }
        let secret = password
        password = ""
        error = nil
        working = true
        let generation = access.generation
        work = Task { @MainActor in
            defer { working = false; work = nil }
            do { try await prepare(file, password: secret, generation: generation) }
            catch { if generation == access.generation { self.error = error.localizedDescription; passwordFocused = true } }
        }
    }

    private func prepare(_ file: CredentialFile, password: String?, generation: UUID) async throws {
        let decoded = try await Task.detached(priority: .userInitiated) { try BackupArchive.decode(file.data, password: password) }.value
        guard access.generation == generation, !Task.isCancelled else { throw VaultError.cancelled }
        let canCreate = try restore.vault.canCreateKey()
        let prepared = try await access.withKey(reason: "バックアップと現在の資格情報を比較します", allowCreation: canCreate, vault: restore.vault) { key in
            try restore.prepare(decoded, key: key)
        }
        guard access.generation == generation, !Task.isCancelled else { throw VaultError.cancelled }
        snapshot = decoded
        authorization.clear()
        plan = prepared
        choices = [:]
        error = nil
        lastActivity = .now
    }

    private func refresh() {
        guard !working, let snapshot else { return }
        working = true
        error = nil
        let generation = access.generation
        work = Task { @MainActor in
            defer { working = false; work = nil }
            do {
                let canCreate = try restore.vault.canCreateKey()
                let refreshed = try await access.withKey(reason: "バックアップの復元差分を更新します", allowCreation: canCreate, vault: restore.vault) { key in
                    try restore.prepare(snapshot, key: key)
                }
                guard generation == access.generation, !Task.isCancelled else { throw VaultError.cancelled }
                authorization.clear()
                plan = refreshed; choices = [:]; lastActivity = .now
            } catch { if generation == access.generation { self.error = error.localizedDescription } }
        }
    }

    private func merge() {
        guard ready, let plan else { return }
        let selected = choices
        working = true
        error = nil
        let generation = access.generation
        work = Task { @MainActor in
            defer { working = false; work = nil }
            do {
                let canCreate = try restore.vault.canCreateKey()
                let merged = try await access.withKey(reason: "バックアップの選択した内容を復元します", allowCreation: canCreate, vault: restore.vault) { key in
                    try restore.merge(plan, choices: selected, authorization: authorization, key: key, safetyBackup: replaceAll ? safetyBackup : nil, replacingAll: replaceAll)
                }
                result = merged
                self.snapshot = nil; self.plan = nil; file = nil; choices = [:]
            } catch { if generation == access.generation { self.error = error.localizedDescription } }
        }
    }
}
