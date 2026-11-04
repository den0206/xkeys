import Foundation

// Search metadata only. It never opens the vault or includes saved passwords or original bytes.
enum CredentialSearch {
    static func hasQuery(_ query: String) -> Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func includes(_ record: StoredCredential, scope: CredentialScope, app: ManagedApp?, query: String,
                         at now: Date, in records: [StoredCredential] = []) -> Bool {
        guard record.deletedAt == nil, record.app?.deletedAt == nil else { return false }
        guard matches(record, query: query) else { return false }
        if hasQuery(query) { return true }
        switch scope {
        case .trash: return false
        case .all: return true
        case .attention: return record.needsAttention(in: records, at: now)
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
