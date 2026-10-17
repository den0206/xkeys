import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
import XcodesLoginKit
@testable import Xkeys

/// Credential parsing, file reading and embedded certificate lists.
extension XkeysTests {
    @MainActor
    func testP12DuplicateCandidatesCompareAllCertificatesWithinTeamWithoutChangingV1Data() throws {
        let (vault, app, _, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let team = try XCTUnwrap(app.team)
        let file = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        let parsed = try CredentialParser.parse(file.data, extension: "p12", password: "fixture-only")
        let key = SymmetricKey(size: .bits256)
        let id = try vault.importFile(file, parsed: parsed, app: app, password: "fixture-only", confirmUnknownTeam: false, key: key)
        let stored = try XCTUnwrap(vault.records().first { $0.id == id })
        let aad = try stored.authenticatedData()
        XCTAssertEqual(try vault.matchingP12Certificates(parsed, team: team).map(\.id), [id])
        XCTAssertTrue(try vault.matchingP12Certificates(parsed, team: XCTUnwrap(other.team)).isEmpty)
        var different = parsed
        different.p12Certificates = [ContainedCertificate(fingerprint: "different", name: "Other", expiresAt: nil)]
        XCTAssertTrue(try vault.matchingP12Certificates(different, team: team).isEmpty)
        var bundle = parsed
        bundle.p12Certificates?.append(ContainedCertificate(fingerprint: "additional", name: "Installer", expiresAt: nil))
        XCTAssertTrue(try vault.matchingP12Certificates(bundle, team: team).isEmpty)
        stored.p12Certificates = StoredCredential.encode(Array(try XCTUnwrap(bundle.p12Certificates).reversed()))
        XCTAssertEqual(try vault.matchingP12Certificates(bundle, team: team).map(\.id), [id])
        stored.deletedAt = .now
        XCTAssertEqual(try vault.matchingP12Certificates(bundle, team: team).map(\.id), [id])
        stored.p12Certificates = nil
        XCTAssertTrue(try vault.matchingP12Certificates(parsed, team: team).isEmpty)
        XCTAssertTrue(try vault.matchingP12Certificates(different, team: team).isEmpty)
        XCTAssertNil(try CredentialParser.parse(fixture("cer"), extension: "cer").p12CertificateFingerprints)
        XCTAssertEqual(try stored.authenticatedData(), aad)
        XCTAssertEqual(try vault.read(stored, key: key).original, file.data)
        XCTAssertEqual(try vault.read(stored, key: key).version, 1)
    }

    func testFolderImportDoesNotFollowSymlinksOrDuplicateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.cer")
        try Data([1]).write(to: file)
        try Data([2]).write(to: root.appendingPathComponent("ignore.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.cer"), withDestinationURL: file)
        XCTAssertEqual(try ImportSources.collect([root, file]).map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
        XCTAssertThrowsError(try ImportSources.collect([root.appendingPathComponent("linked.cer")]))
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
                                         password: nil, confirmUnknownTeam: true, key: key)
        let old = try XCTUnwrap(vault.records().first(where: { $0.id == oldID }))
        let new = try XCTUnwrap(vault.records().first(where: { $0.id == newID }))
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
        XCTAssertThrowsError(try P8Metadata(purposes: [.appStoreConnect], keyID: "DUMMYKEY01", issuerID: nil).validated())
        XCTAssertThrowsError(try P8Metadata(purposes: [.apns], keyID: "short", issuerID: nil).validated())
        let issuer = UUID()
        let asc = try P8Metadata(purposes: [.appStoreConnect], keyID: " DUMMYKEY01 ", issuerID: issuer.uuidString).validated()
        XCTAssertEqual(asc.issuerID, issuer.uuidString.lowercased())
        for purpose in [P8Purpose.apns, .signInWithApple] {
            XCTAssertNil(try P8Metadata(purposes: [purpose], keyID: "DUMMYKEY01", issuerID: "irrelevant").validated().issuerID)
        }
    }

