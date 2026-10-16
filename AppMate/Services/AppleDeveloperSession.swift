import AppKit
import Foundation
import Observation
import XcodesLoginKit

struct SavedAppleDeveloperSession: Codable {
    static let maximumBytes = 266_240
    let version: Int
    let cookies: Data
    let account: AppleDeveloperAccount?

    static func read(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw AppleDeveloperError.sessionStorage }
        if data.starts(with: Data("bplist00".utf8)) {
            let saved = try PropertyListDecoder().decode(Self.self, from: data)
            guard saved.version == 1, !saved.cookies.isEmpty, saved.cookies.count <= 262_144 else { throw AppleDeveloperError.sessionStorage }
            try saved.account?.validate()
            return saved
        }
        // Read the original cookie-only JSON without forcing another login.
        guard (try? JSONSerialization.jsonObject(with: data)) is [[String: Any]] else { throw AppleDeveloperError.sessionStorage }
        return Self(version: 1, cookies: data, account: nil)
    }

    func encoded() throws -> Data {
        guard version == 1, !cookies.isEmpty, cookies.count <= 262_144 else { throw AppleDeveloperError.sessionStorage }
        try account?.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw AppleDeveloperError.sessionStorage }
        return data
    }
}

@MainActor @Observable
final class AppleDeveloperSession {
    static let shared = ProcessInfo.processInfo.environment["APP_MATE_TESTING"] == "1"
        ? AppleDeveloperSession(store: MemoryAppleSessionStore(), observeLock: false)
        : AppleDeveloperSession()
    private(set) var teams: [RemoteDeveloperTeam] = []
    private(set) var authentication: AuthenticationState = .unauthenticated
    private(set) var currentAccount: AppleDeveloperAccount?
    private(set) var savedAccount: AppleDeveloperAccount?
    private(set) var hasSavedSession = false
    private var pendingAccount: String?
    private(set) var connected = false
    private(set) var busy = false
    private(set) var epoch = UUID()
    private(set) var generation = UUID()
    private var validatedAt: Date?
    private var transport: (any AppleDeveloperTransport)?
    private let makeTransport: () -> any AppleDeveloperTransport
    private let store: any AppleSessionStore
    private var observers: [NSObjectProtocol] = []

