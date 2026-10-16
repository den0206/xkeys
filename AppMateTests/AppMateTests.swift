import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
import XcodesLoginKit
@testable import AppMate

final class AppMateTests: XCTestCase {
    @MainActor
    private func restoreAuthorization(for plan: RestorePlan) async throws -> RestoreTeamAuthorization {
        let transport = FakeAppleDeveloperTransport()
        transport.teams = plan.incoming.teams.map { RemoteDeveloperTeam(teamID: $0.teamID, name: $0.name) }
        let session = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        let authorization = RestoreTeamAuthorization()
        try session.confirm(authorization, plan: plan)
        return authorization
    }

    @MainActor
    func testSecondFactorSuccessLeavesCodeEntryBeforeTeamsFinishLoading() async throws {
        let transport = FakeAppleDeveloperTransport()
        transport.loginState = .waitingForSecondFactor(
            .codeSent, try JSONDecoder().decode(AuthOptionsResponse.self, from: Data("{}".utf8)),
            AppleSessionData(serviceKey: "fixture", sessionID: "fixture", scnt: "fixture"))
        let session = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        guard case .waitingForSecondFactor = session.authentication else { return XCTFail("Code entry must be shown") }
        transport.pauseTeams = true
        let pending = Task { try await session.submit(code: "123456") }
        for _ in 0..<100 where transport.teamsGate == nil { await Task.yield() }
        let gate = try XCTUnwrap(transport.teamsGate)
        guard case .authenticated = session.authentication else {
            gate.resume()
            _ = try? await pending.value
            return XCTFail("Successful verification must leave code entry immediately")
        }
        XCTAssertTrue(session.busy)
        XCTAssertFalse(session.connected)
        gate.resume()
        try await pending.value
        XCTAssertTrue(session.connected)
        XCTAssertFalse(session.busy)
        XCTAssertEqual(session.teams, transport.teams)
    }

    @MainActor
    func testAppleAccountPersistsWithoutConnectingAndLegacyCookiesUpgrade() async throws {
        let store = MemoryAppleSessionStore()
        let transport = FakeAppleDeveloperTransport()
        transport.accountIdentity = AppleDeveloperAccount(email: "verified@example.invalid", name: "Fixture")
        let session = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        try await session.login(account: "input@example.invalid", password: "fixture-only")
        XCTAssertEqual(session.currentAccount?.email, "verified@example.invalid")
        session.suspend()
        XCTAssertNil(session.currentAccount)
        let restored = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        try restored.loadSavedAccount()
        XCTAssertEqual(restored.savedAccount?.email, "verified@example.invalid")
        XCTAssertFalse(restored.connected)
        XCTAssertFalse(transport.imported)
        try await restored.resume()
        XCTAssertEqual(restored.currentAccount?.email, "verified@example.invalid")
        try restored.disconnect()
        XCTAssertNil(restored.savedAccount)
        XCTAssertFalse(restored.hasSavedSession)
        store.data = Data("[]".utf8)
        try restored.loadSavedAccount()
        XCTAssertTrue(restored.hasSavedSession)
        XCTAssertNil(restored.savedAccount)
        try await restored.resume()
        XCTAssertEqual(try SavedAppleDeveloperSession.read(XCTUnwrap(store.data)).account?.email, "verified@example.invalid")
        XCTAssertThrowsError(try SavedAppleDeveloperSession(version: 2, cookies: Data([1]), account: nil).encoded())
        XCTAssertThrowsError(try SavedAppleDeveloperSession.read(Data("invalid".utf8)))
    }

    @MainActor
    func testTeamManagementRestoresSavedLoginWhenOpened() async throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let team = try XCTUnwrap(app.team)
        team.name = "個人開発"
        vault.context.insert(DeveloperTeam(name: "別のチーム", teamID: "OTHERID001"))
        try vault.context.save()
        let store = MemoryAppleSessionStore()
        let transport = FakeAppleDeveloperTransport()
        transport.teams = [RemoteDeveloperTeam(teamID: team.teamID, name: team.name)]
        let previous = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        try await previous.login(account: "fixture@example.invalid", password: "fixture-only")
        previous.suspend()
        let restored = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        XCTAssertFalse(restored.connected)
        let view = NSHostingView(rootView: TeamManagementView(vault: vault, appleSession: restored, onDeleted: { _ in })
            .modelContainer(vault.context.container).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.orderFront(nil)
        for _ in 0..<100 where !restored.connected { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(restored.connected)
        XCTAssertTrue(transport.imported)
        XCTAssertEqual(restored.currentAccount?.email, "fixture@example.invalid")
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "team-management-login-actions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAppleAccountParserValidatesServerIdentity() throws {
        let data = Data(#"{"user":{"emailAddress":" verified@example.invalid ","fullName":" Fixture "}}"#.utf8)
        XCTAssertEqual(try AppleDeveloperClient.parseAccount(data), AppleDeveloperAccount(email: "verified@example.invalid", name: "Fixture"))
        XCTAssertThrowsError(try AppleDeveloperClient.parseAccount(Data("{}".utf8)))
        let oversized = try JSONSerialization.data(withJSONObject: ["user": ["emailAddress": String(repeating: "a", count: 1_025)]])
        XCTAssertThrowsError(try AppleDeveloperClient.parseAccount(oversized))
    }

    func testAppleTeamParserValidatesIDsDuplicatesAndLegacyPlist() throws {
        let valid: [String: Any] = ["resultCode": 0, "teams": [["teamId": "TESTTEAM01", "name": " Fixture "]]]
        for data in [try JSONSerialization.data(withJSONObject: valid),
                     try PropertyListSerialization.data(fromPropertyList: valid, format: .xml, options: 0)] {
            XCTAssertEqual(try AppleDeveloperClient.parseTeams(data), [RemoteDeveloperTeam(teamID: "TESTTEAM01", name: "Fixture")])
        }
        for teams in [ [["teamId": "wrong", "name": "Fixture"]],
                       [["teamId": "TESTTEAM01", "name": ""]],
                       [["teamId": "TESTTEAM01", "name": "One"], ["teamId": "TESTTEAM01", "name": "Other"]] ] {
            XCTAssertThrowsError(try AppleDeveloperClient.parseTeams(JSONSerialization.data(withJSONObject: ["resultCode": 0, "teams": teams])))
        }
        XCTAssertThrowsError(try AppleDeveloperClient.parseTeams(Data("<html>Login</html>".utf8)))
        XCTAssertThrowsError(try AppleDeveloperClient.parseTeams(Data("{\"teams\":[]}".utf8)))
        XCTAssertThrowsError(try AppleDeveloperClient.parseTeams(Data("{\"resultCode\":1100}".utf8)))
    }

    @MainActor
    func testAppleSessionSurvivesSuspendAndNetworkFailureButDisconnectDeletesIt() async throws {
        let store = MemoryAppleSessionStore()
        let transport = FakeAppleDeveloperTransport()
        let session = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        XCTAssertTrue(session.connected)
        XCTAssertNotNil(store.data)
        session.suspend()
        XCTAssertFalse(session.connected)
        XCTAssertTrue(transport.cancelled)
        XCTAssertNotNil(store.data)
        try await session.resume()
        XCTAssertTrue(transport.imported)
        XCTAssertTrue(session.connected)
        transport.failure = URLError(.notConnectedToInternet)
        do { try await session.resume(); XCTFail("Network failure must stop the operation") } catch { }
        XCTAssertNotNil(store.data)
        transport.failure = AppleDeveloperError.loginRequired
        do { try await session.resume(); XCTFail("Expired login must fail") } catch { }
        XCTAssertNil(store.data)
        transport.failure = nil
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        try session.disconnect()
        XCTAssertNil(store.data)
        XCTAssertFalse(session.connected)
    }

    @MainActor
    func testUnregisteredRestoreRequiresMembershipAndReceiptExpiresOrInvalidates() async throws {
        let (source, _, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory) }
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = CredentialVault(context: ModelContext(container), blobs: EncryptedBlobStore(directory: directory))
        let service = BackupRestore(vault: target)
        let key = SymmetricKey(size: .bits256)
        let plan = try service.prepare(BackupSnapshot.capture(vault: source, key: key), key: key)
        XCTAssertFalse(plan.requiredTeamIDs.isEmpty)
        XCTAssertThrowsError(try service.merge(plan, choices: [:], key: key))
        XCTAssertThrowsError(try service.merge(plan, choices: [:], key: key, replacingAll: true))
        XCTAssertTrue(try target.context.fetch(FetchDescriptor<DeveloperTeam>()).isEmpty)
        let transport = FakeAppleDeveloperTransport()
        let session = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { transport }, observeLock: false)
        let authorization = RestoreTeamAuthorization()
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        try session.confirm(authorization, plan: plan)
        XCTAssertThrowsError(try authorization.validate(plan)) // The second team is still missing.
        session.useAnotherAccount()
        transport.teams = plan.incoming.teams.filter { $0.teamID != "TESTTEAM01" }.map { RemoteDeveloperTeam(teamID: $0.teamID, name: $0.name) }
        try await session.login(account: "other@example.invalid", password: "fixture-only")
        try session.confirm(authorization, plan: plan)
        XCTAssertNoThrow(try authorization.validate(plan))
        XCTAssertThrowsError(try authorization.validate(plan, at: Date.now.addingTimeInterval(301)))
        session.suspend()
        XCTAssertThrowsError(try authorization.validate(plan))
        let approved = try await restoreAuthorization(for: plan)
        _ = try service.merge(plan, choices: [:], authorization: approved, key: key)
        let repeatPlan = try service.prepare(plan.incoming, key: key)
        XCTAssertTrue(repeatPlan.requiredTeamIDs.isEmpty)
        XCTAssertNoThrow(try service.merge(repeatPlan, choices: [:], key: key))
    }

