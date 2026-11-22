import Foundation

// Rules about stored credentials that do not depend on any screen. Views add their colours and symbols in Features.

enum CredentialScope: Hashable {
    case all, attention, trash, app(UUID), team(UUID)

    var title: String {
        switch self {
        case .trash: String(localized: "最近削除した項目")
        case .all: String(localized: "すべての鍵とファイル")
        case .attention: String(localized: "対応が必要")
        case .app: "App"
        case .team: String(localized: "チームの鍵・証明書")
        }
    }
}

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
}

enum CredentialDisplayState: Equatable {
    case expired, withinDay, expiring(Int), valid, stored

    var needsRenewal: Bool {
        switch self { case .withinDay, .expiring: true; default: false }
    }
    var title: String {
        switch self {
        case .expired: String(localized: "期限切れ")
        case .withinDay: String(localized: "24時間以内")
        case .expiring(let days): String(localized: "あと\(days)日")
        case .valid: String(localized: "有効")
        case .stored: String(localized: "保管中")
        }
    }
}

extension StoredCredential {
    func displayState(at now: Date) -> CredentialDisplayState {
        guard let expiresAt else { return .stored }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return .expired }
        if seconds < 86400 { return .withinDay }
        if seconds <= 30 * 86400 { return .expiring(Int(ceil(seconds / 86400))) }
        return .valid
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
