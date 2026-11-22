import CryptoKit
import Foundation
import Observation

/// Screen-side gate for secret operations: one operation at a time, cancelled by `lock()`.
@MainActor @Observable
final class VaultAccess {
    private(set) var busy = false
    private(set) var generation = UUID()
    @ObservationIgnored private let authentication = OwnerAuthentication()
    @ObservationIgnored private let keyProvider: ((String, Bool) async throws -> SymmetricKey)?

    init(keyProvider: ((String, Bool) async throws -> SymmetricKey)? = nil) { self.keyProvider = keyProvider }

    func lock() {
        generation = UUID()
        authentication.cancel()
    }

    func withKey<T>(reason: String, allowCreation: Bool, vault: CredentialVault? = nil, alwaysAsk: Bool = false, operation: (SymmetricKey) throws -> T) async throws -> T {
        guard !busy else { throw VaultError.cancelled }
        busy = true
        let generation = self.generation
        defer { busy = false; authentication.cancel() }
        let key: SymmetricKey
        if let keyProvider {
            key = try await keyProvider(reason, allowCreation)
        } else {
            try EncryptionKeychain.requireSigning()
            // Unreadable settings fall back to asking every time.
            let reuse = !alwaysAsk && (vault.flatMap { try? PreferencesStore.read(in: $0.context).reuseAuthentication } ?? false)
            let context = try await authentication.authenticate(reason: reason, reuse: reuse)
            // A rejected approval is not reused, so the next attempt asks again.
            do { key = try EncryptionKeychain.vault.key(context: context, allowCreation: allowCreation) }
            catch { OwnerAuthentication.forget(); throw error }
        }
        guard self.generation == generation, !Task.isCancelled else { throw VaultError.cancelled }
        // Getting the key never deletes data: the 30-day purge runs only at launch (CatalogView).
        if let vault {
            // Display-only metadata: a failure here must not block the requested operation.
            try? await VaultManagement(vault: vault).backfillSigningCertificates(key: key)
            guard self.generation == generation, !Task.isCancelled else { throw VaultError.cancelled }
        }
        let result = try operation(key)
        // Records a restore just added are read now, not on the next authentication.
        if let vault, self.generation == generation { try? await VaultManagement(vault: vault).backfillSigningCertificates(key: key) }
        return result
    }

    /// Authenticates and quarantines unreadable data. Every blob moves only when the Keychain confirms the vault key is absent.
    func quarantineUnreadable(reason: String, vault: CredentialVault) async throws -> Int {
        guard !busy else { throw VaultError.cancelled }
        busy = true
        let generation = self.generation
        defer { busy = false; authentication.cancel() }
        var key: SymmetricKey?
        do {
            if let keyProvider {
                key = try await keyProvider(reason, false)
            } else {
                try EncryptionKeychain.requireSigning()
                let context = try await authentication.authenticate(reason: reason)
                key = try EncryptionKeychain.vault.key(context: context, allowCreation: false)
            }
        } catch ValidationError.keyNotFound { key = nil }
        guard self.generation == generation, !Task.isCancelled else { throw VaultError.cancelled }
        return try VaultManagement(vault: vault).quarantineUnreadable(key: key)
    }
}
