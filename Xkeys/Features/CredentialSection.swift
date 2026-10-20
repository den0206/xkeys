import SwiftUI

/// The three kinds the lists are split into. Profiles live on app pages, certificates and keys on the team page.
enum CredentialGroup: CaseIterable {
    case profile, certificate, key

    init(_ record: StoredCredential) {
        switch record.fileExtension {
        case "p8": self = .key
        case "cer", "p12": self = .certificate
        default: self = .profile
        }
    }

    var title: String {
        switch self {
        case .profile: String(localized: "プロファイル")
        case .certificate: String(localized: "証明書")
        case .key: String(localized: "鍵（.p8）")
        }
    }

    var symbol: String {
        switch self {
        case .profile: "doc.text"
        case .certificate: "checkmark.seal"
        case .key: "key"
        }
    }

    var tint: Color {
        switch self {
        case .profile: XkeysStyle.accent
        case .certificate: XkeysStyle.successText
        case .key: XkeysStyle.warningText
        }
    }

    var background: Color {
        switch self {
        case .profile: XkeysStyle.profileBackground
        case .certificate: XkeysStyle.certificateBackground
        case .key: XkeysStyle.keyBackground
        }
    }

    var border: Color {
        switch self {
        case .profile: XkeysStyle.profileBorder
        case .certificate: XkeysStyle.certificateBorder
        case .key: XkeysStyle.keyBorder
        }
    }

    /// Headings of the name and middle columns in the list.
    var columns: (name: String, detail: String) {
        switch self {
        case .profile: (String(localized: "プロファイル"), "Bundle ID")
        case .certificate: (String(localized: "名前"), String(localized: "使っているアプリ"))
        case .key: ("Key ID", String(localized: "用途"))
        }
    }
}

extension StoredCredential {
    /// "Apple Distribution: Name (TEAMID)" → ("Apple Distribution", "Name"); the team page already shows the Team ID.
    var certificateNameParts: (title: String, holder: String?) {
        guard let range = name.range(of: ": ") else { return (name, nil) }
        var holder = String(name[range.upperBound...])
        if let id = team?.teamID, holder.hasSuffix(" (\(id))") { holder.removeLast(id.count + 3) }
        return (String(name[..<range.lowerBound]), holder)
    }

    var signingDigestList: [String] {
        signingCertificateDigests?.split(separator: ",").map(String.init) ?? []
    }

    /// Certificates in a .p12 other than the chosen one. Empty until the file was read.
    var bundledCertificates: [ContainedCertificate] {
        guard let data = p12Certificates?.data(using: .utf8),
              let all = try? JSONDecoder().decode([ContainedCertificate].self, from: data) else { return [] }
        return all.filter { $0.fingerprint != fingerprint }
    }

    /// Fingerprint and expiry of every certificate this file holds.
    private var certificateExpiries: [String: Date?] {
        var result = [String: Date?]()
        for certificate in bundledCertificates { result[certificate.fingerprint] = certificate.expiresAt }
        if let fingerprint { result[fingerprint] = expiresAt }
        return result
    }

    /// Certificates (.cer / .p12 of the same team) embedded in this profile. Empty until the profile was read.
    func signingCertificates(in records: [StoredCredential]) -> [StoredCredential] {
        let digests = Set(signingDigestList)
        guard !digests.isEmpty else { return [] }
        return records.filter { other in
            other.deletedAt == nil && other.team?.id == team?.id && CredentialGroup(other) == .certificate
                && !digests.isDisjoint(with: other.certificateExpiries.keys)
        }
    }

    /// Profiles that embed this certificate or one bundled with it.
    func profilesUsing(in records: [StoredCredential]) -> [StoredCredential] {
        guard CredentialGroup(self) == .certificate else { return [] }
        let fingerprints = Set(certificateExpiries.keys)
        guard !fingerprints.isEmpty else { return [] }
        return records.filter { $0.deletedAt == nil && $0.app?.deletedAt == nil && $0.team?.id == team?.id && !fingerprints.isDisjoint(with: $0.signingDigestList) }
    }

    /// True when every known signing certificate of this profile has expired.
    func signingCertificatesExpired(in records: [StoredCredential], at now: Date) -> Bool {
        let digests = Set(signingDigestList)
        let expiries = signingCertificates(in: records).flatMap { $0.certificateExpiries.filter { digests.contains($0.key) }.map(\.value) }
        return !expiries.isEmpty && expiries.allSatisfy { $0.map { $0 <= now } ?? false }
    }

    func needsAttention(in records: [StoredCredential], at now: Date) -> Bool {
        let state = displayState(at: now)
        return state == .expired || state.needsRenewal || signingCertificatesExpired(in: records, at: now)
    }
}

