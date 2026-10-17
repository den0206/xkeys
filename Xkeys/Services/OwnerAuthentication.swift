import CryptoKit
import LocalAuthentication
import Security

@MainActor
final class OwnerAuthentication {
    private var active: LAContext?

    func authenticate(reason: String) async throws -> LAContext {
        cancel()
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        active = context
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason),
              active === context else { throw LAError(.appCancel) }
        return context
    }

    func cancel() {
        active?.invalidate()
        active = nil
    }
}

struct EncryptionKeychain {
    static let vault = EncryptionKeychain(service: "com.yuuki.xkeys.vault.encryption", account: "vault-key-v1")
    private let service: String
    private let account: String

    static func hasAccessGroup(_ entitlements: [String: Any]) -> Bool {
        if let identifier = entitlements["com.apple.application-identifier"] as? String,
           !identifier.isEmpty { return true }
        return (entitlements["keychain-access-groups"] as? [String])?.contains { !$0.isEmpty } ?? false
    }

    static func requireSigning() throws {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              hasAccessGroup(entitlements) else {
            throw ValidationError.signingRequired
        }
    }

    func key(context: LAContext, allowCreation: Bool) throws -> SymmetricKey {
        try Self.requireSigning()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let bytes = result as? Data, bytes.count == 32 else { throw ValidationError.missingKey }
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound else { throw ValidationError.security(status) }
        // Only a confirmed absence is reported as keyNotFound: it allows quarantining every blob.
        guard allowCreation else { throw ValidationError.keyNotFound }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .userPresence, &error) else {
            throw error?.takeRetainedValue() as Error? ?? ValidationError.missingKey
        }
        let key = SymmetricKey(size: .bits256)
        var attributes = query
        attributes.removeValue(forKey: kSecReturnData as String)
        attributes[kSecAttrAccessControl as String] = control
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw ValidationError.security(added) }
        return key
    }
}
