import SwiftUI

/// 説明モード. The switch is a per-Mac display aid kept in UserDefaults, so it is not part of backups or `AppPreferences`.
enum GuideMode {
    static let storageKey = "Xkeys.guideMode"
}

/// What the guide shows. `tourStep` is the highlighted place of the screen tour, or nil when the tour is closed.
struct GuideState: Equatable {
    var active = false
    var tourStep: Int?
}

extension EnvironmentValues {
    @Entry var guide = GuideState()
}

struct GuideTourStep: Equatable {
    let title: String
    let detail: String
}

/// The places of the main window, in the order of the numbers drawn by `guideSpot`.
enum GuideTour {
    static var steps: [GuideTourStep] {
        [
            GuideTourStep(title: String(localized: "いま表示しているチーム"),
                          detail: String(localized: "Apple Developer の契約ごとに「チーム」があります。複数のチームに入っているときは、ここで切り替えます。")),
            GuideTourStep(title: String(localized: "アプリの一覧と状態"),
                          detail: String(localized: "アプリごとに状態を表示します。赤は「対応が必要」、黄は「期限が近い」、緑は「問題なし」です。")),
            GuideTourStep(title: String(localized: "チーム共通の鍵と証明書"),
                          detail: String(localized: "どのアプリでも使う証明書と鍵（.p8）はここにまとめます。証明書の期限が切れると、その証明書を使うプロファイルも使えなくなります。")),
            GuideTourStep(title: String(localized: "バックアップの状態"),
                          detail: String(localized: "バックアップは自動では作りません。「バックアップが必要」と出たら、ここから保存してください。")),
            GuideTourStep(title: String(localized: "ファイルを追加"),
                          detail: String(localized: "Mac にある証明書・プロファイル・鍵を選ぶか、Apple Developer から取り込みます。画面にドロップしても追加できます。"))
        ]
    }
}

private struct GuideSpot: ViewModifier {
    let number: Int
    @Environment(\.guide) private var guide

    func body(content: Content) -> some View {
        let current = guide.active && guide.tourStep == number - 1
        content
            .overlay {
                if current {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(XkeysStyle.accent, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if guide.active {
                    Text(verbatim: String(number)).font(.system(size: 10, weight: .bold))
                        .foregroundStyle(current ? Color.white : XkeysStyle.accent)
                        .frame(width: 18, height: 18)
                        .background(current ? XkeysStyle.accent : XkeysStyle.canvas, in: Circle())
                        .overlay(Circle().stroke(current ? Color.clear : XkeysStyle.selectionBorder, lineWidth: 1.5))
                        .offset(y: -4).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// Numbers a place of the screen tour while the guide is on and outlines it while the tour points at it.
    func guideSpot(_ number: Int) -> some View { modifier(GuideSpot(number: number)) }
}

/// The card of the screen tour, shown at the lower right of the main window.
struct GuideTourCard: View {
    let step: Int
    let onBack: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void
    let onGlossary: () -> Void

    private static let background = Color(red: 30/255, green: 27/255, blue: 75/255)
    private static let muted = Color(red: 199/255, green: 203/255, blue: 245/255)
    private static let bodyText = Color(red: 224/255, green: 227/255, blue: 255/255)

    var body: some View {
        let steps = GuideTour.steps
        let index = min(max(step, 0), steps.count - 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: String(index + 1)).font(.system(size: 12, weight: .bold)).foregroundStyle(Self.background)
                    .frame(width: 22, height: 22).background(Color.white, in: Circle())
                Text("画面の見方 · \(index + 1) / \(steps.count)").font(.system(size: 12)).foregroundStyle(Self.muted)
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Self.muted).accessibilityLabel("画面のガイドを閉じる")
            }
            Text(steps[index].title).font(.system(size: 16, weight: .bold))
            Text(steps[index].detail).foregroundStyle(Self.bodyText).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("用語集", action: onGlossary).buttonStyle(.plain).foregroundStyle(Self.muted)
                Spacer(minLength: 0)
                if index > 0 {
                    Button("戻る", action: onBack).buttonStyle(.plain).padding(.horizontal, 12).frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Self.muted.opacity(0.5)))
                }
                Button(index + 1 < steps.count ? String(localized: "次へ") : String(localized: "おわり"), action: onNext)
                    .buttonStyle(.plain).fontWeight(.bold).foregroundStyle(Self.background)
                    .padding(.horizontal, 14).frame(height: 28).background(Color.white, in: RoundedRectangle(cornerRadius: 7))
            }.padding(.top, 4)
        }
        .font(.system(size: 13)).foregroundStyle(.white)
        .padding(18).frame(width: 340, alignment: .leading)
        .background(Self.background, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: Self.background.opacity(0.35), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "画面の見方 \(index + 1) / \(steps.count)"))
    }
}

