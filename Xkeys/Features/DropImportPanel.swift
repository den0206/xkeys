import SwiftUI

/// Files dropped on a page are added without the import sheet.
/// Only a .p12 password is asked here; anything that needs more (a .p8 purpose, a target choice,
/// several certificates in one .p12) opens the import sheet with the same files.
struct DropImportPanel: View {
    let sources: [URL]
    let app: ManagedApp?
    let team: DeveloperTeam
    let vault: CredentialVault
    let openSheet: ([URL]) -> Void
    let close: (UUID?) -> Void

    private struct Item {
        let file: CredentialFile
        let parsed: ParsedCredential
        let app: ManagedApp?
        let password: String?
    }

    @State private var access = VaultAccess()
    @State private var scoped: [URL] = []
    @State private var ready: [Item] = []
    @State private var waiting: [CredentialFile] = []
    @State private var notes: [String] = []
    @State private var saved: [String] = []
    @State private var lastSavedID: UUID?
    @State private var reading = true
    @State private var finished = false
    @State private var password = ""
    @State private var showingPassword = false
    @State private var error: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if reading { ProgressView().controlSize(.small) }
                else { Image(systemName: finished ? "checkmark.circle.fill" : "square.and.arrow.down").foregroundStyle(finished ? XkeysStyle.successText : XkeysStyle.accent) }
                Text(title).fontWeight(.bold)
                Spacer(minLength: 0)
                Button { finish() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(XkeysStyle.secondary)
                    .accessibilityLabel("閉じる").disabled(access.busy)
            }
            ForEach(Array((finished ? saved : ready.map(\.file.name)).enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary).lineLimit(1)
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "minus.circle").font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
            }
            if let file = waiting.first, !finished {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(waiting.count > 1 ? "あと\(waiting.count)件、パスワードが必要です" : "あと1件、パスワードが必要です").fontWeight(.semibold)
                    Text(file.name + String(localized: " · 証明書")).font(.system(size: 12)).foregroundStyle(XkeysStyle.secondary)
                    HStack(spacing: 4) {
                        Group {
                            if showingPassword { TextField(".p12 のパスワード", text: $password) }
                            else { SecureField(".p12 のパスワード", text: $password) }
                        }.textFieldStyle(.plain).focused($passwordFocused).onSubmit(readPassword)
                        Button { showingPassword.toggle(); passwordFocused = true } label: { Image(systemName: showingPassword ? "eye.slash" : "eye") }
                            .buttonStyle(.plain).foregroundStyle(XkeysStyle.secondary)
                            .accessibilityLabel(showingPassword ? "パスワードを隠す" : "パスワードを表示")
                    }.padding(.horizontal, 10).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(error == nil ? XkeysStyle.accent : XkeysStyle.danger, lineWidth: 1.5))
                    HStack {
                        Spacer()
                        Button("飛ばす") { skipWaiting() }.buttonStyle(XkeysButtonStyle(compact: true))
                        Button("読み取る", action: readPassword).buttonStyle(XkeysButtonStyle(compact: true))
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(XkeysStyle.dangerText).fixedSize(horizontal: false, vertical: true) }
            if !reading && waiting.isEmpty {
                HStack {
                    Spacer()
                    if finished {
                        Button("閉じる") { finish() }.buttonStyle(XkeysButtonStyle(primary: true, compact: true))
                    } else if !ready.isEmpty {
                        Button { commit() } label: { Label("Touch ID で \(ready.count)件を追加", systemImage: "touchid") }
                            .buttonStyle(XkeysButtonStyle(primary: true, compact: true)).disabled(access.busy)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .font(.system(size: 13)).padding(16).frame(width: 380)
        .background(XkeysStyle.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(XkeysStyle.border))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        .task { await read() }
        .onChange(of: access.generation) { _, _ in finish() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in finish() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in finish() }
        .onDisappear { release() }
    }

    private var title: String {
        if reading { return String(localized: "読み取っています…") }
        if finished { return saved.isEmpty ? String(localized: "追加したファイルはありません") : String(localized: "\(saved.count)件を追加しました") }
        if !waiting.isEmpty { return String(localized: "\(ready.count + waiting.count)件を追加します") }
        return ready.isEmpty ? String(localized: "追加できるファイルはありません") : String(localized: "\(ready.count)件を追加します")
    }

    private func read() async {
        scoped = sources.filter { $0.startAccessingSecurityScopedResource() }
        do {
            let urls = try ImportSources.collect(sources)
            for url in urls {
                let file = try await Task.detached(priority: .userInitiated) { try CredentialFile(url: url) }.value
                let ext = (file.name as NSString).pathExtension.lowercased()
                if ext == "p8" { return fallback() }
                if file.requiresPasswordEntry { waiting.append(file); continue }
                let results = try await Task.detached(priority: .userInitiated) { try CredentialParser.parseAll(file.data, extension: ext) }.value
                guard results.count == 1, accept(file, parsed: results[0], password: nil) else { return fallback() }
            }
            reading = false
            passwordFocused = !waiting.isEmpty
        } catch {
            reading = false
            self.error = error.localizedDescription
        }
    }

    /// Adds a file that needs no choice. Returns false when the import sheet must ask something.
    private func accept(_ file: CredentialFile, parsed: ParsedCredential, password: String?) -> Bool {
        var destination: ManagedApp?
        if let bundle = parsed.bundleID {
            if let app { destination = app.target(forProfileBundleID: bundle) }
            else {
                let matches = team.apps.filter { $0.deletedAt == nil && CredentialVault.profileMatches(bundle, bundleID: $0.bundleID) }
                destination = matches.count == 1 ? matches[0] : nil
            }
            guard destination != nil else { return false }
        }
        do {
            try vault.validate(file: file, parsed: parsed, app: destination, team: team, confirmUnknownTeam: false, p8: nil)
            if let fingerprints = parsed.p12CertificateFingerprints {
                guard try vault.matchingP12Certificates(parsed, team: team).isEmpty,
                      !ready.contains(where: { $0.parsed.p12CertificateFingerprints == fingerprints }) else { return false }
            }
            ready.append(Item(file: file, parsed: parsed, app: destination, password: password))
            return true
        } catch VaultError.duplicate {
            notes.append(file.name + String(localized: " · 追加済みのため飛ばしました"))
            return true
        } catch { return false }
    }

    private func readPassword() {
        guard let file = waiting.first else { return }
        let input = password
        password = ""
        error = nil
        Task { @MainActor in
            do {
                let results = try await Task.detached(priority: .userInitiated) { try CredentialParser.parseAll(file.data, extension: "p12", password: input) }.value
                guard results.count == 1, accept(file, parsed: results[0], password: input) else { return fallback() }
                waiting.removeFirst()
                showingPassword = false
            } catch {
                self.error = String(localized: "パスワードが違います。大文字・小文字も区別されます。")
                passwordFocused = true
            }
        }
    }

    private func skipWaiting() {
        guard let file = waiting.first else { return }
        notes.append(file.name + String(localized: " · 飛ばしました"))
        waiting.removeFirst()
        password = ""
        error = nil
    }

    private func commit() {
        let items = ready
        error = nil
        Task { @MainActor in
            do {
                let canCreate = try vault.canCreateKey()
                try await access.withKey(reason: String(localized: "\(items.count)件の資格情報を暗号化して保存します"), allowCreation: canCreate, vault: vault) { key in
                    for item in items {
                        do {
                            lastSavedID = try vault.importFile(item.file, parsed: item.parsed, app: item.app, team: team, password: item.password,
                                                               confirmUnknownTeam: false, key: key)
                            saved.append(item.file.name)
                        } catch { notes.append(item.file.name + " · " + error.localizedDescription) }
                    }
                }
                ready = []
                finished = true
                release()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func fallback() {
        let urls = sources
        release()
        ready = []
        waiting = []
        openSheet(urls)
    }

    private func finish() {
        release()
        ready = []
        waiting = []
        password = ""
        access.lock()
        close(lastSavedID)
    }

    private func release() {
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        scoped = []
    }
}
