import SwiftData
import SwiftUI
import XcodesLoginKit

struct AppleDeveloperLoginView: View {
    var onTeam: ((RemoteDeveloperTeam) throws -> Void)? = nil
    var onVerified: (() throws -> Void)? = nil
    var restoreSavedSession: Bool
    var verificationTitle: String
    @Environment(\.dismiss) private var dismiss
    @Query private var registeredTeams: [DeveloperTeam]
    @State private var session: AppleDeveloperSession
    @State private var account = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var passwordVisible = false
    @State private var code = ""
    @State private var selection: String?
    @State private var error: String?
    @State private var showCodeHelp = false
    @State private var running = false
    @State private var work: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field { case account, password, code }

    init(onTeam: ((RemoteDeveloperTeam) throws -> Void)? = nil,
         onVerified: (() throws -> Void)? = nil,
         session: AppleDeveloperSession = .shared,
         verificationTitle: String = String(localized: "復元するチームへの所属を確認"), restoreSavedSession: Bool = true) {
        self.onTeam = onTeam
        self.onVerified = onVerified
        self.restoreSavedSession = restoreSavedSession
        self.verificationTitle = verificationTitle
        _session = State(initialValue: session)
    }

    private var busy: Bool { running || session.busy }
    private var trimmedAccount: String { account.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedTeamIsRegistered: Bool { registeredTeams.contains { $0.teamID == selection } }
    private var primaryTitle: String {
        if onTeam == nil { return String(localized: "所属を確認") }
        return selectedTeamIsRegistered ? String(localized: "このチームを開く") : String(localized: "チームを追加")
    }

    private var step: Int {
        if session.connected { return 3 }
        switch session.authentication {
        case .authenticated: return 3
        case .waitingForSecondFactor: return 2
        default: return showPassword ? 1 : 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LoginSteps(current: step)
            if session.connected {
                teams.disabled(busy)
            } else if case .authenticated = session.authentication {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Apple Developer にサインイン済み").font(.system(size: 20, weight: .bold))
                    if !busy {
                        Button("再読み込み") { run { try await session.resume() } }
                            .buttonStyle(XkeysButtonStyle(primary: true))
                    }
                    Button("キャンセル") { dismiss() }.buttonStyle(XkeysButtonStyle())
                }
            } else if case let .waitingForSecondFactor(option, options, _) = session.authentication {
                verification(option, options).disabled(busy)
            } else {
                signIn
            }
            if busy, step != 2 {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Appleに接続しています…") }.foregroundStyle(XkeysStyle.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .font(.system(size: 13)).padding(32).frame(width: 440)
        .background(XkeysStyle.canvas).foregroundStyle(XkeysStyle.text).tint(XkeysStyle.accent)
        .task {
            guard restoreSavedSession, !session.connected else { return }
            run {
                do { try await session.resume() }
                catch AppleDeveloperError.loginRequired { }
            }
        }
        .onDisappear { work?.cancel(); password = ""; passwordVisible = false; code = ""; session.cancelAttempt() }
        .onChange(of: session.generation) { _, _ in password = ""; passwordVisible = false; code = "" }
    }

    private var signIn: some View {
        VStack(spacing: 16) {
            Image(systemName: "apple.logo").font(.system(size: 36)).padding(.top, 8)
            Text("Apple Developer にサインイン").font(.system(size: 20, weight: .bold))
            Text("所属しているチームを読み込みます。\n証明書やプロファイルは取り込みません。")
                .multilineTextAlignment(.center).foregroundStyle(XkeysStyle.secondary)
            VStack(spacing: 0) {
                if showPassword {
                    Button { showPassword = false; password = ""; focus = .account } label: {
                        Text(account).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                    }.buttonStyle(.plain).frame(height: 44)
                    Divider()
                    HStack(spacing: 6) {
                        Group {
                            if passwordVisible { TextField("パスワード", text: $password) }
                            else { SecureField("パスワード", text: $password) }
                        }.textFieldStyle(.plain).textContentType(.password)
                            .focused($focus, equals: .password).onSubmit(login)
                        Button { passwordVisible.toggle(); focus = .password } label: {
                            Image(systemName: passwordVisible ? "eye.slash" : "eye").frame(width: 24, height: 24)
                        }.buttonStyle(.plain)
                            .help(passwordVisible ? "パスワードを隠す" : "パスワードを表示")
                            .accessibilityLabel(passwordVisible ? "パスワードを隠す" : "パスワードを表示")
                        continueButton(enabled: !password.isEmpty, action: login)
                    }.padding(.leading, 14).frame(height: 44)
                } else {
                    HStack(spacing: 6) {
                        TextField("Apple Account", text: $account).textFieldStyle(.plain).textContentType(.username)
                            .focused($focus, equals: .account).onSubmit(revealPassword)
                        continueButton(enabled: !trimmedAccount.isEmpty, action: revealPassword)
                    }.padding(.leading, 14).frame(height: 44)
                }
            }
            .disabled(busy)
            .background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focus == nil ? XkeysStyle.border : XkeysStyle.accent, lineWidth: focus == nil ? 1 : 2))
            Link(showPassword ? "パスワードをお忘れの場合" : "Apple Account をお忘れの場合",
                 destination: URL(string: showPassword ? "https://iforgot.apple.com/password/verify/appleid" : "https://iforgot.apple.com")!)
            Text("パスワードは保存しません。サインイン後の接続情報はこのMacのキーチェーンに保存し、次回も使います。")
                .font(.caption).foregroundStyle(XkeysStyle.secondary).multilineTextAlignment(.center)
            HStack { Spacer(); Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(XkeysButtonStyle()) }
        }
        .onAppear { focus = showPassword ? .password : .account }
    }

