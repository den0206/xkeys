import Foundation

enum CredentialTypeFilter: String, CaseIterable, Identifiable {
    case all, key, certificate, identity, profile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "すべての種類"
        case .key: "秘密鍵（.p8）"
        case .certificate: "証明書（.cer）"
        case .identity: "証明書＋秘密鍵（.p12）"
        case .profile: "プロファイル"
        }
    }
    func matches(_ record: StoredCredential) -> Bool {
        switch self {
        case .all: true
        case .key: record.fileExtension == "p8"
        case .certificate: record.fileExtension == "cer"
        case .identity: record.fileExtension == "p12"
        case .profile: ["mobileprovision", "provisionprofile"].contains(record.fileExtension)
        }
    }
}

enum CredentialPurposeFilter: String, CaseIterable, Identifiable {
    case all, signing, appStoreConnect, apns, signInWithApple, intermediateCA, unspecified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "すべての用途"
        case .signing: "署名"
        case .appStoreConnect: "App Store Connect API"
        case .apns: "プッシュ通知"
        case .signInWithApple: "Appleでサインイン"
        case .intermediateCA: "中間CA"
        case .unspecified: "未設定"
        }
    }
    func matches(_ record: StoredCredential) -> Bool {
        if self == .all { return true }
        if record.isIntermediateCA { return self == .intermediateCA }
        if record.fileExtension != "p8" { return self == .signing }
        switch record.keyPurpose.flatMap(P8Purpose.init(rawValue:)) {
        case .appStoreConnect: return self == .appStoreConnect
        case .apns: return self == .apns
        case .signInWithApple: return self == .signInWithApple
        case nil: return self == .unspecified
        }
    }
}

// Search metadata only. It never opens the vault or includes saved passwords or original bytes.
enum CredentialSearch {
    static func hasQuery(_ query: String) -> Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func includes(_ record: StoredCredential, scope: CredentialScope, app: ManagedApp?, query: String,
                         type: CredentialTypeFilter, showReplaced: Bool, at now: Date) -> Bool {
        guard record.deletedAt == nil, record.app?.deletedAt == nil else { return false }
        guard showReplaced || record.replacedByID == nil else { return false }
        guard type.matches(record), matches(record, query: query) else { return false }
        if hasQuery(query) { return true }
        switch scope {
        case .trash: return false
        case .credential(let id): return record.id == id
        case .all: return true
        case .expired: return record.displayState(at: now) == .expired
        case .expiring: return record.displayState(at: now).needsRenewal
        case .app: return !record.isTeamShared && (app.map { app in
            app.parentAppID == nil ? app.targets.contains { record.isVisible(in: $0) } : record.isVisible(in: app)
        } ?? false)
        case .team(let id): return record.isTeamShared && record.team?.id == id
        }
    }

    static func matches(_ record: StoredCredential, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        var fields = [record.name, record.kind, record.originalName, record.fileExtension,
                      record.keyID ?? "", record.issuerID ?? "", record.bundleID ?? "",
                      record.team?.name ?? "", record.team?.teamID ?? ""]
        let apps = record.app.map { [$0] } ?? []
        fields += apps.flatMap { [$0.name, $0.bundleID, $0.platform, $0.product.name] }
        return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
    }
}
