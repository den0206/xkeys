import AsyncNetworkService
import Foundation
import Security
import XcodesLoginKit

struct RemoteDeveloperTeam: Identifiable, Equatable, Sendable {
    let teamID: String
    let name: String
    var id: String { teamID }
}

enum AppleDeveloperError: LocalizedError {
    case invalidResponse, noTeams, loginRequired, permissionDenied, agreementRequired
    case unsupportedLogin, rateLimited, sessionStorage, membershipRequired, busy

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
        case .busy: "別のApple Developerへの接続操作が進行中です。完了してから再試行してください。"
        }
    }

    static func message(for error: Error) -> String {
        if error is RegistrationError || error is RestoreError { return error.localizedDescription }
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

@MainActor
protocol AppleDeveloperTransport: AnyObject {
    func login(account: String, password: String) async throws -> AuthenticationState
    func validate() async throws -> AuthenticationState
    func submit(code: SecurityCode, session: AppleSessionData) async throws -> AuthenticationState
    func sms(phone: AuthOptionsResponse.TrustedPhoneNumber, options: AuthOptionsResponse, session: AppleSessionData) async throws -> AuthenticationState
    func listTeams() async throws -> [RemoteDeveloperTeam]
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

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: AppleRedirectPolicy(), delegateQueue: nil)
        urlSession = session
        client = Client(urlSession: session)
    }

    func login(account: String, password: String) async throws -> AuthenticationState {
        try await client.authenticationState(accountName: account, password: password)
    }
    func validate() async throws -> AuthenticationState {
        do { return try await client.validateSession() }
        catch NetworkError.non200StatusCode(let status, _) {
            switch status {
            case 401: throw AppleDeveloperError.loginRequired
            case 403: throw AppleDeveloperError.permissionDenied
            case 429: throw AppleDeveloperError.rateLimited
            default: throw AppleDeveloperError.invalidResponse
            }
        }
    }
    func submit(code: SecurityCode, session: AppleSessionData) async throws -> AuthenticationState {
        try await client.submitSecurityCode(code, sessionData: session)
    }
    func sms(phone: AuthOptionsResponse.TrustedPhoneNumber, options: AuthOptionsResponse, session: AppleSessionData) async throws -> AuthenticationState {
        try await client.requestSMSSecurityCode(to: phone, authOptions: options, sessionData: session)
    }

    func listTeams() async throws -> [RemoteDeveloperTeam] {
        let url = URL(string: "https://developer.apple.com/services-account/QH65B2/account/listTeams.action")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, application/x-plist", forHTTPHeaderField: "Accept")
        request.setValue("https://developer.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://developer.apple.com/account/", forHTTPHeaderField: "Referer")
        request.httpBody = Data("clientId=XABBG36SBA".utf8)
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
        return try Self.parseTeams(data)
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
    func cancel() { urlSession.invalidateAndCancel(); client.signout() }
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
        guard status == errSecSuccess, let data = result as? Data else { throw AppleDeveloperError.sessionStorage }
        return data
    }
    func write(_ data: Data) throws {
        guard data.count <= 262_144 else { throw AppleDeveloperError.sessionStorage }
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