/// Words a first-time developer meets in Xkeys. Display text only; nothing here is stored.
enum GuideTerm: String, CaseIterable, Identifiable {
    case team, bundleID, certificate, profile, distribution, key

    var id: String { rawValue }

    var title: String {
        switch self {
        case .team: String(localized: "チーム · Team ID")
        case .bundleID: "Bundle ID"
        case .certificate: String(localized: "証明書（.cer / .p12）")
        case .profile: String(localized: "プロファイル")
        case .distribution: String(localized: "開発用と配布用")
        case .key: String(localized: "鍵（.p8）")
        }
    }

    var detail: String {
        switch self {
        case .team: String(localized: "Apple Developer Program の契約の単位です。英大文字と数字10文字の Team ID で区別します。")
        case .bundleID: String(localized: "アプリを見分ける名前です。com.example.app のような形で、ターゲットごとに1つあります。")
        case .certificate: String(localized: "チームが作ったアプリだと示す署名に使います。署名には秘密鍵を含む .p12 が必要です。だいたい1年で期限が来ます。")
        case .profile: String(localized: "「このアプリを、この証明書で、ここに配ってよい」という許可証です。使う証明書の期限が切れると、プロファイルも使えなくなります。")
        case .distribution: String(localized: "開発用は自分の端末で試すとき、配布用は App Store や TestFlight に出すときに使います。")
        case .key: String(localized: "プッシュ通知や App Store Connect API などに使う鍵です。Apple からは一度しかダウンロードできません。期限はありません。")
        }
    }
}

extension CredentialGroup {
    var guideTerm: GuideTerm {
        switch self {
        case .profile: .profile
        case .certificate: .certificate
        case .key: .key
        }
    }
}

