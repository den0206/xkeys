import AppKit
import SwiftUI

/// One line of the CI secret file. Values are read only while writing, so the sheet never holds secrets.
struct CISecretEntry: Identifiable {
    enum Section: CaseIterable {
        case team, certificate, profile, key
        var title: String {
            switch self {
            case .team: String(localized: "チーム")
            case .certificate: String(localized: "証明書（.p12）")
            case .profile: String(localized: "プロファイル")
            case .key: String(localized: "鍵（.p8）")
            }
        }
    }
    enum Source {
        case file(StoredCredential), password(StoredCredential), text(String)
    }

    let id: String
    let section: Section
    let title: String
    var name: String
    let source: Source
    var included: Bool
    var note: String?
    var warns = false
    /// The file entry this value belongs to; checking the file also checks it.
    var parent: String?
}

enum CISecretError: LocalizedError {
    case empty, invalidName(String), reservedName(String), duplicateName(String), unsupportedPassword
    var errorDescription: String? {
        switch self {
        case .empty: String(localized: "書き出す項目を1つ以上選んでください。")
        case .invalidName(let name): String(localized: "変数名「\(name)」は使えません。英字・数字・_ で、先頭は英字か _ にしてください。")
        case .reservedName(let name): String(localized: "変数名「\(name)」は GITHUB_ で始まるため使えません。")
        case .duplicateName(let name): String(localized: "変数名「\(name)」が重複しています。")
        case .unsupportedPassword: String(localized: ".p12 のパスワードに ' または改行が含まれるため、ファイルに書けません。CI に直接設定してください。")
        }
    }
}

@MainActor enum CISecretFile {
    static func entries(for app: ManagedApp, records: [StoredCredential], at now: Date) -> [CISecretEntry] {
        let product = app.product
        guard let team = product.team else { return [] }
        let active = records.filter { $0.deletedAt == nil && $0.team?.id == team.id && $0.displayState(at: now) != .expired }
        var entries = [CISecretEntry(id: "team", section: .team, title: String(localized: "Team ID（\(team.name)）"), name: "APPLE_TEAM_ID",
                                     source: .text(team.teamID), included: true)]

        var chosenProfiles: [StoredCredential] = []
        for target in product.targets {
            let profiles = active.filter { $0.app?.id == target.id && CredentialGroup($0) == .profile }.sorted(by: newer)
            let suffix = target.parentAppID == nil ? "" : "_" + nameSuffix(target.bundleID)
            for (index, profile) in profiles.enumerated() {
                if index == 0 { chosenProfiles.append(profile) }
                entries.append(CISecretEntry(id: "profile-\(profile.id)", section: .profile, title: "\(target.name) · \(profile.name)",
                                             name: "BUILD_PROVISION_PROFILE\(suffix)_BASE64", source: .file(profile), included: index == 0))
            }
        }

        // Only .p12 carries the private key that CI needs to sign. Linked certificates come first.
        let linked = Set(chosenProfiles.flatMap { $0.signingCertificates(in: records) }.map(\.id))
        let certificates = active.filter { $0.isTeamShared && $0.fileExtension == "p12" }
            .sorted { linked.contains($0.id) != linked.contains($1.id) ? linked.contains($0.id) : newer($0, $1) }
        for (index, certificate) in certificates.enumerated() {
            let include = index == 0 && linked.contains(certificate.id)
            entries.append(CISecretEntry(id: "p12-\(certificate.id)", section: .certificate, title: certificate.name,
                                         name: "BUILD_CERTIFICATE_BASE64", source: .file(certificate), included: include,
                                         note: linked.contains(certificate.id) ? String(localized: "プロファイルが使う証明書") : nil))
            entries.append(CISecretEntry(id: "password-\(certificate.id)", section: .certificate, title: String(localized: "パスワード"),
                                         name: "P12_PASSWORD", source: .password(certificate), included: include,
                                         note: certificate.hasSavedPassword ? nil : String(localized: "保存していません。空の値で書き出します"),
                                         warns: !certificate.hasSavedPassword, parent: "p12-\(certificate.id)"))
        }

        // Every key is offered; only the newest App Store Connect key starts checked, since CI uploads with it.
        let isASC = { (key: StoredCredential) in key.keyPurpose == P8Purpose.appStoreConnect.rawValue }
        let keys = active.filter { $0.isTeamShared && $0.fileExtension == "p8" }
            .sorted { isASC($0) != isASC($1) ? isASC($0) : newer($0, $1) }
        for (index, key) in keys.enumerated() {
            let prefix = keyPrefix(key)
            let include = index == 0 && isASC(key)
            entries.append(CISecretEntry(id: "p8-\(key.id)", section: .key, title: key.name,
                                         name: "\(prefix)_KEY_P8_BASE64", source: .file(key), included: include))
            if let keyID = key.keyID {
                entries.append(CISecretEntry(id: "keyid-\(key.id)", section: .key, title: "Key ID",
                                             name: "\(prefix)_KEY_ID", source: .text(keyID), included: include,
                                             parent: "p8-\(key.id)"))
            }
            if let issuerID = key.issuerID {
                entries.append(CISecretEntry(id: "issuer-\(key.id)", section: .key, title: "Issuer ID",
                                             name: "\(prefix)_ISSUER_ID", source: .text(issuerID), included: include,
                                             parent: "p8-\(key.id)"))
            }
        }
        return entries
    }

