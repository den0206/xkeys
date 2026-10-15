import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
@testable import AppMate

final class AppMateTests: XCTestCase {
    @MainActor
    func testTargetsGroupExistingAppsAndRouteProfilesWithoutChangingCredentials() throws {
        let (vault, root, child, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let profile = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
        let parsed = try CredentialParser.parse(profile.data, extension: "mobileprovision")
        // The fixture's profile belongs to root; use that existing target as the extension.
        try AppCatalog(context: vault.context).setParent(child.id, for: root, name: root.name, platform: root.platform)
        let id = try vault.importFile(profile, parsed: parsed, app: root, password: nil, confirmUnknownTeam: false, key: key)
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        XCTAssertEqual(child.targets.count, 2)
        XCTAssertEqual(child.target(forProfileBundleID: root.bundleID)?.id, root.id)
        XCTAssertNil(child.target(forProfileBundleID: "com.example.unregistered"))
        XCTAssertNil(child.target(forProfileBundleID: "*"))
        XCTAssertTrue(CredentialSearch.includes(record, scope: .app(child.id), app: child, query: "", type: .all, showReplaced: false, at: .now))
        XCTAssertFalse(record.isVisible(in: child))
        XCTAssertThrowsError(try AppCatalog(context: vault.context).setParent(root.id, for: child, name: child.name, platform: child.platform))
        XCTAssertThrowsError(try AppCatalog(context: vault.context).setParent(other.id, for: root, name: root.name, platform: root.platform))
        let aad = try record.authenticatedData()
        try AppCatalog(context: vault.context).setParent(nil, for: root, name: root.name, platform: root.platform)
        XCTAssertEqual(try record.authenticatedData(), aad)
        XCTAssertEqual(try vault.read(record, key: key).original, profile.data)
    }

    @MainActor
    func testTargetRegistrationAndBackupRelationshipsRoundTrip() throws {
        let (vault, root, _, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let catalog = AppCatalog(context: vault.context)
        let teamID = try XCTUnwrap(root.team?.id)
        let id = try catalog.addApp(name: "Share", bundleID: "com.example.AppMate.fixture.share", platform: "iOS", teamID: teamID, parentAppID: root.id)
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
        _ = try BackupRestore(vault: destination).merge(plan, choices: choices, key: key)
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
            let invalid = BackupSnapshot(version: 3, createdAt: source.createdAt, appVersion: source.appVersion,
                                         teams: source.teams, apps: apps, credentials: source.credentials)
            XCTAssertThrowsError(try invalid.validate())
        }
        let nestedApps = source.apps.map { value -> BackupSnapshot.App in
            var value = value
            if value.id == root.id { value.parentAppID = child.id }
            if value.id == child.id { value.parentAppID = root.id }
            return value
        }
        XCTAssertThrowsError(try BackupSnapshot(version: 3, createdAt: source.createdAt, appVersion: source.appVersion,
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
        let childDeletedAt = child.deletedAt
        try management.trash(root, key: key)
        try management.restore(root)
        XCTAssertEqual(child.deletedAt, childDeletedAt)
        try management.trash(root, key: key)
        try management.purge(records: [], apps: [root], key: key)
        XCTAssertNil(child.parentAppID)
        try management.restore(child)
        XCTAssertNil(child.deletedAt)
        _ = try BackupSnapshot.capture(vault: vault, key: key)
    }

    @MainActor
    func testP8ImportsWithoutUnknownTeamConfirmation() throws {
        let (vault, app, sibling, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = p8File()
        let parsed = try CredentialParser.parse(file.data, extension: "p8")
        XCTAssertNil(parsed.teamID)
        let metadata = P8Metadata(purpose: .appStoreConnect, keyID: "DUMMYKEY01", issuerID: UUID().uuidString)
        XCTAssertThrowsError(try vault.validate(file: file, parsed: parsed, app: app, confirmUnknownTeam: false))
        let id = try vault.importFile(file, parsed: parsed, app: app, password: nil,
                                      confirmUnknownTeam: false, key: SymmetricKey(size: .bits256), p8: metadata)
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        XCTAssertTrue(record.isVisible(in: app))
        XCTAssertTrue(record.isVisible(in: sibling))
        XCTAssertFalse(record.isVisible(in: other))
        let certificate = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let unidentified = ParsedCredential(name: "Unknown Team", kind: "証明書", teamID: nil, bundleID: nil, expiresAt: nil)
        XCTAssertThrowsError(try vault.validate(file: certificate,
                                               parsed: unidentified,
                                               app: app, confirmUnknownTeam: false)) { error in
            guard case VaultError.confirmTeam = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    func testCatalogAndCredentialWritesPreserveOtherPendingChanges() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
        let oldFile = p8File()
        let oldID = try vault.importFile(oldFile, parsed: CredentialParser.parse(oldFile.data, extension: "p8"), app: app,
                                         password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let newFile = p8File()
        let parsed = try CredentialParser.parse(newFile.data, extension: "p8")
        try vault.importFile(newFile, parsed: parsed, app: app, password: nil, confirmUnknownTeam: true,
                             key: key, p8: metadata, replacingID: oldID, confirmReplacement: true)
        let old = try XCTUnwrap(vault.records().first { $0.id == oldID })
        let replacement = old.replacedByID
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).sorted()
        let history = try vault.context.fetchCount(FetchDescriptor<BackupChange>())
        let teamID = try XCTUnwrap(app.team?.id)
        app.name = "pending edit"
        let catalog = AppCatalog(context: vault.context)
        let extra = p8File()
        for operation: () throws -> Void in [
            { _ = try catalog.addTeam(name: "Extra", teamID: "EXTRATEAM1") },
            { _ = try catalog.addApp(name: "Extra", bundleID: "com.example.extra", platform: "iOS", teamID: teamID) },
            { _ = try vault.importFile(extra, parsed: CredentialParser.parse(extra.data, extension: "p8"), app: app,
                                      password: nil, confirmUnknownTeam: true, key: key, p8: metadata) },
            { try vault.restoreToList(old, key: key) }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case RestoreError.pendingChanges = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(vault.context.hasChanges)
            XCTAssertEqual(app.name, "pending edit")
        }
        XCTAssertEqual(old.replacedByID, replacement)
        XCTAssertEqual(try vault.records().count, 2)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).sorted(), files)
        vault.context.rollback()
    }

    @MainActor
    func testV1BackupRejectsIconFieldsAndAcceptsLegacyApps() throws {
        let (vault, _, _, _) = try makeVault()
        let captured = try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256))
        var legacy = try editing(captured) { json in
            json["version"] = 1
            json.removeValue(forKey: "preferences")
        }
        XCTAssertNoThrow(try legacy.validate())
        for field in ["iconColor", "iconImage"] {
            let invalid = try editing(legacy) { json in
                var apps = json["apps"] as! [[String: Any]]
                apps[0][field] = field == "iconColor" ? "blue" : Data([1]).base64EncodedString()
                json["apps"] = apps
            }
            XCTAssertThrowsError(try invalid.validate())
            XCTAssertThrowsError(try BackupArchive.encode(invalid, password: nil))
        }
        legacy.version = 2
        XCTAssertNoThrow(try legacy.validate())
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
    func testCatalogRendersAtMinimumAndDefaultWindowSizes() async throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/ScreenChecks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 960, height: 640)] {
            let view = NSHostingView(rootView: CatalogView(container: vault.context.container, navigation: AppNavigation()).modelContainer(vault.context.container))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("catalog-\(Int(size.width)).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "catalog-\(Int(size.width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(png.count, 1000)
            window.close()
        }
    }

    @MainActor
    func testDesignReferenceScreensRenderWithIsolatedFixtures() async throws {
        let (vault, app, _, _) = try makeVault()
        app.name = "Tsumiki"
        app.platform = "iOS"
        app.iconColor = "orange"
        let team = try XCTUnwrap(app.team)
        for other in try vault.context.fetch(FetchDescriptor<ManagedApp>()) where other.id != app.id { vault.context.delete(other) }
        for other in try vault.context.fetch(FetchDescriptor<DeveloperTeam>()) where other.id != team.id { vault.context.delete(other) }
        team.name = "個人開発"
        for (name, bundle) in [("Pocket Ledger", "com.example.ledger"), ("Hikari Notes", "com.example.hikari")] {
            let item = ManagedApp(name: name, bundleID: bundle, platform: "iOS", team: team)
            item.iconColor = name == "Pocket Ledger" ? "green" : "blue"
            vault.context.insert(item)
        }
        let calendar = Calendar(identifier: .gregorian)
        let expires = calendar.date(byAdding: .day, value: 12, to: .now)!
        var sample: StoredCredential?
        for (index, item) in [("App Store 配布用", "mobileprovision"), ("開発用", "mobileprovision"), ("配布用", "p12"), ("開発用", "cer"), ("App Store Connect の鍵", "p8"), ("プッシュ通知の鍵", "p8")].enumerated() {
            let file = CredentialFile(data: Data("design-fixture-\(index)".utf8), name: "sample-\(index)." + item.1)
            let record = StoredCredential(file: file, parsed: ParsedCredential(name: item.0, kind: item.1 == "p8" ? "鍵" : item.1 == "mobileprovision" ? "プロファイル" : "証明書", teamID: team.teamID, bundleID: item.1 == "mobileprovision" ? app.bundleID : nil, expiresAt: index >= 4 ? nil : index % 2 == 0 ? expires : calendar.date(byAdding: .year, value: 1, to: .now)), app: app, team: team, savePassword: item.1 == "p12")
            record.keyPurpose = index == 4 ? P8Purpose.appStoreConnect.rawValue : index == 5 ? P8Purpose.apns.rawValue : nil
            vault.context.insert(record)
            if index == 2 { sample = record }
        }
        try vault.context.save()
        let container = vault.context.container
        let navigation = AppNavigation()
        navigation.scope = .app(app.id)
        let importURL = vault.blobs.directory.appendingPathComponent("design-sample.p8")
        try FileManager.default.createDirectory(at: vault.blobs.directory, withIntermediateDirectories: true)
        try p8File().data.write(to: importURL)
        let trashed = StoredCredential(file: CredentialFile(data: Data("design-trash".utf8), name: "previous.cer"), parsed: ParsedCredential(name: "配布用（2024年発行）", kind: "証明書", teamID: team.teamID, bundleID: nil, expiresAt: nil), app: app, team: team, savePassword: false)
        trashed.deletedAt = .now.addingTimeInterval(-7 * 86400)
        vault.context.insert(trashed)
        try vault.context.save()
        let screens: [(String, NSSize, AnyView)] = [
            ("main", NSSize(width: 1232, height: 752), AnyView(CatalogView(container: container, navigation: navigation).modelContainer(container))),
            ("main-narrow", NSSize(width: 960, height: 640), AnyView(CatalogView(container: container, navigation: navigation).modelContainer(container))),
            ("settings", NSSize(width: 852, height: 592), AnyView(AppSettingsView(container: container))),
            ("welcome", NSSize(width: 760, height: 518), AnyView(OnboardingView(onFinished: { _ in }))),
            ("onboarding-import", NSSize(width: 760, height: 518), AnyView(OnboardingView(step: 1, onFinished: { _ in }))),
            ("onboarding-security", NSSize(width: 760, height: 518), AnyView(OnboardingView(step: 2, onFinished: { _ in }))),
            ("add-app", NSSize(width: 560, height: 520), AnyView(RegistrationForm(container: container, teams: [team], initialTeam: team.id, isTeam: false, onSaved: { _ in }))),
            ("add-team", NSSize(width: 600, height: 320), AnyView(RegistrationForm(container: container, teams: [team], initialTeam: team.id, isTeam: true, onSaved: { _ in }))),
            ("backup", NSSize(width: 600, height: 620), AnyView(BackupView(container: container).modelContainer(container))),
            ("restore", NSSize(width: 640, height: 300), AnyView(BackupView(container: container, restoring: true))),
            ("ci-copy", NSSize(width: 600, height: 620), AnyView(CICopyView(vault: vault, record: try XCTUnwrap(sample)))),
            ("import", NSSize(width: 720, height: 620), AnyView(CredentialImportView(app: app, vault: vault, existing: [], onSaved: { _ in }))),
            ("p8-metadata", NSSize(width: 720, height: 620), AnyView(CredentialImportView(app: app, vault: vault, existing: [], initialSources: [importURL], onSaved: { _ in }))),
            ("delete", NSSize(width: 460, height: 380), AnyView(CredentialDeleteConfirmation(record: try XCTUnwrap(sample), onDelete: {}))),
            ("trash", NSSize(width: 996, height: 700), AnyView(TrashView(vault: vault)))
        ]
        for (name, size, screen) in screens {
            let view = NSHostingView(rootView: screen.modelContainer(container).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(png.count, 1000, name)
            window.close()
        }
    }

    @MainActor
    func testAppIconSurvivesProtectedBackupAndRestoreAndOlderBackups() throws {
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
        _ = try restore.merge(plan, choices: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) }), key: key)
        XCTAssertEqual(app.iconImage, originalIcon)
        XCTAssertEqual(app.iconColor, "blue")
        let old = try editing(snapshot) { json in
            var apps = json["apps"] as! [[String: Any]]
            for index in apps.indices { apps[index].removeValue(forKey: "iconColor"); apps[index].removeValue(forKey: "iconImage") }
            json["apps"] = apps
        }
        XCTAssertTrue(old.apps.allSatisfy { $0.iconColor == nil && $0.iconImage == nil })
        let invalid = try editing(snapshot) { json in
            var apps = json["apps"] as! [[String: Any]]
            apps[0]["iconImage"] = Data(repeating: 0, count: 1_048_577).base64EncodedString()
            json["apps"] = apps
        }
        XCTAssertThrowsError(try invalid.validate())
    }

