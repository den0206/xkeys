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

    @State private var copied: CIValue?
    @State private var pending: CIValue?
    @State private var copiedAt = Date.distantPast
    @State private var now = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CI 用にコピー").font(.system(size: 18, weight: .bold))
                    Text("\(record.name)（.\(record.fileExtension)） · \(record.app?.name ?? record.team?.name ?? "")").foregroundStyle(XkeysStyle.secondary)
                }
                Text("GitHub Actions などの CI の設定画面に、1つずつ貼り付けます。\nXkeys から CI へ送ることはありません。")
                    .lineSpacing(3).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
                VStack(spacing: 0) {
                    ForEach(values, id: \.self) { value in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(value.title).fontWeight(.semibold)
                                Text(detail(value)).font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            let remaining = 60 - Int(now.timeIntervalSince(copiedAt))
                            if copied == value && remaining > 0 {
                                Label("コピーしました · 残り \(remaining)秒", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                                    .contentTransition(.numericText(countsDown: true)).animation(XkeysMotion.feedback, value: remaining)
                                    .foregroundStyle(XkeysStyle.successText).padding(.horizontal, 10).frame(height: 30)
                                    .background(XkeysStyle.successBackground, in: RoundedRectangle(cornerRadius: 7))
                                    .transition(.symbolEffect(.drawOn))
                            } else {
                                Button { copy(value) } label: {
                                    Label("コピー", systemImage: "touchid").symbolEffect(.pulse, isActive: pending == value && XkeysMotion.enabled)
                                }.buttonStyle(XkeysButtonStyle(compact: true)).disabled(!available(value) || access.busy)
                            }
                        }.padding(.vertical, 12)
                            .overlay(alignment: .top) { Rectangle().fill(XkeysStyle.rowBorder).frame(height: 1) }
                    }
                }
                Text("コピーした値は画面に表示しません。60秒たつとクリップボードから消します（その間に別のものをコピーした場合は消しません）。")
                    .font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary).fixedSize(horizontal: false, vertical: true)
                if let message { Text(message).font(.caption).foregroundStyle(XkeysStyle.dangerText) }
            }.padding(.horizontal, 28).padding(.vertical, 22)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text("Bitrise などはファイルを書き出して使います").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                Spacer()
                Button("閉じる") { dismiss() }.buttonStyle(XkeysButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }.font(.system(size: 13)).frame(width: 560, height: 520)
            .background(XkeysStyle.canvas).foregroundStyle(XkeysStyle.text).tint(XkeysStyle.accent)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in if !access.busy { access.lock(); dismiss() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in access.lock(); dismiss() }
            .onDisappear { access.lock() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in access.lock(); dismiss() }
    }

    private func detail(_ value: CIValue) -> String {
        switch value {
        case .base64: String(localized: "CI の Secrets に貼り付ける、ファイルの中身（base64）です")
        case .keyID: String(localized: "鍵を見分ける ID です")
        case .issuerID: String(localized: "App Store Connect の Issuer ID です")
        case .password: record.hasSavedPassword ? String(localized: "取り込みのときに保存したパスワードです") : String(localized: "パスワードは保存していません")
        }
    }

    private func available(_ value: CIValue) -> Bool {
        value != .password || record.hasSavedPassword
    }
    private func copy(_ value: CIValue) {
        pending = value
        Task { @MainActor in
            defer { pending = nil }
            do {
                try await access.withKey(reason: String(localized: "CIへ登録する値をコピーします"), allowCreation: false, vault: vault) { key in
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
                message = nil
                copiedAt = .now
                now = .now
                withAnimation(XkeysMotion.feedback) { copied = value }
                XkeysMotion.confirm()
            } catch { message = error.localizedDescription }
        }
    }
}
