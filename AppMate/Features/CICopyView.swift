import AppKit
import SwiftUI

@MainActor enum SecretClipboard {
    static var cleanup: Task<Void, Never>?
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general) throws {
        cleanup?.cancel()
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        guard pasteboard.writeObjects([item]) else { throw ValidationError.invalidFile }
        let count = pasteboard.changeCount
        cleanup = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            clear(pasteboard, ifUnchanged: count)
        }
    }
    static func clear(_ pasteboard: NSPasteboard, ifUnchanged count: Int) {
        if pasteboard.changeCount == count { pasteboard.clearContents() }
    }
}

struct CICopyView: View {
    let vault: CredentialVault
    let record: StoredCredential
    @Environment(\.dismiss) private var dismiss
    @State private var access = VaultAccess()
    @State private var templates: [CITemplate] = []
    @State private var message: String?
    @State private var repository = "owner/repo"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CIに登録する値").font(.title2.bold())
            Text(record.originalName).font(.body.monospaced())
            Text("値は1項目ずつ認証してコピーします。60秒後、コピー内容が変わっていなければ消去します。ほかのアプリによる記録を完全には防げません。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("GitHubリポジトリ（owner/repo）", text: $repository)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(templates) { template in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading) { Text(template.variable).font(.body.monospaced()); Text(template.value.title + " · ••••••••").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("認証してコピー") { copy(template.value) }.disabled(!available(template.value) || access.busy)
                            }
                            if repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil {
                                Text("pbpaste | gh secret set \(template.variable) --repo '\(repository)'").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }.padding(12).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text("テンプレートの追加・変数名の編集は「設定 → CIテンプレート」で行えます。Bitriseへは元形式の書き出しを使ってください。")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption) }
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 660, height: 550)
            .task { do { templates = try PreferencesStore.read(in: vault.context).templates } catch { message = error.localizedDescription } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if !access.busy { access.lock(); dismiss() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in access.lock(); dismiss() }
            .onDisappear { access.lock() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in access.lock(); dismiss() }
    }
    private func available(_ value: CIValue) -> Bool {
        switch value {
        case .base64: ["p8", "p12"].contains(record.fileExtension)
        case .keyID: record.keyID != nil
        case .issuerID: record.issuerID != nil
        case .teamID: record.team != nil
        case .password: record.hasSavedPassword
        }
    }
    private func copy(_ value: CIValue) {
        Task { @MainActor in
            do {
                try await access.withKey(reason: "CIへ登録する値をコピーします", allowCreation: false, vault: vault) { key in
                    let payload = try vault.read(record, key: key)
                    let secret: String?
                    switch value {
                    case .base64: secret = payload.original.base64EncodedString()
                    case .keyID: secret = record.keyID
                    case .issuerID: secret = record.issuerID
                    case .teamID: secret = record.team?.teamID
                    case .password: secret = payload.password
                    }
                    guard let secret else { throw ValidationError.invalidFile }
                    try SecretClipboard.copy(secret)
                }
                message = "コピーしました。60秒後に内容を確認して消去します。"
            } catch { message = error.localizedDescription }
        }
    }
}
