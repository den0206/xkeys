import AsyncNetworkService
import Foundation
import Security
import XcodesLoginKit

struct RemoteDeveloperTeam: Identifiable, Equatable, Sendable {
    let teamID: String
    let name: String
    var id: String { teamID }
}

struct RemoteDeveloperKey: Equatable, Sendable {
    let keyID: String
    let name: String
    let purposes: [P8Purpose]
}

enum AppleDeveloperError: LocalizedError {
    case invalidResponse, noTeams, loginRequired, permissionDenied, agreementRequired
    case unsupportedLogin, rateLimited, sessionStorage, membershipRequired, busy, teamAccessRequired, importLimit

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Appleからの応答を確認できません。時間をおいて再試行してください。"
        case .noTeams: "このApple Accountで利用できるDeveloperチームがありません。"
        case .loginRequired: "Apple Developerにログインしてください。保存済みの接続は無効になっています。"
        case .permissionDenied: "このApple Accountには必要なアクセス権がありません。"
        case .agreementRequired: "Apple DeveloperのWebサイトで規約などの確認を完了してください。"
        case .unsupportedLogin: "この認証方式にはまだ対応していません。信頼済み端末またはSMSの確認コードを利用できるアカウントが必要です。"
        case .rateLimited: "Appleへの接続が制限されています。しばらく待って再試行してください。"
        case .sessionStorage: "接続情報をKeychainで保存・取得・削除できませんでした。再試行してください。"
        case .membershipRequired: "未登録のすべてのTeam IDへの所属を確認してから復元してください。"
        case .teamAccessRequired: "選択中のチームに所属するApple Accountでログインしてください。"
        case .importLimit: "一度に200ファイル・合計32MBまで取り込めます。対象を分けてください。"
        case .busy: "別のApple Developerへの接続操作が進行中です。完了してから再試行してください。"
        }
    }

    static func message(for error: Error) -> String {
        if error is RegistrationError || error is RestoreError || error is ValidationError || error is VaultError { return error.localizedDescription }
        if let error = error as? AppleDeveloperError { return error.localizedDescription }
        if let error = error as? AuthenticationError {
            switch error {
            case .invalidUsernameOrPassword, .missingPasswordForNonFederatedAccount:
                return "Apple Accountまたはパスワードを確認してください。"
            case .incorrectSecurityCode: return "確認コードが正しくありません。もう一度入力してください。"
            case .appleIDAndPrivacyAcknowledgementRequired: return Self.agreementRequired.localizedDescription
            case .accountLocked: return "Apple Accountがロックされています。AppleのWebサイトで確認してください。"
            case .notDeveloperAppleId: return Self.noTeams.localizedDescription
            case .federatedAuthenticationRequired, .accountUsesTwoStepAuthentication, .accountUsesUnknownAuthenticationKind:
                return Self.unsupportedLogin.localizedDescription
            default: return "Appleへの認証に失敗しました。接続状態を確認して再試行してください。"
            }
        }
        if error is CancellationError { return "接続操作をキャンセルしました。" }
        return "Appleに接続できませんでした。ネットワークを確認して再試行してください。"
    }
}

struct AppleDeveloperAccount: Codable, Equatable, Sendable {
    let email: String?
    let name: String?
    var label: String { email ?? name ?? "アカウント情報を取得できませんでした" }