    private func verification(_ option: TwoFactorOption, _ options: AuthOptionsResponse) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "apple.logo").font(.system(size: 36)).padding(.top, 8)
            Text("2ファクタ認証").font(.system(size: 20, weight: .bold))
            if busy {
                ProgressView("Appleに認証情報を確認しています…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(secondFactorLabel(option)).multilineTextAlignment(.center).foregroundStyle(XkeysStyle.secondary)
                if option == .smsPendingChoice {
                    if let phones = options.trustedPhoneNumbers {
                        ForEach(phones) { phone in
                            Button("\(phone.numberWithDialCode)にSMSを送信") { run { try await session.sendSMS(phone) } }
                                .buttonStyle(XkeysButtonStyle()).disabled(busy)
                        }
                    }
                } else if option != .securityKey {
                    codeBoxes
                    Button("確認コードが届かない場合") { showCodeHelp = true }
                        .buttonStyle(.borderless).foregroundStyle(XkeysStyle.accent)
                        .popover(isPresented: $showCodeHelp, arrowEdge: .bottom) { codeHelp(options) }
                }
            }
            HStack { Spacer(); Button("戻る") { session.useAnotherAccount(); showPassword = true; focus = .password }.buttonStyle(XkeysButtonStyle()) }
        }
        .onAppear { if option != .smsPendingChoice { focus = .code } }
    }

    private var codeBoxes: some View {
        ZStack {
            TextField("", text: $code).textFieldStyle(.plain).focused($focus, equals: .code)
                .frame(width: 1, height: 1).opacity(0.01)
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { code = digits; return }
                    if digits.count == 6, !busy { submitCode() }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    if index == 3 { Spacer().frame(width: 8) }
                    Text(code.count > index ? String(code[code.index(code.startIndex, offsetBy: index)]) : "")
                        .font(.system(size: 22, weight: .semibold)).frame(width: 40, height: 50)
                        .background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(code.count == index ? XkeysStyle.accent : XkeysStyle.border, lineWidth: code.count == index ? 2 : 1))
                }
            }.allowsHitTesting(false)
        }
        .frame(height: 50).contentShape(Rectangle()).onTapGesture { focus = .code }
        .accessibilityElement(children: .ignore).accessibilityLabel("確認コード").accessibilityValue("\(code.count)桁入力済み")
    }

    private func codeHelp(_ options: AuthOptionsResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let phones = options.trustedPhoneNumbers, !phones.isEmpty {
                ForEach(phones) { phone in
                    Button("\(phone.numberWithDialCode)にSMSを送信") {
                        showCodeHelp = false
                        run { try await session.sendSMS(phone) }
                    }.buttonStyle(XkeysButtonStyle())
                }
            } else {
                Text("信頼済みのApple端末に表示されたコードを確認してください。")
                    .foregroundStyle(XkeysStyle.secondary)
            }
        }.padding(16).frame(width: 280)
    }

    private var teams: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text((session.currentAccount?.label ?? trimmedAccount).first.map { String($0).uppercased() } ?? "A")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Color.gray, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.currentAccount?.label ?? String(localized: "ログイン中")).textSelection(.enabled)
                    Text("Apple Developer にログイン中").font(.caption).foregroundStyle(XkeysStyle.secondary)
                }
                Spacer()
                Menu("アカウント") {
                    Button("チームを再読み込み") { run { try await session.resume() } }
                    Button("別のApple Accountでサインイン") { switchAccount() }
                    Divider()
                    Button("ログアウト") {
                        do { try session.disconnect(); switchAccount() } catch { self.error = AppleDeveloperError.message(for: error) }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Text(onTeam == nil ? verificationTitle : String(localized: "追加するチーム")).font(.system(size: 20, weight: .bold))
            Text(onTeam == nil ? "このアカウントで確認できるチームです。" : "このアカウントが所属するチームです。")
                .foregroundStyle(XkeysStyle.secondary)
            if session.teams.isEmpty {
                Text("このApple Accountには所属チームがありません。").foregroundStyle(XkeysStyle.secondary)
                Button("別のApple Accountでサインイン", action: switchAccount).buttonStyle(.borderless).foregroundStyle(XkeysStyle.accent)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(session.teams) { team in
                            if onTeam != nil {
                                Button { selection = team.id } label: { teamRow(team) }.buttonStyle(.plain)
                                    .accessibilityLabel("\(team.name)、Team ID \(team.teamID)")
                                    .accessibilityValue(registeredTeams.contains { $0.teamID == team.id } ? "登録済み" : "未登録")
                                    .accessibilityAddTraits(selection == team.id ? .isSelected : [])
                            } else { teamRow(team) }
                        }
                    }
                }.frame(maxHeight: 240)
                    .background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(XkeysStyle.border))
            }
            Link("チームが表示されない場合", destination: URL(string: "https://developer.apple.com/account/")!)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(XkeysButtonStyle())
                Button(primaryTitle, action: commit).buttonStyle(XkeysButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(!session.connected || busy || session.teams.isEmpty || (onTeam != nil && selection == nil))
            }
        }
    }

    private func teamRow(_ team: RemoteDeveloperTeam) -> some View {
        let registered = registeredTeams.contains { $0.teamID == team.id }
        let selected = onTeam != nil && selection == team.id
        return HStack(spacing: 12) {
            if onTeam != nil {
                Circle().strokeBorder(selected ? XkeysStyle.accent : XkeysStyle.secondary, lineWidth: selected ? 5 : 1.5).frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(team.name).fontWeight(.semibold)
                Text(team.teamID).font(.system(.caption, design: .monospaced)).foregroundStyle(XkeysStyle.secondary)
            }
            Spacer()
            if registered { Text("登録済み").font(.caption).foregroundStyle(XkeysStyle.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? XkeysStyle.selectedRow : .clear)
        .overlay(alignment: .bottom) { Divider().opacity(team.id == session.teams.last?.id ? 0 : 1) }
        .contentShape(Rectangle())
    }

    private func continueButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)) }
            }
            .foregroundStyle(.white).frame(width: 30, height: 30)
            .background(enabled && !busy ? XkeysStyle.accent : XkeysStyle.border, in: Circle())
        }.buttonStyle(.plain).disabled(!enabled || busy).padding(.trailing, 6)
    }

    private func secondFactorLabel(_ option: TwoFactorOption) -> String {
        switch option {
        case .codeSent: String(localized: "ほかのApple製デバイスに確認コードを送信しました。\n6桁のコードを入力してください。")
        case .smsSent(let phone): String(localized: "\(phone.numberWithDialCode)に確認コードを送信しました。\n6桁のコードを入力してください。")
        case .smsPendingChoice: String(localized: "確認コードを受け取る電話番号を選んでください。")
        case .securityKey: String(localized: "この認証方式にはまだ対応していません。")
        }
    }

    private func revealPassword() {
        guard !trimmedAccount.isEmpty else { return }
        showPassword = true
        passwordVisible = false
        focus = .password
    }
    private func switchAccount() {
        session.useAnotherAccount()
        account = ""; password = ""; passwordVisible = false; code = ""; showPassword = false; selection = nil; error = nil
        focus = .account
    }
    private func login() {
        guard !busy, !password.isEmpty else { return }
        let secret = password
        passwordVisible = false
        password = ""
        run { try await session.login(account: account, password: secret) }
    }
    private func submitCode() {
        guard !busy, code.count == 6 else { return }
        let secret = code
        code = ""
        run { try await session.submit(code: secret) }
    }
    private func commit() {
        do {
            if let onTeam, let team = session.teams.first(where: { $0.id == selection }) { try onTeam(team) }
            else if let onVerified { try onVerified() }
            else { return }
            dismiss()
        } catch { self.error = AppleDeveloperError.message(for: error) }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        work?.cancel(); error = nil
        running = true
        focus = nil
        work = Task { @MainActor in
            defer { running = false }
            do { try await action() }
            catch { if !Task.isCancelled { self.error = AppleDeveloperError.message(for: error) } }
        }
    }
}

/// Where the user is in the sign-in: account, password, code, team.
struct LoginSteps: View {
    let current: Int
    private let titles = ["Apple Account", String(localized: "パスワード"), String(localized: "確認コード"), String(localized: "チーム")]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(titles.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(index <= current ? XkeysStyle.accent : XkeysStyle.canvas)
                        Circle().stroke(index <= current ? XkeysStyle.accent : XkeysStyle.border)
                        if index < current { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) }
                        else { Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(index == current ? .white : XkeysStyle.tertiary) }
                    }.frame(width: 18, height: 18)
                    Text(titles[index]).font(.system(size: 11, weight: index == current ? .bold : .regular))
                        .foregroundStyle(index == current ? XkeysStyle.text : index < current ? XkeysStyle.secondary : XkeysStyle.tertiary)
                        .fixedSize()
                }
                if index < titles.count - 1 { Rectangle().fill(XkeysStyle.border).frame(height: 1) }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("手順 \(current + 1) / \(titles.count)：\(titles[current])")
    }
}
