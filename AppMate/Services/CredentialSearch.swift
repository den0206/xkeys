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
        case .app: return app.map { record.isVisible(in: $0) } ?? false
        case .shared(let purpose): return record.isTeamShared && record.keyPurpose == purpose.rawValue
        }
    }

    static func matches(_ record: StoredCredential, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        var fields = [record.name, record.kind, record.originalName, record.fileExtension,
                      record.keyID ?? "", record.issuerID ?? "", record.bundleID ?? "",
                      record.team?.name ?? "", record.team?.teamID ?? ""]
        let apps = record.isTeamShared ? record.team?.apps ?? [] : record.app.map { [$0] } ?? []
        fields += apps.flatMap { [$0.name, $0.bundleID, $0.platform] }
        return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
    }
}

struct MenuBarSummary {
    let expired: Int
    let expiring: Int
    let total: Int

    init(records: [StoredCredential], at now: Date) {
        let active = records.filter { $0.replacedByID == nil && $0.deletedAt == nil && $0.app?.deletedAt == nil }
        expired = active.filter { $0.displayState(at: now) == .expired }.count
        expiring = active.filter { $0.displayState(at: now).needsRenewal }.count
        total = active.count
    }
    var attentionCount: Int { expired + expiring }
}