    init(email: String?, name: String?) {
        self.email = email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func validate() throws {
        guard [email, name].allSatisfy({ $0.map { !$0.isEmpty && $0.utf8.count <= 1_024 } ?? true }) else {
            throw AppleDeveloperError.invalidResponse
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
protocol AppleDeveloperTransport: AnyObject {
    var accountIdentity: AppleDeveloperAccount? { get }
    func login(account: String, password: String) async throws -> AuthenticationState
    func validate() async throws -> AuthenticationState
    func submit(code: SecurityCode, session: AppleSessionData) async throws -> AuthenticationState
    func sms(phone: AuthOptionsResponse.TrustedPhoneNumber, options: AuthOptionsResponse, session: AppleSessionData) async throws -> AuthenticationState
    func listTeams() async throws -> [RemoteDeveloperTeam]
    func key(keyID: String, teamID: String) async throws -> RemoteDeveloperKey?
    func listFiles(teamID: String, kind: RemoteDeveloperFile.Kind) async throws -> [RemoteDeveloperFile]
    func download(_ item: RemoteDeveloperFile, teamID: String) async throws -> CredentialFile
    func exportCookies() throws -> Data
    func importCookies(_ data: Data) throws
    func cancel()
}

// Redirects must never send the authentication request to another host.
final class AppleRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == response.url?.host ? request : nil)
    }
}

@MainActor
final class AppleDeveloperClient: AppleDeveloperTransport {
    private let urlSession: URLSession
    private let client: Client
    private var csrfHeaders: [String: String] = [:]
    private(set) var accountIdentity: AppleDeveloperAccount?

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: AppleRedirectPolicy(), delegateQueue: nil)
        urlSession = session
        client = Client(urlSession: session)
    }

    func login(account: String, password: String) async throws -> AuthenticationState {
        try await captureIdentity(try await client.authenticationState(accountName: account, password: password))
    }
    func validate() async throws -> AuthenticationState {
        accountIdentity = nil
        let (bytes, response) = try await urlSession.bytes(from: URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!)
        guard let response = response as? HTTPURLResponse else { throw AppleDeveloperError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401: throw AppleDeveloperError.loginRequired
        case 403: throw AppleDeveloperError.permissionDenied
        case 429: throw AppleDeveloperError.rateLimited
        default: throw AppleDeveloperError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AppleDeveloperError.invalidResponse }
            data.append(byte)
        }
        let session = try JSONDecoder().decode(AppleSession.self, from: data)
        accountIdentity = try Self.parseAccount(data)
        return .authenticated(session)
    }
    nonisolated static func parseAccount(_ data: Data) throws -> AppleDeveloperAccount {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["user"] as? [String: Any] else { throw AppleDeveloperError.invalidResponse }
        let account = AppleDeveloperAccount(email: user["emailAddress"] as? String, name: user["fullName"] as? String)
        try account.validate()
        return account
    }
    private func captureIdentity(_ state: AuthenticationState) async throws -> AuthenticationState {
        if case .authenticated = state { return try await validate() }
        return state
    }
    func submit(code: SecurityCode, session: AppleSessionData) async throws -> AuthenticationState {
        try await captureIdentity(try await client.submitSecurityCode(code, sessionData: session))
    }
    func sms(phone: AuthOptionsResponse.TrustedPhoneNumber, options: AuthOptionsResponse, session: AppleSessionData) async throws -> AuthenticationState {
        try await client.requestSMSSecurityCode(to: phone, authOptions: options, sessionData: session)
    }

    func listTeams() async throws -> [RemoteDeveloperTeam] {
        try Self.parseTeams(await portalRequest("account/listTeams.action", form: "clientId=XABBG36SBA"))
    }

    func key(keyID: String, teamID: String) async throws -> RemoteDeveloperKey? {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              keyID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw AppleDeveloperError.invalidResponse }
        return try Self.parseKey(await portalRequest("account/auth/key/get", form: "teamId=\(teamID)&keyId=\(keyID)"), keyID: keyID)
    }

    // Callers pass only validated alphanumeric values, so the form needs no percent-encoding.
    private func portalRequest(_ path: String, form: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://developer.apple.com/services-account/QH65B2/" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, application/x-plist", forHTTPHeaderField: "Accept")
        request.setValue("https://developer.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://developer.apple.com/account/", forHTTPHeaderField: "Referer")
        for (name, value) in csrfHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(form.utf8)
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppleDeveloperError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401: throw AppleDeveloperError.loginRequired
        case 403: throw AppleDeveloperError.permissionDenied
        case 429: throw AppleDeveloperError.rateLimited
        default: throw AppleDeveloperError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AppleDeveloperError.invalidResponse }
            data.append(byte)
        }
        updateCSRF(response)
        return data
    }

    // Service IDs from fastlane's Spaceship::Portal::Key; other services are recognized by name.
    nonisolated static func purpose(serviceID: String, name: String) -> P8Purpose {
        switch serviceID {
        case "U27F4V844T": return .apns
        case "DQ8HTZ7739": return .deviceCheck
        case "6A7HVUVQ3M": return .mediaServices
        default: break
        }
        let name = name.lowercased()
        if name.contains("push") || name.contains("apns") { return .apns }
        if name.contains("sign in with apple") { return .signInWithApple }
        if name.contains("devicecheck") || name.contains("device check") { return .deviceCheck }
        if name.contains("map") { return .maps }
        if name.contains("weather") { return .weatherKit }
        if name.contains("music") || name.contains("media") || name.contains("shazam") { return .mediaServices }
        return .other
    }

    /// Returns nil when the Developer key list has no such key, e.g. an App Store Connect API key.
    nonisolated static func parseKey(_ data: Data, keyID: String) throws -> RemoteDeveloperKey? {
        guard data.count <= 1_048_576, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = body["resultCode"] as? Int else { throw AppleDeveloperError.invalidResponse }
        if code == 1100 { throw AppleDeveloperError.loginRequired }
        if code == 1041 { throw AppleDeveloperError.agreementRequired }
        // shortcut: Apple's "not found" codes are undocumented, so any other failure reads as not found; split them if a code is confirmed.
        guard code == 0 else { return nil }
        let keys = body["keys"] as? [[String: Any]] ?? []
        guard keys.count <= 1_000 else { throw AppleDeveloperError.invalidResponse }
        guard let value = keys.first(where: { $0["keyId"] as? String == keyID }) else { return nil }
        let name = (value["keyName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.utf8.count <= 1_024, let services = value["services"] as? [[String: Any]],
              !services.isEmpty, services.count <= 100 else { throw AppleDeveloperError.invalidResponse }
        var purposes = Set<P8Purpose>()
        for service in services {
            let id = service["id"] as? String ?? "", title = service["name"] as? String ?? ""
            guard id.utf8.count <= 128, title.utf8.count <= 256 else { throw AppleDeveloperError.invalidResponse }
            purposes.insert(purpose(serviceID: id, name: title))
        }
        return RemoteDeveloperKey(keyID: keyID, name: name.isEmpty ? keyID : name, purposes: P8Purpose.allCases.filter(purposes.contains))
    }

    nonisolated static func parseTeams(_ data: Data) throws -> [RemoteDeveloperTeam] {
        guard data.count <= 1_048_576 else { throw AppleDeveloperError.invalidResponse }
        let object: Any
        if let json = try? JSONSerialization.jsonObject(with: data) { object = json }
        else if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) { object = plist }
        else { throw AppleDeveloperError.invalidResponse }
        guard let body = object as? [String: Any], let code = body["resultCode"] as? Int else { throw AppleDeveloperError.invalidResponse }
        guard code == 0 else {
            if code == 1100 { throw AppleDeveloperError.loginRequired }
            if code == 1041 { throw AppleDeveloperError.agreementRequired }
            throw AppleDeveloperError.invalidResponse
        }
        guard let values = body["teams"] as? [[String: Any]], values.count <= 1_000 else { throw AppleDeveloperError.invalidResponse }
        var teams: [RemoteDeveloperTeam] = []
        var ids = Set<String>()
        for value in values {
            guard let id = value["teamId"] as? String, id.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
                  let rawName = value["name"] as? String else { throw AppleDeveloperError.invalidResponse }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 1_024, ids.insert(id).inserted else { throw AppleDeveloperError.invalidResponse }
            teams.append(RemoteDeveloperTeam(teamID: id, name: name))
        }
        guard !teams.isEmpty else { throw AppleDeveloperError.noTeams }
        return teams.sorted { ($0.name, $0.teamID) < ($1.name, $1.teamID) }
    }

    private struct Cookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let httpOnly: Bool

        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            expires = cookie.expiresDate; httpOnly = cookie.isHTTPOnly
        }
        func make() throws -> HTTPCookie {
            let allowed = ["apple.com", "idmsa.apple.com", "appstoreconnect.apple.com", "developer.apple.com"]
            guard allowed.contains(domain.hasPrefix(".") ? String(domain.dropFirst()) : domain), path.hasPrefix("/"),
                  !name.isEmpty, name.utf8.count <= 1_024, value.utf8.count <= 32_768 else { throw AppleDeveloperError.sessionStorage }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"]
            if let expires { properties[.expires] = expires }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties) else { throw AppleDeveloperError.sessionStorage }
            return cookie
        }
    }
    func exportCookies() throws -> Data {
        let cookies = (urlSession.configuration.httpCookieStorage?.cookies ?? []).filter { cookie in
            cookie.isSecure && (try? Cookie(cookie).make()) != nil && (cookie.expiresDate.map { $0 > .now } ?? true)
        }
        guard !cookies.isEmpty, cookies.count <= 100 else { throw AppleDeveloperError.sessionStorage }
        let data = try JSONEncoder().encode(cookies.map(Cookie.init))
        guard data.count <= 262_144 else { throw AppleDeveloperError.sessionStorage }
        return data
    }
    func importCookies(_ data: Data) throws {
        guard data.count <= 262_144 else { throw AppleDeveloperError.sessionStorage }
        let values = try JSONDecoder().decode([Cookie].self, from: data)
        guard !values.isEmpty, values.count <= 100 else { throw AppleDeveloperError.sessionStorage }
        let cookies = try values.map { try $0.make() }
        for cookie in cookies where cookie.expiresDate.map({ $0 > .now }) ?? true {
            urlSession.configuration.httpCookieStorage?.setCookie(cookie)
        }
    }
    func cancel() { accountIdentity = nil; csrfHeaders = [:]; urlSession.invalidateAndCancel(); client.signout() }

    private func updateCSRF(_ response: HTTPURLResponse) {
        for name in ["csrf", "csrf_ts"] {
            if let value = response.value(forHTTPHeaderField: name), value.utf8.count <= 8_192 {
                csrfHeaders[name] = value
            }
        }
    }
}

