import SwiftData
import SwiftUI
import XcodesLoginKit

struct AppleDeveloperLoginView: View {
    var onTeam: ((RemoteDeveloperTeam) throws -> Void)? = nil
    var onVerified: (() throws -> Void)? = nil
    var verificationTitle: String
    @Environment(\.dismiss) private var dismiss
    @Query private var registeredTeams: [DeveloperTeam]
    @State private var session: AppleDeveloperSession
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @State private var selection: String?
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    init(onTeam: ((RemoteDeveloperTeam) throws -> Void)? = nil,
         onVerified: (() throws -> Void)? = nil,
         session: AppleDeveloperSession = .shared,
         verificationTitle: String = "復元するチームへの所属を確認") {
        self.onTeam = onTeam
        self.onVerified = onVerified
        self.verificationTitle = verificationTitle
        _session = State(initialValue: session)
    }

    private var selectedTeamIsRegistered: Bool {
        registeredTeams.contains { $0.teamID == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(onTeam == nil ? verificationTitle : "チームを追加")
                .font(.system(size: 18, weight: .bold))
            if session.connected {
                Text(onTeam == nil ? "Apple Developerの所属チーム" : "追加するチームを選択してください")
                if onTeam != nil {
                    Text("登録済みのチームを選ぶと、そのチームを開きます。")
                        .font(.caption).foregroundStyle(AppMateStyle.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(session.teams) { team in
                            if onTeam != nil {
                                Button { selection = team.id } label: { teamRow(team) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(team.name)、Team ID \(team.teamID)")
                                    .accessibilityValue(registeredTeams.contains { $0.teamID == team.id } ? "登録済み" : "未登録")
                                    .accessibilityAddTraits(selection == team.id ? .isSelected : [])
                            } else {
                                teamRow(team)
                            }
                        }
                    }
                }.frame(maxHeight: 240)
                Button("所属チームを更新") { run { try await session.resume() } }.disabled(session.busy)
                Button("別のApple Accountでログイン…") {
                    session.useAnotherAccount(); selection = nil; error = nil
                }
            } else if case let .waitingForSecondFactor(option, options, _) = session.authentication {
                Text(secondFactorLabel(option)).foregroundStyle(AppMateStyle.secondary)
                if option != .smsPendingChoice {
                    SecureField("確認コード", text: $code).onSubmit { submitCode() }
                    Button("確認コードを送信", action: submitCode).disabled(code.isEmpty || session.busy)
                }
                if let phones = options.trustedPhoneNumbers {
                    ForEach(phones) { phone in
                        Button("\(phone.numberWithDialCode)にSMSを送信") {
                            run { try await session.sendSMS(phone) }
                        }.disabled(session.busy)
                    }
                }
                Button("ログインからやり直す") { session.useAnotherAccount(); code = ""; error = nil }
            } else {
                Text(onTeam == nil ? "対象チームに所属するApple Accountでログインしてください。" : "所属チームを取得して登録します。証明書やプロファイルの取り込みは行いません。")
                    .foregroundStyle(AppMateStyle.secondary)
                TextField("Apple Account", text: $account).textContentType(.username)
                SecureField("パスワード", text: $password).textContentType(.password).onSubmit { login() }
                Text("パスワードは保存しません。接続情報はこのMacのKeychainに保存し、次回も利用します。")
                    .font(.caption).foregroundStyle(AppMateStyle.secondary)
                Button("Apple Developerにログイン", action: login)
                    .disabled(account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || session.busy)
                Button("保存済みの接続で再試行") { run { try await session.resume() } }.disabled(session.busy)
            }
            if session.busy { HStack { ProgressView().controlSize(.small); Text("Appleに接続しています…") } }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Link("Apple Developerのアカウントを確認", destination: URL(string: "https://developer.apple.com/account/")!)
                .font(.caption)
            Divider()
            HStack {
                Button("接続を解除") {
                    work?.cancel()
                    do { try session.disconnect(); error = nil } catch { self.error = AppleDeveloperError.message(for: error) }
                }.disabled(session.busy)
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(onTeam == nil ? "所属を確認" : selectedTeamIsRegistered ? "このチームを開く" : "このチームを登録") {
                    do {
                        if let onTeam, let team = session.teams.first(where: { $0.id == selection }) { try onTeam(team) }
                        else if let onVerified { try onVerified() }
                        else { return }
                        dismiss()
                    } catch { self.error = AppleDeveloperError.message(for: error) }
                }.buttonStyle(AppMateButtonStyle(primary: true))
                    .disabled(!session.connected || session.busy || (onTeam != nil && selection == nil))
            }
        }
        .font(.system(size: 13)).textFieldStyle(.roundedBorder)
        .buttonStyle(AppMateButtonStyle()).padding(24).frame(width: 540)
        .background(AppMateStyle.canvas).foregroundStyle(AppMateStyle.text)
        .task {
            guard !session.connected else { return }
            run {
                do { try await session.resume() }
                catch AppleDeveloperError.loginRequired { }
            }
        }
        .onDisappear { work?.cancel(); password = ""; code = ""; session.cancelAttempt() }
        .onChange(of: session.generation) { _, _ in password = ""; code = "" }
    }

    private func teamRow(_ team: RemoteDeveloperTeam) -> some View {
        let registered = registeredTeams.contains { $0.teamID == team.id }
        let selected = onTeam != nil && selection == team.id
        return HStack(spacing: 12) {
            if onTeam != nil {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AppMateStyle.accent : AppMateStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(team.name).fontWeight(.medium)
                Text("Team ID: " + team.teamID).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppMateStyle.secondary)
            }
            Spacer()
            Label(registered ? "登録済み" : "未登録", systemImage: registered ? "checkmark.circle.fill" : "plus.circle")
                .font(.caption).foregroundStyle(registered ? AppMateStyle.accent : AppMateStyle.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(registered ? AppMateStyle.selectedRow : AppMateStyle.canvas, in: Capsule())
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppMateStyle.selectedRow : AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? AppMateStyle.accent : AppMateStyle.border, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }

    private func secondFactorLabel(_ option: TwoFactorOption) -> String {
        switch option {
        case .codeSent: "信頼済みのApple端末に表示された確認コードを入力してください。"
        case .smsSent(let phone): "\(phone.numberWithDialCode)に届いた確認コードを入力してください。"
        case .smsPendingChoice: "確認コードを受け取る電話番号を選んでください。"
        case .securityKey: "この認証方式にはまだ対応していません。"
        }
    }
    private func login() {
        let secret = password
        password = ""
        run { try await session.login(account: account, password: secret) }
    }
    private func submitCode() {
        let secret = code
        code = ""
        run { try await session.submit(code: secret) }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !session.busy else { return }
        work?.cancel(); error = nil
        work = Task { @MainActor in
            do { try await action() }
            catch { if !Task.isCancelled { self.error = AppleDeveloperError.message(for: error) } }
        }
    }
}