extension P8Purpose {
    var shortTitle: String {
        switch self {
        case .appStoreConnect: "App Store Connect"
        case .apns: String(localized: "通知")
        case .signInWithApple: String(localized: "Appleでサインイン")
        case .deviceCheck: "DeviceCheck"
        case .maps: String(localized: "マップ")
        case .weatherKit: String(localized: "天気")
        case .mediaServices: String(localized: "メディア")
        case .other: String(localized: "その他")
        }
    }

    var symbol: String {
        switch self {
        case .appStoreConnect: "a.square"
        case .apns: "bell"
        case .signInWithApple: "person.crop.circle"
        case .deviceCheck: "checkmark.shield"
        case .maps: "mappin.and.ellipse"
        case .weatherKit: "cloud.sun"
        case .mediaServices: "music.note"
        case .other: "ellipsis.circle"
        }
    }

    var tint: Color {
        switch self {
        case .appStoreConnect: Color(red: 0.11, green: 0.31, blue: 0.85)
        case .apns: Color(red: 0.76, green: 0.25, blue: 0.05)
        case .signInWithApple: XkeysStyle.text
        case .deviceCheck: XkeysStyle.successText
        case .maps: Color(red: 0.05, green: 0.45, blue: 0.56)
        case .weatherKit: Color(red: 0.63, green: 0.38, blue: 0.03)
        case .mediaServices: Color(red: 0.53, green: 0.10, blue: 0.56)
        case .other: XkeysStyle.secondary
        }
    }
}

struct PurposeLabels: View {
    let record: StoredCredential

    var body: some View {
        let purposes = record.keyPurpose.flatMap(P8Purpose.purposes(stored:)) ?? []
        HStack(spacing: 10) {
            if purposes.isEmpty { Text("用途未設定").foregroundStyle(XkeysStyle.secondary) }
            ForEach(purposes, id: \.self) { purpose in
                Label { Text(purpose.shortTitle) } icon: { Image(systemName: purpose.symbol).foregroundStyle(purpose.tint) }
                    .labelStyle(.titleAndIcon)
            }
        }.font(.system(size: 12)).foregroundStyle(XkeysStyle.text.opacity(0.8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "用途：") + (purposes.isEmpty ? String(localized: "未設定") : purposes.map(\.shortTitle).joined(separator: String(localized: "、"))))
    }
}

/// A section that opens and closes. Its state is not remembered: each page opens expanded.
struct CollapsibleSection<Content: View>: View {
    let title: String
    let detail: String
    let attention: Int
    /// Explained by a “?” beside the title while the guide is on.
    var term: GuideTerm? = nil
    @ViewBuilder let content: Content
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 0 : -90)).foregroundStyle(XkeysStyle.secondary)
                            .animation(XkeysMotion.feedback, value: expanded)
                        Text(title).fontWeight(.bold).foregroundStyle(XkeysStyle.text.opacity(0.75))
                        Text(detail).foregroundStyle(XkeysStyle.tertiary)
                        if !expanded && attention > 0 {
                            Label("要対応 \(attention)", systemImage: "circle.fill").labelStyle(AttentionBadgeStyle())
                        }
                    }.font(.system(size: 13)).padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(title)、\(detail)") + (attention > 0 ? String(localized: "、要対応\(attention)件") : ""))
                    .accessibilityValue(expanded ? "開いています" : "閉じています")
                if let term { GuideTermButton(term: term) }
            }.padding(.bottom, 6)
            if expanded {
                VStack(alignment: .leading, spacing: 6) { content }
            }
        }
    }
}

struct AttentionBadgeStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }.font(.system(size: 11, weight: .bold)).foregroundStyle(XkeysStyle.dangerText)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color(red: 0.996, green: 0.886, blue: 0.886), in: Capsule())
    }
}

/// Empty pages: drop files here, or choose them.
struct CredentialDropZone: View {
    let title: String
    let formats: [String]
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 26)).foregroundStyle(XkeysStyle.accent)
            Text(title).font(.system(size: 15, weight: .bold))
            Text("追加画面を開かずに、そのまま取り込みます").foregroundStyle(XkeysStyle.secondary)
            HStack(spacing: 6) {
                ForEach(formats, id: \.self) { format in
                    Text(format).font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 3)
                        .background(XkeysStyle.canvas, in: Capsule()).overlay(Capsule().stroke(XkeysStyle.border))
                }
            }
            Button("ファイルを選ぶ…", action: choose).buttonStyle(XkeysButtonStyle()).padding(.top, 4)
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
            .background(XkeysStyle.selectedRow, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(XkeysStyle.dropBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }
}

/// The separate card for Apple Developer import, the same as in the import sheet.
struct AppleImportCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.down").font(.system(size: 15)).foregroundStyle(XkeysStyle.text.opacity(0.75))
                    .frame(width: 32, height: 32).background(XkeysStyle.search, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Developer から取り込む").fontWeight(.semibold)
                    Text("ログイン中のアカウントから証明書とプロファイルを選んで取り込みます")
                        .font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(XkeysStyle.tertiary)
            }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(XkeysStyle.rowBorder))
        }.buttonStyle(.plain)
    }
}