@MainActor
protocol AppleSessionStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

struct AppleDeveloperSessionStore: AppleSessionStore {
    private let blockedKey = "appleDeveloperSessionDisconnected"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.example.AppMate.apple-developer.session",
         kSecAttrAccount as String: "session-v1", kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> Data? {
        guard !UserDefaults.standard.bool(forKey: blockedKey) else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= SavedAppleDeveloperSession.maximumBytes else { throw AppleDeveloperError.sessionStorage }
        return data
    }
    func write(_ data: Data) throws {
        guard data.count <= SavedAppleDeveloperSession.maximumBytes else { throw AppleDeveloperError.sessionStorage }
        let update = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(update) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppleDeveloperError.sessionStorage }
        UserDefaults.standard.removeObject(forKey: blockedKey)
    }
    func delete() throws {
        // Prevent reuse on next launch even when Keychain deletion fails.
        UserDefaults.standard.set(true, forKey: blockedKey)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppleDeveloperError.sessionStorage }
    }
}

@MainActor
final class MemoryAppleSessionStore: AppleSessionStore {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}

struct RemoteDeveloperFile: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case certificates, profiles
        var id: String { rawValue }
        var title: String { self == .certificates ? "証明書" : "プロファイル" }
        var contentKey: String { self == .certificates ? "certificateContent" : "profileContent" }
    }
    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let expiresAt: Date?
    let platform: String
    var fileName: String {
        let ext = kind == .certificates ? "cer" : platform == "MAC_OS" ? "provisionprofile" : "mobileprovision"
        return "\(kind.rawValue)-\(id).\(ext)"
    }
}