    func testBackupReminderOnlyQueuesOncePerPeriodAndCanRescheduleBeforeDelivery() throws {
        let now = Date.now
        let period = UUID()
        let old = now.addingTimeInterval(-10 * 86400)
        let first = try XCTUnwrap(NotificationPlanner.reminder(period: period, oldest: old, days: 7, queuedPeriod: nil, queuedAt: nil, now: now))
        XCTAssertEqual(first.date, now.addingTimeInterval(2))
        XCTAssertNil(NotificationPlanner.reminder(period: period, oldest: old, days: 7, queuedPeriod: period, queuedAt: now.addingTimeInterval(-1), now: now))
        let future = try XCTUnwrap(NotificationPlanner.reminder(period: period, oldest: now, days: 14, queuedPeriod: period, queuedAt: now.addingTimeInterval(7 * 86400), now: now))
        XCTAssertGreaterThan(future.date, now.addingTimeInterval(13 * 86400))
        XCTAssertNotNil(NotificationPlanner.reminder(period: UUID(), oldest: old, days: 7, queuedPeriod: period, queuedAt: now.addingTimeInterval(-1), now: now))
        XCTAssertNil(NotificationPlanner.reminder(period: period, oldest: old, days: 0, queuedPeriod: nil, queuedAt: nil, now: now))
    }

