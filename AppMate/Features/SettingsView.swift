import SwiftData
import SwiftUI

struct AppSettingsView: View {
    let container: ModelContainer
    @State private var preferences = AppPreferences()
    @State private var error: String?
    @State private var loaded = false
    @State private var apple = AppleDeveloperSession.shared

    /// `initialSection` is kept for callers of the old two-page layout; every group is now on one page.
    init(container: ModelContainer, appleSession: AppleDeveloperSession = .shared, initialSection: String = "一般") {
        self.container = container
        _apple = State(initialValue: appleSession)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("設定").font(.system(size: 20, weight: .bold))
                    settingsGroup("Apple Developer") {
                        AppleDeveloperAccountView(session: apple).padding(14)
                        settingsNote("パスワードは保存しません。接続情報だけをこの Mac のキーチェーンに保存しています。")
                    }
                    settingsGroup("表示") {
                        settingsToggle("Dock アイコンに件数を表示", detail: "30日以内に期限が来るものの数を出します", isOn: $preferences.showDockBadge)
                    }
                    settingsGroup("安全のために") {
                        safetyRow("touchid", "コピー・書き出し・削除の前に、毎回 Touch ID で確認します")
                        safetyRow("clock", "5分操作しないと、表示中のパスワードやメモを閉じます")
                        safetyRow("arrow.triangle.2.circlepath", "iCloud 同期や自動起動はしません。元のファイルも変更しません")
                    }
                }.padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(AppMateStyle.dangerText) }
                Spacer()
                Button("設定を保存") {
                    do { try PreferencesStore.save(preferences, in: container.mainContext); error = nil }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(AppMateButtonStyle(primary: true)).disabled(!loaded)
            }.padding(.horizontal, 28).padding(.vertical, 14)
        }
        .font(.system(size: 13)).foregroundStyle(AppMateStyle.text).background(AppMateStyle.sidebar)
        .tint(AppMateStyle.accent).frame(width: 640, height: 592)
        .task {
            do { preferences = try PreferencesStore.read(in: container.mainContext); loaded = true }
            catch { self.error = error.localizedDescription }
        }
    }
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(AppMateStyle.text.opacity(0.75))
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppMateStyle.canvas, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppMateStyle.rowBorder, lineWidth: 1))
        }
    }

    private func settingsNote(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
    }

    private func safetyRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(AppMateStyle.secondary).frame(width: 20)
            Text(text)
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(AppMateStyle.rowBorder).frame(height: 1) }
    }

    private func settingsToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.system(size: 12)).foregroundStyle(AppMateStyle.secondary)
            }
            Spacer(minLength: 10)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }

}

struct AppleDeveloperAccountView: View {
    let session: AppleDeveloperSession
    var compact = false
    @State private var showingLogin = false
    @State private var error: String?

    var body: some View {
        Group {
            if compact {
                Menu {
                    Text(session.connected ? "ログイン中" : session.hasSavedSession ? "前回のログイン" : "未ログイン")
                    if let account = session.currentAccount ?? session.savedAccount { Text(account.label) }
                    accountActions
                    if let error { Text(error) }
                } label: {
                    Label((session.currentAccount ?? session.savedAccount)?.label ?? "Apple Developerにログイン", systemImage: "person.crop.circle")
                        .font(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.menuStyle(.borderlessButton)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(session.connected ? "ログイン中のApple Account" : session.hasSavedSession ? "前回ログインしたApple Account" : "ログインしていません",
                          systemImage: session.connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.headline)
                    if let account = session.currentAccount ?? session.savedAccount {
                        Text(account.label).font(.system(size: 17, weight: .semibold))
                            .textSelection(.enabled)
                        if let email = account.email, let name = account.name, email != name {
                            Text(name).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if !session.connected {
                        Text(session.hasSavedSession
                             ? "保存したログイン情報を次回のオンライン操作で使用します。期限が切れている場合は再ログインが必要です。"
                             : "Apple Developerにログインして所属チームを確認できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack { accountActions }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .task {
            do { try session.loadSavedAccount() }
            catch { self.error = AppleDeveloperError.message(for: error) }
        }
        .sheet(isPresented: $showingLogin) {
            AppleDeveloperLoginView(onVerified: {}, session: session,
                                    verificationTitle: "所属チーム", restoreSavedSession: false)
                .onChange(of: session.connected) { _, connected in
                    if connected { showingLogin = false }
                }
        }
    }
    @ViewBuilder
    private var accountActions: some View {
        Button(session.hasSavedSession || session.connected ? "再ログイン…" : "ログイン…") {
            session.useAnotherAccount()
            showingLogin = true
        }.disabled(session.busy)
        if session.hasSavedSession && !session.connected {
            Button("ログイン状態を確認") {
                Task {
                    do { try await session.resume(); error = nil }
                    catch { self.error = AppleDeveloperError.message(for: error) }
                }
            }.disabled(session.busy)
        }
        if session.hasSavedSession || session.connected {
            Button("ログアウト", role: .destructive) {
                do { try session.disconnect(); error = nil }
                catch { self.error = AppleDeveloperError.message(for: error) }
            }
        }
        if session.busy { ProgressView().controlSize(.small) }
    }

}