    @MainActor
    func testRemoteTeamRegistrationKeepsExistingIdentityAndLocalName() async throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let team = try XCTUnwrap(app.team)
        let originalName = team.name
        let transport = FakeAppleDeveloperTransport()
        transport.teams = [RemoteDeveloperTeam(teamID: team.teamID, name: "Remote name")]
        let session = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        XCTAssertEqual(try session.register(transport.teams[0], catalog: AppCatalog(context: vault.context)), team.id)
        XCTAssertEqual(team.name, originalName)
        XCTAssertThrowsError(try session.register(RemoteDeveloperTeam(teamID: "OTHERID001", name: "Unknown"), catalog: AppCatalog(context: vault.context)))
    }

    @MainActor
    func testAppleSessionRejectsLateValidationAfterSuspendAndKeychainFailures() async throws {
        let store = FailingAppleSessionStore()
        let transport = FakeAppleDeveloperTransport()
        let session = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        store.failWrite = true
        do { try await session.login(account: "fixture@example.invalid", password: "fixture-only"); XCTFail("Saving must fail") } catch { }
        XCTAssertFalse(session.connected)
        store.failWrite = false
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        let saved = store.data
        session.suspend()
        transport.pauseValidation = true
        let pending = Task { try await session.resume() }
        for _ in 0..<100 where transport.validationGate == nil { await Task.yield() }
        let gate = try XCTUnwrap(transport.validationGate)
        session.suspend()
        gate.resume()
        do { try await pending.value; XCTFail("Old validation must not reconnect") } catch { }
        XCTAssertFalse(session.connected)
        XCTAssertEqual(store.data, saved)
        store.failDelete = true
        XCTAssertThrowsError(try session.disconnect())
        XCTAssertFalse(session.connected)
        store.failDelete = false
        try session.disconnect()
        XCTAssertNil(store.data)
    }

    @MainActor
    func testRestoreReceiptCannotAuthorizeAnotherSnapshotOrForgedTeamList() async throws {
        let (source, _, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: source.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        let incoming = try BackupSnapshot.capture(vault: source, key: key)
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = CredentialVault(context: ModelContext(container), blobs: EncryptedBlobStore(directory: directory))
        let service = BackupRestore(vault: target)
        let plan = try service.prepare(incoming, key: key)
        let approval = try await restoreAuthorization(for: plan)
        let changed = BackupSnapshot(version: incoming.version, createdAt: incoming.createdAt, appVersion: incoming.appVersion,
                                     teams: incoming.teams.enumerated().map { index, team in
                                         .init(id: team.id, name: index == 0 ? "Changed" : team.name, teamID: team.teamID)
                                     }, apps: incoming.apps, credentials: incoming.credentials, preferences: incoming.preferences)
        let other = try service.prepare(changed, key: key)
        XCTAssertThrowsError(try service.merge(other, choices: [:], authorization: approval, key: key))
        let forged = RestorePlan(incoming: plan.incoming, localRevision: plan.localRevision, items: [], requiresSafetyBackup: false)
        XCTAssertThrowsError(try service.merge(forged, choices: [:], authorization: approval, key: key, replacingAll: true))
        XCTAssertTrue(try target.context.fetch(FetchDescriptor<DeveloperTeam>()).isEmpty)
    }

    @MainActor
    func testAppleCookiesStayIsolatedAndRejectUntrustedDomainsAndOversizedValues() throws {
        let client = AppleDeveloperClient()
        defer { client.cancel() }
        let valid: [[String: Any]] = [["name": "myacinfo", "value": "fixture-token", "domain": ".apple.com", "path": "/", "httpOnly": true]]
        try client.importCookies(JSONSerialization.data(withJSONObject: valid))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: client.exportCookies()) as? [[String: Any]])
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?["value"] as? String, "fixture-token")
        XCTAssertEqual(exported.first?["httpOnly"] as? Bool, true)
        for (domain, path, value) in [("apple.com.invalid", "/", "fixture"),
                                      (".apple.com", "invalid", "fixture"),
                                      (".apple.com", "/", String(repeating: "x", count: 32_769))] {
            let invalid: [[String: Any]] = [["name": "myacinfo", "value": value, "domain": domain, "path": path, "httpOnly": false]]
            XCTAssertThrowsError(try client.importCookies(JSONSerialization.data(withJSONObject: invalid)))
        }
        XCTAssertThrowsError(try client.importCookies(Data(repeating: 0, count: 262_145)))
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: client.exportCookies()) as? [[String: Any]]).count, 1)
    }

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

    func testDeveloperFilePagesRejectInvalidMetadataAndUnsafePaginationLinks() throws {
        let object: [String: Any] = ["data": [["id": "CERT001", "type": "certificates", "attributes": ["name": "Fixture", "certificateType": "DISTRIBUTION", "expirationDate": "2027-01-01T00:00:00.000Z"]]],
                                     "links": ["next": NSNull()]]
        let page = try AppleDeveloperClient.parseFilePage(JSONSerialization.data(withJSONObject: object), kind: .certificates)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].id, "CERT001")
        XCTAssertNotNil(page.items[0].expiresAt)
        XCTAssertNil(page.next)
        XCTAssertThrowsError(try AppleDeveloperClient.parseFilePage(JSONSerialization.data(withJSONObject: object), kind: .profiles))
        for id in ["../escape", "", String(repeating: "a", count: 129)] {
            let invalid: [String: Any] = ["data": [["id": id, "type": "certificates", "attributes": ["name": "Fixture"]]]]
            XCTAssertThrowsError(try AppleDeveloperClient.parseFilePage(JSONSerialization.data(withJSONObject: invalid), kind: .certificates))
        }
        for link in ["https://example.invalid/v1/certificates", "http://developer.apple.com/services-account/v1/certificates",
                     "https://developer.apple.com/services-account/v1/profiles", "https://user@developer.apple.com/v1/certificates",
                     "https://developer.apple.com:444/v1/certificates"] {
            XCTAssertThrowsError(try AppleDeveloperClient.provisioningURL(link, kind: .certificates))
        }
        let normalized = try AppleDeveloperClient.provisioningURL("https://api.appstoreconnect.apple.com/v1/certificates?cursor=NEXT", kind: .certificates)
        XCTAssertEqual(normalized.host, "developer.apple.com")
        XCTAssertEqual(normalized.path, "/services-account/v1/certificates")
        XCTAssertEqual(normalized.query, "cursor=NEXT")
    }

    @MainActor
    func testDeveloperFileClientUsesTeamScopedReadProxyAndFollowsPages() async throws {
        let certificate = try fixture("cer")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeveloperHTTPStub.self]
        let client = AppleDeveloperClient(configuration: configuration)
        defer { client.cancel(); DeveloperHTTPStub.handler = nil }
        DeveloperHTTPStub.handler = { request in
            XCTAssertEqual(request.url?.host, "developer.apple.com")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-HTTP-Method-Override"), "GET")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: DeveloperHTTPStub.body(request)) as? [String: String])
            XCTAssertEqual(body["teamId"], "TESTTEAM01")
            if request.url?.path.hasSuffix("/CERT001") == true {
                let result: [String: Any] = ["data": ["id": "CERT001", "type": "certificates", "attributes": ["certificateContent": certificate.base64EncodedString()]]]
                return (200, try JSONSerialization.data(withJSONObject: result))
            }
            let second = body["urlEncodedQueryParams"]?.contains("cursor=NEXT") == true
            if second { XCTAssertEqual(request.value(forHTTPHeaderField: "csrf"), "fixture-csrf") }
            let id = second ? "CERT002" : "CERT001"
            let next: Any = second ? NSNull() : "https://developer.apple.com/services-account/v1/certificates?cursor=NEXT"
            let result: [String: Any] = ["data": [["id": id, "type": "certificates", "attributes": ["name": id]]], "links": ["next": next]]
            return (200, try JSONSerialization.data(withJSONObject: result))
        }
        let items = try await client.listFiles(teamID: "TESTTEAM01", kind: .certificates)
        XCTAssertEqual(items.map(\.id), ["CERT001", "CERT002"])
        let file = try await client.download(items[0], teamID: "TESTTEAM01")
        XCTAssertEqual(file.data, certificate)
        XCTAssertEqual(file.name, "certificates-CERT001.cer")
        DeveloperHTTPStub.handler = { _ in (403, Data()) }
        do { _ = try await client.listFiles(teamID: "TESTTEAM01", kind: .profiles); XCTFail("Access must fail") }
        catch AppleDeveloperError.permissionDenied { }
    }

    func testDeveloperDownloadsRejectWrongResourceAndInvalidBase64() throws {
        let item = RemoteDeveloperFile(id: "PROFILE001", kind: .profiles, name: "Fixture", detail: "IOS_APP_STORE", expiresAt: nil, platform: "IOS")
        let original = try fixture("mobileprovision")
        func response(id: String, content: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["data": ["id": id, "type": "profiles", "attributes": ["profileContent": content]]])
        }
        let file = try AppleDeveloperClient.parseDownload(response(id: item.id, content: original.base64EncodedString()), item: item)
        XCTAssertEqual(file.data, original)
        XCTAssertEqual(try CredentialParser.parse(file.data, extension: "mobileprovision").teamID, "TESTTEAM01")
        XCTAssertThrowsError(try AppleDeveloperClient.parseDownload(response(id: "OTHER", content: original.base64EncodedString()), item: item))
        XCTAssertThrowsError(try AppleDeveloperClient.parseDownload(response(id: item.id, content: "!invalid!"), item: item))
        XCTAssertThrowsError(try AppleDeveloperClient.parseDownload(response(id: item.id, content: ""), item: item))
    }

    @MainActor
    func testOnlineImportRequiresMembershipAndRejectsMismatchedCredentialTeam() async throws {
        let transport = FakeAppleDeveloperTransport()
        let item = RemoteDeveloperFile(id: "CERT001", kind: .certificates, name: "Fixture", detail: "DISTRIBUTION", expiresAt: nil, platform: "IOS")
        transport.remoteFiles = [item]
        transport.downloads[item.id] = CredentialFile(data: try fixture("cer"), name: "fixture.cer")
        let session = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        let files = try await session.listFiles(teamID: "TESTTEAM01", kind: .certificates)
        XCTAssertEqual(files, [item])
        let downloaded = try await session.download(files, teamID: "TESTTEAM01")
        XCTAssertEqual(downloaded.count, 1)
        do { _ = try await session.listFiles(teamID: "OTHERTEAM1", kind: .certificates); XCTFail("Membership must be required") }
        catch AppleDeveloperError.teamAccessRequired { }
        transport.teams = [RemoteDeveloperTeam(teamID: "OTHERTEAM1", name: "Other")]
        _ = try await session.listFiles(teamID: "OTHERTEAM1", kind: .certificates)
        do { _ = try await session.download(files, teamID: "OTHERTEAM1"); XCTFail("Team mismatch must fail") }
        catch VaultError.teamMismatch { }
        XCTAssertFalse(session.connected)
    }

    func testDeveloperKeyParsingMapsEnabledServicesToPurposes() throws {
        func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let services: [[String: Any]] = [["id": "U27F4V844T", "name": "Apple Push Notifications service"], ["id": "NEWID00001", "name": "Maps"],
                                         ["id": "NEWID00002", "name": "WeatherKit"], ["id": "NEWID00003", "name": "Future Service"]]
        let body: [String: Any] = ["resultCode": 0, "keys": [["keyId": "OTHERKEY01", "keyName": "Other", "services": [["id": "DQ8HTZ7739", "name": "x"]]],
                                                             ["keyId": "DUMMYKEY01", "keyName": " Fixture Maps ", "services": services]]]
        XCTAssertEqual(try AppleDeveloperClient.parseKey(data(body), keyID: "DUMMYKEY01"),
                       RemoteDeveloperKey(keyID: "DUMMYKEY01", name: "Fixture Maps", purposes: [.apns, .maps, .weatherKit, .other]))
        XCTAssertEqual(try AppleDeveloperClient.parseKey(data(body), keyID: "OTHERKEY01")?.purposes, [.deviceCheck])
        XCTAssertNil(try AppleDeveloperClient.parseKey(data(body), keyID: "MISSINGKEY"))
        XCTAssertNil(try AppleDeveloperClient.parseKey(data(["resultCode": 35]), keyID: "DUMMYKEY01"))
        XCTAssertThrowsError(try AppleDeveloperClient.parseKey(data(["resultCode": 1100]), keyID: "DUMMYKEY01")) { error in
            guard case AppleDeveloperError.loginRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }
        for invalid in [Data("<html>Login</html>".utf8), try data(["resultCode": 0, "keys": [["keyId": "DUMMYKEY01", "services": []]]])] {
            XCTAssertThrowsError(try AppleDeveloperClient.parseKey(invalid, keyID: "DUMMYKEY01"))
        }
        XCTAssertEqual(AppleDeveloperClient.purpose(serviceID: "6A7HVUVQ3M", name: ""), .mediaServices)
        XCTAssertEqual(AppleDeveloperClient.purpose(serviceID: "", name: "Sign in with Apple"), .signInWithApple)
    }

    @MainActor
    func testDeveloperKeyLookupRequiresTeamMembership() async throws {
        let transport = FakeAppleDeveloperTransport()
        let expected = RemoteDeveloperKey(keyID: "DUMMYKEY01", name: "Fixture", purposes: [.maps])
        transport.remoteKey = expected
        let session = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        let found = try await session.key(keyID: "DUMMYKEY01", teamID: "TESTTEAM01")
        XCTAssertEqual(found, expected)
        do { _ = try await session.key(keyID: "DUMMYKEY01", teamID: "OTHERTEAM1"); XCTFail("Membership must be required") }
        catch AppleDeveloperError.teamAccessRequired { }
    }

    @MainActor
    func testDeveloperKeyLookupSendsTeamAndKeyToPortal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeveloperHTTPStub.self]
        let client = AppleDeveloperClient(configuration: configuration)
        defer { client.cancel(); DeveloperHTTPStub.handler = nil }
        DeveloperHTTPStub.handler = { request in
            if request.url?.path.hasSuffix("listTeams.action") == true {
                return (200, Data(#"{"resultCode":0,"teams":[{"teamId":"TESTTEAM01","name":"Fixture"}]}"#.utf8))
            }
            XCTAssertEqual(request.url?.absoluteString, "https://developer.apple.com/services-account/QH65B2/account/auth/key/get")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "csrf"), "fixture-csrf")
            XCTAssertEqual(String(decoding: try DeveloperHTTPStub.body(request), as: UTF8.self), "teamId=TESTTEAM01&keyId=DUMMYKEY01")
            return (200, Data(#"{"resultCode":0,"keys":[{"keyId":"DUMMYKEY01","keyName":"Fixture","services":[{"id":"x","name":"Maps"}]}]}"#.utf8))
        }
        _ = try await client.listTeams()
        let key = try await client.key(keyID: "DUMMYKEY01", teamID: "TESTTEAM01")
        XCTAssertEqual(key?.purposes, [.maps])
        do { _ = try await client.key(keyID: "bad&id=1", teamID: "TESTTEAM01"); XCTFail("Key ID must be validated") }
        catch AppleDeveloperError.invalidResponse { }
    }

    @MainActor
    func testOnlineImportFromSavedCookiesDownloadsAndEncryptsCertificatesAndProfiles() async throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let team = try XCTUnwrap(app.team)
        let certificate = try fixture("cer")
        let profile = try fixture("mobileprovision")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeveloperHTTPStub.self]
        let client = AppleDeveloperClient(configuration: configuration)
        defer { client.cancel(); DeveloperHTTPStub.handler = nil }
        let store = MemoryAppleSessionStore()
        let cookies = Data(#"[{"name":"myacinfo","value":"fixture-only","domain":".apple.com","path":"/","httpOnly":true}]"#.utf8)
        store.data = try SavedAppleDeveloperSession(version: 1, cookies: cookies, account: nil).encoded()
        DeveloperHTTPStub.handler = { request in
            if request.url?.host == "appstoreconnect.apple.com" {
                return (200, Data(#"{"user":{"fullName":"Fixture","emailAddress":"fixture@example.invalid"}}"#.utf8))
            }
            if request.url?.path.hasSuffix("listTeams.action") == true {
                return (200, Data(#"{"resultCode":0,"teams":[{"teamId":"TESTTEAM01","name":"Fixture"}]}"#.utf8))
            }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-HTTP-Method-Override"), "GET")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: DeveloperHTTPStub.body(request)) as? [String: String])
            XCTAssertEqual(body["teamId"], "TESTTEAM01")
            let isCertificate = request.url?.path.contains("/certificates") == true
            let kind = isCertificate ? "certificates" : "profiles"
            let attributes: [String: Any] = ["name": "Fixture", "platform": "IOS", isCertificate ? "certificateContent" : "profileContent": (isCertificate ? certificate : profile).base64EncodedString()]
            let resource: [String: Any] = ["id": "FILE001", "type": kind, "attributes": attributes]
            let detail = request.url?.path.hasSuffix("/FILE001") == true
            let data: Any = detail ? resource as Any : [resource] as Any
            return (200, try JSONSerialization.data(withJSONObject: ["data": data]))
        }
        let session = AppleDeveloperSession(store: store, makeTransport: { client }, observeLock: false)
        let key = SymmetricKey(size: .bits256)
        for kind in RemoteDeveloperFile.Kind.allCases {
            let items = try await session.listFiles(teamID: team.teamID, kind: kind)
            XCTAssertEqual(items.count, 1)
            let downloaded = try await session.download(items, teamID: team.teamID)
            let file = try XCTUnwrap(downloaded.first)
            let parsed = try CredentialParser.parse(file.data, extension: (file.name as NSString).pathExtension)
            let id = try vault.importFile(file, parsed: parsed, app: kind == .profiles ? app : nil, team: team,
                                          password: nil, confirmUnknownTeam: false, key: key)
            let record = try XCTUnwrap(vault.records().first { $0.id == id })
            XCTAssertEqual(try vault.read(record, key: key).original, kind == .certificates ? certificate : profile)
        }
    }

    @MainActor
    func testOnlineDownloadRetriesAfterNetworkFailureAndRestoresSavedSession() async throws {
        let store = MemoryAppleSessionStore()
        let transport = FakeAppleDeveloperTransport()
        let item = RemoteDeveloperFile(id: "CERT001", kind: .certificates, name: "Fixture", detail: "DISTRIBUTION", expiresAt: nil, platform: "IOS")
        let certificate = CredentialFile(data: try fixture("cer"), name: "fixture.cer")
        transport.downloads[item.id] = certificate
        let session = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        transport.downloadFailure = URLError(.networkConnectionLost)
        do { _ = try await session.download([item], teamID: "TESTTEAM01"); XCTFail("Download must fail") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        XCTAssertNotNil(store.data)
        transport.downloadFailure = nil
        let retried = try await session.download([item], teamID: "TESTTEAM01")
        XCTAssertEqual(retried.map(\.data), [certificate.data])
        session.suspend()
        let restored = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        let downloaded = try await restored.download([item], teamID: "TESTTEAM01")
        XCTAssertTrue(transport.imported)
        XCTAssertEqual(downloaded.map(\.data), [certificate.data])
    }

    @MainActor
    func testOnlineDownloadRevalidatesExpiredLoginAndChangedMembershipBeforeFetching() async throws {
        let store = MemoryAppleSessionStore()
        let transport = FakeAppleDeveloperTransport()
        let item = RemoteDeveloperFile(id: "CERT001", kind: .certificates, name: "Fixture", detail: "", expiresAt: nil, platform: "IOS")
        let session = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        transport.failure = AppleDeveloperError.loginRequired
        do { _ = try await session.download([item], teamID: "TESTTEAM01"); XCTFail("Expired login must fail") }
        catch AppleDeveloperError.loginRequired { }
        XCTAssertNil(store.data)
        XCTAssertEqual(transport.downloadCount, 0)
        transport.failure = nil
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        transport.teams = [RemoteDeveloperTeam(teamID: "OTHERTEAM1", name: "Other")]
        do { _ = try await session.download([item], teamID: "TESTTEAM01"); XCTFail("Membership must be checked again") }
        catch AppleDeveloperError.teamAccessRequired { }
        XCTAssertEqual(transport.downloadCount, 0)
    }

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
    func testTargetRegistrationAndBackupRelationshipsRoundTrip() async throws {
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
        XCTAssertEqual(root.targets.map(\.id), [root.id])
        XCTAssertNil(root.target(forProfileBundleID: child.bundleID))
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
        let blob = vault.blobs.file(profile.blobID ?? profile.id)
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
        let (vault, app, child, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let identity = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        _ = try vault.importFile(identity, parsed: CredentialParser.parse(identity.data, extension: "p12", password: "fixture-only"), app: app, password: nil, confirmUnknownTeam: false, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
        _ = try vault.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app,
                                 password: nil, confirmUnknownTeam: false, key: key)
        let catalog = AppCatalog(context: vault.context)
        try catalog.setParent(nil, for: app, name: "Example App Store", platform: app.platform)
        try catalog.setParent(app.id, for: child, name: "Example Share App Store Extension", platform: child.platform)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-mate-sidebar-check", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screens: [(String, CredentialScope)] = [("all", .all), ("team", .team(try XCTUnwrap(app.team?.id))), ("app", .app(app.id)), ("target", .app(child.id))]
        for (screen, scope) in screens {
            let navigation = AppNavigation()
            navigation.scope = scope
            for size in [NSSize(width: 1280, height: 800), NSSize(width: 960, height: 640)] {
                let view = NSHostingView(rootView: CatalogView(container: vault.context.container, navigation: navigation).modelContainer(vault.context.container).preferredColorScheme(.dark))
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
                try png.write(to: directory.appendingPathComponent("catalog-\(screen)-\(Int(size.width)).png"))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "catalog-\(screen)-\(Int(size.width))"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThan(png.count, 1000)
                window.close()
        }
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
        let emptyTeam = DeveloperTeam(name: "未使用のチーム", teamID: "EMPTYTEAM1")
        vault.context.insert(emptyTeam)
        try vault.context.save()
        let loginTransport = FakeAppleDeveloperTransport()
        loginTransport.teams = [RemoteDeveloperTeam(teamID: team.teamID, name: team.name),
                                RemoteDeveloperTeam(teamID: "NEWTEAM001", name: "新しいチーム")]
        let loginSession = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { loginTransport }, observeLock: false)
        try await loginSession.login(account: "fixture@example.invalid", password: "fixture-only")
        loginTransport.remoteFiles = [RemoteDeveloperFile(id: "CERT001", kind: .certificates, name: "Apple Distribution", detail: "DISTRIBUTION", expiresAt: .now.addingTimeInterval(86400), platform: "IOS")]
        let onlineFile = CredentialFile(data: try fixture("cer"), name: "downloaded.cer")
        let screens: [(String, NSSize, AnyView)] = [
            ("online-import", NSSize(width: 640, height: 520), AnyView(AppleDeveloperImportView(team: team, vault: vault, session: loginSession, onSaved: { _ in }))),
            ("online-confirm", NSSize(width: 860, height: 640), AnyView(CredentialImportView(app: nil, team: team, vault: vault, initialFiles: [onlineFile], onSaved: { _ in }))),
            ("main", NSSize(width: 1232, height: 752), AnyView(CatalogView(container: container, navigation: navigation, appleSession: loginSession).modelContainer(container))),
            ("main-narrow", NSSize(width: 960, height: 640), AnyView(CatalogView(container: container, navigation: navigation, appleSession: loginSession).modelContainer(container))),
            ("settings", NSSize(width: 640, height: 592), AnyView(AppSettingsView(container: container))),
            ("settings-account", NSSize(width: 640, height: 592), AnyView(AppSettingsView(container: container, appleSession: loginSession, initialSection: "セキュリティ"))),
            ("welcome", NSSize(width: 760, height: 518), AnyView(OnboardingView(onFinished: { _ in }))),
            ("onboarding-import", NSSize(width: 760, height: 518), AnyView(OnboardingView(step: 1, onFinished: { _ in }))),
            ("onboarding-security", NSSize(width: 760, height: 518), AnyView(OnboardingView(step: 2, onFinished: { _ in }))),
            ("add-app", NSSize(width: 560, height: 520), AnyView(RegistrationForm(container: container, teams: [team], initialTeam: team.id, isTeam: false, onSaved: { _ in }))),
            ("add-team", NSSize(width: 600, height: 540), AnyView(RegistrationForm(container: container, teams: [team], initialTeam: team.id, isTeam: true, onSaved: { _ in }))),
            ("edit-app-icon", NSSize(width: 490, height: 430), AnyView(CatalogEditor(vault: vault, team: nil, app: app))),
            ("team-management", NSSize(width: 600, height: 440), AnyView(TeamManagementView(vault: vault, appleSession: loginSession, onDeleted: { _ in }))),
            ("team-deletion-empty", NSSize(width: 490, height: 360), AnyView(TeamDeletionView(vault: vault, team: emptyTeam, onDeleted: {}))),
            ("team-deletion-blocked", NSSize(width: 490, height: 400), AnyView(TeamDeletionView(vault: vault, team: team, onDeleted: {}))),
            ("team-selection", NSSize(width: 540, height: 540), AnyView(AppleDeveloperLoginView(onTeam: { _ in }, session: loginSession))),
            ("backup", NSSize(width: 600, height: 620), AnyView(BackupView(container: container).modelContainer(container))),
            ("restore", NSSize(width: 640, height: 300), AnyView(BackupView(container: container, restoring: true))),
            ("ci-copy", NSSize(width: 560, height: 520), AnyView(CICopyView(vault: vault, record: try XCTUnwrap(sample)))),
            ("import", NSSize(width: 680, height: 640), AnyView(CredentialImportView(app: app, team: team, vault: vault, onSaved: { _ in }))),
            ("p8-metadata", NSSize(width: 860, height: 640), AnyView(CredentialImportView(app: app, team: team, vault: vault, initialSources: [importURL], onSaved: { _ in }))),
            ("target-delete", NSSize(width: 548, height: 520), AnyView(TargetDeleteConfirmation(target: app, records: try vault.records(), onDelete: {}))),
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
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("app-mate-" + name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(png.count, 1000, name)
            window.close()
        }
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
    func testSVGAppIconRendersAndPersistsInBackup() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" fill="red"/></svg>"#.utf8)
        let image = try XCTUnwrap(NSImage(data: svg))
        XCTAssertEqual(image.size, NSSize(width: 64, height: 64))
        XCTAssertNotNil(image.tiffRepresentation)
        try AppCatalog(context: vault.context).updateApp(app, name: app.name, platform: app.platform,
                                                       parentAppID: nil, iconColor: nil, iconImage: svg)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256))
        let archive = try BackupArchive.encode(snapshot, password: nil)
        let decoded = try BackupArchive.decode(archive, password: nil)
        XCTAssertEqual(decoded.apps.first { $0.id == app.id }?.iconImage, svg)
    }

    @MainActor
    func testAppIconSurvivesProtectedBackupAndRestoreAndOlderBackups() async throws {
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
        let next = try vault.importFile(renewed, parsed: CredentialParser.parse(renewed.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        try linkLegacyReplacement(old, to: next, vault: vault, key: key)
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
        let blob = vault.blobs.file(last.blobID ?? last.id)
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
    func testDeletionIsExcludedFromSearchAndLegacyRevocationSurvivesBackup() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        record.revokedAt = .now
        try vault.context.save()
        try VaultManagement(vault: vault).trash(record, key: key)
        XCTAssertFalse(CredentialSearch.includes(record, scope: .all, app: nil, query: "sample", type: .all, at: .now))
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        XCTAssertNotNil(snapshot.credentials.first?.deletedAt)
        XCTAssertNotNil(snapshot.credentials.first?.revokedAt)
    }

    @MainActor
    func testPreferencesAreStableIgnoreLegacyTemplatesAndAreIncludedInRestoreConflicts() async throws {
        let (vault, _, _, _) = try makeVault()
        XCTAssertEqual(try PreferencesStore.read(in: vault.context), try PreferencesStore.read(in: vault.context))
        var prefs = AppPreferences()
        prefs.showDockBadge = false
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
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: choices, authorization: approvalPlan1, key: key)
        XCTAssertEqual(try PreferencesStore.read(in: other.context), prefs)
        let legacy = Data(#"{"showDockBadge":false,"templates":[{"id":"00000000-0000-0000-0001-000000000004","name":"Team ID","variable":"APPLE_TEAM_ID","value":"teamID"}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: legacy), prefs)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString + ".appmatebackup")
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
        let profile = CredentialFile(data: try fixture("mobileprovision"), name: "sample.mobileprovision")
        XCTAssertThrowsError(try vault.validate(file: profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: nil, team: try XCTUnwrap(app.team), confirmUnknownTeam: true))
    }

    @MainActor
    func testGlobalSearchOverridesAppScopeButPreservesTypeFilterAndShowsLegacyReplacedRecords() throws {
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
        record.replacedByID = UUID()
        XCTAssertTrue(includes("other"))
    }

    @MainActor
    private func backupHistory(_ context: ModelContext) throws -> BackupHistorySummary {
        BackupHistorySummary(changes: try context.fetch(FetchDescriptor<BackupChange>()),
                             checkpoint: try context.fetch(FetchDescriptor<BackupCheckpoint>()).first,
                             hasStoredItems: try BackupHistory.hasStoredItems(in: context))
    }

    @MainActor
    func testEmptyCatalogDoesNotShowHistoricalChangesAsPendingBackup() throws {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        try BackupHistory.bootstrap(in: context)
        context.insert(BackupChange(count: 4))
        try context.save()
        XCTAssertEqual(try backupHistory(context).pendingCount, 0)
        XCTAssertNil(try backupHistory(context).oldestChange)
        // Custom settings still need a backup even without catalog items.
        var prefs = AppPreferences()
        prefs.showDockBadge = false
        try PreferencesStore.save(prefs, in: context)
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
        XCTAssertNotNil(try backupHistory(context).oldestChange)
        try PreferencesStore.save(AppPreferences(), in: context)
        XCTAssertEqual(try backupHistory(context).pendingCount, 0)
        // A leftover team alone does not prompt for backup; trashed apps still do.
        let team = DeveloperTeam(name: "Team", teamID: "TESTTEAM01")
        context.insert(team)
        try context.save()
        XCTAssertEqual(try backupHistory(context).pendingCount, 0)
        let app = ManagedApp(name: "Deleted", bundleID: "com.example.deleted", platform: "macOS", team: team)
        app.deletedAt = .now
        context.insert(app)
        try context.save()
        XCTAssertGreaterThan(try backupHistory(context).pendingCount, 0)
        context.delete(app)
        context.delete(team)
        try context.save()
        XCTAssertEqual(try backupHistory(context).pendingCount, 0)
    }

    @MainActor
    func testHistoryTracksOnlyCommittedProductChangesAndNotIndividualExports() async throws {
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
        let key = SymmetricKey(size: .bits256), metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let file = p8File(), next = p8File()
        let oldID = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "p8"), app: app,
                                         password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        XCTAssertEqual(try backupHistory(context).pendingCount, 3)
        let old = try XCTUnwrap(vault.records().first { $0.id == oldID })
        try vault.export(old, to: directory.appendingPathComponent("exported.p8"), key: key)
        _ = try vault.read(old, key: key)
        XCTAssertEqual(try backupHistory(context).pendingCount, 3)
        _ = try vault.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                 password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        XCTAssertEqual(try backupHistory(context).pendingCount, 4)
        let failed = p8File()
        XCTAssertThrowsError(try vault.importFile(failed, parsed: CredentialParser.parse(failed.data, extension: "p8"), app: app,
                                                  password: nil, confirmUnknownTeam: true, key: key, p8: metadata,
                                                  beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try backupHistory(context).pendingCount, 4)
        XCTAssertEqual(try vault.records().count, 2)
        let restore = BackupRestore(vault: vault)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: key)
        _ = try restore.merge(restore.prepare(snapshot, key: key), choices: [:], key: key)
        XCTAssertEqual(try backupHistory(context).pendingCount, 4)
        let changed = try editing(snapshot) { json in
            var teams = json["teams"] as! [[String: Any]]
            teams[0]["name"] = "Restored Team"
            json["teams"] = teams
        }
        let plan = try restore.prepare(changed, key: key)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, RestoreChoice.backup) })
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        XCTAssertThrowsError(try restore.merge(plan, choices: choices, authorization: approvalPlan1, key: key, beforeCommit: { throw ValidationError.invalidFile }))
        XCTAssertEqual(try backupHistory(context).pendingCount, 4)
        let approvalPlan2 = try await restoreAuthorization(for: plan)
        _ = try restore.merge(plan, choices: choices, authorization: approvalPlan2, key: key)
        XCTAssertEqual(try backupHistory(context).pendingCount, 5)
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
    func testExistingVaultMigratesBlobReferenceAndKeepsOldEncryptedBytes() async throws {
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
    func testBackupRestoreToNewVaultKeepsIDsOriginalsPasswordsAndSharingAfterReopen() async throws {
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
        let metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let oldID = try source.importFile(first, parsed: CredentialParser.parse(first.data, extension: "p8"), app: app,
                                          password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        let nextID = try source.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                           password: nil, confirmUnknownTeam: true, key: sourceKey, p8: metadata)
        try linkLegacyReplacement(oldID, to: nextID, vault: source, key: sourceKey)
        let backup = try BackupArchive.decode(BackupArchive.encode(BackupSnapshot.capture(vault: source, key: sourceKey), password: "fixture-backup-password"), password: "fixture-backup-password")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
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
        let oldURL = vault.blobs.file(record.blobID ?? record.id)
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
    func testRestoreRemapsNaturalIdentitiesAndReplacementReferences() async throws {
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
        try linkLegacyReplacement(sourceOld, to: newID, vault: source, key: sourceKey)
        let service = BackupRestore(vault: target)
        let plan = try service.prepare(BackupSnapshot.capture(vault: source, key: sourceKey), key: targetKey)
        XCTAssertEqual(plan.addedCount, 1)
        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.kind == .credential ? RestoreChoice.backup : .current) })
        let approvalPlan1 = try await restoreAuthorization(for: plan)
        _ = try service.merge(plan, choices: choices, authorization: approvalPlan1, key: targetKey)
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
    func testRestoreRejectsMalformedScopeAndCyclicHistory() throws {
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
        let metadata = P8Metadata(purposes: [.apns], keyID: "DUMMYKEY01", issuerID: nil)
        let old = try vault.importFile(first, parsed: CredentialParser.parse(first.data, extension: "p8"), app: app,
                                       password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        let next = p8File()
        let replacement = try vault.importFile(next, parsed: CredentialParser.parse(next.data, extension: "p8"), app: app,
                                               password: nil, confirmUnknownTeam: true, key: key, p8: metadata)
        try linkLegacyReplacement(old, to: replacement, vault: vault, key: key)
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
        record.revokedAt = now
        XCTAssertEqual(record.displayState(at: now), .stored)
        XCTAssertTrue(CredentialDisplayState.withinDay.needsRenewal)
        XCTAssertFalse(CredentialDisplayState.expired.needsRenewal)
        _ = vault
    }

    // Older versions linked a renewed credential to the one it replaced; this rebuilds that stored state.
    @MainActor
    private func linkLegacyReplacement(_ oldID: UUID, to newID: UUID, vault: CredentialVault, key: SymmetricKey) throws {
        let records = try vault.records()
        let old = try XCTUnwrap(records.first { $0.id == oldID }), new = try XCTUnwrap(records.first { $0.id == newID })
        let payload = try vault.read(new, key: key)
        new.replacesCredentialID = oldID
        old.replacedByID = newID
        let blob = UUID()
        new.blobID = blob
        try vault.blobs.write(JSONEncoder().encode(payload), id: blob, key: key, authenticating: new.authenticatedData())
        try vault.context.save()
        try vault.recover()
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

    func testP8KeyIDComesOnlyFromApplesDownloadName() {
        XCTAssertEqual(P8Metadata.keyID(fromFileName: "AuthKey_DUMMYKEY01.p8"), "DUMMYKEY01")
        for name in ["authkey_DUMMYKEY01.p8", "AuthKey_dummykey01.p8", "AuthKey_DUMMYKEY01 (1).p8", "AuthKey_DUMMYKEY0.p8", "key.p8"] {
            XCTAssertNil(P8Metadata.keyID(fromFileName: name), name)
        }
    }

    @MainActor
    func testP8StoresMultiplePurposesCanonicallyAndKeepsSinglePurposeCompatibility() throws {
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
        // Non-canonical order, unknown values and the old single-value form must be validated as before.
        for (value, valid) in [("maps,apns", false), ("apns,unknown", false), ("", false), ("apns,,maps", false), ("apns", true), ("sign-in", true)] {
            let changed = try JSONDecoder().decode(BackupSnapshot.self, from: JSONEncoder().encode(snapshot)
                .replacing(Data(#""keyPurpose":"apns,maps""#.utf8), with: Data(#""keyPurpose":"\#(value)""#.utf8)))
            XCTAssertEqual(changed.credentials.first?.keyPurpose, value)
            XCTAssertEqual((try? changed.validate()) != nil, valid, value)
        }
        XCTAssertEqual(stored.keyPurpose, "apns,maps")
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
        XCTAssertEqual(record.metadataVersion, 2)
        XCTAssertEqual(record.purposeTitle, "Maps・WeatherKit")
        let payload = try vault.read(record, key: key)
        XCTAssertEqual(payload.original, file.data)
        XCTAssertEqual(payload.note, "note")
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history + 1)
        _ = try BackupSnapshot.capture(vault: vault, key: key)
        record.keyPurpose = "apns,weatherkit"
        XCTAssertThrowsError(try vault.read(record, key: key))
        vault.context.rollback()

        let newFile = p8File()
        let newID = try vault.importFile(newFile, parsed: CredentialParser.parse(newFile.data, extension: "p8"), app: app, password: nil,
                                         confirmUnknownTeam: true, key: key, p8: P8Metadata(purposes: [.maps, .weatherKit], keyID: "DUMMYKEY02", issuerID: nil))
        try linkLegacyReplacement(id, to: newID, vault: vault, key: key)
        for linked in [record, try XCTUnwrap(vault.records().first { $0.id == newID })] {
            XCTAssertThrowsError(try management.updatePurposes(linked, metadata: P8Metadata(purposes: [.apns], keyID: "", issuerID: nil), key: key)) { error in
                guard case ManagementError.purposeLocked = error else { return XCTFail("Unexpected error: \(error)") }
            }
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

    func testProfileParsesEmbeddedCertificateDigestsInOrder() throws {
        let sha = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let value = try CredentialParser.parse(fixture("mobileprovision", name: "certs"), extension: "mobileprovision")
        XCTAssertEqual(value.signingCertificateDigests, [sha(try fixture("cer")), sha(try fixture("cer", name: "renewed"))])
        XCTAssertEqual(try CredentialParser.parse(fixture("mobileprovision"), extension: "mobileprovision").signingCertificateDigests, [])
        XCTAssertNil(try CredentialParser.parse(fixture("cer"), extension: "cer").signingCertificateDigests)
    }

    @MainActor
    func testBackfillReadsProfileCertificatesWithoutChangingAADOrBackupHistory() throws {
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

        try VaultManagement(vault: vault).backfillSigningCertificates(key: key)
        XCTAssertEqual(record.signingCertificateDigests, expected)
        XCTAssertEqual(try record.authenticatedData(), aad)
        XCTAssertEqual(try vault.read(record, key: key).original, file.data)
        XCTAssertEqual(try vault.context.fetchCount(FetchDescriptor<BackupChange>()), history)
        XCTAssertEqual(try BackupSnapshot.capture(vault: vault, key: key).credentials.count, 1)
    }

    @MainActor
    func testBackfillMarksUnreadableProfileOnceAndKeepsOtherProfiles() throws {
        let (vault, app, _, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "mobileprovision"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let record = try XCTUnwrap(vault.records().first)
        record.signingCertificateDigests = nil
        try vault.context.save()
        // A different key cannot decrypt the blob: the profile is marked "" and is not retried.
        try VaultManagement(vault: vault).backfillSigningCertificates(key: SymmetricKey(size: .bits256))
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
        XCTAssertEqual(certificate.name, "App Mate Test Only")
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

    func testEncryptedBlobStoreRejectsWrongKeyAADAndTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppMateTests/" + UUID().uuidString)
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

@MainActor
private final class FakeAppleDeveloperTransport: AppleDeveloperTransport {
    var accountIdentity: AppleDeveloperAccount?
    var teams = [RemoteDeveloperTeam(teamID: "TESTTEAM01", name: "Fixture")]
    var failure: Error?
    var loginState: AuthenticationState?
    var pauseTeams = false
    var teamsGate: CheckedContinuation<Void, Never>?
    var pauseValidation = false
    var validationGate: CheckedContinuation<Void, Never>?
    var imported = false
    var cancelled = false
    var state: AuthenticationState {
        get throws { try JSONDecoder().decode(AppleSession.self, from: Data("{\"user\":{\"fullName\":\"Fixture\"}}".utf8)).asAuthenticationState }
    }
    func login(account: String, password: String) async throws -> AuthenticationState { if let loginState { return loginState }; return try state }
    func validate() async throws -> AuthenticationState {
        if pauseValidation { await withCheckedContinuation { validationGate = $0 } }
        if let failure { throw failure }
        return try state
    }
    func submit(code: SecurityCode, session: AppleSessionData) async throws -> AuthenticationState { try state }
    func sms(phone: AuthOptionsResponse.TrustedPhoneNumber, options: AuthOptionsResponse, session: AppleSessionData) async throws -> AuthenticationState { try state }
    var remoteFiles: [RemoteDeveloperFile] = []
    var downloads: [String: CredentialFile] = [:]
    var downloadFailure: Error?
    var downloadCount = 0
    func listTeams() async throws -> [RemoteDeveloperTeam] {
        if pauseTeams { await withCheckedContinuation { teamsGate = $0 } }
        return teams
    }
    func listFiles(teamID: String, kind: RemoteDeveloperFile.Kind) async throws -> [RemoteDeveloperFile] { remoteFiles }
    var remoteKey: RemoteDeveloperKey?
    func key(keyID: String, teamID: String) async throws -> RemoteDeveloperKey? { remoteKey }
    func download(_ item: RemoteDeveloperFile, teamID: String) async throws -> CredentialFile {
        downloadCount += 1
        if let downloadFailure { throw downloadFailure }
        guard let file = downloads[item.id] else { throw ValidationError.invalidFile }
        return file
    }
    func exportCookies() throws -> Data { Data("fixture-cookie".utf8) }
    func importCookies(_ data: Data) throws { imported = true }
    func cancel() { cancelled = true }
}

private extension AppleSession {
    var asAuthenticationState: AuthenticationState { .authenticated(self) }
}

@MainActor
private final class FailingAppleSessionStore: AppleSessionStore {
    var data: Data?
    var failWrite = false
    var failDelete = false
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        if failWrite { throw AppleDeveloperError.sessionStorage }
        self.data = data
    }
    func delete() throws {
        if failDelete { throw AppleDeveloperError.sessionStorage }
        data = nil
    }
}

private final class DeveloperHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "csrf": "fixture-csrf", "csrf_ts": "fixture-time"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
    static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