extension AppleDeveloperClient {
    func listFiles(teamID: String, kind: RemoteDeveloperFile.Kind) async throws -> [RemoteDeveloperFile] {
        let fields = kind == .certificates
            ? "name,displayName,certificateType,expirationDate,platform"
            : "name,profileType,profileState,expirationDate,platform"
        var components = URLComponents(string: "https://developer.apple.com/services-account/v1/" + kind.rawValue)!
        components.queryItems = [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "fields[\(kind.rawValue)]", value: fields)]
        var next = components.url
        var visited = Set<URL>()
        var ids = Set<String>()
        var items: [RemoteDeveloperFile] = []
        while let url = next {
            guard visited.count < 100, visited.insert(url).inserted else { throw AppleDeveloperError.invalidResponse }
            let data = try await provisioningRequest(url: url, teamID: teamID, maximumBytes: 4 * 1_048_576)
            let page = try Self.parseFilePage(data, kind: kind)
            for item in page.items {
                guard ids.insert(item.id).inserted, items.count < 10_000 else { throw AppleDeveloperError.invalidResponse }
                items.append(item)
            }
            next = try page.next.map { try Self.provisioningURL($0, kind: kind) }
        }
        return items.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func download(_ item: RemoteDeveloperFile, teamID: String) async throws -> CredentialFile {
        guard Self.validResourceID(item.id) else { throw AppleDeveloperError.invalidResponse }
        let url = URL(string: "https://developer.apple.com/services-account/v1/\(item.kind.rawValue)/\(item.id)")!
        let data = try await provisioningRequest(url: url, teamID: teamID, maximumBytes: 23 * 1_048_576)
        return try Self.parseDownload(data, item: item)
    }

