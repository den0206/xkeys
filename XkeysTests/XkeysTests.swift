import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
import XcodesLoginKit
@testable import Xkeys

final class XkeysTests: XCTestCase {
    @MainActor
    func restoreAuthorization(for plan: RestorePlan) async throws -> RestoreTeamAuthorization {
        let transport = FakeAppleDeveloperTransport()
        transport.teams = plan.incoming.teams.map { RemoteDeveloperTeam(teamID: $0.teamID, name: $0.name) }
        let session = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { transport }, observeLock: false)
        try await session.login(account: "fixture@example.invalid", password: "fixture-only")
        let authorization = RestoreTeamAuthorization()
        try session.confirm(authorization, plan: plan)
        return authorization
    }

    @MainActor
    func backupHistory(_ context: ModelContext) throws -> BackupHistorySummary {
        BackupHistorySummary(changes: try context.fetch(FetchDescriptor<BackupChange>()),
                             checkpoint: try context.fetch(FetchDescriptor<BackupCheckpoint>()).first,
                             hasStoredItems: try BackupHistory.hasStoredItems(in: context))
    }

    func editing(_ snapshot: BackupSnapshot, _ update: (inout [String: Any]) -> Void) throws -> BackupSnapshot {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        update(&json)
        return try JSONDecoder().decode(BackupSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func p8File() -> CredentialFile {
        CredentialFile(data: Data(P256.Signing.PrivateKey().pemRepresentation.utf8), name: "fixture.p8")
    }

    @MainActor
    func testHostUsesIsolatedStore() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["XKEYS_TESTING"], "1")
        XCTAssertTrue(CredentialVault.directory.path.contains("/XkeysTests/"))
        XCTAssertFalse(CredentialVault.directory.path.contains("/XkeysVault/"))
    }

    /// Quarantine sits next to the blob directory, so these vaults get a parent folder of their own.
    @MainActor
    func makeIsolatedVault() throws -> (CredentialVault, ManagedApp) {
        let (base, app, _, _) = try makeVault()
        let directory = base.blobs.directory.appendingPathComponent("blobs", isDirectory: true)
        return (CredentialVault(context: base.context, blobs: EncryptedBlobStore(directory: directory)), app)
    }

    @MainActor
    func makeVault() throws -> (CredentialVault, ManagedApp, ManagedApp, ManagedApp) {
        let container = try ModelContainer(for: DeveloperTeam.self, ManagedApp.self, StoredCredential.self, BackupChange.self, BackupCheckpoint.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let team = DeveloperTeam(name: "Fixture Team", teamID: "TESTTEAM01")
        let otherTeam = DeveloperTeam(name: "Other Team", teamID: "TESTTEAM02")
        let first = ManagedApp(name: "First", bundleID: "com.example.Xkeys.fixture", platform: "macOS", team: team)
        let sibling = ManagedApp(name: "Sibling", bundleID: "com.example.other", platform: "iOS", team: team)
        let other = ManagedApp(name: "Other", bundleID: first.bundleID, platform: "macOS", team: otherTeam)
        context.insert(first); context.insert(sibling); context.insert(other)
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XkeysTests", isDirectory: true).appendingPathComponent(UUID().uuidString)
        return (CredentialVault(context: context, blobs: EncryptedBlobStore(directory: directory)), first, sibling, other)
    }

    func fixture(_ ext: String, name: String = "sample") throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

// Frozen pre-restore model: proves that adding the blob reference preserves existing encrypted files.
enum BeforeBackupCountRemoval {
    @Model
    final class BackupChange {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var count: Int

        init(id: UUID) {
            self.id = id
            createdAt = .now
            count = 42
        }
    }
}

@MainActor
final class FakeAppleDeveloperTransport: AppleDeveloperTransport {
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
    var importFailure: Error?
    func importCookies(_ data: Data) throws {
        if let importFailure { throw importFailure }
        imported = true
    }
    func cancel() { cancelled = true }
}

extension AppleSession {
    var asAuthenticationState: AuthenticationState { .authenticated(self) }
}

@MainActor
final class FailingAppleSessionStore: AppleSessionStore {
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

final class DeveloperHTTPStub: URLProtocol, @unchecked Sendable {
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