    init(store: any AppleSessionStore = AppleDeveloperSessionStore(),
         makeTransport: @escaping () -> any AppleDeveloperTransport = { AppleDeveloperClient() },
         observeLock: Bool = ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1") {
        self.store = store
        self.makeTransport = makeTransport
        if observeLock {
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.suspend() }
                })
            }
        }
    }

    func suspend() {
        epoch = UUID()
        resetMemory()
    }

    private func resetMemory() {
        generation = UUID()
        transport?.cancel(); transport = nil
        teams = []; authentication = .unauthenticated; currentAccount = nil; pendingAccount = nil
        connected = false; validatedAt = nil; busy = false
    }

    func disconnect() throws {
        suspend()
        savedAccount = nil; hasSavedSession = false
        try store.delete()
    }

    func loadSavedAccount() throws {
        guard !busy, !connected else { return }
        let saved = try store.read().map(SavedAppleDeveloperSession.read)
        savedAccount = saved?.account
        hasSavedSession = saved != nil
    }

    private func saveSession(_ transport: any AppleDeveloperTransport, account: AppleDeveloperAccount?) throws {
        let saved = SavedAppleDeveloperSession(version: 1, cookies: try transport.exportCookies(), account: account)
        try store.write(saved.encoded())
        savedAccount = account; hasSavedSession = true
    }

    func cancelAttempt() {
        // Preserve an established connection when only the team picker closes.
        if !connected { resetMemory() }
    }

    func useAnotherAccount() {
        // Restore receipts survive this deliberate account switch, but not lock or disconnect.
        resetMemory()
    }

    func login(account: String, password: String) async throws {
        guard !busy else { throw AppleDeveloperError.busy }
        resetMemory()
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 1_024 else { throw AppleDeveloperError.invalidResponse }
        pendingAccount = name
        let transport = makeTransport()
        self.transport = transport
        let generation = generation
        busy = true
        defer { if generation == self.generation { busy = false } }
        do {
            let state = try await transport.login(account: account.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            try await accept(state, transport: transport, generation: generation)
        } catch { try handle(error, generation: generation) }
    }

    /// Restores cookies only for an explicit online action; never during launch or offline use.
    func resume() async throws {
        guard !busy else { throw AppleDeveloperError.busy }
        let generation = generation
        busy = true
        defer { if generation == self.generation { busy = false } }
        do {
            let active: any AppleDeveloperTransport
            if let transport { active = transport }
            else {
                guard let data = try store.read() else { throw AppleDeveloperError.loginRequired }
                let saved = try SavedAppleDeveloperSession.read(data)
                savedAccount = saved.account; hasSavedSession = true
                active = makeTransport()
                try active.importCookies(saved.cookies)
                transport = active
            }
            let state = try await active.validate()
            try await accept(state, transport: active, generation: generation)
        } catch { try handle(error, generation: generation) }
    }

    func submit(code: String) async throws {
        guard !busy, let transport, case let .waitingForSecondFactor(option, _, session) = authentication else { throw AppleDeveloperError.loginRequired }
        let securityCode: SecurityCode
        switch option {
        case .codeSent: securityCode = .device(code: code)
        case .smsSent(let phone): securityCode = .sms(code: code, phoneNumberId: phone.id)
        default: throw AppleDeveloperError.unsupportedLogin
        }
        let generation = generation
        busy = true
        defer { if generation == self.generation { busy = false } }
        do { try await accept(try await transport.submit(code: securityCode, session: session), transport: transport, generation: generation) }
        catch { try handle(error, generation: generation) }
    }

    func sendSMS(_ phone: AuthOptionsResponse.TrustedPhoneNumber) async throws {
        guard !busy, let transport, case let .waitingForSecondFactor(_, options, session) = authentication else { throw AppleDeveloperError.loginRequired }
        let generation = generation
        busy = true
        defer { if generation == self.generation { busy = false } }
        do { try await accept(try await transport.sms(phone: phone, options: options, session: session), transport: transport, generation: generation) }
        catch { try handle(error, generation: generation) }
    }

    private func accept(_ state: AuthenticationState, transport: any AppleDeveloperTransport, generation: UUID) async throws {
        try check(generation)
        switch state {
        case .authenticated(let authenticated):
            let identity = AppleDeveloperAccount(email: transport.accountIdentity?.email ?? pendingAccount ?? savedAccount?.email,
                                                 name: transport.accountIdentity?.name ?? authenticated.user.fullName)
            try identity.validate()
            let teams = try await transport.listTeams()
            try check(generation)
            try saveSession(transport, account: identity)
            currentAccount = identity
            pendingAccount = nil
            self.teams = teams
            self.authentication = state
            connected = true
            validatedAt = .now
        case .waitingForSecondFactor(let option, _, _):
            guard option != .securityKey else { throw AppleDeveloperError.unsupportedLogin }
            authentication = state
        case .waitingForFederatedAuthentication:
            throw AppleDeveloperError.unsupportedLogin
        case .notAppleDeveloper: throw AppleDeveloperError.noTeams
        case .unauthenticated: throw AppleDeveloperError.loginRequired
        }
    }

    private func check(_ generation: UUID) throws {
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
    }

    private func handle(_ error: Error, generation: UUID) throws {
        try check(generation)
        let expired: Bool
        if let failure = error as? AuthenticationError {
            switch failure {
            case .invalidSession, .notAuthorized: expired = true
            case .badStatusCode(let status, _, _): expired = status == 401
            default: expired = false
            }
        } else if let failure = error as? AppleDeveloperError, case .loginRequired = failure { expired = true }
        else { expired = false }
        if expired {
            suspend()
            savedAccount = nil; hasSavedSession = false
            try store.delete()
            throw AppleDeveloperError.loginRequired
        }
        // Never display the library's raw errors; some include server bodies or account details.
        connected = false; teams = []; currentAccount = nil; validatedAt = nil
        throw error
    }

    func listFiles(teamID: String, kind: RemoteDeveloperFile.Kind) async throws -> [RemoteDeveloperFile] {
        try await resume()
        guard teams.contains(where: { $0.teamID == teamID }), let transport else { throw AppleDeveloperError.teamAccessRequired }
        guard !busy else { throw AppleDeveloperError.busy }
        let generation = generation
        busy = true
        defer { if generation == self.generation { busy = false } }
        do {
            let files = try await transport.listFiles(teamID: teamID, kind: kind)
            try check(generation)
            try saveSession(transport, account: currentAccount)
            return files
        } catch { try handle(error, generation: generation); throw error }
    }

    func download(_ items: [RemoteDeveloperFile], teamID: String) async throws -> [CredentialFile] {
        guard !items.isEmpty, items.count <= 200, Set(items.map { $0.kind.rawValue + ":" + $0.id }).count == items.count else { throw AppleDeveloperError.importLimit }
        // Revalidate after time spent selecting files, and recover from a failed download.
        try await resume()
        guard teams.contains(where: { $0.teamID == teamID }), let transport else { throw AppleDeveloperError.teamAccessRequired }
        guard !busy else { throw AppleDeveloperError.busy }
        let generation = generation
        busy = true
        defer { if generation == self.generation { busy = false } }
        do {
            var files: [CredentialFile] = []
            var totalBytes = 0
            for item in items {
                try check(generation)
                let file = try await transport.download(item, teamID: teamID)
                try check(generation)
                guard file.data.count <= CredentialParser.maximumBytes else { throw ValidationError.tooLarge }
                totalBytes += file.data.count
                guard totalBytes <= 32 * 1_048_576 else { throw AppleDeveloperError.importLimit }
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try CredentialParser.parse(file.data, extension: (file.name as NSString).pathExtension)
                }.value
                try check(generation)
                if let sourceTeam = parsed.teamID, sourceTeam != teamID { throw VaultError.teamMismatch }
                files.append(file)
            }
            try saveSession(transport, account: currentAccount)
            return files
        } catch { try handle(error, generation: generation); throw error }
    }

    func register(_ team: RemoteDeveloperTeam, catalog: AppCatalog) throws -> UUID {
        guard connected, let date = validatedAt, Date.now.timeIntervalSince(date) < 300,
              teams.contains(team) else { throw AppleDeveloperError.loginRequired }
        return try catalog.registerRemoteTeam(team)
    }

    func confirm(_ authorization: RestoreTeamAuthorization, plan: RestorePlan) throws {
        guard connected, let date = validatedAt, Date.now.timeIntervalSince(date) < 300 else { throw AppleDeveloperError.loginRequired }
        let ids = Set(teams.map(\.teamID))
        guard plan.requiredTeamIDs.isEmpty || !plan.requiredTeamIDs.isDisjoint(with: ids) else { throw AppleDeveloperError.membershipRequired }
        try authorization.record(teamIDs: ids, plan: plan, session: self, date: date)
    }
}

