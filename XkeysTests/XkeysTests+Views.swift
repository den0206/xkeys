import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import Security
import XCTest
import XcodesLoginKit
@testable import Xkeys

/// Screens rendered with fixtures, the guide, install location and the clipboard.
extension XkeysTests {
    @MainActor
    func testCustomSecretEditorRendersEmptyAndPopulatedAtSupportedWindowSizes() async throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let key = SymmetricKey(size: .bits256)
        for state in ["empty", "adding", "populated"] {
            let populated = state == "populated"
            let secrets = populated ? [AppSecret(name: "HOTPEPPER_API_KEY", value: "fixture-only"),
                                       AppSecret(name: "SUPABASE_URL", value: "https://example.invalid")] : []
            try VaultManagement(vault: vault).saveCustomSecrets(secrets, app: app, key: key)
            for width in [960, 1232] {
                let screen = AppSecretEditor(vault: vault, app: app, startAdding: state == "adding", access: VaultAccess(keyProvider: { _, _ in key }))
                    .frame(width: CGFloat(width), height: 640).environment(\.colorScheme, .light)
                let view = NSHostingView(rootView: screen)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "custom-secrets-\(state)-\(width)"
                try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("xkeys-" + name + ".png"))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThan(png.count, 1000)
                window.close()
            }
        }
    }

    @MainActor
    func testCatalogRendersAtMinimumAndDefaultWindowSizes() async throws {
        let (vault, app, child, _) = try makeVault()
        let key = SymmetricKey(size: .bits256)
        let file = CredentialFile(data: try fixture("cer"), name: "sample.cer")
        _ = try vault.importFile(file, parsed: CredentialParser.parse(file.data, extension: "cer"), app: app, password: nil, confirmUnknownTeam: true, key: key)
        let identity = CredentialFile(data: try fixture("p12"), name: "sample.p12")
        _ = try vault.importFile(identity, parsed: CredentialParser.parse(identity.data, extension: "p12", password: "fixture-only"), app: app, password: nil, confirmUnknownTeam: false, key: key)
        let profile = CredentialFile(data: try fixture("mobileprovision", name: "certs"), name: "certs.mobileprovision")
        _ = try vault.importFile(profile, parsed: CredentialParser.parse(profile.data, extension: "mobileprovision"), app: app,
                                 password: nil, confirmUnknownTeam: false, key: key)
        let catalog = AppCatalog(context: vault.context)
        try catalog.setParent(nil, for: app, name: "Example App Store", platform: app.platform)
        try catalog.setParent(app.id, for: child, name: "Example Share App Store Extension", platform: child.platform)
        try VaultManagement(vault: vault).saveCustomSecrets([AppSecret(name: "HOTPEPPER_API_KEY", value: "fixture-only")], app: app, key: key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xkeys-sidebar-check", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screens: [(String, CredentialScope)] = [("all", .all), ("team", .team(try XCTUnwrap(app.team?.id))), ("app", .app(app.id)), ("target", .app(child.id))]
        for (screen, scope) in screens {
            let navigation = AppNavigation()
            navigation.scope = scope
            for size in [NSSize(width: 1280, height: 800), NSSize(width: 960, height: 640)] {
                let view = NSHostingView(rootView: CatalogView(container: vault.context.container, navigation: navigation).modelContainer(vault.context.container).preferredColorScheme(.dark))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                view.frame = NSRect(origin: .zero, size: size)
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(350))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("catalog-\(screen)-\(Int(size.width)).png"))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "catalog-\(screen)-\(Int(size.width))"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThan(png.count, 1000)
                window.close()
        }
        }
    }

    @MainActor
    func testDesignReferenceScreensRenderWithIsolatedFixtures() async throws {
        let (vault, app, _, _) = try makeVault()
        app.name = "Tsumiki"
        app.platform = "iOS"
        app.iconColor = "orange"
        let team = try XCTUnwrap(app.team)
        for other in try vault.context.fetch(FetchDescriptor<ManagedApp>()) where other.id != app.id { vault.context.delete(other) }
        for other in try vault.context.fetch(FetchDescriptor<DeveloperTeam>()) where other.id != team.id { vault.context.delete(other) }
        team.name = "個人開発"
        for (name, bundle) in [("Pocket Ledger", "com.example.ledger"), ("Hikari Notes", "com.example.hikari")] {
            let item = ManagedApp(name: name, bundleID: bundle, platform: "iOS", team: team)
            item.iconColor = name == "Pocket Ledger" ? "green" : "blue"
            vault.context.insert(item)
        }
        let calendar = Calendar(identifier: .gregorian)
        let expires = calendar.date(byAdding: .day, value: 12, to: .now)!
        var sample: StoredCredential?
        for (index, item) in [("App Store 配布用", "mobileprovision"), ("開発用", "mobileprovision"), ("配布用", "p12"), ("開発用", "cer"), ("App Store Connect の鍵", "p8"), ("プッシュ通知の鍵", "p8")].enumerated() {
            let file = CredentialFile(data: Data("design-fixture-\(index)".utf8), name: "sample-\(index)." + item.1)
            let record = StoredCredential(file: file, parsed: ParsedCredential(name: item.0, kind: item.1 == "p8" ? "鍵" : item.1 == "mobileprovision" ? "プロファイル" : "証明書", teamID: team.teamID, bundleID: item.1 == "mobileprovision" ? app.bundleID : nil, expiresAt: index >= 4 ? nil : index % 2 == 0 ? expires : calendar.date(byAdding: .year, value: 1, to: .now)), app: app, team: team, savePassword: item.1 == "p12")
            record.keyPurpose = index == 4 ? P8Purpose.appStoreConnect.rawValue : index == 5 ? P8Purpose.apns.rawValue : nil
            vault.context.insert(record)
            if index == 2 { sample = record }
        }
        try vault.context.save()
        let container = vault.context.container
        let navigation = AppNavigation()
        navigation.scope = .app(app.id)
        let importURL = vault.blobs.directory.appendingPathComponent("design-sample.p8")
        try FileManager.default.createDirectory(at: vault.blobs.directory, withIntermediateDirectories: true)
        try p8File().data.write(to: importURL)
        let trashed = StoredCredential(file: CredentialFile(data: Data("design-trash".utf8), name: "previous.cer"), parsed: ParsedCredential(name: "配布用（2024年発行）", kind: "証明書", teamID: team.teamID, bundleID: nil, expiresAt: nil), app: app, team: team, savePassword: false)
        trashed.deletedAt = .now.addingTimeInterval(-7 * 86400)
        vault.context.insert(trashed)
        try vault.context.save()
        let emptyTeam = DeveloperTeam(name: "未使用のチーム", teamID: "EMPTYTEAM1")
        vault.context.insert(emptyTeam)
        try vault.context.save()
        let loginTransport = FakeAppleDeveloperTransport()
        loginTransport.teams = [RemoteDeveloperTeam(teamID: team.teamID, name: team.name),
                                RemoteDeveloperTeam(teamID: "NEWTEAM001", name: "新しいチーム")]
        let loginSession = AppleDeveloperSession(store: MemoryAppleSessionStore(), makeTransport: { loginTransport }, observeLock: false)
        try await loginSession.login(account: "fixture@example.invalid", password: "fixture-only")
        loginTransport.remoteFiles = [RemoteDeveloperFile(id: "CERT001", kind: .certificates, name: "Apple Distribution", detail: "DISTRIBUTION", expiresAt: .now.addingTimeInterval(86400), platform: "IOS")]
        let onlineFile = CredentialFile(data: try fixture("cer"), name: "downloaded.cer")
        let screens: [(String, NSSize, AnyView)] = [
            ("online-import", NSSize(width: 640, height: 520), AnyView(AppleDeveloperImportView(team: team, vault: vault, session: loginSession, onSaved: { _ in }))),
            ("online-confirm", NSSize(width: 860, height: 640), AnyView(CredentialImportView(app: nil, team: team, vault: vault, initialFiles: [onlineFile], onSaved: { _ in }))),
            ("main", NSSize(width: 1232, height: 752), AnyView(CatalogView(container: container, navigation: navigation, appleSession: loginSession).modelContainer(container))),
            ("main-narrow", NSSize(width: 960, height: 640), AnyView(CatalogView(container: container, navigation: navigation, appleSession: loginSession).modelContainer(container))),
            ("settings", NSSize(width: 640, height: 592), AnyView(AppSettingsView(container: container))),
            ("settings-account", NSSize(width: 640, height: 592), AnyView(AppSettingsView(container: container, appleSession: loginSession, initialSection: "セキュリティ"))),
            ("welcome", NSSize(width: 760, height: 518), AnyView(OnboardingView(onFinished: { _ in }))),
            ("onboarding-how-it-works", NSSize(width: 760, height: 518), AnyView(OnboardingView(step: 1, onFinished: { _ in }))),
            ("onboarding-import", NSSize(width: 760, height: 518), AnyView(OnboardingView(step: 2, onFinished: { _ in }))),
            ("onboarding-security", NSSize(width: 760, height: 518), AnyView(OnboardingView(step: 3, onFinished: { _ in }))),
            ("move-to-applications", NSSize(width: 400, height: 520), AnyView(MoveToApplicationsView(location: .diskImage, onContinue: {}))),
            ("guide-tour-card", NSSize(width: 380, height: 260), AnyView(GuideTourCard(step: 2, onBack: {}, onNext: {}, onClose: {}, onGlossary: {}).padding(20))),
            ("guide-glossary", NSSize(width: 480, height: 540), AnyView(GuideGlossaryView())),
            ("renewal-guide", NSSize(width: 600, height: 640), AnyView(RenewalGuideView(expired: true, canImportOnline: true, done: .constant([0]), onAction: { _ in }))),
            ("add-app", NSSize(width: 560, height: 520), AnyView(RegistrationForm(container: container, teams: [team], initialTeam: team.id, isTeam: false, onSaved: { _ in }))),
            ("add-team", NSSize(width: 600, height: 540), AnyView(RegistrationForm(container: container, teams: [team], initialTeam: team.id, isTeam: true, onSaved: { _ in }))),
            ("edit-app-icon", NSSize(width: 490, height: 430), AnyView(CatalogEditor(vault: vault, team: nil, app: app))),
            ("team-management", NSSize(width: 600, height: 440), AnyView(TeamManagementView(vault: vault, appleSession: loginSession, onDeleted: { _ in }))),
            ("team-deletion-empty", NSSize(width: 490, height: 360), AnyView(TeamDeletionView(vault: vault, team: emptyTeam, onDeleted: {}))),
            ("team-deletion-blocked", NSSize(width: 490, height: 400), AnyView(TeamDeletionView(vault: vault, team: team, onDeleted: {}))),
            ("team-selection", NSSize(width: 540, height: 540), AnyView(AppleDeveloperLoginView(onTeam: { _ in }, session: loginSession))),
            ("backup", NSSize(width: 600, height: 620), AnyView(BackupView(container: container).modelContainer(container))),
            ("restore", NSSize(width: 640, height: 300), AnyView(BackupView(container: container, restoring: true))),
            ("ci-copy", NSSize(width: 560, height: 520), AnyView(CICopyView(vault: vault, record: try XCTUnwrap(sample)))),
            ("custom-secrets", NSSize(width: 640, height: 540), AnyView(AppSecretEditor(vault: vault, app: app, access: VaultAccess(keyProvider: { _, _ in SymmetricKey(size: .bits256) })))),
            ("ci-secret-file", NSSize(width: 640, height: 600), AnyView(CISecretFileView(vault: vault, app: app, records: try vault.records()))),
            ("import", NSSize(width: 680, height: 640), AnyView(CredentialImportView(app: app, team: team, vault: vault, onSaved: { _ in }))),
            ("p8-metadata", NSSize(width: 860, height: 640), AnyView(CredentialImportView(app: app, team: team, vault: vault, initialSources: [importURL], onSaved: { _ in }))),
            ("target-delete", NSSize(width: 548, height: 520), AnyView(TargetDeleteConfirmation(target: app, records: try vault.records(), onDelete: {}))),
            ("delete", NSSize(width: 460, height: 380), AnyView(CredentialDeleteConfirmation(record: try XCTUnwrap(sample), onDelete: {}))),
            ("trash", NSSize(width: 996, height: 700), AnyView(TrashView(vault: vault)))
        ]
        for (name, size, screen) in screens {
            let view = NSHostingView(rootView: screen.modelContainer(container).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("xkeys-" + name + ".png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(png.count, 1000, name)
            window.close()
        }
    }

    @MainActor
    func testSVGAppIconRendersAndPersistsInBackup() throws {
        let (vault, app, _, _) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault.blobs.directory) }
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" fill="red"/></svg>"#.utf8)
        let image = try XCTUnwrap(NSImage(data: svg))
        XCTAssertEqual(image.size, NSSize(width: 64, height: 64))
        XCTAssertNotNil(image.tiffRepresentation)
        try AppCatalog(context: vault.context).updateApp(app, name: app.name, platform: app.platform,
                                                       parentAppID: nil, iconColor: nil, iconImage: svg)
        let snapshot = try BackupSnapshot.capture(vault: vault, key: SymmetricKey(size: .bits256))
        let archive = try BackupArchive.encode(snapshot, password: nil)
        let decoded = try BackupArchive.decode(archive, password: nil)
        XCTAssertEqual(decoded.apps.first { $0.id == app.id }?.iconImage, svg)
    }

    @MainActor
    func testClipboardCleanupOnlyClearsOurUnchangedCopy() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); SecretClipboard.cleanup?.cancel() }
        try SecretClipboard.copy("fixture-secret", to: pasteboard)
        let count = pasteboard.changeCount
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        pasteboard.clearContents(); pasteboard.setString("new-user-copy", forType: .string)
        SecretClipboard.clear(pasteboard, ifUnchanged: count)
        XCTAssertEqual(pasteboard.string(forType: .string), "new-user-copy")
        try SecretClipboard.copy("fixture-secret", to: pasteboard)
        SecretClipboard.clear(pasteboard, ifUnchanged: pasteboard.changeCount)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testInstallLocationSuggestsMoveOnlyFromDiskImageOrTranslocation() {
        func location(_ path: String) -> InstallLocation { InstallLocation(bundleURL: URL(fileURLWithPath: path, isDirectory: true)) }
        XCTAssertEqual(location("/Volumes/Xkeys 1.0.0/Xkeys.app"), .diskImage)
        XCTAssertEqual(location("/private/var/folders/ab/cd/T/AppTranslocation/0123-4567/d/Xkeys.app"), .translocated)
        XCTAssertEqual(location("/Applications/Xkeys.app"), .applications)
        XCTAssertEqual(location("/Users/fixture/Applications/Xkeys.app"), .applications)
        XCTAssertEqual(location("/Volumes/External/Applications/Xkeys.app"), .applications)
        XCTAssertEqual(location("/Users/fixture/Library/Developer/Xcode/DerivedData/Xkeys/Build/Products/Debug/Xkeys.app"), .other)
        XCTAssertTrue(location("/Volumes/Xkeys 1.0.0/Xkeys.app").suggestsMove)
        XCTAssertTrue(location("/private/var/folders/ab/cd/T/AppTranslocation/0123/d/Xkeys.app").suggestsMove)
        XCTAssertFalse(location("/Applications/Xkeys.app").suggestsMove)
        XCTAssertFalse(location("/Users/fixture/Downloads/Xkeys.app").suggestsMove)
    }

    @MainActor
    func testGuideTourAndTermsHaveTextForEveryPlace() {
        XCTAssertEqual(GuideTour.steps.count, 5)
        XCTAssertTrue(GuideTour.steps.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        XCTAssertEqual(Set(GuideTerm.allCases.map(\.title)).count, GuideTerm.allCases.count)
        XCTAssertTrue(GuideTerm.allCases.allSatisfy { !$0.detail.isEmpty })
        XCTAssertEqual(CredentialGroup.allCases.map(\.guideTerm), [.profile, .certificate, .key])
    }

    @MainActor
    func testGuideModeIsKeptOutOfBackedUpPreferences() throws {
        let encoded = try JSONEncoder().encode(AppPreferences())
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["reuseAuthentication"])
        XCTAssertNotEqual(GuideMode.storageKey, OnboardingView.completedKey)
        XCTAssertNotEqual(GuideMode.storageKey, InstallLocation.skipKey)
    }

    @MainActor
    func testSidebarAppOrderMovesWithinTeamAndDropsMissingApps() {
        let team = DeveloperTeam(name: "Team", teamID: "TEAM000001")
        let apps = ["Alpha", "Beta", "Gamma"].map { ManagedApp(name: $0, bundleID: "com.example.\($0)", platform: "iOS", team: team) }
        let (a, b, c) = (apps[0].id, apps[1].id, apps[2].id)
        XCTAssertEqual(CatalogView.ordered(apps, order: "").map(\.name), ["Alpha", "Beta", "Gamma"])
        let other = UUID(), removed = UUID()
        let order = CatalogView.moving(c, to: 0, in: [a, b, c], order: [removed, other].map(\.uuidString).joined(separator: "\n"), existing: [a, b, c, other])
        XCTAssertEqual(order, [other, c, a, b].map(\.uuidString).joined(separator: "\n"))
        XCTAssertEqual(CatalogView.ordered(apps, order: order).map(\.name), ["Gamma", "Alpha", "Beta"])
        // Dropping onto a lower row takes that row's place.
        XCTAssertEqual(CatalogView.moving(a, to: 2, in: [a, b, c], order: "", existing: [a, b, c]), [b, c, a].map(\.uuidString).joined(separator: "\n"))
        XCTAssertEqual(CatalogView.moving(UUID(), to: 0, in: [a, b, c], order: "x", existing: [a, b, c]), "x")
    }

    func testPreferencesFromBeforeReuseSettingDecodeWithDefaults() throws {
        let legacy = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"showDockBadge":false}"#.utf8))
        XCTAssertEqual(legacy, AppPreferences())
        XCTAssertTrue(legacy.reuseAuthentication)
        let off = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"reuseAuthentication":false}"#.utf8))
        XCTAssertFalse(off.reuseAuthentication)
    }
}
