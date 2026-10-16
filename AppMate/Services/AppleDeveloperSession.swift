import AppKit
import Foundation
import Observation
import XcodesLoginKit

@MainActor @Observable
final class AppleDeveloperSession {
    static let shared = ProcessInfo.processInfo.environment["APP_MATE_TESTING"] == "1"
        ? AppleDeveloperSession(store: MemoryAppleSessionStore(), observeLock: false)
        : AppleDeveloperSession()
    private(set) var teams: [RemoteDeveloperTeam] = []
    private(set) var authentication: AuthenticationState = .unauthenticated
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
        teams = []; authentication = .unauthenticated
        connected = false; validatedAt = nil; busy = false
    }

    func disconnect() throws {
        suspend()
        try store.delete()
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
                active = makeTransport()
                try active.importCookies(data)
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
        case .authenticated:
            let teams = try await transport.listTeams()
            try check(generation)
            try store.write(transport.exportCookies())
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
            try store.delete()
            throw AppleDeveloperError.loginRequired
        }
        // Never display the library's raw errors; some include server bodies or account details.
        connected = false; teams = []; validatedAt = nil
        throw error
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
