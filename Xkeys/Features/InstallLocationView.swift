import AppKit
import SwiftUI

/// Where this copy of Xkeys runs from. Opened from the DMG or quarantined in place, it should be moved to Applications first.
enum InstallLocation: Equatable {
    case applications, diskImage, translocated, other

    static let skipKey = "Xkeys.skipMoveToApplications"

    init(bundleURL: URL) {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { self = .translocated }
        else if path.contains("/Applications/") { self = .applications }
        else if path.hasPrefix("/Volumes/") { self = .diskImage }
        else { self = .other }
    }

    /// Builds run from Xcode or another folder are left alone; only the two places a downloaded copy lands in are asked about.
    var suggestsMove: Bool { self == .diskImage || self == .translocated }
}

/// The App Sandbox does not let Xkeys move itself, so this explains the drag and opens the folders in Finder.
/// The data lives in the app's container, so it stays the same after the move.
struct MoveToApplicationsView: View {
    let location: InstallLocation
    let onContinue: () -> Void
    @AppStorage(InstallLocation.skipKey) private var skip = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Xkeys を「アプリケーション」フォルダに移動してください").font(.system(size: 15, weight: .bold))
                Text(location == .diskImage
                     ? String(localized: "いまはディスクイメージから開いています。ディスクイメージを取り出すと Xkeys も開けなくなり、アップデートもできません。")
                     : String(localized: "いまはダウンロードした場所から一時的に開いています。この場所ではアップデートが正しく行えないことがあります。"))
                    .font(.system(size: 12)).foregroundStyle(XkeysStyle.text.opacity(0.75)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }.multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                moveStep(1, location == .diskImage ? String(localized: "Finder で Xkeys と「アプリケーション」を開きます")
                                                    : String(localized: "Finder で「アプリケーション」を開きます"))
                moveStep(2, location == .diskImage ? String(localized: "Xkeys を「アプリケーション」へドラッグします")
                                                    : String(localized: "ダウンロードした Xkeys を「アプリケーション」へドラッグします"))
                moveStep(3, String(localized: "「アプリケーション」から Xkeys を開き直します"))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(XkeysStyle.search, in: RoundedRectangle(cornerRadius: 10))
            Text("保存したデータは移動後もそのまま使えます。").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
            VStack(spacing: 8) {
                Button { revealInFinder(); NSApp.terminate(nil) } label: {
                    Text("Finder で開いて終了").frame(maxWidth: .infinity)
                }.buttonStyle(XkeysButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                Button { onContinue() } label: {
                    Text("このまま使う").frame(maxWidth: .infinity)
                }.buttonStyle(XkeysButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Toggle("次回から確認しない", isOn: $skip).toggleStyle(.checkbox).font(.system(size: 12))
        }
        .font(.system(size: 13)).foregroundStyle(XkeysStyle.text).tint(XkeysStyle.accent)
        .padding(.horizontal, 24).padding(.vertical, 22).frame(width: 400).background(XkeysStyle.canvas)
    }

    private func moveStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: String(number)).font(.system(size: 11, weight: .bold)).foregroundStyle(XkeysStyle.accent)
                .frame(width: 20, height: 20).background(XkeysStyle.canvas, in: Circle())
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    private func revealInFinder() {
        // A translocated copy runs from a hidden read-only path, so only the DMG copy is worth selecting.
        if location == .diskImage { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }
}