    @MainActor
    func testP8StoresMultiplePurposesCanonically() throws {
        XCTAssertThrowsError(try P8Metadata(purposes: [], keyID: "DUMMYKEY01", issuerID: nil).validated())
        XCTAssertThrowsError(try P8Metadata(purposes: [.appStoreConnect, .maps], keyID: "DUMMYKEY01", issuerID: UUID().uuidString).validated())
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let file = p8File()
        let id = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app, password: nil,
                                      confirmUnknownTeam: true, key: key, p8: P8Metadata(purposes: [.maps, .apns, .maps], keyID: "DUMMYKEY01", issuerID: nil))
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        XCTAssertEqual(record.keyPurpose, "apns,maps")
        XCTAssertEqual(record.name, "APNs・Maps（DUMMYKEY01）")
        XCTAssertEqual(CredentialPurposeFilter.allCases.filter { $0 != .all && $0.matches(record) }, [.key(.apns), .key(.maps)])
        XCTAssertTrue(CredentialSearch.matches(record, query: "maps"))
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        _ = try BackupArchive.decode(BackupArchive.encode(BackupSnapshot.capture(vault: vault, key: key), password: nil), password: nil)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let stored = try XCTUnwrap(snapshot.credentials.first)
        // Non-canonical order and unknown values are rejected; a single purpose is valid.
        for (value, valid) in [("maps,apns", false), ("apns,unknown", false), ("", false), ("apns,,maps", false), ("apns", true), ("sign-in", true)] {
            let changed = try JSONDecoder().decode(BackupSnapshot.self, from: JSONEncoder().encode(snapshot)
                .replacing(Data(#""keyPurpose":"apns,maps""#.utf8), with: Data(#""keyPurpose":"\#(value)""#.utf8)))
            XCTAssertEqual(changed.credentials.first?.keyPurpose, value)
            XCTAssertEqual((try? changed.validate()) != nil, valid, value)
        }
        XCTAssertEqual(stored.keyPurpose, "apns,maps")
    }

    func testSignedProfileMetadata() throws {
        let data = try fixture("mobileprovision")
        let value = try CredentialParser.parse(data, extension: "mobileprovision")
        XCTAssertEqual(value.name, "Xkeys Test Profile")
        XCTAssertEqual(value.teamID, "TESTTEAM01")
        XCTAssertEqual(value.bundleID, "com.example.Xkeys.fixture")
        XCTAssertEqual(value.expiresAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testProfileParsesEmbeddedCertificateDigestsInOrder() throws {
        let sha = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let value = try CredentialParser.parse(fixture("mobileprovision", name: "certs"), extension: "mobileprovision")
        XCTAssertEqual(value.signingCertificateDigests, [sha(try fixture("cer")), sha(try fixture("cer", name: "renewed"))])
        XCTAssertEqual(try CredentialParser.parse(fixture("mobileprovision"), extension: "mobileprovision").signingCertificateDigests, [])
        XCTAssertNil(try CredentialParser.parse(fixture("cer"), extension: "cer").signingCertificateDigests)
    }

    @MainActor
    func testBackfillReadsProfileCertificatesWithoutChangingAADOrBackupHistory() async throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        let expected = try XCTUnwrap(record.signingCertificateDigests)
        XCTAssertEqual(expected.split(separator: ",").count, 2)
        let aad = try record.authenticatedData()
        // Simulate a profile stored before the field existed.
        record.signingCertificateDigests = nil
        try vault.context.save()
        let history = try vault.context.fetchCount(FetchDescriptor<BackupChange>())

        try await VaultManagement(vault: vault).backfillSigningCertificates(key: key)
        XCTAssertEqual(record.signingCertificateDigests, expected)
        XCTAssertEqual(try record.authenticatedData(), aad)
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history)
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).credentials.count, 1)
    }

