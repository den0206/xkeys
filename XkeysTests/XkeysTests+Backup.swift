import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
import XcodesLoginKit
@testable import Xkeys

/// Backup format, history, restore plans and merges.
extension XkeysTests {
    @MainActor
    func testTargetRegistrationAndBackupRelationshipsRoundTrip() async throws {
        let (vault, root, _, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let catalog = AppCatalog(context: vault.context)
        let teamID = try XCTUnwrap(root.team?.id)
        let id = try catalog.addApp(name: "Share", bundleID: "com.example.Xkeys.fixture.share", platform: "iOS", teamID: teamID, parentAppID: root.id)
        XCTAssertThrowsError(try catalog.addApp(name: "Wrong Team", bundleID: "com.example.wrong", platform: "iOS", teamID: teamID, parentAppID: other.id))
        let child = try XCTUnwrap(root.targets.first { $0.id == id })
        XCTAssertEqual(child.product.id, root.id)
        let key = SymmetricKey(size: .bits256)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertEqual(snapshot.apps.first { $0.id == id }?.parentAppID, root.id)
        let selected = try snapshot.selecting(appIDs: [id])
        XCTAssertEqual(Set(selected.apps.map(\.id)), [root.id, id])
        let decoded = try BackupArchive.decode(BackupArchive.encode(selected, password: nil), password: nil)
        XCTAssertEqual(decoded, selected)
        var invalid = selected
        invalid.version = 2
        XCTAssertThrowsError(try invalid.validate())
        let (destination, localRoot, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: destination.blobs.directory) }
        let plan = try BackupRestore(vault: destination).prepare(decoded, key: key)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try BackupRestore(vault: destination).merge(plan, choices: choices, authorization: approvalPlan1, key: key)
        let restored = try XCTUnwrap(destination.context.fetch(FetchDescriptor<ManagedApp>()).first { $0.bundleID == child.bundleID })
        XCTAssertEqual(restored.parentAppID, localRoot.id)
        XCTAssertEqual(restored.product.id, localRoot.id)
    }

