import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
import XcodesLoginKit
@testable import Xkeys

/// Apple Developer sign-in, sessions, team membership and online import.
extension XkeysTests {
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
    func testRejectedSavedCookiesCancelTheUnusedTransport() async throws {
        let store = MemoryAppleSessionStore()
        store.data = try SavedAppleDeveloperSession(version: 1, cookies: Data("fixture-cookie".utf8), account: nil).encoded()
        let transport = FakeAppleDeveloperTransport()
        transport.importFailure = AppleDeveloperError.sessionStorage
        let session = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        do { try await session.resume(); XCTFail("Rejected cookies must fail") } catch {}
        XCTAssertTrue(transport.cancelled)
        XCTAssertFalse(session.connected)
    }

    @MainActor
    func testAppleAccountPersistsWithoutConnecting() async throws {
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
        XCTAssertThrowsError(try SavedAppleDeveloperSession.read(Data("[]".utf8)))
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests/" + UUID().uuidString)
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
    func testSidebarOffersTeamSelectionForSavedLoginWithoutTeams() async throws {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try BackupHistory.bootstrap(in: ModelContext(container))
        let store = MemoryAppleSessionStore()
        let transport = FakeAppleDeveloperTransport()
        transport.accountIdentity = AppleDeveloperAccount(email: "saved@example.invalid", name: "Fixture")
        let previous = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        try await previous.login(account: "saved@example.invalid", password: "fixture-only")
        previous.suspend()
        let session = AppleDeveloperSession(store: store, makeTransport: { transport }, observeLock: false)
        for (name, size) in [("sidebar-no-team", NSSize(width: 1232, height: 752)), ("sidebar-no-team-narrow", NSSize(width: 960, height: 640))] {
            let view = NSHostingView(rootView: CatalogView(container: container, navigation: AppNavigation(), appleSession: session)
                .modelContainer(container).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("xkeys-" + name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.close()
        }
        // The prompt loads the saved account itself, since the account menu is not shown without a team.
        XCTAssertEqual(session.savedAccount?.email, "saved@example.invalid")
        XCTAssertFalse(session.connected)
    }

    func testP8KeyIDComesOnlyFromApplesDownloadName() {
        XCTAssertEqual(P8Metadata.keyID(fromFileName: "AuthKey_DUMMYKEY01.p8"), "DUMMYKEY01")
        for name in ["authkey_DUMMYKEY01.p8", "AuthKey_dummykey01.p8", "AuthKey_DUMMYKEY01 (1).p8", "AuthKey_DUMMYKEY0.p8", "key.p8"] {
            XCTAssertNil(P8Metadata.keyID(fromFileName: name), name)
        }
    }
}
