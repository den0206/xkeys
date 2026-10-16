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
    @State private var message: String?
    private var values: [CIValue] {
        CIValue.allCases.filter { value in
            switch value {
            case .base64: true
            case .keyID: record.keyID != nil
            case .issuerID: record.issuerID != nil
            case .password: record.fileExtension == "p12"
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("コピー").font(.system(size: 18, weight: .bold))
                    Text("\(record.app?.name ?? record.team?.name ?? "") · \(record.name)（.\(record.fileExtension)）")
                    Text("値を1項目ずつCIの設定画面へ貼り付けます。App MateからCIへは送信しません。Bitriseへは元形式の書き出しを使ってください。")
                        .font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                    VStack(spacing: 0) {
                        HStack {
                            Text("項目").frame(maxWidth: .infinity, alignment: .leading)
                            Text("値").frame(width: 90, alignment: .leading)
                            Text("操作").frame(width: 120, alignment: .leading)
                        }.font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).padding(.horizontal, 6).padding(.vertical, 8)
                        Divider()
                        ForEach(values, id: \.self) { value in
                            HStack {
                                Text(value.title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(available(value) ? "••••••••" : "未保存").font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).frame(width: 90, alignment: .leading)
                                Button("認証してコピー") { copy(value) }
                                    .buttonStyle(AppMateButtonStyle()).disabled(!available(value) || access.busy).frame(width: 120)
                            }.padding(.horizontal, 6).padding(.vertical, 10)
                                .overlay(alignment: .bottom) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
                        }
                    }
                    Text("Touch ID またはMacのパスワードで確認します。コピーした値は60秒後、内容が変わっていない場合だけ消去します。")
                        .font(.system(size: 13)).foregroundStyle(AppMateStyle.warningText).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(AppMateStyle.warningBackground, in: RoundedRectangle(cornerRadius: 9))
                    if let message { Text(message).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Spacer(); Button("閉じる") { dismiss() }.buttonStyle(AppMateButtonStyle()).keyboardShortcut(.cancelAction) }
        }.font(.system(size: 13)).padding(.horizontal, 26).padding(.vertical, 24).frame(width: 600, height: 620)
            .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text).tint(AppMateStyle.accent)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if !access.busy { access.lock(); dismiss() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in access.lock(); dismiss() }
            .onDisappear { access.lock() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in access.lock(); dismiss() }
    }
    private func available(_ value: CIValue) -> Bool {
        value != .password || record.hasSavedPassword
    }
    private func copy(_ value: CIValue) {
        Task { @MainActor in
            do {
                try await access.withKey(reason: "CIへ登録する値をコピーします", allowCreation: false, vault: vault) { key in
                    let payload = try vault.read(record, key: key)
                    let secret: String? = switch value {
                    case .base64: payload.original.base64EncodedString()
                    case .keyID: record.keyID
                    case .issuerID: record.issuerID
                    case .password: payload.password
                    }
                    guard let secret else { throw ValidationError.invalidFile }
                    try SecretClipboard.copy(secret)
                }
                message = "コピーしました。60秒後に内容を確認して消去します。"
            } catch { message = error.localizedDescription }
        }
    }
}