    private func provisioningRequest(url: URL, teamID: String, maximumBytes: Int) async throws -> Data {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "developer.apple.com",
              components.path.hasPrefix("/services-account/v1/"), components.user == nil, components.password == nil else {
            throw AppleDeveloperError.invalidResponse
        }
        let query = components.percentEncodedQuery ?? ""
        components.query = nil
        var request = URLRequest(url: components.url!)
        // The Developer web session API proxies read requests through POST.
        request.httpMethod = "POST"
        request.setValue("GET", forHTTPHeaderField: "X-HTTP-Method-Override")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        request.setValue("https://developer.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://developer.apple.com/account/", forHTTPHeaderField: "Referer")
        for (name, value) in csrfHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["teamId": teamID, "urlEncodedQueryParams": query])
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppleDeveloperError.invalidResponse }
        guard response.expectedContentLength <= maximumBytes else { throw ValidationError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ValidationError.tooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 65_536) { try Task.checkCancellation(); await Task.yield() }
        }
        switch http.statusCode {
        case 200: updateCSRF(http)
        case 401: throw AppleDeveloperError.loginRequired
        case 403:
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errors = root?["errors"] as? [[String: Any]] ?? []
            if errors.contains(where: { $0["code"] as? String == "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED" }) {
                throw AppleDeveloperError.agreementRequired
            }
            throw AppleDeveloperError.permissionDenied
        case 429: throw AppleDeveloperError.rateLimited
        default: throw AppleDeveloperError.invalidResponse
        }
        return data
    }

    nonisolated static func provisioningURL(_ value: String, kind: RemoteDeveloperFile.Kind) throws -> URL {
        guard var components = URLComponents(string: value), components.scheme == "https",
              ["developer.apple.com", "api.appstoreconnect.apple.com"].contains(components.host ?? ""),
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              ["/services-account/v1/" + kind.rawValue, "/v1/" + kind.rawValue].contains(components.path) else {
            throw AppleDeveloperError.invalidResponse
        }
        // Normalize Apple's pagination links back to the cookie-authenticated portal.
        components.host = "developer.apple.com"
        components.path = "/services-account/v1/" + kind.rawValue
        return components.url!
    }

    nonisolated private static func validResourceID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }

    nonisolated static func parseFilePage(_ data: Data, kind: RemoteDeveloperFile.Kind) throws -> (items: [RemoteDeveloperFile], next: String?) {
        guard data.count <= 4 * 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["errors"] == nil, let values = root["data"] as? [[String: Any]], values.count <= 1_000 else {
            throw AppleDeveloperError.invalidResponse
        }
        var ids = Set<String>()
        let items = try values.map { value -> RemoteDeveloperFile in
            guard let id = value["id"] as? String, validResourceID(id), ids.insert(id).inserted,
                  value["type"] as? String == kind.rawValue,
                  let attributes = value["attributes"] as? [String: Any] else { throw AppleDeveloperError.invalidResponse }
            let name = (attributes["displayName"] as? String ?? attributes["name"] as? String ?? "\(kind.title) \(id)").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = attributes[kind == .certificates ? "certificateType" : "profileType"] as? String ?? ""
            let platform = attributes["platform"] as? String ?? ""
            guard !name.isEmpty, name.utf8.count <= 1_024, detail.utf8.count <= 128, platform.utf8.count <= 64 else { throw AppleDeveloperError.invalidResponse }
            var expiresAt: Date?
            if let date = attributes["expirationDate"] as? String {
                let formatter = ISO8601DateFormatter()
                expiresAt = formatter.date(from: date)
                if expiresAt == nil { formatter.formatOptions.insert(.withFractionalSeconds); expiresAt = formatter.date(from: date) }
                guard expiresAt != nil else { throw AppleDeveloperError.invalidResponse }
            }
            return RemoteDeveloperFile(id: id, kind: kind, name: name, detail: detail, expiresAt: expiresAt, platform: platform)
        }
        let links = root["links"] as? [String: Any]
        if let next = links?["next"], !(next is NSNull), !(next is String) { throw AppleDeveloperError.invalidResponse }
        return (items, links?["next"] as? String)
    }

    nonisolated static func parseDownload(_ data: Data, item: RemoteDeveloperFile) throws -> CredentialFile {
        guard data.count <= 23 * 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["errors"] == nil,
              let value = root["data"] as? [String: Any], value["id"] as? String == item.id,
              value["type"] as? String == item.kind.rawValue,
              let attributes = value["attributes"] as? [String: Any],
              let base64 = attributes[item.kind.contentKey] as? String,
              base64.utf8.count <= ((CredentialParser.maximumBytes + 2) / 3) * 4,
              let content = Data(base64Encoded: base64), !content.isEmpty, content.count <= CredentialParser.maximumBytes else {
            throw AppleDeveloperError.invalidResponse
        }
        return CredentialFile(data: content, name: item.fileName)
    }
}