struct GuideTermDetail: View {
    let term: GuideTerm

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(term.title).fontWeight(.bold)
            Text(term.detail).foregroundStyle(XkeysStyle.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small “?” beside a word. It appears only while the guide is on and explains the word in a popover.
struct GuideTermButton: View {
    let term: GuideTerm
    @Environment(\.guide) private var guide
    @State private var showing = false

    var body: some View {
        if guide.active {
            Button { showing = true } label: {
                Image(systemName: "questionmark").font(.system(size: 9, weight: .bold)).foregroundStyle(XkeysStyle.accent)
                    .frame(width: 18, height: 18).background(XkeysStyle.selection, in: Circle())
                    .overlay(Circle().stroke(XkeysStyle.selectionBorder))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).help(term.title)
            .accessibilityLabel(String(localized: "\(term.title)とは"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                GuideTermDetail(term: term).font(.system(size: 13)).padding(18).frame(width: 320)
            }
        }
    }
}

struct GuideGlossaryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("用語集").font(.system(size: 18, weight: .bold))
                Text("Xkeys の画面に出てくる言葉の意味です。").foregroundStyle(XkeysStyle.secondary)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(GuideTerm.allCases) { term in
                        GuideTermDetail(term: term).padding(12)
                            .background(XkeysStyle.sidebar, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.buttonStyle(XkeysButtonStyle(primary: true)).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .font(.system(size: 13)).foregroundStyle(XkeysStyle.text).background(XkeysStyle.canvas).tint(XkeysStyle.accent)
        .frame(width: 480, height: 540)
    }
}

enum RenewalAction {
    case addFile, importOnline
}

/// “直し方を見る”: the steps to replace expiring files. Xkeys cannot create certificates, so the first step opens Apple Developer.
struct RenewalGuideView: View {
    /// True when something has already expired, false when it is only expiring soon.
    let expired: Bool
    let canImportOnline: Bool
    @Binding var done: Set<Int>
    let onAction: (RenewalAction) -> Void
    @Environment(\.dismiss) private var dismiss

    static let portal = URL(string: "https://developer.apple.com/account/resources/certificates/list")!
    static let stepCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: expired ? "exclamationmark.circle" : "clock").font(.system(size: 18))
                        .foregroundStyle(expired ? XkeysStyle.danger : XkeysStyle.warningText)
                        .frame(width: 36, height: 36)
                        .background(expired ? XkeysStyle.dangerBackground : XkeysStyle.warningBackground, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("証明書とプロファイルを更新する").font(.system(size: 18, weight: .bold))
                        Text("\(Self.stepCount)ステップ · \(done.count) / \(Self.stepCount) 完了").foregroundStyle(XkeysStyle.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("なぜこうなった？").fontWeight(.bold)
                    Text(expired
                         ? String(localized: "証明書の期限が切れると、その証明書で署名するプロファイルも一緒に使えなくなります。アプリ本体や保存したデータには影響ありません。")
                         : String(localized: "期限が切れる前に新しいファイルに入れ替えると、提出や配布を止めずに済みます。"))
                        .foregroundStyle(XkeysStyle.text.opacity(0.8)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(XkeysStyle.search, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 0) {
                    step(0, String(localized: "Apple Developer で新しいファイルを作る"),
                         String(localized: "Xkeys では作成できません。Certificates, Identifiers & Profiles で新しい証明書やプロファイルを作り、ダウンロードします。")) {
                        Link(destination: Self.portal) { Label("Apple Developer を開く", systemImage: "arrow.up.right.square") }
                            .buttonStyle(XkeysButtonStyle(compact: true))
                    }
                    step(1, String(localized: "新しいファイルを取り込む"),
                         String(localized: "ダウンロードしたファイルを追加するか、Apple Developer から直接取り込みます。")) {
                        Button("ファイルを追加…") { onAction(.addFile) }.buttonStyle(XkeysButtonStyle(primary: true, compact: true))
                        if canImportOnline {
                            Button("Apple Developer から取り込む") { onAction(.importOnline) }.buttonStyle(XkeysButtonStyle(compact: true))
                        }
                    }
                    step(2, String(localized: "古いファイルを削除する"),
                         String(localized: "期限切れの行のメニューから削除します。30日間は「最近削除した項目」から戻せます。")) { EmptyView() }
                    step(3, String(localized: "バックアップを作る"),
                         String(localized: "新しい .p12 などを保存したら、サイドバー下部の「バックアップが必要」からバックアップします。")) { EmptyView() }
                }
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
            Divider()
            HStack {
                Text("進み具合は、このページを離れるまで残ります").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                Spacer()
                Button("閉じる") { dismiss() }.buttonStyle(XkeysButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }
        .font(.system(size: 13)).foregroundStyle(XkeysStyle.text).background(XkeysStyle.canvas).tint(XkeysStyle.accent)
        .frame(width: 600)
    }

    private var current: Int? { (0..<Self.stepCount).first { !done.contains($0) } }

    private func step<Actions: View>(_ index: Int, _ title: String, _ detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        let finished = done.contains(index)
        let isCurrent = current == index
        return HStack(alignment: .top, spacing: 14) {
            Button {
                if finished { done.remove(index) } else { done.insert(index) }
            } label: {
                Group {
                    if finished { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                    else { Text(verbatim: String(index + 1)).font(.system(size: 12, weight: .bold)) }
                }
                .foregroundStyle(finished || isCurrent ? Color.white : XkeysStyle.secondary)
                .frame(width: 26, height: 26)
                .background(finished ? XkeysStyle.successText : isCurrent ? XkeysStyle.accent : XkeysStyle.canvas, in: Circle())
                .overlay(Circle().stroke(finished || isCurrent ? Color.clear : XkeysStyle.border, lineWidth: 1.5))
                .contentShape(Circle())
            }.buttonStyle(.plain)
                .accessibilityLabel(finished ? String(localized: "未完了に戻す：\(title)") : String(localized: "完了にする：\(title)"))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.bold).strikethrough(finished).foregroundStyle(finished ? XkeysStyle.secondary : XkeysStyle.text)
                Text(detail).foregroundStyle(XkeysStyle.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                if isCurrent { HStack(spacing: 8) { actions() }.padding(.top, 6) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .background(isCurrent ? XkeysStyle.selectedRow : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}
