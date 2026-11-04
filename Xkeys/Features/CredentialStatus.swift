import SwiftUI

enum CredentialDisplayState: Equatable {
    case expired, withinDay, expiring(Int), valid, stored

    var needsRenewal: Bool {
        switch self { case .withinDay, .expiring: true; default: false }
    }
    var title: String {
        switch self {
        case .expired: String(localized: "期限切れ")
        case .withinDay: String(localized: "24時間以内")
        case .expiring(let days): String(localized: "あと\(days)日")
        case .valid: String(localized: "有効")
        case .stored: String(localized: "保管中")
        }
    }
}

extension StoredCredential {
    var fileTypeTitle: String {
        if isIntermediateCA { return String(localized: "中間CA証明書") }
        return switch fileExtension {
        case "cer": String(localized: "証明書")
        case "p12": String(localized: "証明書＋秘密鍵")
        case "p8": String(localized: "秘密鍵")
        default: String(localized: "プロファイル")
        }
    }

    var purposeTitle: String {
        keyPurpose.flatMap(P8Purpose.purposes(stored:))?.map(\.displayTitle).joined(separator: String(localized: "・")) ?? String(localized: "未設定")
    }

    func displayState(at now: Date) -> CredentialDisplayState {
        guard let expiresAt else { return .stored }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return .expired }
        if seconds < 86400 { return .withinDay }
        if seconds <= 30 * 86400 { return .expiring(Int(ceil(seconds / 86400))) }
        return .valid
    }
}