    @MainActor
    func testAutomaticPruneRequiresDeletionAgeAndNeverRemovesActiveExpiredCredentials() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let now = Date.now
        let parsed = ParsedCredential(name: "Expired but active", kind: "Certificate", teamID: nil, bundleID: nil, expiresAt: now.addingTimeInterval(-100 * 86400))
        _ = try vault.importFile(file, parsed: parsed, app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        let manager = VaultManagement(vault: vault)
        try manager.pruneExpired()
        XCTAssertEqual(try vault.records().count, 1)
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        try manager.trash(record, key: key, at: now.addingTimeInterval(-29 * 86400))
        try manager.purge(records: [record], apps: [], at: now, expiredOnly: true)
        XCTAssertEqual(try vault.records().count, 1)
        try manager.change { record.deletedAt = now.addingTimeInterval(-30 * 86400) }
        try manager.purge(records: [record], apps: [], at: now, expiredOnly: true)
        XCTAssertTrue(try vault.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.blobs.file(record.id).path))
        XCTAssertEqual(try fixture("cer"), file.data)
    }

    @MainActor
    func testAutomaticPruneDefersAuthenticatedHistoryAndPreservesReplacementBytes() async throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let old = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let renewed = CredentialFile(data: try fixture("cer", name: "renewed"), name: "renewed.cer")
        let next = try vault.importFile(renewed, parsed: CredentialParser.parse(renewed.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key, replacingID: old, confirmReplacement: true)
        let record = try XCTUnwrap(vault.records().first { $0.id == old })
        let manager = VaultManagement(vault: vault)
        try manager.trash(record, key: key, at: .now.addingTimeInterval(-31 * 86400))
        XCTAssertThrowsError(try manager.pruneExpired())
        let cancelled = VaultAccess(keyProvider: { _, _ in throw VaultError.cancelled })
        do { try await cancelled.withKey(reason: "test", allowCreation: false, vault: vault) { _ in XCTFail("Cancelled") }; XCTFail("Expected cancel") } catch {}
        XCTAssertEqual(try vault.records().count, 2)
        let access = VaultAccess(keyProvider: { _, _ in key })
        try await access.withKey(reason: "test", allowCreation: false, vault: vault) { _ in }
        let survivor = try XCTUnwrap(vault.records().first { $0.id == next })
        XCTAssertNil(survivor.replacesCredentialID)
        XCTAssertEqual(try vault.read(survivor, key: key).original, renewed.data)
        XCTAssertEqual(try vault.records().count, 1)
    }

    @MainActor
    func testAutomaticPruneRetainsDeletedParentWithRecentOrUndeletedChild() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        let manager = VaultManagement(vault: vault)
        try manager.change { app.deletedAt = .now.addingTimeInterval(-31 * 86400) }
        try manager.pruneExpired()
        XCTAssertNotNil(app.modelContext)
        XCTAssertEqual(try vault.records().count, 1)
        try manager.change { record.deletedAt = .now.addingTimeInterval(-7 * 86400) }
        try manager.pruneExpired()
        XCTAssertNotNil(app.modelContext)
        XCTAssertEqual(try vault.records().count, 1)
    }


    @MainActor
    func testEncryptedNotesSurviveBackupMergeAndOrphanRecovery() throws {
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
        _ = try restore.merge(plan, choices: choices, key: targetKey)
        let restoredApp = try XCTUnwrap(target.context.fetch(FetchDescriptor<ManagedApp>()).first { $0.bundleID == app.bundleID && $0.team?.teamID == app.team?.teamID })
        XCTAssertEqual(try VaultManagement(vault: target).readNote(restoredApp, key: targetKey), "App secret note")
        XCTAssertEqual(try target.read(XCTUnwrap(target.records().first), key: targetKey).note, "Credential secret note")
    }

    @MainActor
    func testAppTrashRetainsSharedKeysAndRestoresOnlyItsOwnDeletedProfiles() throws {
        let (vault, app, sibling, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let cert = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(cert, parsed: CredentialParser.parse(cert.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
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
    func testTrashPurgeRemovesOwnedBytesAfterCommitButKeepsTeamSharedBytes() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let manager = VaultManagement(vault: vault)
        try manager.saveNote("private note", app: app, key: key)
        let noteID = try XCTUnwrap(app.noteBlobID)
        try manager.trash(app, key: key, at: .now.addingTimeInterval(-31 * 86400))
        try manager.purge(records: [], apps: [app], expiredOnly: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.blobs.file(noteID).path))
        XCTAssertEqual(try vault.records().count, 1)
        XCTAssertEqual(try vault.read(XCTUnwrap(vault.records().first), key: key).original, file.data)
    }

    @MainActor
    func testRevocationAndDeletionAreExcludedFromNotificationsAndSearch() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        try VaultManagement(vault: vault).setRevoked(record, key: key)
        XCTAssertEqual(record.displayState(at: .now), .revoked)
        XCTAssertEqual(MenuBarSummary(records: [record], at: .now).expired, 0)
        try VaultManagement(vault: vault).trash(record, key: key)
        XCTAssertFalse(CredentialSearch.includes(record, scope: .all, app: nil, query: "sample", type: .all, showReplaced: true, at: .now))
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertNotNil(snapshot.credentials.first?.deletedAt)
        XCTAssertNotNil(snapshot.credentials.first?.revokedAt)
    }

    func testNotificationDatesUseLocalCalendarAndNeverSchedulePastOrAfterExpiry() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let expiry = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-15T23:00:00+09:00"))
        let now = expiry.addingTimeInterval(-40 * 86400)
        let id = UUID()
        let plans = NotificationPlanner.expiry(id: id, expiresAt: expiry, days: [30, 7, 1, 0], now: now, calendar: calendar)
        XCTAssertEqual(plans.count, 4)
        XCTAssertEqual(Set(plans.map(\.id)).count, 4)
        XCTAssertTrue(plans.allSatisfy { calendar.component(.hour, from: $0.date) == 9 && $0.date <= expiry })
        let early = calendar.startOfDay(for: expiry).addingTimeInterval(3600)
        XCTAssertEqual(NotificationPlanner.expiry(id: id, expiresAt: early, days: [0], now: now, calendar: calendar).first?.date, early)
        XCTAssertTrue(NotificationPlanner.expiry(id: id, expiresAt: expiry, days: [30, 7, 1, 0], now: expiry, calendar: calendar).isEmpty)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let dst = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T23:00:00-08:00"))
        XCTAssertTrue(NotificationPlanner.expiry(id: id, expiresAt: dst, days: [1, 0], now: now, calendar: calendar).allSatisfy { calendar.component(.hour, from: $0.date) == 9 })
    }

    @MainActor
    func testPreferencesAreStableValidatedAndIncludedInRestoreConflicts() throws {
        let (vault, _, _, _) = try makeVault()
        XCTAssertEqual(try PreferencesStore.read(in: vault.context), try PreferencesStore.read(in: vault.context))
        var prefs = AppPreferences()
        prefs.showMenuBar = false
        prefs.backupReminderDays = nil
        try PreferencesStore.save(prefs, in: vault.context)
        let key = SymmetricKey(size: .bits256)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertEqual(snapshot.preferences, prefs)
        XCTAssertEqual(snapshot.version, 3)
        var downgraded = snapshot; downgraded.version = 1
        XCTAssertThrowsError(try downgraded.validate())
        let (other, _, _, _) = try makeVault()
        let restore = BackupRestore(vault: other)
        let plan = try restore.prepare(snapshot, key: key)
        XCTAssertTrue(plan.conflicts.contains { $0.kind == .preferences })
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        _ = try restore.merge(plan, choices: choices, key: key)
        XCTAssertEqual(try PreferencesStore.read(in: other.context), prefs)
        prefs.templates[0].variable = "SECRET; rm -rf"
        XCTAssertThrowsError(try PreferencesStore.save(prefs, in: other.context))
        prefs = AppPreferences(); prefs.expirationDays = [-1]
        XCTAssertThrowsError(try prefs.validate())
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
    func testWholeReplaceRequiresVerifiedCurrentSafetyBackupAndRejectsStaleProof() throws {
        let (vault, _, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        try BackupHistory.bootstrap(in: vault.context)
        let current = try BackupSnapshot.capture(vault: vault, key: key)
        let empty = BackupSnapshot(version: 1, createdAt: .now, appVersion: "test", teams: [], apps: [], credentials: [])
        let restore = BackupRestore(vault: vault)
        let plan = try restore.prepare(empty, key: key)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString + ".appmatebackup")
        let archive = try BackupArchive.encode(current, password: nil)
        XCTAssertThrowsError(try SafetyBackup.export(Data([0]), password: nil, snapshot: current, to: url))
        let proof = try SafetyBackup.export(archive, password: nil, snapshot: current, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try restore.merge(plan, choices: [:], key: key, beforeCommit: { throw ValidationError.invalidFile }, safetyBackup: proof))
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<ManagedApp>()), 3)
        _ = try restore.merge(plan, choices: [:], key: key, safetyBackup: proof)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<ManagedApp>()), 0)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<DeveloperTeam>()), 0)
        XCTAssertThrowsError(try restore.merge(plan, choices: [:], key: key, safetyBackup: proof))
    }

    func testFolderImportDoesNotFollowSymlinksOrDuplicateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.cer")
        try Data([1]).write(to: file)
        try Data([2]).write(to: root.appendingPathComponent("ignore.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.cer"), withDestinationURL: file)
        XCTAssertEqual(try ImportSources.collect([root, file]).map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
        XCTAssertThrowsError(try ImportSources.collect([root.appendingPathComponent("linked.cer")]))
    }

    @MainActor
    func testClipboardCleanupOnlyClearsOurUnchangedCopy() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); SecretClipboard.cleanup?.cancel() }
        try SecretClipboard.copy("fixture-secret", to: pasteboard)
        let count = pasteboard.changeCount
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        pasteboard.clearContents(); pasteboard.setString("new-user-copy", forType: .string)
        SecretClipboard.clear(pasteboard, ifUnchanged: count)
        XCTAssertEqual(pasteboard.string(forType: .string), "new-user-copy")
        try SecretClipboard.copy("fixture-secret", to: pasteboard)
        SecretClipboard.clear(pasteboard, ifUnchanged: pasteboard.changeCount)
        XCTAssertNil(pasteboard.string(forType: .string))
    }


    @MainActor
    func testSearchUsesMetadataAcrossTeamAppsWithoutOpeningSecrets() throws {
        let (_, first, sibling, other) = try makeVault()
        first.name = "写真カメラ"
        let record = StoredCredential(file: CredentialFile(data: Data("private-key-byte-sentinel".utf8), name: "AuthKey_FIXTURE.p8"),
                                      parsed: ParsedCredential(name: "開発用キー", kind: "APNs", teamID: nil, bundleID: nil, expiresAt: nil),
                                      app: first, team: try XCTUnwrap(first.team), savePassword: false,
                                      p8: P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil))
        for query in ["", "  \n　", "dummykey01", "AUTHKEY_fixture", "Fixture Team", "TESTTEAM01", "写真", sibling.bundleID,
                      "写真 dummykey01", "TESTTEAM01　apns"] {
            XCTAssertTrue(CredentialSearch.matches(record, query: query), query)
        }
        for query in ["private-key-byte-sentinel", "ForeignOrganization", "TESTTEAM02", "写真 missing-value", other.id.uuidString] {
            XCTAssertFalse(CredentialSearch.matches(record, query: query), query)
        }
        XCTAssertTrue(record.isVisible(in: sibling))
        XCTAssertFalse(record.isVisible(in: other))
    }

    @MainActor
    func testTypeFilterDistinguishesCertificateIdentityKeyAndBothProfiles() throws {
        let (_, app, _, _) = try makeVault()
        let cases: [(String, CredentialTypeFilter)] = [("p8", .key), ("cer", .certificate), ("p12", .identity),
                                                      ("mobileprovision", .profile), ("provisionprofile", .profile)]
        for (ext, expected) in cases {
            let record = StoredCredential(file: CredentialFile(data: Data([1]), name: "fixture." + ext.uppercased()),
                                          parsed: ParsedCredential(name: "Fixture", kind: "Fixture", teamID: nil, bundleID: nil, expiresAt: nil),
                                          app: app, team: try XCTUnwrap(app.team), savePassword: false)
            for filter in CredentialTypeFilter.allCases {
                XCTAssertEqual(filter.matches(record), filter == .all || filter == expected)
            }
        }
    }

    @MainActor
    func testGlobalSearchOverridesAppScopeButPreservesTypeAndReplacementFilters() throws {
        let (_, first, _, other) = try makeVault()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let record = StoredCredential(file: CredentialFile(data: Data([1]), name: "other.cer"),
                                      parsed: ParsedCredential(name: "Other Certificate", kind: "証明書", teamID: nil, bundleID: nil, expiresAt: now),
                                      app: other, team: try XCTUnwrap(other.team), savePassword: false)
        func includes(_ query: String, type: CredentialTypeFilter = .all, old: Bool = false, scope: CredentialScope? = nil) -> Bool {
            CredentialSearch.includes(record, scope: scope ?? .app(first.id), app: first, query: query, type: type, showReplaced: old, at: now)
        }
        XCTAssertFalse(includes(""))
        XCTAssertFalse(includes("　 \n"))
        XCTAssertTrue(includes("testteam02"))
        XCTAssertTrue(includes("other", type: .certificate))
        XCTAssertFalse(includes("other", type: .identity))
        XCTAssertTrue(includes("", scope: .expired))
        XCTAssertFalse(includes("", scope: .expiring))
        record.replacedByID = UUID()
        XCTAssertFalse(includes("other"))
        XCTAssertTrue(includes("other", old: true))
    }

    @MainActor
    func testMenuSummaryCountsSharedCredentialsOnceAndExcludesReplacedItems() throws {
        let (_, app, sibling, _) = try makeVault()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        func record(_ expiry: Date?) throws -> StoredCredential {
            StoredCredential(file: CredentialFile(data: Data(UUID().uuidString.utf8), name: "fixture.cer"),
                             parsed: ParsedCredential(name: "Fixture", kind: "証明書", teamID: nil, bundleID: nil, expiresAt: expiry),
                             app: app, team: try XCTUnwrap(app.team), savePassword: false)
        }
        let expired = try record(now), soon = try record(now.addingTimeInterval(30 * 86400)), noExpiry = try record(nil)
        let replaced = try record(now)
        replaced.replacedByID = UUID()
        XCTAssertTrue(expired.isVisible(in: app))
        XCTAssertTrue(expired.isVisible(in: sibling))
        let summary = MenuBarSummary(records: [expired, soon, noExpiry, replaced], at: now)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.expired, 1)
        XCTAssertEqual(summary.expiring, 1)
        XCTAssertEqual(summary.attentionCount, 2)
        let later = MenuBarSummary(records: [soon], at: now.addingTimeInterval(30 * 86400))
        XCTAssertEqual(later.expired, 1)
        XCTAssertEqual(later.expiring, 0)
    }


    @MainActor
    private func backupHistory(_ context: ModelContext) throws -> BackupHistorySummary {
        BackupHistorySummary(changes: try context.fetch(FetchDescriptor<BackupChange>()),
                             checkpoint: try context.fetch(FetchDescriptor<BackupCheckpoint>()).first)
    }

    @MainActor
    func testHistoryTracksOnlyCommittedProductChangesAndNotIndividualExports() throws {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        try BackupHistory.bootstrap(in: context)
        XCTAssertEqual(try backupHistory(context).pendingCount, 0)
        let catalog = AppCatalog(context: context)
        let team = try catalog.addTeam(name: "Team", teamID: "TESTTEAM01")
        let appID = try catalog.addApp(name: "App", bundleID: "com.example.fixture", platform: "macOS", teamID: team)
        XCTAssertEqual(try backupHistory(context).pendingCount, 2)
        XCTAssertThrowsError(try catalog.addTeam(name: "Duplicate", teamID: "TESTTEAM01"))
        XCTAssertEqual(try backupHistory(context).pendingCount, 2)
        let app = try XCTUnwrap(context.fetch(FetchDescriptor<ManagedApp>()).first { $0.id == appID })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = CredentialVault(context: context, blobs: EncryptedBlobStore(directory: directory))
        let key = SymmetricKey(size: .bits256), metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
        let file = p8File(), next = p8File()
        let oldID = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                         password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        XCTAssertEqual(try backupHistory(context).pendingCount, 3)
        let old = try XCTUnwrap(vault.records().first { $0.id == oldID })
        try vault.export(old, to: directory.appendingPathComponent("exported.p8"), key: key)
        _ = try vault.read(old, key: key)
        XCTAssertEqual(try backupHistory(context).pendingCount, 3)
        let newID = try vault.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                         password: nil, confirmUnknownTeam: true, key: key, p8: metadata,
                                         replacingID: oldID, confirmReplacement: true)
        XCTAssertEqual(old.replacedByID, newID)
        XCTAssertEqual(try backupHistory(context).pendingCount, 4)
        try vault.restoreToList(old, key: key)
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        let failed = p8File()
        XCTAssertThrowsError(try vault.importFile(failed, parsed: CredentialParser.parse(failed.data, extension: "p8"), app: app,
                                                  password: nil, confirmUnknownTeam: true, key: key, p8: metadata,
                                                  beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        XCTAssertEqual(try vault.records().count, 2)
        let restore = BackupRestore(vault: vault)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        _ = try restore.merge(restore.prepare(snapshot, key: key), choices: [:], key: key)
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        let changed = try editing(snapshot) { json in
            var teams = json["teams"] as! [[String: Any]]
            teams[0]["name"] = "Restored Team"
            json["teams"] = teams
        }
        let plan = try restore.prepare(changed, key: key)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        XCTAssertThrowsError(try restore.merge(plan, choices: choices, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        _ = try restore.merge(plan, choices: choices, key: key)
        XCTAssertEqual(try backupHistory(context).pendingCount, 6)
    }

    @MainActor
    func testFullBackupClearsCapturedChangesAndKeepsChangesAddedDuringCreation() throws {
        let (vault, _, _, _) = try makeVault()
        let context = vault.context
        try BackupHistory.bootstrap(in: context)
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256))
        let watermark = try BackupHistory.watermark(in: context, capturedAt: snapshot.createdAt)
        let archive = try BackupArchive.encode(snapshot, password: nil)
        _ = try AppCatalog(context: context).addTeam(name: "During backup", teamID: "TESTTEAM03")
        let later = try XCTUnwrap(context.fetch(FetchDescriptor<BackupChange>()).first { !watermark.changeIDs.contains($0.id) })
        later.createdAt = snapshot.createdAt
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.appmatebackup")
        XCTAssertTrue(try BackupHistory.export(archive, to: url, covering: watermark, in: context))
        let summary = try backupHistory(context)
        XCTAssertEqual(summary.pendingCount, 1)
        XCTAssertEqual(summary.oldestChange, snapshot.createdAt)
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
        XCTAssertEqual(try backupHistory(context).pendingCount, 0)
        _ = try AppCatalog(context: context).addTeam(name: "After both snapshots", teamID: "TESTTEAM04")
        try BackupHistory.complete(older, in: context, at: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(try backupHistory(context).pendingCount, 1)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.appmatebackup")
        let sentinel = Data("existing-file".utf8)
        try sentinel.write(to: existing)
        XCTAssertThrowsError(try BackupHistory.export(archive, to: existing, covering: watermark, in: context))
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        XCTAssertThrowsError(try BackupHistory.complete(watermark, in: context, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        XCTAssertNil(try backupHistory(context).lastCompletedAt)
        app.name = "Another operation still pending"
        let saved = directory.appendingPathComponent("saved.appmatebackup")
        XCTAssertFalse(try BackupHistory.export(archive, to: saved, covering: watermark, in: context))
        XCTAssertEqual(try BackupArchive.decode(Data(contentsOf: saved), password: nil).apps.count, 3)
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(app.name, "Another operation still pending")
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        context.rollback()
        XCTAssertTrue(try BackupHistory.export(archive, to: directory.appendingPathComponent("retry.appmatebackup"), covering: watermark, in: context))
        XCTAssertEqual(try backupHistory(context).pendingCount, 0)
    }

    @MainActor
    func testHistoryReopensWithoutRecountingExistingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
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
            XCTAssertEqual(try backupHistory(context).pendingCount, 3)
            try BackupHistory.bootstrap(in: context)
            XCTAssertEqual(try backupHistory(context).pendingCount, 3)
            let watermark = try BackupHistory.watermark(in: context, capturedAt: savedAt)
            try BackupHistory.complete(watermark, in: context, at: savedAt)
            _ = try AppCatalog(context: context).addTeam(name: "After backup", teamID: "TESTTEAM02")
        }
        let reopened = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
        let context = ModelContext(reopened)
        try BackupHistory.bootstrap(in: context)
        XCTAssertEqual(try backupHistory(context).pendingCount, 1)
        XCTAssertEqual(try backupHistory(context).lastCompletedAt, savedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BackupCheckpoint>()), 1)
    }


    @MainActor
    func testExistingVaultMigratesBlobReferenceAndKeepsOldEncryptedBytes() throws {
        let (source, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let id = try source.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app,
                                       password: nil, confirmUnknownTeam: true, key: key)
        let dto = try XCTUnwrap(BackupSnapshot.capture(vault: source, key: key).credentials.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        let blobs = EncryptedBlobStore(directory: directory.appendingPathComponent("blobs"))
        try FileManager.default.createDirectory(at: blobs.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.blobs.file(id), to: blobs.file(id))
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("legacy.store"))
        try autoreleasepool {
            let schema = Schema([DeveloperTeam.self, ManagedApp.self, BeforeRestoreSchema.StoredCredential.self])
            let legacy = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(legacy)
            let team = DeveloperTeam(name: "Fixture Team", teamID: "TESTTEAM01")
            team.id = dto.team
            let oldApp = ManagedApp(name: app.name, bundleID: app.bundleID, platform: app.platform, team: team)
            oldApp.id = app.id
            oldApp.createdAt = app.createdAt
            context.insert(oldApp)
            context.insert(BeforeRestoreSchema.StoredCredential(restoring: dto, team: team, app: nil))
            try context.save()
        }
        try autoreleasepool {
            let upgraded = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
            let vault = CredentialVault(context: ModelContext(upgraded), blobs: blobs)
            let record = try XCTUnwrap(vault.records().first)
            XCTAssertEqual(record.id, id)
            XCTAssertNil(record.blobID)
            XCTAssertEqual(try vault.read(record, key: key).original, file.data)
            let updated = try editing(BackupSnapshot.capture(vault: vault, key: key)) { json in
                var records = json["credentials"] as! [[String: Any]]
                records[0]["name"] = "Restored after migration"
                json["credentials"] = records
            }
            let service = BackupRestore(vault: vault)
            let plan = try service.prepare(updated, key: key)
            let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
            _ = try service.merge(plan, choices: choices, key: key)
            XCTAssertNotNil(record.blobID)
        }
        let reopened = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
        let vault = CredentialVault(context: ModelContext(reopened), blobs: blobs)
        let record = try XCTUnwrap(vault.records().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.name, "Restored after migration")
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        try vault.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.file(id).path))
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
    }

    private func editing(_ snapshot: BackupSnapshot, _ update: (inout [String: Any]) -> Void) throws -> BackupSnapshot {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        update(&json)
        return try JSONDecoder().decode(BackupSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @MainActor
    func testBackupRestoreToNewVaultKeepsIDsOriginalsPasswordsAndSharingAfterReopen() throws {
        let (source, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory) }
        let sourceKey = SymmetricKey(size: .bits256)
        let p12 = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        let p12ID = try source.importFile(p12, parsed: CredentialParser.parse(p12.data, extension: "p12", password: "fixture-only"), app: app,
                                          password: "fixture-only", confirmUnknownTeam: true, key: sourceKey)
        let profile = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
        let profileID = try source.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app,
                                              password: nil, confirmUnknownTeam: false, key: sourceKey)
        let first = p8File(), next = p8File()
        let metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
        let oldID = try source.importFile(first, parsed: CredentialParser.parse(first.data, extension: "p8"), app: app,
                                          password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        let nextID = try source.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                           password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata,
                                           replacingID: oldID, confirmReplacement: true)
        let backup = try BackupArchive.decode(BackupArchive.encode(BackupSnapshot.capture(vault: source, key: sourceKey), password: "fixture-backup-password"), password: "fixture-backup-password")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("restore.store"))
        let blobs = EncryptedBlobStore(directory: directory.appendingPathComponent("blobs"))
        let localKey = SymmetricKey(size: .bits256)
        try autoreleasepool {
            let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
            let vault = CredentialVault(context: ModelContext(container), blobs: blobs)
            let restore = BackupRestore(vault: vault)
            let plan = try restore.prepare(backup, key: localKey)
            XCTAssertEqual(plan.addedCount, 9)
            let result = try restore.merge(plan, choices: [:], key: localKey)
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
        let originalBlob = try XCTUnwrap(restoredP12.blobID)
        let copiedBlob = UUID()
        try FileManager.default.copyItem(at: blobs.file(originalBlob), to: blobs.file(copiedBlob))
        restoredP12.blobID = copiedBlob
        XCTAssertThrowsError(try vault.read(restoredP12, key: localKey))
        restoredP12.blobID = originalBlob
        try vault.context.save()
        let restoredProfile = try XCTUnwrap(records.first { $0.id == profileID })
        XCTAssertTrue(restoredProfile.isVisible(in: firstApp))
        XCTAssertFalse(restoredProfile.isVisible(in: sibling))
        let old = try XCTUnwrap(records.first { $0.id == oldID })
        let nextRecord = try XCTUnwrap(records.first { $0.id == nextID })
        XCTAssertEqual(old.replacedByID, nextID)
        XCTAssertEqual(nextRecord.replacesCredentialID, oldID)
        XCTAssertEqual(try vault.read(nextRecord, key: localKey).original, next.data)
        try vault.restoreToList(old, key: localKey)
        XCTAssertNil(old.replacedByID)
        try vault.recover()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blobs.directory.path).count, 4)
    }

    @MainActor
    func testRestoreInitialCommitFailureLeavesNoCatalogOrEncryptedFiles() throws {
        let (source, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory) }
        let sourceKey = SymmetricKey(size: .bits256), localKey = SymmetricKey(size: .bits256)
        let file = p8File()
        _ = try source.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                  password: nil, confirmUnknownTeam: true, key: sourceKey,
                                  p8: P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil))
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = CredentialVault(context: ModelContext(container), blobs: EncryptedBlobStore(directory: directory))
        let service = BackupRestore(vault: vault)
        let plan = try service.prepare(BackupSnapshot.capture(vault: source, key: sourceKey), key: localKey)
        XCTAssertThrowsError(try service.merge(plan, choices: [:], key: localKey, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertTrue(try vault.context.fetch(FetchDescriptor<DeveloperTeam>()).isEmpty)
        XCTAssertTrue(try vault.context.fetch(FetchDescriptor<ManagedApp>()).isEmpty)
        XCTAssertTrue(try vault.records().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertEqual(try service.merge(plan, choices: [:], key: localKey).added, 6)
        XCTAssertEqual(try vault.records().count, 1)
    }

    @MainActor
    func testRestoreConflictSelectionAndFailedCommitPreserveOriginalBlobs() throws {
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
        XCTAssertThrowsError(try service.merge(plan, choices: [:], key: key))
        let keep = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.current) })
        XCTAssertEqual(try service.merge(plan, choices: keep, key: key).updated, 0)
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).revision(), try baseline.revision())
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        let oldURL = vault.blobs.file(record.blobID ?? record.id)
        let oldBytes = try Data(contentsOf: oldURL)
        let oldFiles = try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path)
        let useBackup = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        XCTAssertThrowsError(try service.merge(plan, choices: useBackup, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).revision(), try baseline.revision())
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path)), Set(oldFiles))
        let updated = try service.merge(plan, choices: useBackup, key: key)
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
    func testRestoreRemapsNaturalIdentitiesAndReplacementReferences() throws {
        let (source, sourceApp, _, _) = try makeVault()
        let (target, targetApp, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory); try? FileManager.default.removeItem(at: target.blobs.directory) }
        let sourceKey = SymmetricKey(size: .bits256), targetKey = SymmetricKey(size: .bits256)
        let file = p8File(), renewed = p8File()
        let parsed = try CredentialParser.parse(file.data, extension: "p8")
        let metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
        let sourceOld = try source.importFile(file, parsed: parsed, app: sourceApp, password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        let targetOld = try target.importFile(file, parsed: parsed, app: targetApp, password: nil, confirmUnknownTeam: true, key: targetKey, p8: metadata)
        let newID = try source.importFile(renewed, parsed: CredentialParser.parse(renewed.data, extension: "p8"), app: sourceApp,
                                          password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata,
                                          replacingID: sourceOld, confirmReplacement: true)
        let service = BackupRestore(vault: target)
        let plan = try service.prepare(BackupSnapshot.capture(vault: source, key: sourceKey), key: targetKey)
        XCTAssertEqual(plan.addedCount, 1)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.kind == .credential ? RestoreChoice.backup : .current) })
        _ = try service.merge(plan, choices: choices, key: targetKey)
        let records = try target.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(records.contains { $0.id == sourceOld })
        let old = try XCTUnwrap(records.first { $0.id == targetOld })
        let next = try XCTUnwrap(records.first { $0.id == newID })
        XCTAssertEqual(old.replacedByID, next.id)
        XCTAssertEqual(next.replacesCredentialID, targetOld)
        XCTAssertEqual(next.team?.id, targetApp.team?.id)
        XCTAssertEqual(try target.read(next, key: targetKey).original, renewed.data)
        XCTAssertEqual(try target.context.fetch(FetchDescriptor<DeveloperTeam>()).count, 2)
        XCTAssertEqual(try target.context.fetch(FetchDescriptor<ManagedApp>()).count, 3)
    }

    @MainActor
    func testRestoreRejectsStalePreviewAndIdentityCollisionWithoutWrites() throws {
        let (vault, _, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let service = BackupRestore(vault: vault)
        let plan = try service.prepare(snapshot, key: key)
        _ = try AppCatalog(context: vault.context).addTeam(name: "Changed after preview", teamID: "TESTTEAM03")
        XCTAssertThrowsError(try service.merge(plan, choices: [:], key: key)) { error in
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
    func testRestoreRejectsMalformedScopeAndCyclicHistory() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256), metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
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
        let cycle = try editing(snapshot) { json in
            var records = json["credentials"] as! [[String: Any]]
            records[0]["replacesCredentialID"] = records[1]["id"]
            records[1]["replacesCredentialID"] = records[0]["id"]
            json["credentials"] = records
        }
        XCTAssertThrowsError(try cycle.validate())
        let badKey = try editing(snapshot) { json in
            var records = json["credentials"] as! [[String: Any]]
            records[0]["registrationKey"] = "untrusted-key"
            json["credentials"] = records
        }
        XCTAssertThrowsError(try badKey.validate())
    }

    func testBackupFileReaderUsesBoundedSizeWithoutWeakeningCredentialLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.appmatebackup")
        let bytes = Data(repeating: 42, count: CredentialParser.maximumBytes + 1)
        try bytes.write(to: url)
        XCTAssertThrowsError(try CredentialFile(url: url))
        XCTAssertEqual(try CredentialFile(url: url, maximumBytes: BackupArchive.maximumFileBytes).data, bytes)
        XCTAssertThrowsError(try CredentialFile(url: url, maximumBytes: 0))
        let alias = directory.appendingPathComponent("alias.appmatebackup")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        XCTAssertThrowsError(try CredentialFile(url: alias, maximumBytes: BackupArchive.maximumFileBytes))
    }


    @MainActor
    func testBackupPreservesCatalogOriginalsPasswordsAndReplacementHistory() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        let parsed = try CredentialParser.parse(file.data, extension: "p12", password: "fixture-only")
        let id = try vault.importFile(file, parsed: parsed, app: app, password: "fixture-only", confirmUnknownTeam: true, key: key)
        let first = p8File()
        let metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
        let old = try vault.importFile(first, parsed: CredentialParser.parse(first.data, extension: "p8"), app: app,
                                       password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let next = p8File()
        let replacement = try vault.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                               password: nil, confirmUnknownTeam: true, key: key, p8: metadata,
                                               replacingID: old, confirmReplacement: true)
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
        XCTAssertEqual(restored.credentials.first { $0.id == old }?.replacedByID, replacement)
        XCTAssertEqual(restored.credentials.first { $0.id == replacement }?.replacesCredentialID, old)
        XCTAssertThrowsError(try BackupArchive.decode(archive, password: "incorrect-password"))
        XCTAssertThrowsError(try BackupArchive.decode(archive, password: nil))
        var tampered = archive
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try BackupArchive.decode(tampered, password: secret))
        XCTAssertEqual(try vault.read(try XCTUnwrap(vault.records().first { $0.id == id }), key: key).original, file.data)
    }

    func testBackupV1FixtureAndRandomizedProtection() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "empty-v1", withExtension: "appmatebackup", subdirectory: "Fixtures"))
        let snapshot = try BackupArchive.decode(Data(contentsOf: url), password: nil)
        XCTAssertEqual(snapshot.createdAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(snapshot.appVersion, "fixture-v1")
        let first = try BackupArchive.encode(snapshot, password: "fixture-password")
        let second = try BackupArchive.encode(snapshot, password: "fixture-password")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try BackupArchive.decode(second, password: "fixture-password").appVersion, "fixture-v1")
        XCTAssertThrowsError(try BackupArchive.encode(snapshot, password: String(repeating: "あ", count: 400)))
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
                                 p8: P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil))
        XCTAssertThrowsError(try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256)))
        let record = try XCTUnwrap(vault.records().first)
        record.name = "tampered"
        XCTAssertThrowsError(try BackupSnapshot.capture(vault: vault, key: key))
    }

    func testPasswordEntryIsOnlyRequiredForPKCS12Files() {
        for name in ["sample.p12", "SAMPLE.P12"] {
            XCTAssertTrue(CredentialFile(data: Data(), name: name).requiresPasswordEntry)
        }
        for name in ["sample.cer", "sample.p8", "sample.mobileprovision", "sample.provisionprofile", "sample.p12.cer"] {
            XCTAssertFalse(CredentialFile(data: Data(), name: name).requiresPasswordEntry)
        }
    }
    @MainActor
    func testCredentialDisplayStateUsesExactExpiryBoundaries() throws {
        let (vault, first, _, _) = try makeVault()
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        let record = StoredCredential(file: file, parsed: parsed, app: first, team: try XCTUnwrap(first.team), savePassword: false)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        record.expiresAt = now
        XCTAssertEqual(record.displayState(at: now), .expired)
        record.expiresAt = now.addingTimeInterval(1)
        XCTAssertEqual(record.displayState(at: now), .withinDay)
        record.expiresAt = now.addingTimeInterval(86400)
        XCTAssertEqual(record.displayState(at: now), .expiring(1))
        record.expiresAt = now.addingTimeInterval(30 * 86400)
        XCTAssertEqual(record.displayState(at: now), .expiring(30))
        record.expiresAt = now.addingTimeInterval(30 * 86400 + 1)
        XCTAssertEqual(record.displayState(at: now), .valid)
        record.expiresAt = nil
        XCTAssertEqual(record.displayState(at: now), .stored)
        record.replacedByID = UUID()
        XCTAssertEqual(record.displayState(at: now), .replaced)
        XCTAssertTrue(CredentialDisplayState.withinDay.needsRenewal)
        XCTAssertFalse(CredentialDisplayState.expired.needsRenewal)
        _ = vault
    }

    private func p8File() -> CredentialFile {
        CredentialFile(data: Data(P256.Signing.PrivateKey().pemRepresentation.utf8), name: "fixture.p8")
    }

    @MainActor
    func testCertificateRenewalKeepsOldAndNewBytes() throws {
        let (vault, first, sibling, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let oldFile = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "renewed", withExtension: "cer", subdirectory: "Fixtures"))
        let newFile = try CredentialFile(url: url)
        let key = SymmetricKey(size: .bits256)
        let oldID = try vault.importFile(oldFile, parsed: CredentialParser.parse(oldFile.data, extension: "cer"), app: first,
                                         password: nil, confirmUnknownTeam: true, key: key)
        let newID = try vault.importFile(newFile, parsed: CredentialParser.parse(newFile.data, extension: "cer"), app: first,
                                         password: nil, confirmUnknownTeam: true, key: key, replacingID: oldID, confirmReplacement: true)
        let old = try XCTUnwrap(vault.records().first(where: { $0.id == oldID }))
        let new = try XCTUnwrap(vault.records().first(where: { $0.id == newID }))
        XCTAssertEqual(old.replacedByID, newID)
        XCTAssertTrue(new.isVisible(in: sibling))
        XCTAssertEqual(try vault.read(old, key: key).original, oldFile.data)
        XCTAssertEqual(try vault.read(new, key: key).original, newFile.data)
        XCTAssertNotEqual(old.fingerprint, new.fingerprint)
        XCTAssertNotEqual(old.expiresAt, new.expiresAt)
        try vault.recover()
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.blobs.file(oldID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.blobs.file(newID).path))
    }

    func testP8ParserRejectsNonPrivateAndMalformedKeys() throws {
        let file = p8File()
        let parsed = try CredentialParser.parse(file.data, extension: "p8")
        XCTAssertNil(parsed.expiresAt)
        XCTAssertNil(parsed.teamID)
        XCTAssertNotNil(parsed.fingerprint)
        XCTAssertThrowsError(try CredentialParser.parse(Data(P256.Signing.PrivateKey().publicKey.pemRepresentation.utf8), extension: "p8"))
        XCTAssertThrowsError(try CredentialParser.parse(Data(P384.Signing.PrivateKey().pemRepresentation.utf8), extension: "p8"))
        XCTAssertThrowsError(try CredentialParser.parse(file.data + file.data, extension: "p8"))
        XCTAssertThrowsError(try CredentialParser.parse(Data("-----BEGIN PRIVATE KEY-----\ninvalid\n-----END PRIVATE KEY-----".utf8), extension: "p8"))
    }

    func testP8MetadataRequiresIssuerOnlyForASC() throws {
        XCTAssertThrowsError(try P8Metadata(purpose: .appStoreConnect, keyID: "DUMMYKEY01", issuerID: nil).validated())
        XCTAssertThrowsError(try P8Metadata(purpose: .apns, keyID: "short", issuerID: nil).validated())
        let issuer = UUID()
        let asc = try P8Metadata(purpose: .appStoreConnect, keyID: " DUMMYKEY01 ", issuerID: issuer.uuidString).validated()
        XCTAssertEqual(asc.issuerID, issuer.uuidString.lowercased())
        for purpose in [P8Purpose.apns, .signInWithApple] {
            XCTAssertNil(try P8Metadata(purpose: purpose, keyID: "DUMMYKEY01", issuerID: "irrelevant").validated().issuerID)
        }
    }

    @MainActor
    func testP8VaultRequiresMetadataAndSharesEncryptedOriginal() throws {
        let (vault, first, sibling, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = p8File()
        let parsed = try CredentialParser.parse(file.data, extension: "p8")
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true, key: key))
        try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true, key: key,
                             p8: P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: "ignored"))
        let record = try XCTUnwrap(vault.records().first)
        XCTAssertEqual(record.keyID, "DUMMYKEY01")
        XCTAssertNil(record.issuerID)
        XCTAssertNil(record.expiresAt)
        XCTAssertTrue(record.isVisible(in: sibling))
        XCTAssertFalse(record.isVisible(in: other))
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        XCTAssertNil(try Data(contentsOf: vault.blobs.file(record.id)).range(of: file.data))
        record.keyID = "TAMPERED01"
        XCTAssertThrowsError(try vault.read(record, key: key))
    }

    @MainActor
    func testReplacementPreservesBothFilesAndCanRestoreOldToList() throws {
        let (vault, first, sibling, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let oldFile = p8File()
        let newFile = p8File()
        let key = SymmetricKey(size: .bits256)
        let metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
        let oldID = try vault.importFile(oldFile, parsed: CredentialParser.parse(oldFile.data, extension: "p8"), app: first,
                                         password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let parsed = try CredentialParser.parse(newFile.data, extension: "p8")
        XCTAssertThrowsError(try vault.importFile(newFile, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true,
                                                key: key, p8: metadata, replacingID: oldID))
        let newID = try vault.importFile(newFile, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true,
                                         key: key, p8: metadata, replacingID: oldID, confirmReplacement: true)
        let records = try vault.records()
        let old = try XCTUnwrap(records.first(where: { $0.id == oldID }))
        let new = try XCTUnwrap(records.first(where: { $0.id == newID }))
        XCTAssertEqual(old.replacedByID, newID)
        XCTAssertEqual(new.replacesCredentialID, oldID)
        XCTAssertTrue(new.isVisible(in: sibling))
        XCTAssertEqual(records.filter { $0.replacedByID == nil }.map(\.id), [newID])
        XCTAssertEqual(try vault.read(old, key: key).original, oldFile.data)
        XCTAssertEqual(try vault.read(new, key: key).original, newFile.data)
        let output = vault.blobs.directory.appendingPathComponent("old.p8")
        try vault.export(old, to: output, key: key)
        XCTAssertEqual(try Data(contentsOf: output), oldFile.data)
        try vault.restoreToList(old, key: key)
        XCTAssertNil(old.replacedByID)
        XCTAssertEqual(try vault.records().count, 2)
        XCTAssertEqual(try vault.read(old, key: key).original, oldFile.data)
    }

    @MainActor
    func testReplacementFailureAndWrongScopeLeaveOldUnchanged() throws {
        let (vault, first, _, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let oldFile = p8File()
        let newFile = p8File()
        let key = SymmetricKey(size: .bits256)
        let metadata = P8Metadata(purpose: .apns, keyID: "DUMMYKEY01", issuerID: nil)
        let oldID = try vault.importFile(oldFile, parsed: CredentialParser.parse(oldFile.data, extension: "p8"), app: first,
                                         password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let parsed = try CredentialParser.parse(newFile.data, extension: "p8")
        XCTAssertThrowsError(try vault.importFile(newFile, parsed: parsed, app: other, password: nil, confirmUnknownTeam: true,
                                                key: key, p8: metadata, replacingID: oldID, confirmReplacement: true))
        XCTAssertThrowsError(try vault.importFile(newFile, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true,
                                                key: key, p8: P8Metadata(purpose: .signInWithApple, keyID: "DUMMYKEY01", issuerID: nil), replacingID: oldID, confirmReplacement: true))
        struct CommitFailure: Error {}
        XCTAssertThrowsError(try vault.importFile(newFile, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true,
                                                key: key, p8: metadata, replacingID: oldID, confirmReplacement: true) { throw CommitFailure() })
        let old = try XCTUnwrap(vault.records().first)
        XCTAssertNil(old.replacedByID)
        XCTAssertEqual(try vault.records().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).count, 1)
        XCTAssertEqual(try vault.read(old, key: key).original, oldFile.data)
    }

    @MainActor
    func testLegacyCredentialAADRemainsReadable() throws {
        let (vault, first, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        let team = try XCTUnwrap(first.team)
        let record = StoredCredential(file: file, parsed: parsed, app: first, team: team, savePassword: false)
        record.metadataVersion = 1
        let expiry = try XCTUnwrap(parsed.expiresAt)
        let legacy = try JSONEncoder().encode([
            "AppMateCredential-v1", record.id.uuidString, record.registrationKey, team.id.uuidString,
            "", "true", parsed.name, parsed.kind, file.name, "cer", record.digest,
            parsed.fingerprint ?? "", parsed.teamID ?? "", parsed.bundleID ?? "",
            String(expiry.timeIntervalSinceReferenceDate.bitPattern), "false"
        ])
        XCTAssertEqual(try record.authenticatedData(), legacy)
        let key = SymmetricKey(size: .bits256)
        let payload = try JSONEncoder().encode(CredentialPayload(original: file.data, password: nil))
        try vault.blobs.write(payload, id: record.id, key: key, authenticating: legacy)
        vault.context.insert(record)
        try vault.context.save()
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
    }

    @MainActor
    func testHostUsesIsolatedStore() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["APP_MATE_TESTING"], "1")
        XCTAssertTrue(CredentialVault.directory.path.contains("/AppMateTests/"))
        XCTAssertFalse(CredentialVault.directory.path.contains("/AppMateVault/"))
    }

    @MainActor
    func testVaultSchemaUpgradePreservesCatalogAndEncryptedPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Clean up only after the test host releases its SQLite connections.
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("upgrade.store"))
        let identifiers = try autoreleasepool { () throws -> (UUID, UUID) in
            let old = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, VerificationRecord.self, configurations: configuration)
            let context = ModelContext(old)
            let team = DeveloperTeam(name: "Existing Team", teamID: "TESTTEAM01")
            let app = ManagedApp(name: "Existing App", bundleID: "com.example.AppMate.fixture", platform: "macOS", team: team)
            context.insert(app)
            try context.save()
            return (team.id, app.id)
        }
        let upgraded = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, VerificationRecord.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
        let context = ModelContext(upgraded)
        let app = try XCTUnwrap(context.fetch(FetchDescriptor<ManagedApp>()).first)
        XCTAssertEqual(app.id, identifiers.1)
        XCTAssertEqual(app.team?.id, identifiers.0)
        XCTAssertEqual(app.name, "Existing App")
        let blobs = EncryptedBlobStore(directory: directory.appendingPathComponent("blobs"))
        let vault = CredentialVault(context: context, blobs: blobs)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        let key = SymmetricKey(size: .bits256)
        let id = try vault.importFile(file, parsed: parsed, app: app, password: nil, confirmUnknownTeam: true, key: key)
        let reopened = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, VerificationRecord.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
        let reopenedVault = CredentialVault(context: ModelContext(reopened), blobs: blobs)
        let record = try XCTUnwrap(reopenedVault.records().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(try reopenedVault.read(record, key: key).original, file.data)
        XCTAssertNil(try reopenedVault.read(record, key: key).password)
    }

    @MainActor
    private func makeVault() throws -> (CredentialVault, ManagedApp, ManagedApp, ManagedApp) {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let team = DeveloperTeam(name: "Fixture Team", teamID: "TESTTEAM01")
        let otherTeam = DeveloperTeam(name: "Other Team", teamID: "TESTTEAM02")
        let first = ManagedApp(name: "First", bundleID: "com.example.AppMate.fixture", platform: "macOS", team: team)
        let sibling = ManagedApp(name: "Sibling", bundleID: "com.example.other", platform: "iOS", team: team)
        let other = ManagedApp(name: "Other", bundleID: first.bundleID, platform: "macOS", team: otherTeam)
        context.insert(first); context.insert(sibling); context.insert(other)
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests", isDirectory: true).appendingPathComponent(UUID().uuidString)
        return (CredentialVault(context: context, blobs: EncryptedBlobStore(directory: directory)), first, sibling, other)
    }

    @MainActor
    func testVaultCertificateSharesOnlyWithinTeamAndExportsOriginal() throws {
        let (vault, first, sibling, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: false, key: key))
        let id = try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        XCTAssertTrue(record.isVisible(in: first))
        XCTAssertTrue(record.isVisible(in: sibling))
        XCTAssertFalse(record.isVisible(in: other))
        XCTAssertFalse(try vault.canCreateKey())
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        XCTAssertThrowsError(try vault.importFile(file, parsed: parsed, app: sibling, password: nil, confirmUnknownTeam: true, key: key))
        XCTAssertEqual(try vault.records().count, 1)
        XCTAssertNil(try Data(contentsOf: vault.blobs.file(id)).range(of: file.data))
        let output = vault.blobs.directory.appendingPathComponent("export.cer")
        try vault.export(record, to: output, key: key)
        XCTAssertEqual(try Data(contentsOf: output), file.data)
        XCTAssertThrowsError(try vault.export(record, to: output, key: key))
    }

    @MainActor
    func testVaultProfileRejectsWrongTeamAndApp() throws {
        let (vault, first, sibling, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
        let parsed = try CredentialParser.parse(file.data, extension: "mobileprovision")
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try vault.importFile(file, parsed: parsed, app: other, password: nil, confirmUnknownTeam: true, key: key))
        let historyCount = try vault.context.fetchCount(FetchDescriptor<BackupChange>())
        XCTAssertThrowsError(try vault.validate(file: file, parsed: parsed, app: sibling, confirmUnknownTeam: true)) { error in
            guard case VaultError.bundleMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try vault.importFile(file, parsed: parsed, app: sibling, password: nil, confirmUnknownTeam: true, key: key)) { error in
            guard case VaultError.bundleMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(vault.context.hasChanges)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), historyCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.blobs.directory.path))
        XCTAssertTrue(try vault.records().isEmpty)
        try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: false, key: key)
        let record = try XCTUnwrap(vault.records().first)
        XCTAssertTrue(record.isVisible(in: first))
        XCTAssertFalse(record.isVisible(in: sibling))
        XCTAssertFalse(record.isVisible(in: other))
        record.app = nil
        XCTAssertFalse(record.isVisible(in: sibling))
        XCTAssertThrowsError(try vault.read(record, key: key))
    }

    @MainActor
    func testVaultWildcardMatching() {
        XCTAssertTrue(CredentialVault.profileMatches("com.Example.App", bundleID: "com.example.app"))
        XCTAssertTrue(CredentialVault.profileMatches("com.example.*", bundleID: "com.example.app"))
        XCTAssertTrue(CredentialVault.profileMatches("*", bundleID: "com.example.app"))
        XCTAssertFalse(CredentialVault.profileMatches("com.example.*", bundleID: "com.examples.app"))
        XCTAssertFalse(CredentialVault.profileMatches("com.example.*", bundleID: "com.example."))
        XCTAssertFalse(CredentialVault.profileMatches("com.ex*ample.app", bundleID: "com.example.app"))
    }

    @MainActor
    func testVaultPKCS12PasswordAndMetadataAreAuthenticated() throws {
        let (vault, first, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        let parsed = try CredentialParser.parse(file.data, extension: "p12", password: "fixture-only")
        let key = SymmetricKey(size: .bits256)
        try vault.importFile(file, parsed: parsed, app: first, password: "fixture-only", confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        XCTAssertTrue(record.hasSavedPassword)
        XCTAssertEqual(try vault.read(record, key: key).password, "fixture-only")
        let sealed = try Data(contentsOf: vault.blobs.file(record.id))
        XCTAssertNil(sealed.range(of: Data("fixture-only".utf8)))
        XCTAssertThrowsError(try vault.read(record, key: SymmetricKey(size: .bits256)))
        record.name += "tampered"
        XCTAssertThrowsError(try vault.read(record, key: key))
        record.name = parsed.name
        var changed = sealed
        changed[changed.count - 1] ^= 1
        try changed.write(to: vault.blobs.file(record.id))
        XCTAssertThrowsError(try vault.read(record, key: key))
    }

    @MainActor
    func testVaultFailureRollbackAndOrphanRecovery() throws {
        let (vault, first, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        let key = SymmetricKey(size: .bits256)
        struct CommitFailure: Error {}
        XCTAssertThrowsError(try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true, key: key) { throw CommitFailure() })
        XCTAssertTrue(try vault.records().isEmpty)
        XCTAssertTrue(try vault.canCreateKey())
        let orphan = vault.blobs.file(UUID())
        try Data("orphan".utf8).write(to: orphan)
        XCTAssertFalse(try vault.canCreateKey())
        try vault.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let id = try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: true, key: key)
        try vault.recover()
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.blobs.file(id).path))
    }

    @MainActor
    func testVaultAccessCancellationAndLockPreventSideEffects() async throws {
        var performed = false
        let cancelled = VaultAccess(keyProvider: { _, _ in throw VaultError.cancelled })
        do {
            try await cancelled.withKey(reason: "Fixture", allowCreation: false) { _ in performed = true }
            XCTFail("Cancelled authentication must throw")
        } catch {}
        XCTAssertFalse(performed)
        XCTAssertFalse(cancelled.busy)
        var lock: () -> Void = {}
        let access = VaultAccess(keyProvider: { _, _ in lock(); return SymmetricKey(size: .bits256) })
        lock = { access.lock() }
        do {
            try await access.withKey(reason: "Fixture", allowCreation: false) { _ in performed = true }
            XCTFail("Lock during authentication must throw")
        } catch {}
        XCTAssertFalse(performed)
        XCTAssertFalse(access.busy)
    }

    @MainActor
    func testTeamRegistrationRejectsInvalidAndDuplicateIDs() throws {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let catalog = AppCatalog(context: ModelContext(container))
        XCTAssertThrowsError(try catalog.addTeam(name: " ", teamID: "TESTTEAM01"))
        for identifier in ["", "SHORT", "testteam01", "TEST_TEAM1", "TESTTEAM010"] {
            XCTAssertThrowsError(try catalog.addTeam(name: "Team", teamID: identifier))
        }
        let id = try catalog.addTeam(name: " Team A \n", teamID: " TESTTEAM01 ")
        XCTAssertThrowsError(try catalog.addTeam(name: "Duplicate", teamID: "TESTTEAM01"))
        let teams = try ModelContext(container).fetch(FetchDescriptor<DeveloperTeam>())
        XCTAssertEqual(teams.count, 1)
        XCTAssertEqual(teams.first?.id, id)
        XCTAssertEqual(teams.first?.name, "Team A")
    }

    @MainActor
    func testAppUniquenessIsScopedToTeamAndCaseInsensitive() throws {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let catalog = AppCatalog(context: ModelContext(container))
        let first = try catalog.addTeam(name: "Same name", teamID: "TESTTEAM01")
        let second = try catalog.addTeam(name: "Same name", teamID: "TESTTEAM02")
        _ = try catalog.addApp(name: " Original ", bundleID: " com.example.App ", platform: "macOS", teamID: first)
        XCTAssertThrowsError(try catalog.addApp(name: "Duplicate", bundleID: "com.example.app", platform: "iOS", teamID: first))
        _ = try catalog.addApp(name: "Other team", bundleID: "com.example.app", platform: "iOS", teamID: second)
        for bundle in ["", "com.example.*", "com..example", ".example", "com.example.", "com.example_app", "com.\u{65e5}\u{672c}"] {
            XCTAssertThrowsError(try catalog.addApp(name: "Invalid", bundleID: bundle, platform: "macOS", teamID: first))
        }
        XCTAssertThrowsError(try catalog.addApp(name: " ", bundleID: "com.example.valid", platform: "macOS", teamID: first))
        XCTAssertThrowsError(try catalog.addApp(name: "Invalid", bundleID: "com.example.valid", platform: "unknown", teamID: first))
        XCTAssertThrowsError(try catalog.addApp(name: "Invalid", bundleID: "com.example.valid", platform: "macOS", teamID: UUID()))
        let apps = try ModelContext(container).fetch(FetchDescriptor<ManagedApp>())
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(Set(apps.map { $0.team?.id }), [first, second])
        XCTAssertTrue(apps.contains { $0.name == "Original" && $0.bundleID == "com.example.App" })
    }

    @MainActor
    func testCatalogReopensWithTeamRelationships() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SwiftData can retain SQLite handles; remove this test directory after the test host exits.
        try autoreleasepool {
            let configuration = ModelConfiguration(url: directory.appendingPathComponent("catalog.store"))
            let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
            let catalog = AppCatalog(context: ModelContext(container))
            let teamID = try catalog.addTeam(name: "Fixture Team", teamID: "TESTTEAM01")
            let appID = try catalog.addApp(name: "Fixture App", bundleID: "com.example.fixture", platform: "macOS", teamID: teamID)
            let reopened = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self, configurations: configuration)
            let context = ModelContext(reopened)
            let app = try XCTUnwrap(context.fetch(FetchDescriptor<ManagedApp>()).first)
            let team = try XCTUnwrap(context.fetch(FetchDescriptor<DeveloperTeam>()).first)
            XCTAssertEqual(app.id, appID)
            XCTAssertEqual(app.team?.id, teamID)
            XCTAssertEqual(app.platform, "macOS")
            XCTAssertEqual(team.apps.map(\.id), [appID])
            XCTAssertThrowsError(try AppCatalog(context: ModelContext(reopened)).addApp(name: "Duplicate", bundleID: "COM.EXAMPLE.FIXTURE", platform: "macOS", teamID: teamID))
        }
    }

    func testKeychainSigningRequirements() {
        XCTAssertFalse(EncryptionKeychain.hasAccessGroup([:]))
        XCTAssertFalse(EncryptionKeychain.hasAccessGroup(["com.apple.security.app-sandbox": true]))
        XCTAssertFalse(EncryptionKeychain.hasAccessGroup(["com.apple.application-identifier": "", "keychain-access-groups": [""]]))
        XCTAssertTrue(EncryptionKeychain.hasAccessGroup(["com.apple.application-identifier": "TESTTEAM01.com.example.AppMate"]))
        XCTAssertTrue(EncryptionKeychain.hasAccessGroup(["keychain-access-groups": ["TESTTEAM01.com.example.AppMate"]]))
        let message = ValidationError.security(errSecMissingEntitlement).localizedDescription
        XCTAssertTrue(message.contains("開発用署名"))
        XCTAssertFalse(message.contains("パスワードとアクセス許可"))
    }

    private func fixture(_ ext: String, name: String = "sample") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testSignedProfileMetadata() throws {
        let data = try fixture("mobileprovision")
        let value = try CredentialParser.parse(data, extension: "mobileprovision")
        XCTAssertEqual(value.name, "App Mate Test Profile")
        XCTAssertEqual(value.teamID, "TESTTEAM01")
        XCTAssertEqual(value.bundleID, "com.example.AppMate.fixture")
        XCTAssertEqual(value.expiresAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testProfileTamperAndUnsignedPlistRejected() throws {
        let data = try fixture("mobileprovision")
        var bytes = data
        let marker = Data("App Mate Test Profile".utf8)
        let range = try XCTUnwrap(bytes.range(of: marker))
        bytes[range.lowerBound] ^= 1
        XCTAssertThrowsError(try CredentialParser.parse(bytes, extension: "mobileprovision"))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Name": "Not signed"], format: .xml, options: 0)
        XCTAssertThrowsError(try CredentialParser.parse(plist, extension: "mobileprovision"))
    }

    func testCertificateAndPKCS12() throws {
        let certificate = try CredentialParser.parse(fixture("cer"), extension: "cer")
        let identity = try CredentialParser.parse(fixture("p12"), extension: "p12", password: "fixture-only")
        XCTAssertEqual(certificate.name, "App Mate Test Only")
        XCTAssertEqual(identity.name, certificate.name)
        XCTAssertEqual(certificate.expiresAt, identity.expiresAt)
        XCTAssertThrowsError(try CredentialParser.parse(fixture("p12"), extension: "p12", password: "wrong"))
    }

    func testInvalidAndOversizedFilesRejected() {
        for ext in ["cer", "mobileprovision", "p12", "p8"] {
            XCTAssertThrowsError(try CredentialParser.parse(Data(), extension: ext))
            XCTAssertThrowsError(try CredentialParser.parse(Data("invalid".utf8), extension: ext))
        }
        XCTAssertThrowsError(try CredentialParser.parse(Data(repeating: 0, count: CredentialParser.maximumBytes + 1), extension: "cer"))
    }

    func testCertificateChainRequiresSelection() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "chain", withExtension: "p12", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let candidates = try CredentialParser.parseAll(data, extension: "p12", password: "fixture-only")
        XCTAssertEqual(Set(candidates.map(\.name)), ["App Mate Chain Leaf", "App Mate Chain Root"])
        XCTAssertEqual(Set(candidates.compactMap(\.fingerprint)).count, 2)
        XCTAssertThrowsError(try CredentialParser.parse(data, extension: "p12", password: "fixture-only"))
    }

    func testFileRoundTripDoesNotOverwriteSourcesOrAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.cer")
        let original = try fixture("cer")
        try original.write(to: source)
        let file = try CredentialFile(url: source)
        let output = directory.appendingPathComponent("copy.cer")
        try file.export(to: output)
        XCTAssertEqual(try Data(contentsOf: output), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try file.export(to: source))
        XCTAssertThrowsError(try file.export(to: output))
        let alias = directory.appendingPathComponent("alias.cer")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try CredentialFile(url: alias))
        XCTAssertThrowsError(try file.export(to: alias))
        let hardLink = directory.appendingPathComponent("hard.cer")
        try FileManager.default.linkItem(at: source, to: hardLink)
        XCTAssertThrowsError(try file.export(to: hardLink))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(try CredentialFile(url: directory))
        XCTAssertThrowsError(try CredentialFile(url: XCTUnwrap(URL(string: "https://example.com/a.cer"))))
        let oversized = directory.appendingPathComponent("large.cer")
        try Data(repeating: 0, count: CredentialParser.maximumBytes + 1).write(to: oversized)
        XCTAssertThrowsError(try CredentialFile(url: oversized))
    }

    @MainActor
    func testEncryptedStoreReopensWithMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests", isDirectory: true).appendingPathComponent(UUID().uuidString)
        // SwiftData can retain SQLite handles; remove this test directory after the test host exits.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try autoreleasepool {
            let configuration = ModelConfiguration(url: directory.appendingPathComponent("metadata.store"))
            let container = try ModelContainer(for: VerificationRecord.self, configurations: configuration)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let key = SymmetricKey(size: .bits256)
            let data = Data("test-secret-must-not-be-plaintext".utf8)
            let store = EncryptedProbeStore(directory: directory.appendingPathComponent("blobs"))
            try store.save(data, key: key) { record in
                context.insert(record)
                try context.save()
            }
            let reopened = try ModelContainer(for: VerificationRecord.self, configurations: configuration)
            let records = try ModelContext(reopened).fetch(FetchDescriptor<VerificationRecord>())
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(try store.read(record.id, key: key), data)
            let sealed = try Data(contentsOf: store.file(record.id))
            XCTAssertNil(sealed.range(of: data))
            XCTAssertThrowsError(try store.read(record.id, key: SymmetricKey(size: .bits256)))
            var tampered = sealed
            tampered[tampered.count - 1] ^= 1
            try tampered.write(to: store.file(record.id))
            XCTAssertThrowsError(try store.read(record.id, key: key))
        }
    }

    func testFailedCommitAndInterruptedSaveRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedProbeStore(directory: directory)
        let key = SymmetricKey(size: .bits256)
        let data = Data("test".utf8)
        struct CommitFailure: Error {}
        XCTAssertThrowsError(try store.save(data, key: key) { _ in throw CommitFailure() })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        var savedID: UUID?
        try store.save(data, key: key) { savedID = $0.id }
        let saved = try XCTUnwrap(savedID)
        // An unreferenced blob models termination between the file write and metadata commit.
        let orphan = UUID()
        try Data("orphan".utf8).write(to: store.file(orphan))
        try store.removeOrphans(keeping: [saved])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(orphan).path))
        XCTAssertEqual(try store.read(saved, key: key), data)
    }
}

