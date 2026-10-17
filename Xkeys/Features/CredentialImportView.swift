import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
        if finished { return String(localized: "ファイルの追加が終わりました") }
        if readyToCommit { return String(localized: "\(pending.count)件の確認が終わりました") }
        if file == nil { return currentName.isEmpty ? String(localized: "ファイルを追加") : String(localized: "読み取っています…") }
        if needsPassword { return String(localized: ".p12 のパスワードを入力してください") }
        if isP8 { return String(localized: "この鍵の用途を選んでください") }
        if unregisteredBundle != nil { return String(localized: "どのアプリのプロファイルですか？") }
        return String(localized: "内容を確認してください")
    }

    private var subheadline: String {
        if finished { return String(localized: "元のファイルは変更していません。") }
        if readyToCommit { return String(localized: "Touch ID で確認すると、まとめて暗号化して保存します。") }
        if needsPassword { return String(localized: ".p12 を書き出したときに決めたパスワードです。設定していない場合は空欄のまま「読み取る」を押します。") }
        if isP8 { return String(localized: ".p8 のファイルには用途が書かれていません。Apple Developer の鍵のページにある「Enabled Services」と同じものを選びます。") }
        return String(localized: "追加先：\(team.name)")
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
    private var matchingP12Names: [String] {
        guard let parsed, let fingerprints = parsed.p12CertificateFingerprints else { return [] }
        let saved = (try? vault.matchingP12Certificates(parsed, team: team)) ?? []
        let queued = pending.filter { $0.parsed.p12CertificateFingerprints == fingerprints }
        return Array(Set(saved.map(\.originalName) + queued.map { $0.file.name })).sorted()
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
                Text(subheadline).foregroundStyle(XkeysStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if finished {
                        Label("処理済み \(completedItems.count)件", systemImage: "checkmark.circle")
                            .font(.headline).foregroundStyle(XkeysStyle.accent)
                        ForEach(Array(completedItems.enumerated()), id: \.offset) { _, result in
                            Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if file == nil && !readyToCommit && currentName.isEmpty {
                    Button(action: chooseFile) {
                        VStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 24))
                            Text("ファイル・フォルダを選ぶ…").fontWeight(.medium)
                            Text("ここにドロップして追加できます").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                        }.frame(maxWidth: .infinity).padding(18)
                            .background(XkeysStyle.selectedRow, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(XkeysStyle.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    }.buttonStyle(.plain).foregroundStyle(XkeysStyle.accent)
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
                                }.buttonStyle(.plain).foregroundStyle(XkeysStyle.secondary)
                                    .help(showingPassword ? "パスワードを隠す" : "パスワードを表示")
                                    .accessibilityLabel(showingPassword ? "パスワードを隠す" : "パスワードを表示")
                            }.padding(.leading, 10).padding(.trailing, 4).frame(width: 320, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(error == nil ? XkeysStyle.accent : XkeysStyle.danger, lineWidth: 1.5))
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
                                    .font(.caption).foregroundStyle(XkeysStyle.secondary)
                                Button(app == nil ? "このBundle IDのアプリを登録…" : "このアプリにターゲットを追加…") { addingTarget = true }
                            }
                        }
                        if isP8 {
                            Text("用途（複数選べます）").font(.system(size: 12, weight: .semibold)).foregroundStyle(XkeysStyle.text.opacity(0.75))
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
                        LabeledContent("期限", value: parsed.expiresAt?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "期限なし"))
                        LabeledContent("取得したTeam ID", value: parsed.isIntermediateCA ? String(localized: "対象外（中間CA証明書）") : parsed.teamID ?? String(localized: "未取得"))
                        if let bundle = parsed.bundleID { LabeledContent("Bundle ID", value: bundle) }
                        if let fingerprint = parsed.fingerprint { Text("SHA-256：\(fingerprint)").font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                        if !isP8 && !parsed.isIntermediateCA && parsed.teamID == nil {
                            Toggle("Team IDを判別できないため、\(team.name)に割り当てることを確認しました", isOn: $confirmUnknownTeam)
                        }
                        let isP12 = (file?.name as NSString?)?.pathExtension.lowercased() == "p12"
                        Text(parsed.isIntermediateCA ? "中間CA証明書には個人のTeam IDはありません。選択中のTeamを保管先として保存します。" : parsed.bundleID == nil ? "チーム「\(team.name)」の鍵・証明書の一覧に保管します。" : "「\(importApp?.name ?? String(localized: "未選択"))」専用のプロファイルとして保存します。")
                        if isP12 {
                            if !matchingP12Names.isEmpty {
                                Label(String(localized: "同じ証明書構成の.p12が登録済み、または追加待ちです：\(matchingP12Names.joined(separator: "、"))"),
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text("パスワードやファイル名が違っても重複することがあります。秘密鍵の一致は未確認です。既存の項目を確認し、不要ならこのファイルを飛ばしてください。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
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
                        Button("このファイルを飛ばす") { completedItems.append(String(localized: "スキップ：") + currentName + (error.map { " · " + $0 } ?? "")); next() }
                            .buttonStyle(.plain).foregroundStyle(XkeysStyle.secondary).disabled(access.busy)
                    }
                    if readyToCommit {
                        Button { commit() } label: { Label("Touch ID で \(pending.count)件を追加", systemImage: "touchid") }
                            .keyboardShortcut(.defaultAction).buttonStyle(XkeysButtonStyle(primary: true)).disabled(access.busy)
                    } else {
                        Button(action: confirmCurrent) {
                            if isLastItem { Label("Touch ID で \(pending.count + 1)件を追加", systemImage: "touchid") } else { Text("次へ") }
                        }.keyboardShortcut(.defaultAction).buttonStyle(XkeysButtonStyle(primary: true))
                            .disabled(reading || access.busy || parsed == nil || validationIssue != nil)
                    }
                } else {
                    Spacer()
                    Button("閉じる") { access.lock(); dismiss() }
                        .keyboardShortcut(.defaultAction).buttonStyle(XkeysButtonStyle(primary: true))
                }
            }.padding(.horizontal, 26).padding(.top, 14)
        }
        .padding(.bottom, 14).padding(.horizontal, 0).frame(width: showsQueue ? 860 : 680, height: 640)
        .font(.system(size: 13)).buttonStyle(XkeysButtonStyle()).background(XkeysStyle.canvas).tint(XkeysStyle.accent)
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
        guard inputPassword.utf8.count <= 4096 else { error = String(localized: "パスワードが長すぎます。"); passwordFocused = true; return }
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
                try await access.withKey(reason: String(localized: "\(items.count)件の資格情報を暗号化して保存します"), allowCreation: canCreate, vault: vault) { key in
                    for item in items {
                        do {
                            lastSavedID = try vault.importFile(item.file, parsed: item.parsed, app: item.app, team: team, password: item.password,
                                                               confirmUnknownTeam: item.confirmed, key: key, p8: item.p8)
                            completedItems.append(String(localized: "保存済み：") + item.file.name)
                        } catch {
                            completedItems.append(String(localized: "保存できませんでした：") + item.file.name + " · " + error.localizedDescription)
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
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(XkeysStyle.secondary).padding(.horizontal, 8).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(completedItems.enumerated()), id: \.offset) { _, item in
                        let saved = item.hasPrefix(String(localized: "保存済み："))
                        queueRow(item.split(maxSplits: 1, whereSeparator: { $0 == "：" || $0 == ":" }).last.map(String.init) ?? item,
                                 symbol: saved ? "checkmark.circle" : item.hasPrefix(String(localized: "スキップ：")) ? "minus.circle" : "exclamationmark.circle",
                                 tint: saved ? XkeysStyle.successText : item.hasPrefix(String(localized: "スキップ：")) ? XkeysStyle.tertiary : XkeysStyle.dangerText, current: false)
                    }
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, item in
                        queueRow(item.file.name, symbol: "checkmark.circle", tint: XkeysStyle.accent, current: false)
                    }
                    if !currentName.isEmpty { queueRow(currentName, symbol: "smallcircle.filled.circle", tint: XkeysStyle.accent, current: true) }
                    ForEach(Array(memoryQueue.enumerated()), id: \.offset) { _, item in queueRow(item.name, symbol: "circle", tint: XkeysStyle.tertiary, current: false) }
                    ForEach(queue, id: \.self) { url in queueRow(url.lastPathComponent, symbol: "circle", tint: XkeysStyle.tertiary, current: false) }
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 20).frame(width: 250).frame(maxHeight: .infinity, alignment: .top)
            .background(XkeysStyle.sidebar)
            .overlay(alignment: .trailing) { Rectangle().fill(XkeysStyle.rowBorder).frame(width: 1) }
    }

    private func queueRow(_ name: String, symbol: String, tint: Color, current: Bool) -> some View {
        let ext = (name as NSString).pathExtension.lowercased()
        let kind = ext == "p8" ? String(localized: "鍵（.p8）") : ["cer", "p12"].contains(ext) ? String(localized: "証明書") : String(localized: "プロファイル")
        return HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind).fontWeight(current ? .semibold : .regular)
                Text(name).font(.system(size: 11)).foregroundStyle(XkeysStyle.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? XkeysStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? XkeysStyle.selectionBorder : .clear))
            .accessibilityElement(children: .combine)
    }
}
