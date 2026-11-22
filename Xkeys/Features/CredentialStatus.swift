import SwiftUI

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
}