    @MainActor
    func testBackupRejectsInvalidTargetParents() throws {
        let (vault, root, child, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let source = try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256))
        for parent in [child.id, other.id, UUID()] {
            let apps = source.apps.map { value -> BackupSnapshot.App in
                var value = value
                if value.id == child.id { value.parentAppID = parent }
                return value
            }
            let invalid = BackupSnapshot(version: 1, createdAt: source.createdAt, appVersion: source.appVersion,
                                         teams: source.teams, apps: apps, credentials: source.credentials)
            XCTAssertThrowsError(try invalid.validate())
        }
        let nestedApps = source.apps.map { value -> BackupSnapshot.App in
            var value = value
            if value.id == root.id { value.parentAppID = child.id }
            if value.id == child.id { value.parentAppID = root.id }
            return value
        }
        XCTAssertThrowsError(try BackupSnapshot(version: 1, createdAt: source.createdAt, appVersion: source.appVersion,
                                              teams: source.teams, apps: nestedApps, credentials: source.credentials).validate())
    }

    @MainActor
    func testTargetTrashRestoreAndParentPurgePreserveRelationships() throws {
        let (vault, root, child, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        try AppCatalog(context: vault.context).setParent(root.id, for: child, name: child.name, platform: child.platform)
        let management = VaultManagement(vault: vault)
        let key = SymmetricKey(size: .bits256)
        try management.trash(root, key: key)
        XCTAssertNotNil(child.deletedAt)
        XCTAssertThrowsError(try management.restore(child))
        try management.restore(root)
        XCTAssertNil(root.deletedAt)
        XCTAssertNil(child.deletedAt)
        try management.trash(child, key: key)
        XCTAssertEqual(root.targets.map(\.id), [root.id])
        XCTAssertNil(root.target(forProfileBundleID: child.bundleID))
        let childDeletedAt = child.deletedAt
        try management.trash(root, key: key)
        try management.restore(root)
        XCTAssertEqual(child.deletedAt, childDeletedAt)
        try management.trash(root, key: key)
        try management.purge(records: [], apps: [root])
        XCTAssertNil(child.parentAppID)
        try management.restore(child)
        XCTAssertNil(child.deletedAt)
        _ = try BackupSnapshot.capture(vault: vault, key: key)
    }

    @MainActor
    func testTargetDeletionValidatesProfilesAndRestoresRegistrationTogether() throws {
        let (vault, target, parent, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        try AppCatalog(context: vault.context).setParent(parent.id, for: target, name: target.name, platform: target.platform)
        let key = SymmetricKey(size: .bits256)
        for ext in ["mobileprovision", "cer"] {
            let file = CredentialFile(data: try fixture(ext), name: "sample." + ext)
            _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: ext), app: target,
                                     password: nil, confirmUnknownTeam: true, key: key)
        }
        let records = try vault.records()
        let profile = try XCTUnwrap(records.first { !$0.isTeamShared })
        let shared = try XCTUnwrap(records.first { $0.isTeamShared })
        let aad = try profile.authenticatedData()
        let original = try vault.read(profile, key: key).original
        let blob = vault.blobs.file(profile.blobID)
        let bytes = try Data(contentsOf: blob)
        let history = try vault.context.fetchCount(FetchDescriptor<BackupChange>())
        let manager = VaultManagement(vault: vault)
        try Data([0]).write(to: blob)
        XCTAssertThrowsError(try manager.trash(target, key: key))
        XCTAssertNil(target.deletedAt)
        XCTAssertNil(profile.deletedAt)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history)
        try bytes.write(to: blob)
        let now = Date.now
        try manager.trash(target, key: key, at: now)
        XCTAssertEqual(target.deletedAt, now)
        XCTAssertEqual(profile.deletedAt, now)
        XCTAssertNil(parent.deletedAt)
        XCTAssertNil(shared.deletedAt)
        XCTAssertEqual(parent.targets.map(\.id), [parent.id])
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history + 1)
        XCTAssertThrowsError(try manager.restore(profile))
        try manager.restore(target)
        XCTAssertNil(target.deletedAt)
        XCTAssertNil(profile.deletedAt)
        XCTAssertTrue(parent.targets.contains { $0.id == target.id })
        XCTAssertEqual(try profile.authenticatedData(), aad)
        XCTAssertEqual(try vault.read(profile, key: key).original, original)
    }

    @MainActor
    func testCustomSecretsBackupV1RestoreConflictsAndLegacyDefaults() async throws {
        let (vault, app, _, _) = try makeVault()
        let (destination, target, _, _) = try makeVault()
        defer {
            try? FileManager.default.removeItem(at: vault.blobs.directory)
            try? FileManager.default.removeItem(at: destination.blobs.directory)
        }
        let key = SymmetricKey(size: .bits256)
        let secrets = [AppSecret(name: "HOTPEPPER_API_KEY", value: "fixture-only")]
        try VaultManagement(vault: vault).saveCustomSecrets(secrets, app: app, key: key)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertEqual(snapshot.version, 1)
        let data = try BackupArchive.encode(snapshot, password: "fixture-backup")
        XCTAssertNil(data.range(of: Data("fixture-only".utf8)))
        let decoded = try BackupArchive.decode(data, password: "fixture-backup")
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(try snapshot.selecting(appIDs: [app.id]).apps.first { $0.id == app.id }?.customSecrets, secrets)
        let restorer = BackupRestore(vault: destination)
        let plan = try restorer.prepare(decoded, key: key)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        let authorization = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try restorer.merge(plan, choices: choices, authorization: authorization, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertNil(target.customSecretsBlobID)
        _ = try restorer.merge(plan, choices: choices, authorization: authorization, key: key)
        XCTAssertEqual(try VaultManagement(vault: destination).readCustomSecrets(target, key: key), secrets)
        try VaultManagement(vault: destination).saveCustomSecrets([AppSecret(name: "HOTPEPPER_API_KEY", value: "different")], app: target, key: key)
        let conflict = try restorer.prepare(decoded, key: key)
        XCTAssertTrue(conflict.conflicts.contains { $0.target == target.id })
        let before = try BackupSnapshot.capture(vault: destination, key: key)
        try VaultManagement(vault: destination).saveCustomSecrets([], app: target, key: key)
        XCTAssertNil(target.customSecretsBlobID)
        XCTAssertThrowsError(try conflict.merged(with: BackupSnapshot.capture(vault: destination, key: key), choices: [:]))
        XCTAssertNotEqual(try before.revision(), try BackupSnapshot.capture(vault: destination, key: key).revision())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var apps = try XCTUnwrap(json["apps"] as? [[String: Any]])
        for index in apps.indices { apps[index].removeValue(forKey: "customSecrets") }
        json["apps"] = apps
        let legacy = try JSONDecoder().decode(BackupSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        try legacy.validate()
        XCTAssertTrue(legacy.apps.allSatisfy { $0.customSecrets == nil })
        var badApps = snapshot.apps
        let index = try XCTUnwrap(badApps.firstIndex { $0.id == app.id })
        badApps[index].customSecrets = [AppSecret(name: "bad key", value: "fixture-only")]
        let invalid = BackupSnapshot(version: 1, createdAt: .now, appVersion: "test", teams: snapshot.teams, apps: badApps, credentials: snapshot.credentials)
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor
    func testNoteCommitFailuresKeepOriginalEncryptedReferencesAndHistory() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        let manager = VaultManagement(vault: vault)
        try manager.saveNote("app-before", app: app, key: key)
        try manager.saveNote("credential-before", record: record, key: key)
        let before = try BackupSnapshot.capture(vault: vault, key: key).revision()
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).sorted()
        let count = try vault.context.fetchCount(FetchDescriptor<BackupChange>())
        XCTAssertThrowsError(try manager.saveNote("app-after", app: app, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertThrowsError(try manager.saveNote("credential-after", record: record, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).revision(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).sorted(), files)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), count)
    }

    @MainActor
    func testAppIconSurvivesProtectedBackupAndRestore() async throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        app.iconColor = "blue"
        // A valid one-pixel PNG keeps the archive test independent of image generation.
        app.iconImage = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6WQAAAAASUVORK5CYII=")!
        try vault.context.save()
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let archive = try BackupArchive.encode(snapshot, password: "design-fixture-password")
        let decoded = try BackupArchive.decode(archive, password: "design-fixture-password")
        let restoredApp = try XCTUnwrap(decoded.apps.first { $0.id == app.id })
        XCTAssertEqual(restoredApp.iconColor, "blue")
        XCTAssertEqual(restoredApp.iconImage, app.iconImage)
        let originalIcon = app.iconImage
        app.iconImage = nil
        app.iconColor = "orange"
        try vault.context.save()
        let restore = BackupRestore(vault: vault)
        let plan = try restore.prepare(decoded, key: key)
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) }), authorization: approvalPlan1, key: key)
        XCTAssertEqual(app.iconImage, originalIcon)
        XCTAssertEqual(app.iconColor, "blue")
        let invalid = try editing(snapshot) { json in
            var apps = json["apps"] as! [[String: Any]]
            apps[0]["iconImage"] = Data(repeating: 0, count: 1_048_577).base64EncodedString()
            json["apps"] = apps
        }
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor
    func testEncryptedNotesSurviveBackupMergeAndOrphanRecovery() async throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let id = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        let manager = VaultManagement(vault: vault)
        try manager.saveNote("App secret note", app: app, key: key)
        try manager.saveNote("Credential secret note", record: record, key: key)
        try vault.recover()
        XCTAssertEqual(try manager.readNote(app, key: key), "App secret note")
        XCTAssertEqual(try vault.read(record, key: key).note, "Credential secret note")
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        for url in try FileManager.default.contentsOfDirectory(at: vault.blobs.directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: Data("secret note".utf8)))
        }
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let (target, _, _, _) = try makeVault()
        let targetKey = SymmetricKey(size: .bits256)
        let restore = BackupRestore(vault: target)
        let plan = try restore.prepare(snapshot, key: targetKey)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: choices, authorization: approvalPlan1, key: targetKey)
        let restoredApp = try XCTUnwrap(target.context.fetch(FetchDescriptor<ManagedApp>()).first { $0.bundleID == app.bundleID && $0.team?.teamID == app.team?.teamID })
        XCTAssertEqual(try VaultManagement(vault: target).readNote(restoredApp, key: targetKey), "App secret note")
        XCTAssertEqual(try target.read(XCTUnwrap(target.records().first), key: targetKey).note, "Credential secret note")
    }

    @MainActor
    func testBatchTrashValidatesEveryRecordBeforeChangingAnyAndCanBeRestored() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        for ext in ["cer", "mobileprovision"] {
            let file = CredentialFile(data: try fixture(ext), name: "sample." + ext)
            _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: ext), app: app,
                                     password: nil, confirmUnknownTeam: true, key: key)
        }
        let records = try vault.records().sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(records.count, 2)
        let last = try XCTUnwrap(records.last)
        let blob = vault.blobs.file(last.blobID)
        let bytes = try Data(contentsOf: blob)
        try Data([0]).write(to: blob)
        let manager = VaultManagement(vault: vault)
        XCTAssertThrowsError(try manager.trash(records, key: key))
        XCTAssertTrue(records.allSatisfy { $0.deletedAt == nil })
        XCTAssertFalse(vault.context.hasChanges)
        try bytes.write(to: blob)
        let now = Date.now
        try manager.trash(records, key: key, at: now)
        XCTAssertTrue(records.allSatisfy { $0.deletedAt == now })
        XCTAssertFalse(vault.context.hasChanges)
        for record in records {
            try manager.restore(record)
            XCTAssertNil(record.deletedAt)
            XCTAssertFalse(try vault.read(record, key: key).original.isEmpty)
        }
    }

    @MainActor
    func testAppTrashRetainsSharedKeysAndRestoresOnlyItsOwnDeletedProfiles() throws {
        let (vault, app, sibling, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let cert = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(cert, parsed: CredentialParser.parse(cert.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        _ = try vault.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let manager = VaultManagement(vault: vault)
        try manager.trash(app, key: key)
        let records = try vault.records()
        let shared = try XCTUnwrap(records.first { $0.isTeamShared })
        let owned = try XCTUnwrap(records.first { !$0.isTeamShared })
        XCTAssertNil(shared.deletedAt)
        XCTAssertNotNil(owned.deletedAt)
        XCTAssertTrue(shared.isVisible(in: sibling))
        XCTAssertThrowsError(try manager.restore(owned))
        try manager.restore(app)
        XCTAssertNil(owned.deletedAt)
        XCTAssertNil(app.deletedAt)
        XCTAssertEqual(try vault.read(shared, key: key).original, cert.data)
        try manager.trash(owned, key: key, at: Date(timeIntervalSince1970: 0))
        try manager.trash(app, key: key)
        try manager.restore(app)
        XCTAssertNotNil(owned.deletedAt)
    }

    @MainActor
    func testDeletionIsExcludedFromSearchAndSurvivesBackup() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        try VaultManagement(vault: vault).trash(record, key: key)
        XCTAssertFalse(CredentialSearch.includes(record, scope: .all, app: nil, query: "sample", type: .all, at: .now))
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertNotNil(snapshot.credentials.first?.deletedAt)
    }

    @MainActor
    func testPreferencesAreStableAndAreIncludedInRestoreConflicts() async throws {
        let (vault, _, _, _) = try makeVault()
        XCTAssertEqual(try PreferencesStore.read(in: vault.context), try PreferencesStore.read(in: vault.context))
        var prefs = AppPreferences()
        prefs.showDockBadge = false
        try PreferencesStore.save(prefs, in: vault.context)
        let key = SymmetricKey(size: .bits256)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertEqual(snapshot.preferences, prefs)
        XCTAssertEqual(snapshot.version, 1)
        var unknown = snapshot; unknown.version = 2
        XCTAssertThrowsError(try unknown.validate())
        let (other, _, _, _) = try makeVault()
        let restore = BackupRestore(vault: other)
        let plan = try restore.prepare(snapshot, key: key)
        XCTAssertTrue(plan.conflicts.contains { $0.kind == .preferences })
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: choices, authorization: approvalPlan1, key: key)
        XCTAssertEqual(try PreferencesStore.read(in: other.context), prefs)
    }

    @MainActor
    func testSelectedExportIncludesSharedKeysOnceAndNoUnrelatedAppsOrSettings() throws {
        let (vault, app, sibling, other) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let selected = try snapshot.selecting(appIDs: [app.id, sibling.id])
        XCTAssertEqual(selected.apps.count, 2)
        XCTAssertEqual(selected.teams.count, 1)
        XCTAssertEqual(selected.credentials.count, 1)
        XCTAssertNil(selected.preferences)
        XCTAssertFalse(selected.apps.contains { $0.id == other.id })
    }

    @MainActor
    func testWholeReplaceIntoEmptyVaultNeedsNoSafetyBackup() async throws {
        let (source, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = p8File()
        _ = try source.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                  password: nil, confirmUnknownTeam: true, key: key,
                                  p8: P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil))
        let snapshot = try BackupSnapshot.capture(vault: source, key: key)
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source.blobs.directory)
            try? FileManager.default.removeItem(at: directory)
        }
        let target = CredentialVault(context: ModelContext(container), blobs: EncryptedBlobStore(directory: directory))
        let restore = BackupRestore(vault: target)
        let plan = try restore.prepare(snapshot, key: key)
        XCTAssertFalse(plan.requiresSafetyBackup)
        var prefs = AppPreferences()
        prefs.showDockBadge = false
        try PreferencesStore.save(prefs, in: target.context)
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try restore.merge(plan, choices: [:], authorization: approvalPlan1, key: key, replacingAll: true))
        let changed = try restore.prepare(snapshot, key: key)
        XCTAssertTrue(changed.requiresSafetyBackup)
        let approvalChanged1 = try await restoreAuthorization(for: changed)
        XCTAssertThrowsError(try restore.merge(changed, choices: [:], authorization: approvalChanged1, key: key, replacingAll: true))
        try PreferencesStore.save(AppPreferences(), in: target.context)
        let refreshed = try restore.prepare(snapshot, key: key)
        let approvalRefreshed1 = try await restoreAuthorization(for: refreshed)
        _ = try restore.merge(refreshed, choices: [:], authorization: approvalRefreshed1, key: key, replacingAll: true)
        XCTAssertEqual(try target.context.fetchCount(FetchDescriptor<ManagedApp>()), snapshot.apps.count)
        XCTAssertEqual(try target.read(XCTUnwrap(target.records().first), key: key).original, file.data)
        XCTAssertTrue(try restore.prepare(snapshot, key: key).requiresSafetyBackup)
    }

    @MainActor
    func testWholeReplaceRequiresVerifiedCurrentSafetyBackupAndRejectsStaleProof() async throws {
        let (vault, _, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        try BackupHistory.bootstrap(in: vault.context)
        let current = try BackupSnapshot.capture(vault: vault, key: key)
        let empty = BackupSnapshot(version: 1, createdAt: .now, appVersion: "test", teams: [], apps: [], credentials: [])
        let restore = BackupRestore(vault: vault)
        let plan = try restore.prepare(empty, key: key)
        XCTAssertTrue(plan.requiresSafetyBackup)
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try restore.merge(plan, choices: [:], authorization: approvalPlan1, key: key, replacingAll: true))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString + ".xkeysbackup")
        let archive = try BackupArchive.encode(current, password: nil)
        XCTAssertThrowsError(try SafetyBackup.export(Data([0]), password: nil, snapshot: current, to: url))
        let proof = try SafetyBackup.export(archive, password: nil, snapshot: current, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let approvalPlan2 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try restore.merge(plan, choices: [:], authorization: approvalPlan2, key: key, beforeCommit: { throw ValidationError.invalidFile }, safetyBackup: proof))
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<ManagedApp>()), 3)
        let approvalPlan3 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: [:], authorization: approvalPlan3, key: key, safetyBackup: proof)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<ManagedApp>()), 0)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<DeveloperTeam>()), 0)
        let approvalPlan4 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try restore.merge(plan, choices: [:], authorization: approvalPlan4, key: key, safetyBackup: proof))
    }

    @MainActor
    func testEmptyCatalogDoesNotShowHistoricalChangesAsPendingBackup() throws {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        try BackupHistory.bootstrap(in: context)
        context.insert(BackupChange())
        try context.save()
        XCTAssertFalse(try backupHistory(context).needsBackup)
        // Custom settings still need a backup even without catalog items.
        var prefs = AppPreferences()
        prefs.showDockBadge = false
        try PreferencesStore.save(prefs, in: context)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        try PreferencesStore.save(AppPreferences(), in: context)
        XCTAssertFalse(try backupHistory(context).needsBackup)
        // A leftover team alone does not prompt for backup; trashed apps still do.
        let team = DeveloperTeam(name: "Team", teamID: "TESTTEAM01")
        context.insert(team)
        try context.save()
        XCTAssertFalse(try backupHistory(context).needsBackup)
        let app = ManagedApp(name: "Deleted", bundleID: "com.example.deleted", platform: "macOS", team: team)
        app.deletedAt = .now
        context.insert(app)
        try context.save()
        XCTAssertTrue(try backupHistory(context).needsBackup)
        context.delete(app)
        context.delete(team)
        try context.save()
        XCTAssertFalse(try backupHistory(context).needsBackup)
    }

    @MainActor
    func testRemovingBackupCountPreservesCurrentDatabaseAndPendingChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("history.store"))
        let markerID = UUID()
        let savedAt = Date(timeIntervalSince1970: 1_900_000_000)
        try autoreleasepool {
            let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self,
                                               BeforeBackupCountRemoval.BackupChange.self, BackupCheckpoint.self, configurations: configuration)
            let context = ModelContext(container)
            let team = DeveloperTeam(name: "Current team", teamID: "TESTTEAM01")
            context.insert(ManagedApp(name: "Current app", bundleID: "com.example.current", platform: "macOS", team: team))
            context.insert(BeforeBackupCountRemoval.BackupChange(id: markerID))
            let checkpoint = BackupCheckpoint()
            checkpoint.lastCompletedAt = savedAt
            context.insert(checkpoint)
            try context.save()
        }
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self,
                                           BackupChange.self, BackupCheckpoint.self, configurations: configuration)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ManagedApp>()).first?.name, "Current app")
        XCTAssertEqual(try context.fetch(FetchDescriptor<BackupChange>()).map(\.id), [markerID])
        XCTAssertTrue(try backupHistory(context).needsBackup)
        XCTAssertEqual(try backupHistory(context).lastCompletedAt, savedAt)
        try BackupHistory.complete(BackupHistory.watermark(in: context, capturedAt: .now), in: context)
        XCTAssertFalse(try backupHistory(context).needsBackup)
    }

    @MainActor
    func testHistoryTracksOnlyCommittedProductChangesAndNotIndividualExports() async throws {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        try BackupHistory.bootstrap(in: context)
        XCTAssertFalse(try backupHistory(context).needsBackup)
        let catalog = AppCatalog(context: context)
        let team = try catalog.addTeam(name: "Team", teamID: "TESTTEAM01")
        let appID = try catalog.addApp(name: "App", bundleID: "com.example.fixture", platform: "macOS", teamID: team)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        XCTAssertThrowsError(try catalog.addTeam(name: "Duplicate", teamID: "TESTTEAM01"))
        XCTAssertTrue(try backupHistory(context).needsBackup)
        let app = try XCTUnwrap(context.fetch(FetchDescriptor<ManagedApp>()).first { $0.id == appID })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = CredentialVault(context: context, blobs: EncryptedBlobStore(directory: directory))
        let key = SymmetricKey(size: .bits256), metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let file = p8File(), next = p8File()
        let oldID = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                         password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        let old = try XCTUnwrap(vault.records().first { $0.id == oldID })
        try vault.export(old, to: directory.appendingPathComponent("exported.p8"), key: key)
        _ = try vault.read(old, key: key)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        _ = try vault.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                 password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        let failed = p8File()
        XCTAssertThrowsError(try vault.importFile(failed, parsed: CredentialParser.parse(failed.data, extension: "p8"), app: app,
                                                  password: nil, confirmUnknownTeam: true, key: key, p8: metadata,
                                                  beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertTrue(try backupHistory(context).needsBackup)
        XCTAssertEqual(try vault.records().count, 2)
        let restore = BackupRestore(vault: vault)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        _ = try restore.merge(restore.prepare(snapshot, key: key), choices: [:], key: key)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        let changed = try editing(snapshot) { json in
            var teams = json["teams"] as! [[String: Any]]
            teams[0]["name"] = "Restored Team"
            json["teams"] = teams
        }
        let plan = try restore.prepare(changed, key: key)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try restore.merge(plan, choices: choices, authorization: approvalPlan1, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertTrue(try backupHistory(context).needsBackup)
        let approvalPlan2 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: choices, authorization: approvalPlan2, key: key)
        XCTAssertTrue(try backupHistory(context).needsBackup)
    }

    @MainActor
    func testFullBackupClearsCapturedChangesAndKeepsChangesAddedDuringCreation() throws {
        let (vault, _, _, _) = try makeVault()
        let context = vault.context
        try BackupHistory.bootstrap(in: context)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256))
        let watermark = try BackupHistory.watermark(in: context, capturedAt: snapshot.createdAt)
        let archive = try BackupArchive.encode(snapshot, password: nil)
        _ = try AppCatalog(context: context).addTeam(name: "During backup", teamID: "TESTTEAM03")
        let later = try XCTUnwrap(context.fetch(FetchDescriptor<BackupChange>()).first { !watermark.changeIDs.contains($0.id) })
        later.createdAt = snapshot.createdAt
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.xkeysbackup")
        XCTAssertTrue(try BackupHistory.export(archive, to: url, covering: watermark, in: context))
        let summary = try backupHistory(context)
        XCTAssertTrue(summary.needsBackup)
        XCTAssertNotNil(summary.lastCompletedAt)
        let saved = try BackupArchive.decode(CredentialFile(url: url, maximumBytes: BackupArchive.maximumFileBytes).data, password: nil)
        XCTAssertEqual(saved.teams.count, 2)
        XCTAssertFalse(saved.teams.contains { $0.teamID == "TESTTEAM03" })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DeveloperTeam>()), 3)
    }

    @MainActor
    func testOlderBackupCompletionCannotClearNewerChangesOrRollBackTimestamp() throws {
        let (vault, _, _, _) = try makeVault()
        let context = vault.context
        try BackupHistory.bootstrap(in: context)
        let older = try BackupHistory.watermark(in: context, capturedAt: Date(timeIntervalSince1970: 100))
        _ = try AppCatalog(context: context).addTeam(name: "Newer", teamID: "TESTTEAM03")
        let newer = try BackupHistory.watermark(in: context, capturedAt: Date(timeIntervalSince1970: 200))
        try BackupHistory.complete(newer, in: context, at: Date(timeIntervalSince1970: 300))
        XCTAssertFalse(try backupHistory(context).needsBackup)
        _ = try AppCatalog(context: context).addTeam(name: "After both snapshots", teamID: "TESTTEAM04")
        try BackupHistory.complete(older, in: context, at: Date(timeIntervalSince1970: 400))
        XCTAssertTrue(try backupHistory(context).needsBackup)
        XCTAssertEqual(try backupHistory(context).lastCompletedAt, Date(timeIntervalSince1970: 300))
    }

    @MainActor
    func testBackupWriteAndTrackingFailureKeepPendingChanges() throws {
        let (vault, app, _, _) = try makeVault()
        let context = vault.context
        try BackupHistory.bootstrap(in: context)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256))
        let watermark = try BackupHistory.watermark(in: context, capturedAt: snapshot.createdAt)
        let archive = try BackupArchive.encode(snapshot, password: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.xkeysbackup")
        let sentinel = Data("existing-file".utf8)
        try sentinel.write(to: existing)
        XCTAssertThrowsError(try BackupHistory.export(archive, to: existing, covering: watermark, in: context))
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        XCTAssertThrowsError(try BackupHistory.complete(watermark, in: context, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertTrue(try backupHistory(context).needsBackup)
        XCTAssertNil(try backupHistory(context).lastCompletedAt)
        app.name = "Another operation still pending"
        let saved = directory.appendingPathComponent("saved.xkeysbackup")
        XCTAssertFalse(try BackupHistory.export(archive, to: saved, covering: watermark, in: context))
        XCTAssertEqual(try BackupArchive.decode(Data(contentsOf: saved), password: nil).apps.count, 3)
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(app.name, "Another operation still pending")
        XCTAssertTrue(try backupHistory(context).needsBackup)
        context.rollback()
        XCTAssertTrue(try BackupHistory.export(archive, to: directory.appendingPathComponent("retry.xkeysbackup"), covering: watermark, in: context))
        XCTAssertFalse(try backupHistory(context).needsBackup)
    }

    @MainActor
    func testHistoryReopensWithoutMarkingExistingDataAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("history.store"))
        let savedAt = Date(timeIntervalSince1970: 1_900_000_000)
        try autoreleasepool {
            let legacy = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, configurations: configuration)
            let context = ModelContext(legacy)
            let team = DeveloperTeam(name: "Existing", teamID: "TESTTEAM01")
            context.insert(ManagedApp(name: "Existing", bundleID: "com.example.existing", platform: "macOS", team: team))
            try context.save()
        }
        try autoreleasepool {
            let upgraded = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
            let context = ModelContext(upgraded)
            let team = try XCTUnwrap(context.fetch(FetchDescriptor<DeveloperTeam>()).first)
            _ = try AppCatalog(context: context).addApp(name: "First tracked change", bundleID: "com.example.added", platform: "iOS", teamID: team.id)
            XCTAssertTrue(try backupHistory(context).needsBackup)
            try BackupHistory.bootstrap(in: context)
            XCTAssertTrue(try backupHistory(context).needsBackup)
            let watermark = try BackupHistory.watermark(in: context, capturedAt: savedAt)
            try BackupHistory.complete(watermark, in: context, at: savedAt)
            _ = try AppCatalog(context: context).addTeam(name: "After backup", teamID: "TESTTEAM02")
        }
        let reopened = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
        let context = ModelContext(reopened)
        try BackupHistory.bootstrap(in: context)
        XCTAssertTrue(try backupHistory(context).needsBackup)
        XCTAssertEqual(try backupHistory(context).lastCompletedAt, savedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BackupCheckpoint>()), 1)
    }

    @MainActor
    func testBackupRestoreToNewVaultKeepsIDsOriginalsPasswordsAndSharingAfterReopen() async throws {
        let (source, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory) }
        let sourceKey = SymmetricKey(size: .bits256)
        let p12 = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        let p12ID = try source.importFile(p12, parsed: CredentialParser.parse(p12.data, extension: "p12", password: "fixture-only"), app: app,
                                          password: "fixture-only", confirmUnknownTeam: true, key: sourceKey)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        let profileID = try source.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app,
                                              password: nil, confirmUnknownTeam: false, key: sourceKey)
        let first = p8File(), next = p8File()
        let metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let oldID = try source.importFile(first, parsed: CredentialParser.parse(first.data, extension: "p8"), app: app,
                                          password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        let nextID = try source.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                           password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        let backup = try BackupArchive.decode(BackupArchive.encode(BackupSnapshot.capture(vault: source, key: sourceKey), password: "fixture-backup-password"), password: "fixture-backup-password")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("restore.store"))
        let blobs = EncryptedBlobStore(directory: directory.appendingPathComponent("blobs"))
        let localKey = SymmetricKey(size: .bits256)
        let membershipTransport = FakeAppleDeveloperTransport()
        membershipTransport.teams = backup.teams.map { RemoteDeveloperTeam(teamID: $0.teamID, name: $0.name) }
        let membershipSession = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { membershipTransport }, observeLock: false)
        try await membershipSession.login(account: "fixture@example.invalid", password: "fixture-only")
        try autoreleasepool {
            let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
            let vault = CredentialVault(context: ModelContext(container), blobs: blobs)
            let restore = BackupRestore(vault: vault)
            let plan = try restore.prepare(backup, key: localKey)
            XCTAssertEqual(plan.addedCount, 9)
            let approvalPlan1 = RestoreTeamAuthorization()
            try membershipSession.confirm(approvalPlan1, plan: plan)
            let result = try restore.merge(plan, choices: [:], authorization: approvalPlan1, key: localKey)
            XCTAssertEqual(result.added, 9)
            XCTAssertEqual(result.updated, 0)
            let restored = try BackupSnapshot.capture(vault: vault, key: localKey)
            XCTAssertEqual(try restored.revision(), try backup.revision())
            let repeatPlan = try restore.prepare(backup, key: localKey)
            XCTAssertTrue(repeatPlan.conflicts.isEmpty)
            XCTAssertEqual(repeatPlan.duplicateCount, 10)
            XCTAssertEqual(try restore.merge(repeatPlan, choices: [:], key: localKey).added, 0)
        }
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
        let vault = CredentialVault(context: ModelContext(container), blobs: blobs)
        let apps = try vault.context.fetch(FetchDescriptor<ManagedApp>())
        let firstApp = try XCTUnwrap(apps.first { $0.id == app.id })
        let sibling = try XCTUnwrap(apps.first { $0.bundleID == "com.example.other" })
        let records = try vault.records()
        let restoredP12 = try XCTUnwrap(records.first { $0.id == p12ID })
        XCTAssertEqual(try vault.read(restoredP12, key: localKey).password, "fixture-only")
        XCTAssertEqual(try vault.read(restoredP12, key: localKey).original, p12.data)
        XCTAssertThrowsError(try vault.read(restoredP12, key: sourceKey))
        XCTAssertTrue(restoredP12.isVisible(in: sibling))
        let originalBlob = restoredP12.blobID
        let copiedBlob = UUID()
        try FileManager.default.copyItem(at: blobs.file(originalBlob), to: blobs.file(copiedBlob))
        restoredP12.blobID = copiedBlob
        XCTAssertThrowsError(try vault.read(restoredP12, key: localKey))
        restoredP12.blobID = originalBlob
        try vault.context.save()
        let restoredProfile = try XCTUnwrap(records.first { $0.id == profileID })
        XCTAssertTrue(restoredProfile.isVisible(in: firstApp))
        XCTAssertFalse(restoredProfile.isVisible(in: sibling))
        XCTAssertEqual(try vault.read(XCTUnwrap(records.first { $0.id == oldID }), key: localKey).original, first.data)
        let nextRecord = try XCTUnwrap(records.first { $0.id == nextID })
        XCTAssertEqual(try vault.read(nextRecord, key: localKey).original, next.data)
        try vault.recover()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blobs.directory.path).count, 4)
    }

    @MainActor
    func testRestoreInitialCommitFailureLeavesNoCatalogOrEncryptedFiles() async throws {
        let (source, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory) }
        let sourceKey = SymmetricKey(size: .bits256), localKey = SymmetricKey(size: .bits256)
        let file = p8File()
        _ = try source.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                  password: nil, confirmUnknownTeam: true, key: sourceKey,
                                  p8: P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil))
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = CredentialVault(context: ModelContext(container), blobs: EncryptedBlobStore(directory: directory))
        let service = BackupRestore(vault: vault)
        let plan = try service.prepare(BackupSnapshot.capture(vault: source, key: sourceKey), key: localKey)
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try service.merge(plan, choices: [:], authorization: approvalPlan1, key: localKey, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertTrue(try vault.context.fetch(FetchDescriptor<DeveloperTeam>()).isEmpty)
        XCTAssertTrue(try vault.context.fetch(FetchDescriptor<ManagedApp>()).isEmpty)
        XCTAssertTrue(try vault.records().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let approvalPlan2 = try await restoreAuthorization(for: plan)
        XCTAssertEqual(try service.merge(plan, choices: [:], authorization: approvalPlan2, key: localKey).added, 6)
        XCTAssertEqual(try vault.records().count, 1)
    }

    @MainActor
    func testRestoreConflictSelectionAndFailedCommitPreserveOriginalBlobs() async throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        let id = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p12", password: "fixture-only"), app: app,
                                      password: "fixture-only", confirmUnknownTeam: true, key: key)
        let baseline = try BackupSnapshot.capture(vault: vault, key: key)
        let backup = try editing(baseline) { json in
            var teams = json["teams"] as! [[String: Any]]
            let i = teams.firstIndex { $0["id"] as? String == app.team?.id.uuidString }!
            teams[i]["name"] = "Backup Team"
            json["teams"] = teams
            var apps = json["apps"] as! [[String: Any]]
            let j = apps.firstIndex { $0["id"] as? String == app.id.uuidString }!
            apps[j]["name"] = "Backup App"
            json["apps"] = apps
            var records = json["credentials"] as! [[String: Any]]
            records[0]["name"] = "Backup Certificate"
            records[0]["password"] = nil
            records[0]["hasSavedPassword"] = false
            json["credentials"] = records
        }
        let service = BackupRestore(vault: vault)
        let plan = try service.prepare(backup, key: key)
        XCTAssertEqual(plan.conflicts.count, 3)
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try service.merge(plan, choices: [:], authorization: approvalPlan1, key: key))
        let keep = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.current) })
        let approvalPlan2 = try await restoreAuthorization(for: plan)
        XCTAssertEqual(try service.merge(plan, choices: keep, authorization: approvalPlan2, key: key).updated, 0)
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).revision(), try baseline.revision())
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        let oldURL = vault.blobs.file(record.blobID)
        let oldBytes = try Data(contentsOf: oldURL)
        let oldFiles = try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path)
        let useBackup = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        let approvalPlan3 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try service.merge(plan, choices: useBackup, authorization: approvalPlan3, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).revision(), try baseline.revision())
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path)), Set(oldFiles))
        let approvalPlan4 = try await restoreAuthorization(for: plan)
        let updated = try service.merge(plan, choices: useBackup, authorization: approvalPlan4, key: key)
        XCTAssertEqual(updated.updated, 3)
        let changed = try XCTUnwrap(vault.records().first { $0.id == id })
        XCTAssertEqual(changed.name, "Backup Certificate")
        XCTAssertEqual(changed.team?.name, "Backup Team")
        XCTAssertEqual(app.name, "Backup App")
        XCTAssertNil(try vault.read(changed, key: key).password)
        XCTAssertEqual(try vault.read(changed, key: key).original, file.data)
        XCTAssertNotEqual(changed.blobID, changed.id)
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        try vault.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try vault.read(changed, key: key).original, file.data)
    }

    @MainActor
    func testRestoreRemapsNaturalIdentities() async throws {
        let (source, sourceApp, _, _) = try makeVault()
        let (target, targetApp, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory); try? FileManager.default.removeItem(at: target.blobs.directory) }
        let sourceKey = SymmetricKey(size: .bits256), targetKey = SymmetricKey(size: .bits256)
        let file = p8File(), renewed = p8File()
        let parsed = try CredentialParser.parse(file.data, extension: "p8")
        let metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let sourceOld = try source.importFile(file, parsed: parsed, app: sourceApp, password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        let targetOld = try target.importFile(file, parsed: parsed, app: targetApp, password: nil, confirmUnknownTeam: true, key: targetKey, p8: metadata)
        let newID = try source.importFile(renewed, parsed: CredentialParser.parse(renewed.data, extension: "p8"), app: sourceApp,
                                          password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        let service = BackupRestore(vault: target)
        let plan = try service.prepare(BackupSnapshot.capture(vault: source, key: sourceKey), key: targetKey)
        XCTAssertEqual(plan.addedCount, 1)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.kind == .credential ? RestoreChoice.backup : .current) })
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try service.merge(plan, choices: choices, authorization: approvalPlan1, key: targetKey)
        let records = try target.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(records.contains { $0.id == sourceOld })
        XCTAssertTrue(records.contains { $0.id == targetOld })
        let next = try XCTUnwrap(records.first { $0.id == newID })
        XCTAssertEqual(next.team?.id, targetApp.team?.id)
        XCTAssertEqual(try target.read(next, key: targetKey).original, renewed.data)
        XCTAssertEqual(try target.context.fetch(FetchDescriptor<DeveloperTeam>()).count, 2)
        XCTAssertEqual(try target.context.fetch(FetchDescriptor<ManagedApp>()).count, 3)
    }

    @MainActor
    func testRestoreRejectsStalePreviewAndIdentityCollisionWithoutWrites() async throws {
        let (vault, _, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let service = BackupRestore(vault: vault)
        let plan = try service.prepare(snapshot, key: key)
        _ = try AppCatalog(context: vault.context).addTeam(name: "Changed after preview", teamID: "TESTTEAM03")
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try service.merge(plan, choices: [:], authorization: approvalPlan1, key: key)) { error in
            guard case RestoreError.stale = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try vault.context.fetch(FetchDescriptor<DeveloperTeam>()).count, 3)
        let collision = try editing(snapshot) { json in
            var teams = json["teams"] as! [[String: Any]]
            teams[0]["teamID"] = "COLLIDE001"
            json["teams"] = teams
        }
        XCTAssertThrowsError(try service.prepare(collision, key: key)) { error in
            guard case RestoreError.identity = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(try vault.records().isEmpty)
    }

    @MainActor
    func testRestoreRejectsMalformedScopeAndRegistrationKey() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256), metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        for file in [p8File(), p8File()] {
            _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                     password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        }
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let wrongScope = try editing(snapshot) { json in
            var records = json["credentials"] as! [[String: Any]]
            records[0]["app"] = app.id.uuidString
            json["credentials"] = records
        }
        XCTAssertThrowsError(try wrongScope.validate())
        let badKey = try editing(snapshot) { json in
            var records = json["credentials"] as! [[String: Any]]
            records[0]["registrationKey"] = "untrusted-key"
            json["credentials"] = records
        }
        XCTAssertThrowsError(try badKey.validate())
    }

    func testBackupFileReaderUsesBoundedSizeWithoutWeakeningCredentialLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.xkeysbackup")
        let bytes = Data(repeating: 42, count: CredentialParser.maximumBytes + 1)
        try bytes.write(to: url)
        XCTAssertThrowsError(try CredentialFile(url: url))
        XCTAssertEqual(try CredentialFile(url: url, maximumBytes: BackupArchive.maximumFileBytes).data, bytes)
        XCTAssertThrowsError(try CredentialFile(url: url, maximumBytes: 0))
        let alias = directory.appendingPathComponent("alias.xkeysbackup")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        XCTAssertThrowsError(try CredentialFile(url: alias, maximumBytes: BackupArchive.maximumFileBytes))
    }

    @MainActor
    func testBackupPreservesCatalogOriginalsAndPasswords() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        let parsed = try CredentialParser.parse(file.data, extension: "p12", password: "fixture-only")
        let id = try vault.importFile(file, parsed: parsed, app: app, password: "fixture-only", confirmUnknownTeam: true, key: key)
        let first = p8File()
        let metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        _ = try vault.importFile(first, parsed: CredentialParser.parse(first.data, extension: "p8"), app: app,
                                 password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let next = p8File()
        _ = try vault.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                 password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let secret = "backup-fixture-only-password"
        let archive = try BackupArchive.encode(snapshot, password: secret)
        XCTAssertTrue(try BackupArchive.requiresPassword(archive))
        XCTAssertNil(archive.range(of: Data("fixture-only".utf8)))
        let restored = try BackupArchive.decode(archive, password: secret)
        XCTAssertEqual(restored.teams.count, 2)
        XCTAssertEqual(restored.apps.count, 3)
        XCTAssertEqual(restored.credentials.count, 3)
        let credential = try XCTUnwrap(restored.credentials.first { $0.id == id })
        XCTAssertEqual(credential.original, file.data)
        XCTAssertEqual(credential.password, "fixture-only")
        XCTAssertThrowsError(try BackupArchive.decode(archive, password: "incorrect-password"))
        XCTAssertThrowsError(try BackupArchive.decode(archive, password: nil))
        var tampered = archive
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try BackupArchive.decode(tampered, password: secret))
        XCTAssertEqual(try vault.read(try XCTUnwrap(vault.records().first { $0.id == id }), key: key).original, file.data)
    }

    func testBackupV1FixtureAndRandomizedProtection() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "empty-v1", withExtension: "xkeysbackup", subdirectory: "Fixtures"))
        let snapshot = try BackupArchive.decode(Data(contentsOf: url), password: nil)
        XCTAssertEqual(snapshot.createdAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(snapshot.appVersion, "fixture-v1")
        let first = try BackupArchive.encode(snapshot, password: "fixture-password")
        let second = try BackupArchive.encode(snapshot, password: "fixture-password")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try BackupArchive.decode(second, password: "fixture-password").appVersion, "fixture-v1")
        XCTAssertThrowsError(try BackupArchive.encode(snapshot, password: String(repeating: "あ", count: 400)))
    }

    func testBackupPasswordMinimumIsSixCharacters() throws {
        let snapshot = BackupSnapshot(version: 1, createdAt: .now, appVersion: "fixture", teams: [], apps: [], credentials: [])
        for password in ["123456", "あいうえおか", "fixture-password"] {
            let archive = try BackupArchive.encode(snapshot, password: password)
            XCTAssertEqual(try BackupArchive.decode(archive, password: password), snapshot)
        }
        for password in ["", "12345", "あいうえお"] {
            XCTAssertThrowsError(try BackupArchive.encode(snapshot, password: password)) { error in
                guard case BackupError.passwordRequired = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testBackupRejectsUnknownFormatAndExcessiveDerivationBeforeDecrypting() throws {
        let snapshot = BackupSnapshot(version: 1, createdAt: .now, appVersion: "fixture", teams: [], apps: [], credentials: [])
        let plain = try BackupArchive.encode(snapshot, password: nil)
        XCTAssertFalse(try BackupArchive.requiresPassword(plain))
        let recovered = try BackupArchive.decode(plain, password: nil)
        XCTAssertTrue(recovered.credentials.isEmpty)
        var damaged = plain
        damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try BackupArchive.decode(damaged, password: nil))
        XCTAssertThrowsError(try BackupArchive.decode(plain + Data([0]), password: nil))
        XCTAssertThrowsError(try BackupArchive.decode(Data(plain.prefix(11)), password: nil))
        XCTAssertThrowsError(try BackupArchive.encode(snapshot, password: "short"))
        let protected = try BackupArchive.encode(snapshot, password: "fixture-password")
        let headerSize = protected[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        let header = try JSONDecoder().decode(BackupArchive.Header.self, from: protected[12..<(12 + headerSize)])
        func corrupt(_ changed: BackupArchive.Header) throws -> Data {
            let bytes = try JSONEncoder().encode(changed)
            let size = UInt32(bytes.count)
            return Data(protected.prefix(8)) + Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + bytes + protected.dropFirst(12 + headerSize)
        }
        for changed in [
            BackupArchive.Header(version: 99, protection: header.protection, payloadLength: header.payloadLength, kdf: header.kdf, salt: header.salt, iterations: header.iterations, sha256: nil),
            BackupArchive.Header(version: 1, protection: "unknown", payloadLength: header.payloadLength, kdf: header.kdf, salt: header.salt, iterations: header.iterations, sha256: nil),
            BackupArchive.Header(version: 1, protection: "password", payloadLength: header.payloadLength, kdf: header.kdf, salt: header.salt, iterations: UInt32.max, sha256: nil),
            BackupArchive.Header(version: 1, protection: "none", payloadLength: header.payloadLength, kdf: header.kdf, salt: header.salt, iterations: header.iterations, sha256: nil)
        ] {
            XCTAssertThrowsError(try BackupArchive.requiresPassword(corrupt(changed)))
            XCTAssertThrowsError(try BackupArchive.decode(corrupt(changed), password: "fixture-password"))
        }
    }

    @MainActor
    func testBackupFailsIfAnyStoredFileCannotBeDecrypted() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = p8File()
        let key = SymmetricKey(size: .bits256)
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                 password: nil, confirmUnknownTeam: true, key: key,
                                 p8: P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil))
        XCTAssertThrowsError(try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256)))
        let record = try XCTUnwrap(vault.records().first)
        record.name = "tampered"
        XCTAssertThrowsError(try BackupSnapshot.capture(vault: vault, key: key))
    }

    @MainActor
    func testQuarantineMovesOnlyUnreadableDataAndKeepsItsAADSoBackupRunsAgain() throws {
        let (vault, app) = try makeIsolatedVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory.deletingLastPathComponent()) }
        let key = SymmetricKey(size: .bits256)
        let cer = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        try vault.importFile(cer, parsed: CredentialParser.parse(cer.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: false, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        try vault.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let management = VaultManagement(vault: vault)
        try management.saveNote("kept note", app: app, key: key)
        let broken = try XCTUnwrap(vault.records().first { $0.fileExtension == "cer" })
        let brokenBlob = broken.blobID
        let aad = try broken.authenticatedData()
        var corrupted = try Data(contentsOf: vault.blobs.file(brokenBlob))
        corrupted[corrupted.count - 1] ^= 0xFF
        try corrupted.write(to: vault.blobs.file(brokenBlob))
        XCTAssertThrowsError(try BackupSnapshot.capture(vault: vault, key: key))

        XCTAssertEqual(try management.quarantineUnreadable(key: key), 1)
        XCTAssertEqual(try vault.records().map(\.fileExtension), ["mobileprovision"])
        XCTAssertEqual(try management.readNote(app, key: key), "kept note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.blobs.file(brokenBlob).path))
        let quarantine = vault.blobs.directory.deletingLastPathComponent().appendingPathComponent("Quarantine")
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(brokenBlob.uuidString + ".blob")), corrupted)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(brokenBlob.uuidString + ".aad")), aad)
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).credentials.count, 1)
        XCTAssertEqual(try management.quarantineUnreadable(key: key), 0)
    }
}