    @MainActor
    func testBackfillMarksUnreadableProfileOnceAndKeepsOtherProfiles() async throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        record.signingCertificateDigests = nil
        try vault.context.save()
        // A different key cannot decrypt the blob: the profile is marked "" and is not retried.
        try await VaultManagement(vault: vault).backfillSigningCertificates(key: SymmetricKey(size: .bits256))
        XCTAssertEqual(record.signingCertificateDigests, "")
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
    }

    @MainActor
    func testProfileLinksToTeamCertificateAndReportsExpiredSigning() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let certificate = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(certificate, parsed: CredentialParser.parse(certificate.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        _ = try vault.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let records = try vault.records()
        let cer = try XCTUnwrap(records.first { $0.fileExtension == "cer" })
        let prov = try XCTUnwrap(records.first { $0.fileExtension == "mobileprovision" })

        XCTAssertEqual(prov.signingCertificates(in: records).map(\.id), [cer.id])
        XCTAssertEqual(cer.profilesUsing(in: records).map(\.id), [prov.id])
        let now = Date.now
        cer.expiresAt = now.addingTimeInterval(86400 * 365)
        XCTAssertFalse(prov.signingCertificatesExpired(in: records, at: now))
        cer.expiresAt = now.addingTimeInterval(-60)
        XCTAssertTrue(prov.signingCertificatesExpired(in: records, at: now))
        XCTAssertTrue(prov.needsAttention(in: records, at: now))
        // A deleted certificate or an unread profile shows no link instead of a false "unusable".
        cer.deletedAt = now
        XCTAssertFalse(prov.signingCertificatesExpired(in: records, at: now))
        cer.deletedAt = nil
        prov.signingCertificateDigests = nil
        XCTAssertTrue(prov.signingCertificates(in: records).isEmpty)
    }

    func testPKCS12ParsesEveryContainedCertificateForEachCandidate() throws {
        let candidates = try CredentialParser.parseAll(fixture("p12", name: "chain"), extension: "p12", password: "fixture-only")
        XCTAssertGreaterThan(candidates.count, 1)
        for candidate in candidates {
            XCTAssertEqual(candidate.p12Certificates?.map(\.fingerprint), candidates.map(\.fingerprint))
        }
        XCTAssertNil(try CredentialParser.parse(fixture("cer"), extension: "cer").p12Certificates)
    }

    @MainActor
    func testProfileLinksToCertificateBundledInPKCS12AndUsesItsExpiry() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let sha = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let p12 = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        try vault.importFile(p12, parsed: CredentialParser.parse(p12.data, extension: "p12", password: "fixture-only"), app: app,
                             password: "fixture-only", confirmUnknownTeam: true, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        try vault.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app,
                             password: nil, confirmUnknownTeam: true, key: key)
        let records = try vault.records()
        let identity = try XCTUnwrap(records.first { $0.fileExtension == "p12" })
        let prov = try XCTUnwrap(records.first { $0.fileExtension == "mobileprovision" })
        XCTAssertNotNil(identity.p12Certificates)
        XCTAssertTrue(identity.bundledCertificates.isEmpty)

        // The chosen certificate is not in the profile; only the bundled renewed.cer is.
        let now = Date.now
        let renewed = sha(try fixture("cer", name: "renewed"))
        identity.fingerprint = "chosen-not-in-profile"
        identity.expiresAt = now.addingTimeInterval(-60)
        identity.p12Certificates = StoredCredential.encode([
            ContainedCertificate(fingerprint: "chosen-not-in-profile", name: "Chosen", expiresAt: identity.expiresAt),
            ContainedCertificate(fingerprint: renewed, name: "Bundled", expiresAt: now.addingTimeInterval(86400 * 365)),
        ])
        XCTAssertEqual(identity.bundledCertificates.map(\.name), ["Bundled"])
        XCTAssertEqual(prov.signingCertificates(in: records).map(\.id), [identity.id])
        XCTAssertEqual(identity.profilesUsing(in: records).map(\.id), [prov.id])
        XCTAssertFalse(prov.signingCertificatesExpired(in: records, at: now))
        identity.p12Certificates = StoredCredential.encode([
            ContainedCertificate(fingerprint: renewed, name: "Bundled", expiresAt: now.addingTimeInterval(-60)),
        ])
        XCTAssertTrue(prov.signingCertificatesExpired(in: records, at: now))
    }

    @MainActor
    func testBackfillReadsPKCS12CertificatesOnlyWithSavedPassword() async throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let saved = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        try vault.importFile(saved, parsed: CredentialParser.parse(saved.data, extension: "p12", password: "fixture-only"), app: app,
                             password: "fixture-only", confirmUnknownTeam: true, key: key)
        let chain = CredentialFile(data: try fixture("p12", name: "chain"), name: "chain.p12")
        let chainParsed = try XCTUnwrap(CredentialParser.parseAll(chain.data, extension: "p12", password: "fixture-only").first)
        try vault.importFile(chain, parsed: chainParsed, app: app, password: nil, confirmUnknownTeam: true, key: key)
        let records = try vault.records()
        let withPassword = try XCTUnwrap(records.first { $0.originalName == "sample.p12" })
        let withoutPassword = try XCTUnwrap(records.first { $0.originalName == "chain.p12" })
        let expected = try XCTUnwrap(withPassword.p12Certificates)
        let aad = try withPassword.authenticatedData()
        // Simulate files stored before the field existed or restored from a backup.
        withPassword.p12Certificates = nil
        withoutPassword.p12Certificates = nil
        try vault.context.save()
        let history = try vault.context.fetchCount(FetchDescriptor<BackupChange>())

        try await VaultManagement(vault: vault).backfillSigningCertificates(key: key)
        XCTAssertEqual(withPassword.p12Certificates, expected)
        XCTAssertNil(withoutPassword.p12Certificates)
        XCTAssertEqual(try withPassword.authenticatedData(), aad)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history)
    }

    func testProfileTamperAndUnsignedPlistRejected() throws {
        let data = try fixture("mobileprovision")
        var bytes = data
        let marker = Data("Xkeys Test Profile".utf8)
        let range = try XCTUnwrap(bytes.range(of: marker))
        bytes[range.lowerBound] ^= 1
        XCTAssertThrowsError(try CredentialParser.parse(bytes, extension: "mobileprovision"))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Name": "Not signed"], format: .xml, options: 0)
        XCTAssertThrowsError(try CredentialParser.parse(plist, extension: "mobileprovision"))
    }

    @MainActor
    func testIntermediateCAImportsWithoutTeamConfirmationAndSurvivesBackup() async throws {
        let file = CredentialFile(data: try fixture("cer", name: "developer-id-g2"), name: "renamed.cer")
        let parsed = try CredentialParser.parse(file.data, extension: "cer")
        XCTAssertTrue(parsed.isIntermediateCA)
        XCTAssertNil(parsed.teamID)
        XCTAssertEqual(parsed.name, "Developer ID Certification Authority")
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let id = try vault.importFile(file, parsed: parsed, app: app, password: nil, confirmUnknownTeam: false, key: key)
        let record = try XCTUnwrap(vault.records().first { $0.id == id })
        XCTAssertTrue(record.isIntermediateCA)
        XCTAssertEqual(record.fileTypeTitle, "中間CA証明書")
        XCTAssertNil(record.sourceTeamID)
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        let decoded = try BackupArchive.decode(BackupArchive.encode(snapshot, password: nil), password: nil)
        let (target, _, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: target.blobs.directory) }
        let restore = BackupRestore(vault: target)
        let plan = try restore.prepare(decoded, key: key)
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) }), authorization: approvalPlan1, key: key)
        let restored = try XCTUnwrap(target.records().first)
        XCTAssertTrue(restored.isIntermediateCA)
        XCTAssertEqual(try target.read(restored, key: key).original, file.data)
        let ordinary = try CredentialParser.parse(fixture("cer"), extension: "cer")
        XCTAssertFalse(ordinary.isIntermediateCA)
        XCTAssertEqual(ordinary.teamID, "TESTTEAM01")
    }

    func testCertificateAndPKCS12() throws {
        let certificate = try CredentialParser.parse(fixture("cer"), extension: "cer")
        let identity = try CredentialParser.parse(fixture("p12"), extension: "p12", password: "fixture-only")
        XCTAssertEqual(certificate.name, "Xkeys Test Only")
        XCTAssertEqual(identity.name, certificate.name)
        XCTAssertEqual(certificate.teamID, "TESTTEAM01")
        XCTAssertEqual(identity.teamID, "TESTTEAM01")
        XCTAssertEqual(certificate.expiresAt, identity.expiresAt)
        XCTAssertThrowsError(try CredentialParser.parse(fixture("p12"), extension: "p12", password: "wrong"))
    }

    @MainActor
    func testCertificateAndPKCS12RejectDifferentTeams() throws {
        let (vault, app, _, other) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        for ext in ["cer", "p12"] {
            let file = CredentialFile(data: try fixture(ext), name: "sample." + ext)
            let parsed = try CredentialParser.parse(file.data, extension: ext, password: "fixture-only")
            XCTAssertNoThrow(try vault.validate(file: file, parsed: parsed, app: app, confirmUnknownTeam: false))
            XCTAssertThrowsError(try vault.validate(file: file, parsed: parsed, app: other, confirmUnknownTeam: true)) { error in
                guard case VaultError.teamMismatch = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
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
        XCTAssertEqual(Set(candidates.map(\.name)), ["Xkeys Chain Leaf", "Xkeys Chain Root"])
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
}
