import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
import XcodesLoginKit
@testable import Xkeys

/// Encrypted storage, catalog registration, deletion, search and quarantine.
extension XkeysTests {
    @MainActor
    func testTeamDeletionOnlyRemovesEmptyTeamAndRejectsTrashedCredentials() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let catalog = AppCatalog(context: vault.context)
        let management = VaultManagement(vault: vault)
        let originalIDs = Set(try vault.context.fetch(FetchDescriptor<DeveloperTeam>()).map(\.id))
        let emptyID = try catalog.addTeam(name: "Empty", teamID: "EMPTYTEAM1")
        let empty = try XCTUnwrap(vault.context.fetch(FetchDescriptor<DeveloperTeam>()).first { $0.id == emptyID })
        try management.removeTeam(empty)
        XCTAssertEqual(Set(try vault.context.fetch(FetchDescriptor<DeveloperTeam>()).map(\.id)), originalIDs)
        XCTAssertThrowsError(try management.removeTeam(XCTUnwrap(app.team)))
        let sharedID = try catalog.addTeam(name: "Shared", teamID: "SHARED0001")
        let shared = try XCTUnwrap(vault.context.fetch(FetchDescriptor<DeveloperTeam>()).first { $0.id == sharedID })
        let key = SymmetricKey(size: .bits256)
        let file = p8File()
        let recordID = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: nil, team: shared,
                                            password: nil, confirmUnknownTeam: true, key: key,
                                            p8: P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil))
        let record = try XCTUnwrap(vault.records().first { $0.id == recordID })
        XCTAssertThrowsError(try management.removeTeam(shared))
        try management.trash(record, key: key)
        XCTAssertThrowsError(try management.removeTeam(shared))
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
    }

    @MainActor
    func testTargetsGroupExistingAppsAndRouteProfilesWithoutChangingCredentials() throws {
        let (vault, root, child, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        let parsed = try CredentialParser.parse(profile.data, extension: "mobileprovision")
        // The fixture's profile belongs to root; use that existing target as the extension.
        try AppCatalog(context: vault.context).setParent(child.id, for: root, name: root.name, platform: root.platform)
        let id = try vault.importFile(profile, parsed: parsed, app: root, password: nil, confirmUnknownTeam: false, key: key)
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        XCTAssertEqual(child.targets.count, 2)
        XCTAssertEqual(child.target(forProfileBundleID: root.bundleID)?.id, root.id)
        XCTAssertNil(child.target(forProfileBundleID: "com.example.unregistered"))
        XCTAssertNil(child.target(forProfileBundleID: "*"))
        XCTAssertTrue(CredentialSearch.includes(record, scope: .app(child.id), app: child, query: "", type: .all, at: .now))
        XCTAssertFalse(record.isVisible(in: child))
        XCTAssertThrowsError(try AppCatalog(context: vault.context).setParent(root.id, for: child, name: child.name, platform: child.platform))
        XCTAssertThrowsError(try AppCatalog(context: vault.context).setParent(other.id, for: root, name: root.name, platform: root.platform))
        let aad = try record.authenticatedData()
        try AppCatalog(context: vault.context).setParent(nil, for: root, name: root.name, platform: root.platform)
        XCTAssertEqual(try record.authenticatedData(), aad)
        XCTAssertEqual(try vault.read(record, key: key).original, profile.data)
    }

    @MainActor
    func testCustomSecretsEncryptValidateRollbackRecoverAndDeleteWithApp() throws {
        let (vault, app, sibling, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let manager = VaultManagement(vault: vault)
        let key = SymmetricKey(size: .bits256)
        let secrets = [AppSecret(name: "DATABASE_PASSWORD", value: "secret-value-sentinel"), AppSecret(name: "EMPTY", value: "")]
        XCTAssertEqual(try manager.readCustomSecrets(app, key: key), [])
        try manager.saveCustomSecrets(secrets, app: app, key: key)
        XCTAssertEqual(try manager.readCustomSecrets(app, key: key), secrets)
        XCTAssertEqual(try manager.readCustomSecrets(sibling, key: key), [])
        XCTAssertFalse(try vault.canCreateKey())
        let originalID = try XCTUnwrap(app.customSecretsBlobID)
        let bytes = try Data(contentsOf: vault.blobs.file(originalID))
        XCTAssertNil(bytes.range(of: Data(secrets[0].value.utf8)))
        XCTAssertThrowsError(try manager.readCustomSecrets(app, key: SymmetricKey(size: .bits256)))
        try vault.recover()
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.blobs.file(originalID).path))
        let before = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertThrowsError(try manager.saveCustomSecrets([AppSecret(name: "URL", value: "new")], app: app, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(app.customSecretsBlobID, originalID)
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).revision(), try before.revision())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: vault.blobs.directory, includingPropertiesForKeys: nil).count, 1)
        for invalid in [[AppSecret(name: "A", value: "1"), AppSecret(name: "a", value: "2")],
                        [AppSecret(name: "A\n", value: "1")], [AppSecret(name: "GITHUB_TOKEN", value: "1")],
                        [AppSecret(name: "VALUE", value: "\0")], [AppSecret(name: "VALUE", value: String(repeating: "x", count: 65537))]] {
            XCTAssertThrowsError(try manager.saveCustomSecrets(invalid, app: app, key: key))
        }
        app.customSecretNames = "OTHER"
        XCTAssertThrowsError(try manager.readCustomSecrets(app, key: key))
        vault.context.rollback()
        sibling.customSecretsBlobID = originalID
        sibling.customSecretNames = app.customSecretNames
        XCTAssertThrowsError(try manager.readCustomSecrets(sibling, key: key))
        vault.context.rollback()
        try manager.trash(app, key: key)
        try manager.restore(app)
        XCTAssertEqual(try manager.readCustomSecrets(app, key: key), secrets)
        try manager.purge(records: [], apps: [])
        try manager.trash(app, key: key)
        try manager.purge(records: [], apps: [app])
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.blobs.file(originalID).path))
    }

    @MainActor
    func testCustomSecretsExportOnlySelectedValuesAndRejectNameCollisions() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let value = " quote'\" $HOME ${TOKEN} \\ literal\\n\nnext\rline "
        let secrets = [AppSecret(name: "DATABASE_PASSWORD", value: value), AppSecret(name: "EMPTY", value: "")]
        try VaultManagement(vault: vault).saveCustomSecrets(secrets, app: app, key: key)
        var entries = CISecretFile.entries(for: app, records: [], at: .now)
        XCTAssertEqual(entries.filter { $0.section == .custom }.map(\.name), secrets.map(\.name))
        var reads = 0
        let output = try CISecretFile.render(entries, title: app.name, at: .now, readCustom: { source in
            reads += 1
            return try VaultManagement(vault: vault).readCustomSecrets(source, key: key)
        }) { _ in throw ValidationError.invalidFile }
        XCTAssertEqual(reads, 1)
        let text = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(text.contains("EMPTY=\"\""))
        XCTAssertTrue(text.contains("\\$HOME"))
        XCTAssertTrue(text.contains("\\${TOKEN}"))
        XCTAssertTrue(text.contains("\\\\ literal\\\\n\\nnext\\rline"))
        for ending in ["\\", "\""] {
            XCTAssertThrowsError(try CISecretFile.render(entries, title: app.name, at: .now, readCustom: { _ in
                [AppSecret(name: "DATABASE_PASSWORD", value: "fixture" + ending), AppSecret(name: "EMPTY", value: "")]
            }) { _ in throw ValidationError.invalidFile })
        }
        entries[entries.firstIndex { $0.name == "EMPTY" }!].name = "database_password"
        XCTAssertThrowsError(try CISecretFile.validate(entries))
        for index in entries.indices where entries[index].section == .custom { entries[index].included = false }
        reads = 0
        _ = try CISecretFile.render(entries, title: app.name, at: .now, readCustom: { _ in reads += 1; throw ValidationError.invalidFile }) { _ in throw ValidationError.invalidFile }
        XCTAssertEqual(reads, 0)
        try VaultManagement(vault: vault).saveCustomSecrets([AppSecret(name: "APPLE_TEAM_ID", value: "custom")], app: app, key: key)
        XCTAssertThrowsError(try CISecretFile.validate(CISecretFile.entries(for: app, records: [], at: .now)))
    }

    @MainActor
    func testP8ImportsWithoutUnknownTeamConfirmation() throws {
        let (vault, app, sibling, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = p8File()
        let parsed = try CredentialParser.parse(file.data, extension: "p8")
        XCTAssertNil(parsed.teamID)
        let metadata = P8Metadata(purposes: [.appStoreConnect], keyID: "DUMMYKEY01", issuerID: UUID().uuidString)
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
        let metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let oldFile = p8File()
        _ = try vault.importFile(oldFile, parsed: CredentialParser.parse(oldFile.data, extension: "p8"), app: app,
                                 password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let newFile = p8File()
        let parsed = try CredentialParser.parse(newFile.data, extension: "p8")
        try vault.importFile(newFile, parsed: parsed, app: app, password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
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
                                      password: nil, confirmUnknownTeam: true, key: key, p8: metadata) }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case RestoreError.pendingChanges = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(vault.context.hasChanges)
            XCTAssertEqual(app.name, "pending edit")
        }
        XCTAssertEqual(try vault.records().count, 2)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).sorted(), files)
        vault.context.rollback()
    }

    @MainActor
    func testEditingAppIconPersistsAndRejectsInvalidChangesWithoutChangingCredentials() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let id = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app,
                                      password: nil, confirmUnknownTeam: false, key: key)
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        let aad = try record.authenticatedData()
        let catalog = AppCatalog(context: vault.context)
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6WQAAAAASUVORK5CYII=")!
        try catalog.updateApp(app, name: app.name, platform: app.platform, parentAppID: nil, iconColor: "blue", iconImage: image)
        XCTAssertEqual(app.iconImage, image)
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).apps.first { $0.id == app.id }?.iconImage, image)
        XCTAssertThrowsError(try catalog.updateApp(app, name: "Invalid", platform: app.platform, parentAppID: nil, iconColor: "invalid", iconImage: nil))
        XCTAssertThrowsError(try catalog.updateApp(app, name: "Invalid", platform: app.platform, parentAppID: nil, iconColor: "blue", iconImage: Data(repeating: 0, count: 1_048_577)))
        XCTAssertEqual(app.iconImage, image)
        try catalog.setParent(nil, for: app, name: app.name, platform: app.platform)
        XCTAssertEqual(app.iconImage, image)
        try catalog.updateApp(app, name: app.name, platform: app.platform, parentAppID: nil, iconColor: "orange", iconImage: nil)
        XCTAssertEqual(app.iconColor, "orange")
        XCTAssertNil(app.iconImage)
        XCTAssertEqual(try record.authenticatedData(), aad)
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
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
    func testSearchUsesStoredOwnerMetadataWithoutOpeningSecrets() throws {
        let (_, first, sibling, other) = try makeVault()
        first.name = "写真カメラ"
        let record = StoredCredential(file: CredentialFile(data: Data("private-key-byte-sentinel".utf8), name: "AuthKey_FIXTURE.p8"),
                                      parsed: ParsedCredential(name: "開発用キー", kind: "APNs", teamID: nil, bundleID: nil, expiresAt: nil),
                                      app: first, team: try XCTUnwrap(first.team), savePassword: false,
                                      p8: P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil))
        for query in ["", "  \n　", "dummykey01", "AUTHKEY_fixture", "Fixture Team", "TESTTEAM01", "TESTTEAM01　apns"] {
            XCTAssertTrue(CredentialSearch.matches(record, query: query), query)
        }
        for query in ["private-key-byte-sentinel", "ForeignOrganization", "TESTTEAM02", "写真", sibling.bundleID, "写真 dummykey01", "写真 missing-value", other.id.uuidString] {
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
    func testTeamScopeIncludesAllSharedFormatsAndExcludesAppProfilesAndOtherTeams() throws {
        let (_, app, sibling, other) = try makeVault()
        let team = try XCTUnwrap(app.team)
        for ext in ["cer", "p12", "p8", "mobileprovision"] {
            let record = StoredCredential(file: CredentialFile(data: Data(ext.utf8), name: "sample." + ext),
                parsed: ParsedCredential(name: ext, kind: "テスト", teamID: team.teamID, bundleID: nil, expiresAt: nil),
                app: app, team: team, savePassword: false)
            func includes(_ scope: CredentialScope, app: ManagedApp? = nil) -> Bool {
                CredentialSearch.includes(record, scope: scope, app: app, query: "", type: .all, at: .now)
            }
            XCTAssertEqual(includes(.team(team.id)), ext != "mobileprovision")
            XCTAssertFalse(includes(.team(try XCTUnwrap(other.team?.id))))
            XCTAssertEqual(includes(.app(app.id), app: app), ext == "mobileprovision")
            XCTAssertFalse(includes(.app(sibling.id), app: sibling))
        }
    }

    @MainActor
    func testPurposeFiltersSeparateSigningCAAndAllP8Purposes() throws {
        let (_, app, _, _) = try makeVault()
        let team = try XCTUnwrap(app.team)
        for purpose in P8Purpose.allCases {
            let record = StoredCredential(file: CredentialFile(data: Data([1]), name: "key.p8"),
                parsed: ParsedCredential(name: "key", kind: "鍵", teamID: nil, bundleID: nil, expiresAt: nil),
                app: nil, team: team, savePassword: false, p8: P8Metadata(purposes: [purpose], keyID: "DUMMYKEY01", issuerID: nil))
            XCTAssertTrue(CredentialPurposeFilter.all.matches(record))
            XCTAssertEqual(CredentialPurposeFilter.allCases.filter { $0 != .all && $0.matches(record) }, [.key(purpose)])
            record.keyPurpose = nil
            XCTAssertTrue(CredentialPurposeFilter.unspecified.matches(record))
        }
        let ca = StoredCredential(file: CredentialFile(data: Data([1]), name: "ca.cer"),
            parsed: ParsedCredential(name: "CA", kind: ParsedCredential.intermediateCAKind, teamID: nil, bundleID: nil, expiresAt: nil),
            app: nil, team: team, savePassword: false)
        XCTAssertTrue(CredentialPurposeFilter.intermediateCA.matches(ca))
        XCTAssertFalse(CredentialPurposeFilter.signing.matches(ca))
    }

    @MainActor
    func testTeamImportNeedsNoAppsAndPreservesDuplicateValidation() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let team = DeveloperTeam(name: "Empty Team", teamID: "EMPTYTEAM1")
        vault.context.insert(team)
        try vault.context.save()
        XCTAssertTrue(team.apps.isEmpty)
        let key = SymmetricKey(size: .bits256)
        let file = p8File()
        let parsed = try CredentialParser.parse(file.data, extension: "p8")
        let metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let id = try vault.importFile(file, parsed: parsed, app: nil, team: team, password: nil, confirmUnknownTeam: false, key: key, p8: metadata)
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        XCTAssertNil(record.app)
        XCTAssertEqual(record.team?.id, team.id)
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        XCTAssertThrowsError(try vault.importFile(file, parsed: parsed, app: nil, team: team, password: nil, confirmUnknownTeam: false, key: key, p8: metadata))
        XCTAssertThrowsError(try vault.validate(file: file, parsed: parsed, app: app, team: team, confirmUnknownTeam: false, p8: metadata))
        XCTAssertTrue(team.apps.isEmpty)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        XCTAssertThrowsError(try vault.validate(file: profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: nil, team: try XCTUnwrap(app.team), confirmUnknownTeam: true))
    }

    @MainActor
    func testGlobalSearchOverridesAppScopeButPreservesTypeFilter() throws {
        let (_, first, _, other) = try makeVault()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let record = StoredCredential(file: CredentialFile(data: Data([1]), name: "other.cer"),
                                      parsed: ParsedCredential(name: "Other Certificate", kind: "証明書", teamID: nil, bundleID: nil, expiresAt: now),
                                      app: other, team: try XCTUnwrap(other.team), savePassword: false)
        func includes(_ query: String, type: CredentialTypeFilter = .all, scope: CredentialScope? = nil) -> Bool {
            CredentialSearch.includes(record, scope: scope ?? .app(first.id), app: first, query: query, type: type, at: now)
        }
        XCTAssertFalse(includes(""))
        XCTAssertFalse(includes("　 \n"))
        XCTAssertTrue(includes("testteam02"))
        XCTAssertTrue(includes("other", type: .certificate))
        XCTAssertFalse(includes("other", type: .identity))
        XCTAssertTrue(includes("", scope: .expired))
        XCTAssertFalse(includes("", scope: .expiring))
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
        XCTAssertTrue(CredentialDisplayState.withinDay.needsRenewal)
        XCTAssertFalse(CredentialDisplayState.expired.needsRenewal)
        _ = vault
    }

    @MainActor
    func testP8PurposeUpdateReencryptsAndRollsBackOnFailure() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let management = VaultManagement(vault: vault)
        let file = p8File()
        let id = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app, password: nil,
                                      confirmUnknownTeam: true, key: key, p8: P8Metadata(purposes: [.maps], keyID: "DUMMYKEY01", issuerID: nil))
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        try management.saveNote("note", record: record, key: key)
        let history = try vault.context.fetchCount(FetchDescriptor<BackupChange>())
        let blobs = try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).count

        struct CommitFailure: Error {}
        XCTAssertThrowsError(try management.updatePurposes(record, metadata: P8Metadata(purposes: [.weatherKit], keyID: "IGNORED001", issuerID: nil), key: key) { throw CommitFailure() })
        // SwiftData's rollback leaves loaded objects stale until the next fetch refreshes them from the store.
        _ = try vault.records()
        XCTAssertEqual(record.keyPurpose, "maps")
        XCTAssertEqual(record.name, "Maps（DUMMYKEY01）")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).count, blobs)
        XCTAssertEqual(try vault.read(record, key: key).note, "note")
        XCTAssertThrowsError(try management.updatePurposes(record, metadata: P8Metadata(purposes: [.appStoreConnect], keyID: "", issuerID: nil), key: key))
        XCTAssertThrowsError(try management.updatePurposes(record, metadata: P8Metadata(purposes: [.maps], keyID: "", issuerID: nil), key: SymmetricKey(size: .bits256)))

        try management.updatePurposes(record, metadata: P8Metadata(purposes: [.weatherKit, .maps], keyID: "IGNORED001", issuerID: nil), key: key)
        XCTAssertEqual(record.keyID, "DUMMYKEY01")
        XCTAssertEqual(record.keyPurpose, "maps,weatherkit")
        XCTAssertEqual(record.name, "Maps・WeatherKit（DUMMYKEY01）")
        XCTAssertEqual(record.purposeTitle, "Maps・WeatherKit")
        let payload = try vault.read(record, key: key)
        XCTAssertEqual(payload.original, file.data)
        XCTAssertEqual(payload.note, "note")
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history + 1)
        _ = try BackupSnapshot.capture(vault: vault, key: key)
        record.keyPurpose = "apns,weatherkit"
        XCTAssertThrowsError(try vault.read(record, key: key)) { error in
            guard case VaultError.undecryptable(record.originalName) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains(record.originalName))
        }
        vault.context.rollback()
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
                             p8: P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: "ignored"))
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
    func testCredentialAADMatchesV1Format() throws {
        let (vault, first, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        let team = try XCTUnwrap(first.team)
        let record = StoredCredential(file: file, parsed: parsed, app: first, team: team, savePassword: false)
        let expiry = try XCTUnwrap(parsed.expiresAt)
        // Changing these fields makes every stored blob unreadable; a new format needs a new prefix and migration.
        let expected = try JSONEncoder().encode([
            "XkeysCredential-v1", record.id.uuidString, record.registrationKey, team.id.uuidString,
            "", "true", parsed.name, parsed.kind, file.name, "cer", record.digest,
            parsed.fingerprint ?? "", parsed.teamID ?? "", parsed.bundleID ?? "",
            String(expiry.timeIntervalSinceReferenceDate.bitPattern), "false",
            "", "", "", record.blobID.uuidString
        ])
        XCTAssertEqual(try record.authenticatedData(), expected)
        XCTAssertEqual(VaultManagement.noteAAD(first), Data("XkeysAppNote-v1|\(first.id)|\(team.id)".utf8))
        let key = SymmetricKey(size: .bits256)
        let payload = try JSONEncoder().encode(CredentialPayload(original: file.data, password: nil))
        try vault.blobs.write(payload, id: record.blobID, key: key, authenticating: expected)
        vault.context.insert(record)
        try vault.context.save()
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
    }

    @MainActor
    func testVaultCertificateSharesOnlyWithinTeamAndExportsOriginal() throws {
        let (vault, first, sibling, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        let key = SymmetricKey(size: .bits256)
        let id = try vault.importFile(file, parsed: parsed, app: first, password: nil, confirmUnknownTeam: false, key: key)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests", isDirectory: true).appendingPathComponent(UUID().uuidString)
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
        XCTAssertTrue(EncryptionKeychain.hasAccessGroup(["com.apple.application-identifier": "TESTTEAM01.com.yuuki.xkeys"]))
        XCTAssertTrue(EncryptionKeychain.hasAccessGroup(["keychain-access-groups": ["TESTTEAM01.com.yuuki.xkeys"]]))
        let message = ValidationError.security(errSecMissingEntitlement).localizedDescription
        XCTAssertTrue(message.contains("開発用署名"))
        XCTAssertFalse(message.contains("パスワードとアクセス許可"))
    }

    @MainActor
    func testQuarantineWithoutVaultKeyMovesEveryBlobKeepsCatalogAndAllowsNewKey() throws {
        let (vault, app) = try makeIsolatedVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory.deletingLastPathComponent()) }
        let key = SymmetricKey(size: .bits256)
        let cer = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        try vault.importFile(cer, parsed: CredentialParser.parse(cer.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: false, key: key)
        let management = VaultManagement(vault: vault)
        try management.saveNote("note", app: app, key: key)
        try management.saveCustomSecrets([AppSecret(name: "API_TOKEN", value: "fixture")], app: app, key: key)
        try Data("orphan".utf8).write(to: vault.blobs.file(UUID()))
        let blobs = try FileManager.default.contentsOfDirectory(atPath: vault.blobs.directory.path).count
        let apps = try vault.context.fetchCount(FetchDescriptor<ManagedApp>())
        XCTAssertFalse(try vault.canCreateKey())

        XCTAssertEqual(try management.quarantineUnreadable(key: nil), blobs)
        XCTAssertTrue(try vault.records().isEmpty)
        XCTAssertNil(app.noteBlobID)
        XCTAssertNil(app.customSecretsBlobID)
        XCTAssertNil(app.customSecretNames)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<ManagedApp>()), apps)
        XCTAssertTrue(try vault.canCreateKey())
        XCTAssertGreaterThan(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), 0)
    }

    @MainActor
    func testVaultAccessQuarantinesEverythingOnlyWhenKeyIsConfirmedMissing() async throws {
        let (vault, app) = try makeIsolatedVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory.deletingLastPathComponent()) }
        let key = SymmetricKey(size: .bits256)
        let cer = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        try vault.importFile(cer, parsed: CredentialParser.parse(cer.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: false, key: key)
        let present = VaultAccess { _, _ in key }
        let unchanged = try await present.quarantineUnreadable(reason: "test", vault: vault)
        XCTAssertEqual(unchanged, 0)
        let failing = VaultAccess { _, _ in throw ValidationError.missingKey }
        do { _ = try await failing.quarantineUnreadable(reason: "test", vault: vault); XCTFail("Other key errors must not quarantine") } catch {}
        XCTAssertEqual(try vault.records().count, 1)
        let missing = VaultAccess { _, _ in throw ValidationError.keyNotFound }
        let moved = try await missing.quarantineUnreadable(reason: "test", vault: vault)
        XCTAssertEqual(moved, 1)
        XCTAssertTrue(try vault.records().isEmpty)
        XCTAssertTrue(QuarantineAction.applies(to: ValidationError.keyNotFound))
        XCTAssertTrue(QuarantineAction.applies(to: VaultError.undecryptable("sample.cer")))
        XCTAssertFalse(QuarantineAction.applies(to: ValidationError.missingKey))
    }

    @MainActor
    func testEmptyAppNoteRemovesReferenceAndRecordsChange() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let management = VaultManagement(vault: vault)
        try management.saveNote("note", app: app, key: key)
        let saved = try XCTUnwrap(app.noteBlobID)
        let history = try vault.context.fetchCount(FetchDescriptor<BackupChange>())
        try management.saveNote("", app: app, key: key)
        XCTAssertNil(app.noteBlobID)
        XCTAssertNil(try management.readNote(app, key: key))
        XCTAssertGreaterThan(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history)
        try vault.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.blobs.file(saved).path))
        XCTAssertNil(try BackupSnapshot.capture(vault: vault, key: key).apps.first { $0.id == app.id }?.note)
    }

    @MainActor
    func testAppNoteRejectsTrashedApp() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let management = VaultManagement(vault: vault)
        try management.trash(app, key: key)
        XCTAssertThrowsError(try management.saveNote("note", app: app, key: key)) { error in
            guard case VaultError.invalidAssociation = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNil(app.noteBlobID)
        XCTAssertFalse(vault.context.hasChanges)
    }

    @MainActor
    func testAddingAppWithBundleIDOfTrashedAppPointsToRecentlyDeleted() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let catalog = AppCatalog(context: vault.context)
        let teamID = try XCTUnwrap(app.team?.id)
        XCTAssertThrowsError(try catalog.addApp(name: "Again", bundleID: app.bundleID, platform: "macOS", teamID: teamID)) { error in
            guard case RegistrationError.duplicateApp = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try VaultManagement(vault: vault).trash(app, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try catalog.addApp(name: "Again", bundleID: app.bundleID.uppercased(), platform: "macOS", teamID: teamID)) { error in
            guard case RegistrationError.deletedDuplicateApp = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    func testCISecretFileSelectsLinkedCredentialsAndWritesEditableDotenv() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let team = try XCTUnwrap(app.team)
        let key = SymmetricKey(size: .bits256)
        let p12 = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        try vault.importFile(p12, parsed: CredentialParser.parse(p12.data, extension: "p12", password: "fixture-only"), app: app,
                             password: "fixture-only", confirmUnknownTeam: true, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        try vault.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app,
                             password: nil, confirmUnknownTeam: true, key: key)
        let p8 = p8File()
        try vault.importFile(p8, parsed: CredentialParser.parse(p8.data, extension: "p8"), app: nil, team: team, password: nil,
                             confirmUnknownTeam: true, key: key,
                             p8: P8Metadata(purposes: [.appStoreConnect], keyID: "DUMMYKEY01", issuerID: "69A6DE7E-0000-4000-8000-000000000001"))
        let apns = p8File()
        try vault.importFile(apns, parsed: CredentialParser.parse(apns.data, extension: "p8"), app: nil, team: team, password: nil,
                             confirmUnknownTeam: true, key: key, p8: P8Metadata(purposes: [.apns, .weatherKit], keyID: "DUMMYKEY02", issuerID: nil))
        let child = ManagedApp(name: "Share", bundleID: "com.example.Xkeys.fixture.share-ext", platform: "iOS", team: team)
        child.parentAppID = app.id
        vault.context.insert(child)
        let childProfile = StoredCredential(file: CredentialFile(data: Data("child-profile".utf8), name: "child.mobileprovision"),
                                            parsed: ParsedCredential(name: "Share Profile", kind: "プロファイル", teamID: team.teamID,
                                                                     bundleID: child.bundleID, expiresAt: .now.addingTimeInterval(86400 * 90)),
                                            app: child, team: team, savePassword: false)
        vault.context.insert(childProfile)
        try vault.context.save()

        var entries = CISecretFile.entries(for: app, records: try vault.records(), at: .now)
        XCTAssertEqual(entries.filter(\.included).map(\.name), [
            "APPLE_TEAM_ID", "BUILD_PROVISION_PROFILE_BASE64", "BUILD_PROVISION_PROFILE_SHARE_EXT_BASE64",
            "BUILD_CERTIFICATE_BASE64", "P12_PASSWORD", "ASC_KEY_P8_BASE64", "ASC_KEY_ID", "ASC_ISSUER_ID"])
        // Other keys are offered unchecked, named after their first purpose.
        XCTAssertEqual(entries.filter { !$0.included && $0.section == .key }.map(\.name), ["APNS_KEY_P8_BASE64", "APNS_KEY_ID"])
        // Checking a key or certificate brings its values along; unchecking clears them too.
        var toggled = entries
        let apnsID = try XCTUnwrap(toggled.first { $0.name == "APNS_KEY_P8_BASE64" }).id
        CISecretFile.setIncluded(true, id: apnsID, in: &toggled)
        XCTAssertEqual(toggled.filter { $0.included && $0.name.hasPrefix("APNS_") }.map(\.name), ["APNS_KEY_P8_BASE64", "APNS_KEY_ID"])
        let p12ID = try XCTUnwrap(toggled.first { $0.name == "BUILD_CERTIFICATE_BASE64" }).id
        CISecretFile.setIncluded(false, id: p12ID, in: &toggled)
        XCTAssertFalse(toggled.contains { $0.included && ["BUILD_CERTIFICATE_BASE64", "P12_PASSWORD"].contains($0.name) })
        CISecretFile.setIncluded(false, id: try XCTUnwrap(toggled.first { $0.name == "ASC_KEY_ID" }).id, in: &toggled)
        XCTAssertTrue(try XCTUnwrap(toggled.first { $0.name == "ASC_KEY_P8_BASE64" }).included)
        // The fixture child profile has no blob; leave it out and rename one entry like the sheet does.
        entries[try XCTUnwrap(entries.firstIndex { $0.id == "profile-\(childProfile.id)" })].included = false
        entries[0].name = "TEAM_ID"
        let text = try XCTUnwrap(String(data: CISecretFile.render(entries, title: "First\nApp", at: .now) { try vault.read($0, key: key) },
                                        encoding: .utf8))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "# このファイルは Xkeys が自動生成しました。編集しないでください。")
        XCTAssertTrue(lines[2].hasPrefix("# 生成元: First App · "))
        XCTAssertTrue(lines.contains("TEAM_ID='TESTTEAM01'"))
        XCTAssertTrue(lines.contains("BUILD_PROVISION_PROFILE_BASE64='\(profile.data.base64EncodedString())'"))
        XCTAssertTrue(lines.contains("BUILD_CERTIFICATE_BASE64='\(p12.data.base64EncodedString())'"))
        XCTAssertTrue(lines.contains("P12_PASSWORD='fixture-only'"))
        XCTAssertTrue(lines.contains("ASC_KEY_P8_BASE64='\(p8.data.base64EncodedString())'"))
        XCTAssertTrue(lines.contains("ASC_ISSUER_ID='69a6de7e-0000-4000-8000-000000000001'"))
        XCTAssertFalse(text.contains("APPLE_TEAM_ID"))

        let output = vault.blobs.directory.appendingPathComponent("First.ci-secrets.env")
        try CredentialFile(data: Data(text.utf8), name: output.lastPathComponent).export(to: output)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try CredentialFile(data: Data(), name: output.lastPathComponent).export(to: output))

        func rejects(_ name: String, at index: Int = 0) {
            var changed = entries
            changed[index].name = name
            XCTAssertThrowsError(try CISecretFile.validate(changed), name)
        }
        rejects("asc_key_id")
        rejects("GITHUB_TOKEN")
        rejects("1TEAM")
        rejects("TEAM ID")
        XCTAssertThrowsError(try CISecretFile.validate(entries.map { var entry = $0; entry.included = false; return entry }))

        // A missing password is written commented out; a password dotenv cannot quote is refused.
        let original = try vault.read(try XCTUnwrap(vault.records().first { $0.fileExtension == "p12" }), key: key).original
        let missing = try XCTUnwrap(String(data: CISecretFile.render(entries, title: "First", at: .now) { record in
            record.fileExtension == "p12" ? CredentialPayload(original: original, password: nil) : try vault.read(record, key: key)
        }, encoding: .utf8))
        XCTAssertTrue(missing.contains("\n# P12_PASSWORD=\n"))
        XCTAssertFalse(missing.contains("P12_PASSWORD='"))
        XCTAssertThrowsError(try CISecretFile.render(entries, title: "First", at: .now) { record in
            record.fileExtension == "p12" ? CredentialPayload(original: original, password: "it's") : try vault.read(record, key: key)
        })

        // Expired profiles are not offered, so their certificate is no longer chosen.
        let stored = try XCTUnwrap(vault.records().first { $0.fileExtension == "mobileprovision" && $0.app?.id == app.id })
        stored.expiresAt = .now.addingTimeInterval(-60)
        let later = CISecretFile.entries(for: app, records: try vault.records(), at: .now)
        XCTAssertFalse(later.contains { $0.id == "profile-\(stored.id)" })
        XCTAssertFalse(try XCTUnwrap(later.first { $0.name == "BUILD_CERTIFICATE_BASE64" }).included)
    }

    @MainActor
    func testAttentionScopeIncludesExpiredAndExpiringAcrossTeams() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        let now = Date.now
        let includes = { CredentialSearch.includes(record, scope: .attention, app: nil, query: "", type: .all, at: now) }
        record.expiresAt = now.addingTimeInterval(86400 * 90)
        XCTAssertFalse(includes())
        record.expiresAt = now.addingTimeInterval(86400 * 10)
        XCTAssertTrue(includes())
        record.expiresAt = now.addingTimeInterval(-1)
        XCTAssertTrue(includes())
        record.expiresAt = nil
        XCTAssertFalse(includes())
    }

    func testEncryptedBlobStoreRejectsWrongKeyAADAndTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedBlobStore(directory: directory)
        let key = SymmetricKey(size: .bits256), id = UUID(), aad = Data("fixture-aad".utf8)
        let data = Data("test-secret-must-not-be-plaintext".utf8)
        try store.write(data, id: id, key: key, authenticating: aad)
        XCTAssertEqual(try store.read(id, key: key, authenticating: aad), data)
        XCTAssertThrowsError(try store.write(data, id: id, key: key, authenticating: aad))
        let sealed = try Data(contentsOf: store.file(id))
        XCTAssertNil(sealed.range(of: data))
        XCTAssertThrowsError(try store.read(id, key: SymmetricKey(size: .bits256), authenticating: aad))
        XCTAssertThrowsError(try store.read(id, key: key, authenticating: Data("other-aad".utf8)))
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: store.file(id))
        XCTAssertThrowsError(try store.read(id, key: key, authenticating: aad))
    }

    func testEncryptedBlobStoreRemovesOnlyUnreferencedBlobs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedBlobStore(directory: directory)
        let key = SymmetricKey(size: .bits256), saved = UUID(), aad = Data("fixture-aad".utf8)
        try store.write(Data("test".utf8), id: saved, key: key, authenticating: aad)
        // An unreferenced blob models termination between the file write and metadata commit.
        let orphan = UUID()
        try Data("orphan".utf8).write(to: store.file(orphan))
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        try store.removeOrphans(keeping: [saved])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try store.read(saved, key: key, authenticating: aad), Data("test".utf8))
    }
}
