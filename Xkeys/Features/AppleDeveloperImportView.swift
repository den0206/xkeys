import AppKit
import SwiftUI

struct AppleDeveloperImportView: View {
    let team: DeveloperTeam
    let vault: CredentialVault
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session: AppleDeveloperSession
    @State private var kind: RemoteDeveloperFile.Kind = .certificates
    @State private var items: [RemoteDeveloperFile] = []
    @State private var selectedIDs: Set<String> = []
    @State private var files: [CredentialFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false
    @State private var showingLogin = false
    @State private var showingImport = false
    @State private var work: Task<Void, Never>?
    @State private var lastActivity = Date.now

    init(team: DeveloperTeam, vault: CredentialVault, session: AppleDeveloperSession = .shared,
         onSaved: @escaping (UUID) -> Void) {
        self.team = team
        self.vault = vault
        self.onSaved = onSaved
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apple Developerから取り込む").font(.title2.bold())
            Text("保管先：\(team.name)（\(team.teamID)）").textSelection(.enabled)
            Picker("種類", selection: $kind) {
                ForEach(RemoteDeveloperFile.Kind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(loading)
            HStack {
                Button("一覧を更新", action: load).disabled(loading)
                Button("ログインを確認・変更…") { showingLogin = true }.disabled(loading)
                Spacer()
                Text("選択 \(selectedIDs.count)件 / \(items.count)件").foregroundStyle(.secondary)
            }
            if loading { HStack { ProgressView().controlSize(.small); Text("Appleから取得しています…") } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        Toggle(isOn: Binding(get: { selectedIDs.contains(item.id) }, set: { selected in
                            if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                            lastActivity = .now
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).fontWeight(.medium)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                if let date = item.expiresAt {
                                    Text(String(localized: "期限：") + date.formatted(date: .numeric, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.toggleStyle(.checkbox).padding(10)
                            .background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if loaded && items.isEmpty { Text("取得できる\(kind.title)はありません。").foregroundStyle(.secondary).padding() }
                }
            }.disabled(loading)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Text("一度に200件・合計32MBまで。取得後に内容と所属を確認し、1件ずつ認証して保存します。ダウンロード済みの.p8や証明書の秘密鍵は取得できません。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("選択した項目を確認…", action: download)
                    .buttonStyle(XkeysButtonStyle(primary: true)).disabled(loading || selectedIDs.isEmpty || selectedIDs.count > 200)
            }
        }
        .padding(24).frame(width: 640, height: 520)
        .font(.system(size: 13)).buttonStyle(XkeysButtonStyle())
        .background(XkeysStyle.canvas).foregroundStyle(XkeysStyle.text)
        .sheet(isPresented: $showingLogin) {
            AppleDeveloperLoginView(onVerified: {
                guard session.teams.contains(where: { $0.teamID == team.teamID }) else { throw AppleDeveloperError.teamAccessRequired }
                load()
            }, session: session, verificationTitle: String(localized: "取り込み先チームへの所属を確認")).modelContainer(vault.context.container)
        }
        .sheet(isPresented: $showingImport, onDismiss: { files = []; lastActivity = .now }) {
            CredentialImportView(app: nil, team: team, vault: vault, initialFiles: files, onSaved: onSaved)
                .modelContainer(vault.context.container)
        }
        .task { load() }
        .onChange(of: kind) { _, _ in load() }
        .onDisappear { work?.cancel(); files = []; items = [] }
        .onChange(of: session.epoch) { _, _ in
            files = []; items = []; selectedIDs = []
            if showingImport { close() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in close() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in close() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !loading && !showingLogin && !showingImport && Date.now.timeIntervalSince(lastActivity) >= 300 { close() }
        }
    }

    private func close() {
        work?.cancel(); files = []; items = []; selectedIDs = []
        showingImport = false; showingLogin = false
        dismiss()
    }

    private func load() {
        work?.cancel(); items = []; selectedIDs = []; error = nil; loaded = false
        lastActivity = .now
        let kind = kind
        loading = true
        work = Task { @MainActor in
            defer { if !Task.isCancelled { loading = false } }
            do {
                let result = try await session.listFiles(teamID: team.teamID, kind: kind)
                try Task.checkCancellation()
                items = result; loaded = true; lastActivity = .now
            } catch {
                if !Task.isCancelled {
                    self.error = AppleDeveloperError.message(for: error)
                    if let failure = error as? AppleDeveloperError {
                        switch failure {
                        case .loginRequired, .teamAccessRequired: showingLogin = true
                        default: break
                        }
                    }
                }
            }
        }
    }

    private func download() {
        let selected = items.filter { selectedIDs.contains($0.id) }
        loading = true; error = nil; lastActivity = .now
        work = Task { @MainActor in
            defer { if !Task.isCancelled { loading = false } }
            do {
                let downloaded = try await session.download(selected, teamID: team.teamID)
                try Task.checkCancellation()
                files = downloaded; showingImport = true; lastActivity = .now
            } catch {
                if !Task.isCancelled {
                    self.error = AppleDeveloperError.message(for: error)
                    if let failure = error as? AppleDeveloperError {
                        switch failure {
                        case .loginRequired, .teamAccessRequired: showingLogin = true
                        default: break
                        }
                    }
                }
            }
        }
    }
}
