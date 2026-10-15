import AppKit
import CryptoKit
import LocalAuthentication
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct VerificationView: View {
    let container: ModelContainer
    @State private var authentication = OwnerAuthentication()
    @State private var candidates: [ParsedCredential] = []
    @State private var selectedCandidate = -1
    @State private var sourceFile: CredentialFile?
    @State private var operationID = UUID()

    private var parsed: ParsedCredential? {
        candidates.indices.contains(selectedCandidate) ? candidates[selectedCandidate] : nil
    }
    @State private var status = "検証する操作を選んでください。"
    @State private var error: String?
    @State private var password = ""
    @State private var busy = false
    @State private var recordCount = 0
    @State private var choosingFile = false

    private var store: EncryptedProbeStore {
        let base = URL.applicationSupportDirectory.appendingPathComponent("AppMatePrototype", isDirectory: true)
        return EncryptedProbeStore(directory: base.appendingPathComponent("blobs", isDirectory: true))
    }

    var body: some View {
        NavigationSplitView {
            List {
                Label("技術検証", systemImage: "checkmark.shield")
                Section("検証する内容") {
                    Label("プロファイル・証明書解析", systemImage: "doc.text.magnifyingglass")
                    Label("暗号化と再読み込み", systemImage: "lock.doc")
                    Label("認証と通知", systemImage: "person.badge.key")
                }
            }
            .navigationSplitViewColumnWidth(240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("App Mate の技術検証").font(.title.bold())
                    Text("テスト用の資格情報を使ってください。暗号化テストでは固定のサンプル文だけを保存します。")
                        .foregroundStyle(.secondary)
                    GroupBox("ファイルの解析") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button("サンプルプロファイルを解析", action: parseSample)
                                Button("テストファイルを選ぶ…", action: selectFile)
                            }
                            SecureField(".p12のパスワード（必要な場合のみ）", text: $password)
                                .textFieldStyle(.roundedBorder)
                            Text(".mobileprovision / .provisionprofile / .cer / .p12、16MB以下。元ファイルは変更しません。ここへ1ファイルをドロップできます。")
                                .font(.caption).foregroundStyle(.secondary)
                            if candidates.count > 1 {
                                Picker("表示する証明書", selection: $selectedCandidate) {
                                    Text("証明書を選択してください").tag(-1)
                                    ForEach(candidates.indices, id: \.self) { index in
                                        Text("\(candidates[index].name) — \(candidates[index].fingerprint?.prefix(12) ?? "")").tag(index)
                                    }
                                }
                                Text("候補の表示だけを切り替えます。書き出しは証明書チェーンと鍵を含む元ファイル全体です。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let parsed {
                                Divider()
                                LabeledContent("名前", value: parsed.name)
                                LabeledContent("種類", value: parsed.kind)
                                if let fingerprint = parsed.fingerprint {
                                    LabeledContent("SHA-256", value: fingerprint).textSelection(.enabled)
                                }
                                LabeledContent("Team ID", value: parsed.teamID ?? "未取得")
                                LabeledContent("Bundle ID", value: parsed.bundleID ?? "対象外")
                                LabeledContent("期限", value: parsed.expiresAt?.formatted(date: .abbreviated, time: .standard) ?? "期限なし")
                                Text("解析結果はローカルの内容です。Apple発行元の信頼性やオンラインの失効状態は確認していません。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("認証して元ファイル全体を書き出す…", action: exportFile)
                                .disabled(sourceFile == nil || parsed == nil)
                            Text("新しい名前で保存します。既存ファイルには上書きしません。元の.p12パスワードは変わりません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !busy, urls.count == 1, let url = urls.first else {
                            error = "一度に1ファイルを指定してください。"
                            return false
                        }
                        parseFile(url)
                        return true
                    }
                    GroupBox("認証・暗号化保存") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("保存済みの検証データ：\(recordCount)件")
                            HStack {
                                Button("認証してサンプルを保存") { performAuthenticated(save: true) }
                                Button("認証して再読み込み") { performAuthenticated(save: false) }
                                    .disabled(recordCount == 0)
                            }
                            Text("Touch ID またはMacのパスワードで確認します。再起動後も読み込めるかを確認してください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    GroupBox("ローカル通知") {
                        HStack {
                            Text("許可後、5秒後のテスト通知を1件予約します。")
                            Spacer()
                            Button("通知をテスト") { testNotification() }
                        }.padding(8)
                    }
                    if busy { ProgressView("確認しています…") }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                    Text(status).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(28)
                .disabled(busy)
            }
            .frame(minWidth: 650, minHeight: 600)
            .navigationTitle("App Mate")
            .toolbar {
                Button("ロック", systemImage: "lock") { lock() }
            }
        }
        .task { refreshAndRecover() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in lock() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !choosingFile { clearFile(); password = "" }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in lock() }
    }

    private func lock() {
        authentication.cancel()
        operationID = UUID()
        clearFile()
        password = ""
        status = "秘密表示と認証状態を閉じました。次の操作で再認証します。"
    }

    private func refreshAndRecover() {
        do {
            let context = ModelContext(container)
            let records = try context.fetch(FetchDescriptor<VerificationRecord>())
            try store.removeOrphans(keeping: Set(records.map(\.id)))
            recordCount = records.count
        } catch {
            self.error = "保存状態を確認できませんでした。\(error.localizedDescription)"
        }
    }

    private func parseSample() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "mobileprovision") else {
            error = "検証用サンプルが見つかりません。"
            return
        }
        parseFile(url)
    }

    private func selectFile() {
        choosingFile = true
        defer { choosingFile = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["mobileprovision", "provisionprofile", "cer", "p12"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parseFile(url)
    }

    private func clearFile() {
        operationID = UUID()
        candidates = []
        selectedCandidate = -1
        sourceFile = nil
    }

    private func parseFile(_ url: URL) {
        error = nil
        clearFile()
        let inputPassword = password
        password = ""
        let currentOperation = operationID
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let (file, results) = try await Task.detached(priority: .userInitiated) {
                    let file = try CredentialFile(url: url)
                    let results = try CredentialParser.parseAll(file.data, extension: url.pathExtension, password: inputPassword)
                    return (file, results)
                }.value
                guard currentOperation == operationID else { return }
                candidates = results
                sourceFile = file
                selectedCandidate = candidates.count == 1 ? 0 : -1
                status = "解析が完了しました。元ファイルは変更していません。"
            } catch {
                if currentOperation == operationID { self.error = error.localizedDescription }
            }
        }
    }

    private func exportFile() {
        guard let file = sourceFile, parsed != nil else { return }
        error = nil
        busy = true
        choosingFile = true
        let currentOperation = operationID
        Task { @MainActor in
            defer { busy = false; choosingFile = false; authentication.cancel(); clearFile(); password = "" }
            do {
                _ = try await authentication.authenticate(reason: "資格情報の元ファイル全体を書き出します")
                guard currentOperation == operationID else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "copy-" + file.name
                panel.message = "元ファイル全体を複製します。新しい名前を指定してください。既存ファイルへの上書きはできません。"
                guard panel.runModal() == .OK, let url = panel.url, currentOperation == operationID else { return }
                try file.export(to: url)
                status = "元ファイル全体を書き出しました。取り込み元は変更していません。"
            } catch { self.error = error.localizedDescription }
        }
    }

    private func performAuthenticated(save: Bool) {
        error = nil
        do { try EncryptionKeychain.requireSigning() }
        catch { self.error = error.localizedDescription; return }
        busy = true
        Task { @MainActor in
            defer { busy = false; authentication.cancel() }
            do {
                let context = try await authentication.authenticate(reason: "暗号化サンプルの保存・読み込みを確認します")
                let database = ModelContext(container)
                database.autosaveEnabled = false
                let records = try database.fetch(FetchDescriptor<VerificationRecord>()).sorted { $0.createdAt > $1.createdAt }
                let key = try EncryptionKeychain.verification.key(context: context, allowCreation: records.isEmpty)
                let sample = Data("App Mate の暗号化テスト。実際の秘密情報は含みません。".utf8)
                if save {
                    do {
                        try store.save(sample, key: key) { record in
                            database.insert(record)
                            try database.save()
                        }
                    } catch {
                        database.rollback()
                        throw error
                    }
                    status = "暗号化・読み戻し・メタデータ保存に成功しました。再起動して再読み込みを確認できます。"
                } else if let record = records.first {
                    let data = try store.read(record.id, key: key)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard data == sample, digest == record.digest else { throw ValidationError.invalidFile }
                    status = "保存済みサンプルの復号と一致確認に成功しました。"
                }
                refreshAndRecover()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func testNotification() {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let center = UNUserNotificationCenter.current()
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    status = "通知はオフです。Macのシステム設定でApp Mateの通知を許可してください。"
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "App Mate"
                content.body = "ローカル通知のテストです。"
                let request = UNNotificationRequest(identifier: "prototype-notification", content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
                try await center.add(request)
                status = "5秒後の通知を予約しました。アプリを背面にして配送を確認してください。"
            } catch { self.error = error.localizedDescription }
        }
    }
}