@MainActor @Observable
final class RestoreTeamAuthorization {
    private var fingerprint: String?
    private var receipts: [String: Date] = [:]
    private var epoch: UUID?
    private var session: AppleDeveloperSession?

    func clear() { fingerprint = nil; receipts = [:]; epoch = nil; session = nil }

    fileprivate func record(teamIDs: Set<String>, plan: RestorePlan, session: AppleDeveloperSession, date: Date) throws {
        let key = try plan.authorizationFingerprint()
        if fingerprint != key || epoch != session.epoch { clear() }
        fingerprint = key; epoch = session.epoch; self.session = session
        for id in plan.requiredTeamIDs.intersection(teamIDs) { receipts[id] = date }
    }

    func confirmedTeamIDs(for plan: RestorePlan, at date: Date = .now) throws -> Set<String> {
        guard fingerprint == (try plan.authorizationFingerprint()), let session, epoch == session.epoch else { return [] }
        return Set(receipts.filter { date.timeIntervalSince($0.value) >= 0 && date.timeIntervalSince($0.value) < 300 }.keys)
    }

    func validate(_ plan: RestorePlan, at date: Date = .now) throws {
        guard try plan.requiredTeamIDs.isSubset(of: confirmedTeamIDs(for: plan, at: date)) else { throw AppleDeveloperError.membershipRequired }
    }
}