    /// Checking a .p8 or .p12 also checks its Key ID, Issuer ID or password; a value can still be unchecked alone.
    static func setIncluded(_ value: Bool, id: String, in entries: inout [CISecretEntry]) {
        for index in entries.indices where entries[index].id == id || entries[index].parent == id {
            entries[index].included = value
        }
    }

    /// GitHub treats secret names case-insensitively and reserves the GITHUB_ prefix.
    static func validate(_ entries: [CISecretEntry]) throws {
        let included = entries.filter(\.included)
        guard !included.isEmpty else { throw CISecretError.empty }
        var names = Set<String>()
        for entry in included {
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil else { throw CISecretError.invalidName(entry.name) }
            guard !name.uppercased().hasPrefix("GITHUB_") else { throw CISecretError.reservedName(name) }
            guard names.insert(name.uppercased()).inserted else { throw CISecretError.duplicateName(name) }
        }
    }

    /// Writes dotenv lines. Single quotes keep values literal in dotenv parsers.
    static func render(_ entries: [CISecretEntry], title: String, at now: Date,
                       read: (StoredCredential) throws -> CredentialPayload) throws -> Data {
        try validate(entries)
        let included = entries.filter(\.included)
        let label = title.components(separatedBy: .newlines).joined(separator: " ")
        var lines = [String(localized: "# このファイルは App Mate が自動生成しました。編集しないでください。"),
                     String(localized: "# 値を変える場合は、App Mate で書き出し直してください。"),
                     String(localized: "# 生成元: \(label) · \(now.formatted(.iso8601.year().month().day()))"),
                     String(localized: "# このファイルは暗号化されていません。CI に登録したら削除してください。")]
        var payloads: [UUID: CredentialPayload] = [:]
        func payload(_ record: StoredCredential) throws -> CredentialPayload {
            if let cached = payloads[record.id] { return cached }
            let value = try read(record)
            payloads[record.id] = value
            return value
        }
        for entry in included {
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            let value: String
            switch entry.source {
            case .text(let text): value = text
            case .file(let record): value = try payload(record).original.base64EncodedString()
            case .password(let record):
                guard let password = try payload(record).password else {
                    lines += [String(localized: "# \(name): パスワードを保存していないため空です。CI に直接設定してください。"), "# \(name)="]
                    continue
                }
                value = password
            }
            guard !value.contains("'"), !value.contains(where: \.isNewline) else { throw CISecretError.unsupportedPassword }
            lines.append("\(name)='\(value)'")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func defaultFileName(for app: ManagedApp) -> String {
        let name = app.product.name.components(separatedBy: CharacterSet(charactersIn: "/:").union(.newlines)).joined(separator: "-")
        return "\(name.isEmpty ? "App" : name).ci-secrets.env"
    }

    private static func keyPrefix(_ key: StoredCredential) -> String {
        switch key.keyPurpose.flatMap(P8Purpose.purposes(stored:))?.first {
        case .appStoreConnect: "ASC"
        case .apns: "APNS"
        case .signInWithApple: "SIWA"
        case .deviceCheck: "DEVICECHECK"
        case .maps: "MAPS"
        case .weatherKit: "WEATHERKIT"
        case .mediaServices: "MEDIA"
        case .other, nil: "APPLE"
        }
    }

    private static func nameSuffix(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? ""
        return last.uppercased().replacing(/[^A-Z0-9]/, with: "_")
    }

    private static func newer(_ lhs: StoredCredential, _ rhs: StoredCredential) -> Bool {
        (lhs.expiresAt ?? .distantFuture, lhs.createdAt) > (rhs.expiresAt ?? .distantFuture, rhs.createdAt)
    }
}

struct CISecretFileView: View {
    let vault: CredentialVault
    let app: ManagedApp
    let records: [StoredCredential]
    @Environment(\.dismiss) private var dismiss
    @State private var access = VaultAccess()
    @State private var entries: [CISecretEntry]
    @State private var message: String?
    @State private var written: URL?

    init(vault: CredentialVault, app: ManagedApp, records: [StoredCredential]) {
        self.vault = vault
        self.app = app
        self.records = records
        _entries = State(initialValue: CISecretFile.entries(for: app, records: records, at: .now))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CI 用の Secret ファイルを作成").font(.system(size: 18, weight: .bold))
                    Text("\(app.product.name) · \(app.product.targets.count)ターゲット · \(app.product.team?.teamID ?? "")").foregroundStyle(AppMateStyle.secondary)
                }
                Text("GitHub Actions などに登録する値を .env 形式のファイルにまとめます。変数名は編集できます。\n各 CI の Secrets 設定に貼り付けて登録します。")
                    .lineSpacing(3).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppMateStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(CISecretEntry.Section.allCases, id: \.self) { section in
                            let indices = entries.indices.filter { entries[$0].section == section }
                            if !indices.isEmpty {
                                Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(AppMateStyle.secondary)
                                    .padding(.top, 10).padding(.bottom, 4)
                                ForEach(indices, id: \.self) { row($entries[$0]) }
                            }
                        }
                        if !entries.contains(where: { $0.section == .profile }) {
                            Text("期限内のプロファイルがありません").font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary).padding(.top, 10)
                        }
                    }
                }
                Label("書き出したファイルは暗号化しません。秘密鍵とパスワードを含みます。CI に登録したら削除し、リポジトリに追加しないでください。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(AppMateStyle.warningText).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppMateStyle.warningBackground, in: RoundedRectangle(cornerRadius: 8))
                if let written {
                    Label("\(written.lastPathComponent) に書き出しました", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(AppMateStyle.successText)
                }
                if let message { Text(message).font(.caption).foregroundStyle(AppMateStyle.dangerText).fixedSize(horizontal: false, vertical: true) }
            }.padding(.horizontal, 28).padding(.vertical, 22)
            Divider()
            HStack {
                Text("\(entries.filter(\.included).count)項目").font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
                Spacer()
                Button("閉じる") { dismiss() }.buttonStyle(AppMateButtonStyle()).keyboardShortcut(.cancelAction)
                Button { export() } label: { Label("書き出す…", systemImage: "touchid") }
                    .buttonStyle(AppMateButtonStyle(primary: true)).disabled(access.busy || !entries.contains(where: \.included))
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }.font(.system(size: 13)).frame(width: 640, height: 600)
            .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text).tint(AppMateStyle.accent)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if !access.busy && !access.presentingPanel { access.lock(); dismiss() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in access.lock(); dismiss() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in access.lock(); dismiss() }
            .onDisappear { access.lock() }
    }

    private func row(_ entry: Binding<CISecretEntry>) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { entry.wrappedValue.included },
                                     set: { CISecretFile.setIncluded($0, id: entry.wrappedValue.id, in: &entries) }))
                .labelsHidden().toggleStyle(.checkbox).padding(.leading, entry.wrappedValue.parent == nil ? 0 : 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.wrappedValue.title).lineLimit(1).truncationMode(.middle)
                if case .file(let record) = entry.wrappedValue.source, record.fileExtension == "p8" { PurposeLabels(record: record) }
                if let note = entry.wrappedValue.note {
                    Text(note).font(.system(size: 11))
                        .foregroundStyle(entry.wrappedValue.warns ? AppMateStyle.warningText : AppMateStyle.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            TextField("変数名", text: entry.name).font(.system(size: 12).monospaced()).textFieldStyle(.roundedBorder)
                .frame(width: 290).disabled(!entry.wrappedValue.included)
                .accessibilityLabel("\(entry.wrappedValue.title)の変数名")
        }.padding(.vertical, 6)
            .overlay(alignment: .top) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
    }

    private func export() {
        message = nil
        written = nil
        // Check names before asking for a location; values are read only after authentication.
        do { try CISecretFile.validate(entries) } catch { message = error.localizedDescription; return }
        let generation = access.generation
        access.presentingPanel = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CISecretFile.defaultFileName(for: app)
        panel.message = String(localized: "ファイル名を変更できます。保存先では App Mate の暗号化保護の対象外になります。既存ファイルは上書きしません。")
        let response = panel.runModal()
        access.presentingPanel = false
        guard response == .OK, let url = panel.url, generation == access.generation else { return }
        let entries = entries
        Task { @MainActor in
            do {
                try await access.withKey(reason: String(localized: "CI 用の Secret ファイルを書き出します"), allowCreation: false, vault: vault) { key in
                    let data = try CISecretFile.render(entries, title: app.product.name, at: .now) { try vault.read($0, key: key) }
                    try CredentialFile(data: data, name: url.lastPathComponent).export(to: url)
                }
                written = url
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch let error as POSIXError where error.code == .EEXIST {
                message = String(localized: "同じ名前のファイルがあります。別の名前を指定してください。")
            } catch { message = error.localizedDescription }
        }
    }
}
