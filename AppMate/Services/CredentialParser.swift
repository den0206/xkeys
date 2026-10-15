import Darwin
import CryptoKit
import Foundation
import Security

struct ParsedCredential: Equatable, Sendable {
    static let intermediateCAKind = "中間CA証明書"
    var isIntermediateCA: Bool { kind == Self.intermediateCAKind }
    var fingerprint: String? = nil
    let name: String
    let kind: String
    let teamID: String?
    let bundleID: String?
    let expiresAt: Date?
}

enum ValidationError: LocalizedError {
    case invalidFile, tooLarge, unsupported, multipleCertificates, signingRequired, security(OSStatus), missingKey

    var errorDescription: String? {
        switch self {
        case .invalidFile: "ファイルを解析できません。形式と内容を確認してください。"
        case .tooLarge: "ファイルは16MB以下を選んでください。"
        case .multipleCertificates: "複数の証明書を含む.p12は、解析対象を選んでください。"
        case .unsupported: "プロファイル・.cer・.p12・.p8に対応しています。"
        case .signingRequired:
            "Keychainを使用するための開発用署名が必要です。XcodeでApple Development証明書とTeamを設定してから、F5で再ビルドしてください。"
        case .security(let status):
            status == errSecMissingEntitlement
                ? ValidationError.signingRequired.localizedDescription
                : "セキュリティ処理に失敗しました（\(status)）。パスワードとアクセス許可を確認してください。"
        case .missingKey: "保存済みデータの暗号鍵を取得できません。新しい鍵で上書きしません。"
        }
    }
}

struct CredentialParser {
    static let maximumBytes = 16 * 1024 * 1024

    static func parse(_ data: Data, extension ext: String, password: String = "") throws -> ParsedCredential {
        let candidates = try parseAll(data, extension: ext, password: password)
        guard candidates.count == 1 else { throw ValidationError.multipleCertificates }
        return candidates[0]
    }

