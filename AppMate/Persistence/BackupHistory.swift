import Foundation
import SwiftData

@Model
final class BackupChange {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var count: Int

    init(count: Int = 1, at date: Date = .now) {
        id = UUID()
        createdAt = date
        self.count = count
    }
}

@Model
final class BackupCheckpoint {
    @Attribute(.unique) var key: String
    var lastCompletedAt: Date?
    var lastSnapshotAt: Date?
    var preferencesData: Data?

    init() { key = "full-backup" }
}

struct BackupWatermark: Sendable {
    let changeIDs: Set<UUID>
    let capturedAt: Date
}

struct BackupHistorySummary {
    let pendingCount: Int
    let oldestChange: Date?
    let lastCompletedAt: Date?

    init(changes: [BackupChange], checkpoint: BackupCheckpoint?, hasStoredItems: Bool) {
        let hasCustomPreferences = checkpoint?.preferencesData.map {
            (try? JSONDecoder().decode(AppPreferences.self, from: $0)) != AppPreferences()
        } ?? false
        let needsBackup = hasStoredItems || hasCustomPreferences
        pendingCount = needsBackup ? changes.reduce(0) { $0 + $1.count } : 0
        oldestChange = needsBackup ? changes.map(\.createdAt).min() : nil
        lastCompletedAt = checkpoint?.lastCompletedAt
    }
}

@MainActor
enum BackupHistory {
    static func hasStoredItems(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<ManagedApp>()) > 0
            || context.fetchCount(FetchDescriptor<StoredCredential>()) > 0
    }

    // Called before a mutation; its inserts are committed or rolled back with that mutation.
    static func prepare(in context: ModelContext, at date: Date = .now) throws {
        guard try context.fetch(FetchDescriptor<BackupCheckpoint>()).isEmpty else { return }
        let existing = try context.fetchCount(FetchDescriptor<DeveloperTeam>())
            + context.fetchCount(FetchDescriptor<ManagedApp>())
            + context.fetchCount(FetchDescriptor<StoredCredential>())
        context.insert(BackupCheckpoint())
        if existing > 0 { context.insert(BackupChange(count: existing, at: date)) }
    }

    static func record(in context: ModelContext, at date: Date = .now) {
        context.insert(BackupChange(at: date))
    }

    static func bootstrap(in context: ModelContext) throws {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        context.autosaveEnabled = false
        do {
            try prepare(in: context)
            if context.hasChanges { try context.save() }
        } catch { context.rollback(); throw error }
    }

    static func watermark(in context: ModelContext, capturedAt: Date) throws -> BackupWatermark {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        guard try context.fetch(FetchDescriptor<BackupCheckpoint>()).count == 1 else { throw BackupError.invalid }
        return BackupWatermark(changeIDs: Set(try context.fetch(FetchDescriptor<BackupChange>()).map(\.id)), capturedAt: capturedAt)
    }

    static func export(_ archive: Data, to url: URL, covering watermark: BackupWatermark, in context: ModelContext) throws -> Bool {
        try CredentialFile(data: archive, name: url.lastPathComponent).export(to: url)
        do {
            try complete(watermark, in: context)
            return true
        } catch {
            // The verified backup is valid even if tracking cannot be updated; keep changes pending.
            return false
        }
    }

    static func complete(_ watermark: BackupWatermark, in context: ModelContext, at date: Date = .now,
                         beforeCommit: () throws -> Void = {}) throws {
        guard !context.hasChanges else { throw RestoreError.pendingChanges }
        guard let checkpoint = try context.fetch(FetchDescriptor<BackupCheckpoint>()).first else { throw BackupError.invalid }
        let changes = try context.fetch(FetchDescriptor<BackupChange>())
        context.autosaveEnabled = false
        do {
            for change in changes where watermark.changeIDs.contains(change.id) { context.delete(change) }
            // A slower, older backup must not replace the timestamp of a newer snapshot.
            if checkpoint.lastSnapshotAt.map({ watermark.capturedAt >= $0 }) ?? true {
                checkpoint.lastSnapshotAt = watermark.capturedAt
                checkpoint.lastCompletedAt = date
            }
            try beforeCommit()
            try context.save()
        } catch { context.rollback(); throw error }
    }
}

struct SafetyBackup: Sendable {
    let revision: String
    private init(revision: String) { self.revision = revision }

    static func export(_ archive: Data, password: String?, snapshot: BackupSnapshot, to url: URL) throws -> SafetyBackup {
        let decoded = try BackupArchive.decode(archive, password: password)
        guard try decoded.revision() == snapshot.revision() else { throw BackupError.invalid }
        try CredentialFile(data: archive, name: url.lastPathComponent).export(to: url)
        return SafetyBackup(revision: try snapshot.revision())
    }
}
