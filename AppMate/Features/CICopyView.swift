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
    private var shownTemplates: [CITemplate] {
        templates.filter { template in
            switch template.value {
            case .base64: return true
            case .password: return record.fileExtension == "p12"
            case .keyID: return record.keyID != nil
            case .issuerID: return record.issuerID != nil
            case .teamID: return false
            }
        }.map { template in
            var item = template
            if item.id == AppPreferences().templates.first?.id, item.variable == "ASC_KEY_P8_BASE64" {
                switch record.fileExtension {
                case "p12": item.variable = "BUILD_CERTIFICATE_BASE64"
                case "mobileprovision", "provisionprofile": item.variable = "BUILD_PROVISION_PROFILE_BASE64"
                case "cer": item.variable = "CERTIFICATE_BASE64"
                default: break
                }
            }
            return item
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("コピー").font(.system(size: 18, weight: .bold))
                    Text("\(record.app?.name ?? record.team?.name ?? "") · \(record.name)（.\(record.fileExtension)）")
                    Text("変数名と値を1項目ずつCIの設定画面へ貼り付けます。App MateからCIへは送信しません。")
                        .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                    VStack(spacing: 0) {
                        HStack {
                            Text("変数名").frame(maxWidth: .infinity, alignment: .leading)
                            Text("値").frame(width: 90, alignment: .leading)
                            Text("操作").frame(width: 120, alignment: .leading)
                        }.font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).padding(.horizontal, 6).padding(.vertical, 8)
                        Divider()
                        ForEach(shownTemplates) { template in
                            HStack {
                                Text(template.variable).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Text(available(template.value) ? "••••••••" : "未保存").font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).frame(width: 90, alignment: .leading)
                                Button("認証してコピー") { copy(template.value) }
                                    .buttonStyle(AppMateButtonStyle()).disabled(!available(template.value) || access.busy).frame(width: 120)
                            }.padding(.horizontal, 6).padding(.vertical, 10)
                                .overlay(alignment: .bottom) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
                        }
                    }
                    Text("Touch ID またはMacのパスワードで確認します。コピーした値は60秒後、内容が変わっていない場合だけ消去します。")
                        .font(.system(size: 13)).foregroundStyle(AppMateStyle.warningText).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(AppMateStyle.warningBackground, in: RoundedRectangle(cornerRadius: 9))
                    DisclosureGroup("テンプレートについて") {
                        Text("追加・変数名の編集は「設定 → CIテンプレート」で行えます。Bitriseへは元形式の書き出しを使ってください。")
                            .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                    }
                    if let message { Text(message).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Spacer(); Button("閉じる") { dismiss() }.buttonStyle(AppMateButtonStyle()).keyboardShortcut(.cancelAction) }
        }.font(.system(size: 13)).padding(.horizontal, 26).padding(.vertical, 24).frame(width: 600, height: 620)
            .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text).tint(AppMateStyle.accent)
            .task { do { templates = try PreferencesStore.read(in: vault.context).templates } catch { message = error.localizedDescription } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if !access.busy { access.lock(); dismiss() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in access.lock(); dismiss() }
            .onDisappear { access.lock() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in access.lock(); dismiss() }
    }
    private func available(_ value: CIValue) -> Bool {
        switch value {
        case .base64: true
        case .keyID: record.keyID != nil
        case .issuerID: record.issuerID != nil
        case .teamID: false
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
                    case .teamID: secret = nil
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