    static func parseAll(_ data: Data, extension ext: String, password: String = "") throws -> [ParsedCredential] {
        guard !data.isEmpty else { throw ValidationError.invalidFile }
        guard data.count <= maximumBytes else { throw ValidationError.tooLarge }
        switch ext.lowercased() {
        case "mobileprovision", "provisionprofile": return [try profile(data)]
        case "cer":
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
                throw ValidationError.invalidFile
            }
            return [try certificateInfo(certificate, kind: "証明書")]
        case "p12": return try pkcs12(data, password: password)
        case "p8":
            guard data.count <= 16 * 1024, let text = String(data: data, encoding: .utf8) else {
                throw ValidationError.invalidFile
            }
            let pem = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard pem.hasPrefix("-----BEGIN PRIVATE KEY-----"), pem.hasSuffix("-----END PRIVATE KEY-----"),
                  pem.components(separatedBy: "-----BEGIN").count == 2 else { throw ValidationError.invalidFile }
            let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
            let fingerprint = SHA256.hash(data: key.publicKey.derRepresentation).map { String(format: "%02x", $0) }.joined()
            return [ParsedCredential(fingerprint: fingerprint, name: "Apple APIキー", kind: "秘密鍵（用途未指定）",
                                     teamID: nil, bundleID: nil, expiresAt: nil)]
        default: throw ValidationError.unsupported
        }
    }

    private static func profile(_ data: Data) throws -> ParsedCredential {
        var decoder: CMSDecoder?
        try check(CMSDecoderCreate(&decoder))
        guard let decoder else { throw ValidationError.invalidFile }
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { throw ValidationError.invalidFile }
            try check(CMSDecoderUpdateMessage(decoder, address, bytes.count))
        }
        try check(CMSDecoderFinalizeMessage(decoder))
        var signers = 0
        try check(CMSDecoderGetNumSigners(decoder, &signers))
        guard signers > 0, signers <= 8 else { throw ValidationError.invalidFile }
        for index in 0..<signers {
            var status = CMSSignerStatus(rawValue: 0)!
            var trust: SecTrust?
            // Parse local metadata; signature integrity is distinct from Apple issuer trust.
            try check(CMSDecoderCopySignerStatus(decoder, index, SecPolicyCreateBasicX509(), false, &status, &trust, nil))
            guard status == .valid else { throw ValidationError.invalidFile }
        }
        var content: CFData?
        try check(CMSDecoderCopyContent(decoder, &content))
        guard let content,
              let plist = try PropertyListSerialization.propertyList(from: content as Data, format: nil) as? [String: Any],
              let name = plist["Name"] as? String, !name.isEmpty,
              let expiry = plist["ExpirationDate"] as? Date,
              let team = (plist["TeamIdentifier"] as? [String])?.first,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let identifier = (entitlements["application-identifier"] ?? entitlements["com.apple.application-identifier"]) as? String
        else { throw ValidationError.invalidFile }
        let prefix = (plist["ApplicationIdentifierPrefix"] as? [String])?.first ?? team
        guard identifier.hasPrefix(prefix + "."), identifier.count > prefix.count + 1 else {
            throw ValidationError.invalidFile
        }
        return ParsedCredential(name: name, kind: "プロファイル", teamID: team,
                                bundleID: String(identifier.dropFirst(prefix.count + 1)), expiresAt: expiry)
    }

    private static func pkcs12(_ data: Data, password: String) throws -> [ParsedCredential] {
        var format = SecExternalFormat.formatPKCS12
        var type = SecExternalItemType.itemTypeAggregate
        let passphrase = password as CFString
        let title = "App Mate" as CFString
        var parameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION), flags: [],
            passphrase: Unmanaged.passUnretained(passphrase),
            alertTitle: Unmanaged.passUnretained(title), alertPrompt: Unmanaged.passUnretained(title),
            accessRef: nil, keyUsage: nil, keyAttributes: nil)
        var items: CFArray?
        // A nil importKeychain prevents persistent keychain import.
        try withExtendedLifetime((passphrase, title)) {
            try check(SecItemImport(data as CFData, nil, &format, &type, [], &parameters, nil, &items))
        }
        guard let items = items as? [Any] else { throw ValidationError.invalidFile }
        guard items.count <= 64 else { throw ValidationError.invalidFile }
        var certificates: [SecCertificate] = []
        for item in items {
            if CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() {
                var certificate: SecCertificate?
                try check(SecIdentityCopyCertificate(item as! SecIdentity, &certificate))
                if let certificate { certificates.append(certificate) }
            } else if CFGetTypeID(item as CFTypeRef) == SecCertificateGetTypeID() {
                certificates.append(item as! SecCertificate)
            }
        }
        var seen = Set<Data>()
        let unique = certificates.filter { seen.insert(SecCertificateCopyData($0) as Data).inserted }
        guard !unique.isEmpty else { throw ValidationError.invalidFile }
        // Memory-only import does not reliably expose private-key associations on all supported systems.
        return try unique.map { try certificateInfo($0, kind: "PKCS#12（証明書候補）") }
    }

    private static func certificateInfo(_ certificate: SecCertificate, kind: String) throws -> ParsedCredential {
        let keys = [kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1SubjectName, kSecOIDBasicConstraints] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let expiry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let time = expiry[kSecPropertyKeyValue as String] as? NSNumber else {
            throw ValidationError.invalidFile
        }
        let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any]
        let fields = subject?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        let teams = Set(fields.filter {
            ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationalUnitName as String)
        }.compactMap { $0[kSecPropertyKeyValue as String] as? String }.filter {
            $0.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
        })
        let constraints = values[kSecOIDBasicConstraints as String] as? [String: Any]
        let constraintFields = constraints?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        let isCA = constraintFields.contains {
            ($0[kSecPropertyKeyLabel as String] as? String) == "Certificate Authority" &&
            ($0[kSecPropertyKeyValue as String] as? String) == "Yes"
        }
        let subjectName = SecCertificateCopyNormalizedSubjectSequence(certificate)
        let issuerName = SecCertificateCopyNormalizedIssuerSequence(certificate)
        let intermediate = kind == "証明書" && isCA && subjectName != nil && issuerName != nil && subjectName != issuerName
        let team = !intermediate && teams.count == 1 ? teams.first : nil
        return ParsedCredential(fingerprint: SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined(),
                                name: SecCertificateCopySubjectSummary(certificate) as String? ?? "証明書",
                                kind: intermediate ? ParsedCredential.intermediateCAKind : kind, teamID: team, bundleID: nil,
                                expiresAt: Date(timeIntervalSinceReferenceDate: time.doubleValue))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ValidationError.security(status) }
    }
}

// Keep the exact bytes selected by the user; exporting never reserializes a certificate or its keys.
struct CredentialFile: Sendable {
    let data: Data
    let name: String

    var requiresPasswordEntry: Bool { (name as NSString).pathExtension.lowercased() == "p12" }

    init(data: Data, name: String) { self.data = data; self.name = name }

    init(url: URL, maximumBytes: Int = CredentialParser.maximumBytes) throws {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw ValidationError.tooLarge }
        guard url.isFileURL else { throw ValidationError.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ValidationError.invalidFile }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError.invalidFile
        }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !bytes.isEmpty else { throw ValidationError.invalidFile }
        guard bytes.count <= maximumBytes else { throw ValidationError.tooLarge }
        data = bytes
        name = url.lastPathComponent
    }

    func export(to url: URL) throws {
        guard url.isFileURL else { throw ValidationError.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Exclusive creation also protects the source through hard links and symbolic links.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.seek(toOffset: 0)
            var offset = 0
            while offset < data.count {
                let end = min(offset + 1024 * 1024, data.count)
                guard let chunk = try handle.read(upToCount: end - offset), !chunk.isEmpty,
                      chunk == data[offset..<(offset + chunk.count)] else { throw ValidationError.invalidFile }
                offset += chunk.count
            }
            guard try handle.read(upToCount: 1)?.isEmpty != false else { throw ValidationError.invalidFile }
        } catch {
            var opened = stat()
            var current = stat()
            // Remove a partial output only while the path still names the file we created.
            if fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
               opened.st_dev == current.st_dev, opened.st_ino == current.st_ino {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }
}