// Frozen pre-restore model: proves that adding the blob reference preserves existing encrypted files.
private enum BeforeRestoreSchema {
    @Model
    final class StoredCredential {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var registrationKey: String
        var name: String
        var kind: String
        var originalName: String
        var fileExtension: String
        var digest: String
        var fingerprint: String?
        var sourceTeamID: String?
        var bundleID: String?
        var expiresAt: Date?
        var createdAt: Date
        var isTeamShared: Bool
        var hasSavedPassword: Bool
        var team: DeveloperTeam?
        var app: ManagedApp?
        var metadataVersion: Int = 1
        var keyPurpose: String?
        var keyID: String?
        var issuerID: String?
        var replacesCredentialID: UUID?
        var replacedByID: UUID?

        init(restoring value: BackupSnapshot.Credential, team: DeveloperTeam, app: ManagedApp?) {
            id = value.id
            registrationKey = value.registrationKey
            name = value.name
            kind = value.kind
            originalName = value.originalName
            fileExtension = value.fileExtension
            digest = value.digest
            fingerprint = value.fingerprint
            sourceTeamID = value.sourceTeamID
            bundleID = value.bundleID
            expiresAt = value.expiresAt
            createdAt = value.createdAt
            isTeamShared = value.isTeamShared
            hasSavedPassword = value.hasSavedPassword
            self.team = team
            self.app = app
            metadataVersion = value.metadataVersion
            keyPurpose = value.keyPurpose
            keyID = value.keyID
            issuerID = value.issuerID
            replacesCredentialID = value.replacesCredentialID
            replacedByID = value.replacedByID
        }

    }
}
